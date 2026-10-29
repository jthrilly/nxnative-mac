// Ports: an AI coding agent (Claude Code or Codex) attempts the port of a game nxnative has no profile for, following the repository's porting guide in a
// git worktree of its own. A run is unattended in the app (its JSONL output written raw to the run's transcript file on a background queue and folded
// into an AgentTranscript in batches; a time limit; a checkpoint commit afterwards) or interactive in Terminal (recorded, not tracked). Agents run side by
// side on different games, one per port, and never together with a conversion of the same game folder; a port's worktree has one user at a time
// (PortRules). Also the port's git operations (checkpoint, rebase, diff, removal)
import AppKit
import ConverterCore
import Foundation
import Observation

/// What the start sheet was opened for: a new port, or a further run of one
struct PortSheetRequest: Identifiable {
    let id = UUID()
    var titleID: String
    var gameName: String
    var folder: URL
    var continuing: Bool
    var interactive = false
    var lastLogs: URL?
    var lastError: String?
}

/// Why the ports store could not be read in full at launch, and where the file as it was is kept
struct PortsStoreNotice {
    let title: String
    let message: String
    let file: URL?
}

struct PortRunOptions {
    var kind: AgentKind
    var interactive: Bool
    var budgetUSD: Double?
    var timeLimitHours: Double
    var model: String
    var claudeSandbox: ClaudeSandbox
    var codexSandbox: CodexSandbox
    var ignoreUserConfig: Bool
    var instructions: String
}

struct DiffSheetItem: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}

private enum AgentChunk: Sendable {
    case events([AgentEvent], Date)
    case stderr(String, Date)
}

/// An agent run in progress (and, for a while, the ones that finished in this session: their transcripts hold the stderr lines and notes too)
@MainActor @Observable final class PortRun: Identifiable {
    let id: UUID                 // the AgentRunRecord's
    let titleID: String
    let gameName: String
    let folder: URL
    let kind: AgentKind
    let startedAt = Date()
    let transcriptFile: URL
    private(set) var phase = "Preparing…"
    private(set) var finished = false
    private(set) var stopRequested = false
    private(set) var leftOut: [SkippedFile] = []   // what its checkpoint did not take (too large, binary, a game or key file, a repository)
    // Mutated in place like ConversionJob's build state; revision tells the views
    @ObservationIgnored private var storage = AgentTranscript()
    private var revision = 0
    var transcript: AgentTranscript { _ = revision; return storage }
    @ObservationIgnored var process: Subprocess?
    @ObservationIgnored var timedOut = false

    init(id: UUID, titleID: String, gameName: String, folder: URL, kind: AgentKind, transcriptFile: URL) {
        self.id = id; self.titleID = titleID; self.gameName = gameName; self.folder = folder; self.kind = kind; self.transcriptFile = transcriptFile
    }

    var canStop: Bool { !finished && !stopRequested }

    func set(phase: String) { self.phase = phase }
    func requestStop() { stopRequested = true }
    func finish() { finished = true; process = nil }
    func checkpointed(leaving skipped: [SkippedFile]) { leftOut = skipped }

    func note(_ text: String) { storage.appendNote(text, at: Date()); revision += 1 }

    fileprivate func ingest(_ chunks: [AgentChunk]) {
        for chunk in chunks {
            switch chunk {
            case .events(let events, let date): storage.apply(events, at: date)
            case .stderr(let line, let date): storage.appendStderr(line, at: date)
            }
        }
        revision += 1
    }
}

/// Appends the agent's stdout lines to the raw transcript on a serial queue, so that the reader threads never wait on the disk and the main thread never writes
private final class TranscriptWriter: Sendable {
    private let queue = DispatchQueue(label: "org.nxnative.converter.transcript", qos: .utility)
    private let handle: FileHandle

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
    }

    func append(_ line: String) {
        queue.async { [handle] in try? handle.write(contentsOf: Data((line + "\n").utf8)) }
    }

    func close() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [handle] in
                try? handle.close()
                done.resume()
            }
        }
    }
}

extension AgentKind {
    var prerequisite: PrerequisiteID {
        switch self {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }
}

extension AppModel {
    // MARK: Derived state

    var selectedPort: PortRecord? { ports.first { $0.titleID == selectedPortID } }
    func port(_ titleID: String) -> PortRecord? { ports.first { $0.titleID == titleID } }
    /// The agent run in progress on a port (or on a title ID whose port has no record yet)
    func activeRun(_ titleID: String?) -> PortRun? { activePortRuns.first { $0.titleID == titleID } }
    func isActiveRun(_ id: UUID) -> Bool { activePortRuns.contains { $0.id == id } }
    func canStopPortRun(_ titleID: String?) -> Bool { activeRun(titleID)?.canStop ?? false }
    func isRunning(_ port: PortRecord) -> Bool { activeRun(port.titleID) != nil }

    /// What runs now, as far as this port is concerned: the agent is the one on this port, or on another port of the same game folder
    func situation(for port: PortRecord) -> PortSituation {
        let agent = activeRun(port.titleID) ?? activePortRuns.first { PortRules.samePath($0.folder.path, port.folder) }
        return PortSituation(agent: agent.map { (titleID: $0.titleID, name: $0.kind.displayName, game: $0.gameName) }, operation: portOperations[port.titleID],
                      conversion: activeJob.map { (name: $0.name, folder: $0.folder.path, repository: $0.repository?.path) },
                      terminalSession: terminalSessions.contains(port.titleID))
    }

    /// Why an agent run of this port cannot start now (an agent runs on it or its folder, something else uses its worktree, its folder is being converted),
    /// nil when it can
    func runBlock(_ port: PortRecord) -> PortBlock? { PortRules.runBlock(port, situation(for: port)) }
    func canStartRun(_ port: PortRecord) -> Bool { isReady && !isQuitting && runBlock(port) == nil }

    /// Why "Port with an Agent…" (or "Continue Port…") on a game cannot start now, nil when it can: its port's run block, or with no port yet, the app
    /// quitting or an agent preparing it
    func portBlockReason(titleID: String?) -> String? {
        if isQuitting { return "nxnative Converter is quitting." }
        if let port = titleID.flatMap(port) {
            if !isReady { return "The shell environment is not ready yet." }
            return runBlock(port)?.message
        }
        return activeRun(titleID).map { PortBlock.agentRunning(agent: $0.kind.displayName, game: $0.gameName).message }
    }

    /// A git operation on the port's worktree can run: no agent, other operation or conversion uses it
    func operationBlock(_ port: PortRecord) -> PortBlock? { PortRules.operationBlock(port, situation(for: port)) }
    func canOperateOnPort(_ port: PortRecord) -> Bool { isReady && !isQuitting && operationBlock(port) == nil }

    /// Build App can queue a conversion from the worktree: its agent and its worktree operations are not running
    func buildBlock(_ port: PortRecord) -> PortBlock? { PortRules.buildBlock(port, situation(for: port)) }
    func canBuildApp(_ port: PortRecord) -> Bool { isReady && !isQuitting && buildBlock(port) == nil }

    /// The agents the app runs, for the prerequisite check: a path set in Settings › Agents is checked even when nothing is there, so that it shows as missing
    var agentExecutables: [AgentKind: String] {
        var found: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            let configured = (settings.agentPath(kind).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if let exe = agentExecutable(kind) ?? (configured.isEmpty ? nil : configured) { found[kind] = exe }
        }
        return found
    }

    /// The ports whose newest interactive run still has its Terminal session open (checked when the app becomes active again)
    func refreshTerminalSessions() {
        var open: Set<String> = []
        for port in ports {
            guard let run = port.runs.last(where: { $0.interactive }) else { continue }
            let marker = PortRules.sessionMarker(runFolder: PortStore.runFolder(titleID: port.titleID), runID: run.id)
            if PortRules.sessionIsOpen(marker: marker, startedAt: run.startedAt) { open.insert(port.titleID) }
        }
        if open != terminalSessions { terminalSessions = open }
    }

    func agentCheck(_ kind: AgentKind) -> PrerequisiteCheck? { checks.first { $0.id == kind.prerequisite } }

    /// Settings › Agents path, else the agent on the login shell's PATH (or where its installer puts it)
    func agentExecutable(_ kind: AgentKind) -> String? {
        let fm = FileManager.default
        let configured = (settings.agentPath(kind).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !configured.isEmpty {
            if configured.contains("/") { return fm.isExecutableFile(atPath: configured) ? configured : nil }
            return environment?.which(configured)
        }
        if let found = environment?.which(kind.executableName) { return found }
        let local = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(kind.executableName)").path
        return fm.isExecutableFile(atPath: local) ? local : nil
    }

    func workspace(for port: PortRecord) -> PortWorkspace? {
        environment.map { PortWorkspace(repository: settings.repositoryURL, path: URL(fileURLWithPath: port.workspace), branch: port.branch, environment: $0) }
    }

    func liveRun(_ id: UUID?) -> PortRun? {
        guard let id else { return nil }
        return activePortRuns.first { $0.id == id } ?? finishedRuns.first { $0.id == id }
    }

    // MARK: Records

    func loadPorts() {
        do {
            let contents = try PortStore(fileURL: PortStore.defaultURL).read()
            ports = contents.records
            portsNotice = contents.notice.map { PortsStoreNotice(title: "Some of the ports could not be read", message: $0, file: contents.preserved) }
            if let notice = contents.notice { alert = AlertItem(title: "Some of the ports could not be read", message: notice) }
        } catch {
            portsNotice = PortsStoreNotice(title: "The ports could not be read", message: error.localizedDescription, file: nil)
            alert = AlertItem(title: "The ports could not be read", message: error.localizedDescription)
        }
        var interrupted = false
        for p in ports.indices {
            for r in ports[p].runs.indices where ports[p].runs[r].status == .running {
                ports[p].runs[r].status = .failed
                ports[p].runs[r].message = "Interrupted: nxnative Converter quit while this run was in progress."
                interrupted = true
            }
        }
        if interrupted { savePorts() }
        selectedPortID = ports.first?.titleID
        refreshTerminalSessions()
    }

    func savePorts() {
        do { try PortStore(fileURL: PortStore.defaultURL).save(ports) } catch {
            alert = AlertItem(title: "The ports could not be saved", message: error.localizedDescription)
        }
    }

    private func updatePort(_ titleID: String, _ change: (inout PortRecord) -> Void) {
        guard let i = ports.firstIndex(where: { $0.titleID == titleID }) else { return }
        change(&ports[i])
        savePorts()
    }

    private func updateRun(_ titleID: String, _ runID: UUID, _ change: (inout AgentRunRecord) -> Void) {
        updatePort(titleID) { port in
            if let r = port.runs.firstIndex(where: { $0.id == runID }) { change(&port.runs[r]) }
        }
    }

    func refreshPortStatus(_ titleID: String) async {
        guard let port = port(titleID), let ws = workspace(for: port) else { return }
        portStatuses[titleID] = await ws.status()
    }

    func refreshPortStatuses() async {
        refreshTerminalSessions()
        for port in ports { await refreshPortStatus(port.titleID) }
    }

    // MARK: Entry points

    /// "Port with an Agent…" on a job (a game with no profile, or a failed conversion)
    func offerPort(for job: ConversionJob) {
        guard let titleID = job.titleID else {
            alert = AlertItem(title: "The game's title ID is unknown", message: "A port needs the base game's title ID, which the folder's files did not show.")
            return
        }
        let logs = ConversionCommand.logsFolder(folder: job.folder, titleID: titleID)
        offerPort(titleID: titleID, gameName: job.name, folder: job.folder, lastLogs: logs, lastError: job.state == .failed ? job.message : nil)
    }

    /// "Port with an Agent…" on a failed conversion in the Library's history
    func offerPort(for record: ConversionRecord) {
        guard let titleID = record.titleID else { return }
        let folder = URL(fileURLWithPath: record.folder)
        offerPort(titleID: titleID, gameName: record.gameName, folder: folder, lastLogs: ConversionCommand.logsFolder(folder: folder, titleID: titleID), lastError: record.message)
    }

    /// "Port with an Agent…" on a game in the Convert sheet, which has closed: the start sheet opens once it is gone
    func offerPort(for game: PendingGame) {
        guard let titleID = game.scan.titleIDString else { return }
        let failed = newestRecord(folder: game.folder.path).flatMap { $0.status == .failed ? $0.message : nil }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            offerPort(titleID: titleID, gameName: game.scan.displayName, folder: game.folder,
                      lastLogs: ConversionCommand.logsFolder(folder: game.folder, titleID: titleID), lastError: failed)
        }
    }

    private func offerPort(titleID: String, gameName: String, folder: URL, lastLogs: URL, lastError: String?) {
        let logs = FileManager.default.fileExists(atPath: lastLogs.path) ? lastLogs : nil
        portSheet = PortSheetRequest(titleID: titleID, gameName: port(titleID)?.gameName ?? gameName, folder: folder, continuing: port(titleID) != nil,
                                     lastLogs: logs, lastError: lastError)
    }

    func continuePort(_ port: PortRecord, interactive: Bool = false) {
        guard canStartRun(port) else { return }
        portSheet = PortSheetRequest(titleID: port.titleID, gameName: port.gameName, folder: URL(fileURLWithPath: port.folder), continuing: true, interactive: interactive)
    }

    /// Ports › Open in Terminal: resumes the newest session interactively, or asks how to start one when there is none
    func openPortInTerminal(_ port: PortRecord) {
        guard canStartRun(port) else { return }
        let kind = port.runs.last?.kind ?? settings.defaultAgent
        guard port.lastSession(of: kind) != nil else { return continuePort(port, interactive: true) }
        let request = PortSheetRequest(titleID: port.titleID, gameName: port.gameName, folder: URL(fileURLWithPath: port.folder), continuing: true, interactive: true)
        startPort(request, options: PortRunOptions(kind: kind, interactive: true, budgetUSD: nil, timeLimitHours: settings.agentTimeLimitHours, model: settings.agentModel(kind),
                                                   claudeSandbox: settings.claudeSandbox, codexSandbox: settings.codexSandbox, ignoreUserConfig: settings.codexIgnoreUserConfig,
                                                   instructions: ""))
    }

    // MARK: A run

    func startPort(_ request: PortSheetRequest, options: PortRunOptions) {
        let fm = FileManager.default
        guard let env = environment, !isQuitting else { return }
        // a new port has no worktree yet: only an agent on its title ID or folder, an operation on its title ID or a conversion of its folder can be in the way
        let probe = port(request.titleID) ?? PortRecord(titleID: request.titleID, gameName: request.gameName, folder: request.folder.path, workspace: "", branch: "",
                                                        baseCommit: "", createdAt: Date())
        if let block = runBlock(probe) {
            alert = AlertItem(title: block.title, message: block.message)
            return
        }
        guard repository?.isNXNative == true, repository?.isGitRepository == true else {
            alert = AlertItem(title: "nxnative is not ready", message: "A port needs a git checkout of nxnative (it makes a worktree of it). Set it up on the nxnative page.")
            return
        }
        guard let keys = settings.keysURL, fm.fileExists(atPath: keys.path) else {
            alert = AlertItem(title: "The prod.keys file was not found", message: "Choose it on the Setup page: the agent passes its path to the repository's tools.")
            return
        }
        guard let executable = agentExecutable(options.kind) else {
            alert = AlertItem(title: "\(options.kind.displayName) was not found", message: "Install it on the Setup page (Agents), or set its path in Settings › Agents.")
            return
        }
        guard let guardCommand = Main.keysGuardCommand(keysFile: keys) else {
            alert = AlertItem(title: "The keys guard is not available", message: "nxnative Converter could not find its own executable for the hook that keeps the key file from the agent.")
            return
        }
        let runID = UUID()
        let runFolder = PortStore.runFolder(titleID: request.titleID)
        if options.interactive {
            portOperations[request.titleID] = "Preparing the worktree…"
            Task {
                await runInteractive(request, options: options, runID: runID, runFolder: runFolder, executable: executable, keys: keys, guardCommand: guardCommand, env: env)
                portOperations[request.titleID] = nil
            }
            return
        }
        let run = PortRun(id: runID, titleID: request.titleID, gameName: request.gameName, folder: request.folder, kind: options.kind,
                          transcriptFile: runFolder.appendingPathComponent("\(runID.uuidString).jsonl"))
        activePortRuns.append(run)
        selectedPortID = request.titleID
        selectedRunID = runID
        page = .ports
        portRunTasks[runID] = Task {
            await runUnattended(run, request, options: options, runFolder: runFolder, executable: executable, keys: keys, guardCommand: guardCommand, env: env)
            finishedRuns.insert(run, at: 0)
            if finishedRuns.count > 4 { finishedRuns.removeLast(finishedRuns.count - 4) }
            activePortRuns.removeAll { $0.id == runID }
            portRunTasks[runID] = nil
            startNextIfPossible()
        }
    }

    /// The worktree, the run's files and the request, shared by both modes
    private func prepare(_ request: PortSheetRequest, options: PortRunOptions, runID: UUID, runFolder: URL, executable: String, keys: URL, guardCommand: String,
                         env: ShellEnvironment) async throws -> (port: PortRecord, workspace: PortWorkspace, request: AgentRunRequest, promptFile: URL) {
        let fm = FileManager.default
        let titleID = request.titleID
        var port = self.port(titleID) ?? PortRecord(
            titleID: titleID, gameName: request.gameName, folder: request.folder.path,
            workspace: settings.portsFolderURL.appendingPathComponent(titleID, isDirectory: true).path, branch: PortWorkspace.branchName(titleID: titleID),
            baseCommit: "", createdAt: Date(), runs: [])
        let ws = PortWorkspace(repository: settings.repositoryURL, path: URL(fileURLWithPath: port.workspace), branch: port.branch, environment: env)
        try fm.createDirectory(at: ws.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ws.create(base: "HEAD")
        let status = await ws.status()
        if port.baseCommit.isEmpty { port.baseCommit = status.base ?? status.head?.sha ?? "" }
        portStatuses[titleID] = status
        if let i = ports.firstIndex(where: { $0.titleID == titleID }) { ports[i] = port } else { ports.append(port) }
        savePorts()

        try fm.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let schema = runFolder.appendingPathComponent("report-schema.json")
        let claudeSettings = runFolder.appendingPathComponent("claude-settings.json")
        let promptFile = runFolder.appendingPathComponent("\(runID.uuidString)-prompt.txt")
        try AgentReport.jsonSchema.write(to: schema, atomically: true, encoding: .utf8)
        // boot.sh through a launcher at a path with no spaces: an exemption whose path has a space never matches
        let launcher = PortStore.toolsFolder(titleID: titleID).appendingPathComponent("boot.sh")
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PortStore.bootLauncher(workFolder: ConversionCommand.workFolder(folder: request.folder, titleID: titleID)).write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let gameTools = KeysGuard.gameToolCommands(worktree: ws.path.path, bootLauncher: launcher.path)
        try KeysGuard.claudeSettings(guardCommand: guardCommand, keyFiles: [keys.path], sandbox: options.claudeSandbox, unsandboxed: gameTools)
            .write(to: claudeSettings, atomically: true, encoding: .utf8)

        let folder = request.folder
        let scan = await Task.detached { NSPScanner.scan(folder: folder) }.value
        let survey = ConversionCommand.surveyFile(folder: folder, titleID: titleID)
        let provisional = ConversionCommand.provisionalProfile(folder: folder, titleID: titleID)
        let logs = request.lastLogs ?? ConversionCommand.logsFolder(folder: folder, titleID: titleID)
        let continuing = request.continuing || !port.runs.isEmpty
        // the newest conversion's error, unless it is older than the last run: the agent may have fixed it since (an earlier failure is stale)
        let failure = PortRules.currentFailure(records, folder: folder.path, since: continuing ? port.runs.last?.startedAt : nil)
        let lastError = failure?.message ?? (records.contains { PortRules.samePath($0.folder, folder.path) } ? nil : request.lastError)
        let context = PortContext(
            titleID: titleID, gameName: port.gameName, versions: scan.versions, nspFolder: folder, keysFile: keys, workspace: ws.path, branch: port.branch,
            survey: fm.fileExists(atPath: survey.path) ? survey : nil,
            provisionalProfile: fm.fileExists(atPath: provisional.appendingPathComponent("game.tsv").path) ? provisional : nil,
            lastLogs: fm.fileExists(atPath: logs.path) ? logs : nil, lastError: lastError, lastErrorSource: failure.map(PortRules.failureSource), agent: options.kind,
            sandboxed: options.kind == .claudeCode && options.claudeSandbox == .sandboxed, bootLauncher: launcher)
        let instructions = options.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = continuing ? PortPrompt.continuation(context, previous: port.latestReport, instructions: instructions)
            : PortPrompt.initial(context, instructions: instructions)
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let resumeID = continuing ? port.lastSession(of: options.kind) : nil
        let sessionID: String
        switch options.kind {
        case .claudeCode: sessionID = resumeID ?? UUID().uuidString.lowercased()
        case .codex: sessionID = resumeID ?? ""
        }
        let agentRequest = AgentRunRequest(
            kind: options.kind, executable: executable, workspace: ws.path, extraDirectories: [folder], prompt: prompt, sessionID: sessionID,
            resume: resumeID != nil, model: options.model.trimmingCharacters(in: .whitespaces), budgetUSD: options.kind == .claudeCode ? options.budgetUSD : nil,
            reportSchema: schema, lastMessageFile: runFolder.appendingPathComponent("\(runID.uuidString)-last-message.txt"), claudeSettings: claudeSettings.path,
            claudeSandbox: options.claudeSandbox, codexSandbox: options.codexSandbox, codexIgnoreUserConfig: options.ignoreUserConfig)
        return (port, ws, agentRequest, promptFile)
    }

    private func newRunRecord(_ id: UUID, _ options: PortRunOptions, sessionID: String, status: AgentRunStatus, transcript: URL?) -> AgentRunRecord {
        AgentRunRecord(id: id, kind: options.kind, sessionID: sessionID, interactive: options.interactive, startedAt: Date(), finishedAt: nil, status: status,
                       usage: nil, turns: nil, report: nil, message: nil, checkpoint: nil, transcriptFile: transcript?.path,
                       instructions: options.instructions.trimmingCharacters(in: .whitespacesAndNewlines), model: options.model.trimmingCharacters(in: .whitespaces))
    }

    private func runInteractive(_ request: PortSheetRequest, options: PortRunOptions, runID: UUID, runFolder: URL, executable: String, keys: URL, guardCommand: String,
                                env: ShellEnvironment) async {
        let prepared: (port: PortRecord, workspace: PortWorkspace, request: AgentRunRequest, promptFile: URL)
        do { prepared = try await prepare(request, options: options, runID: runID, runFolder: runFolder, executable: executable, keys: keys, guardCommand: guardCommand, env: env) } catch {
            alert = AlertItem(title: "The port could not be prepared", message: error.localizedDescription)
            return
        }
        let line = AgentCommand.interactiveArguments(for: prepared.request, promptFile: prepared.promptFile)
        let file = runFolder.appendingPathComponent("\(runID.uuidString).command")
        let text = AppScripts.portSession(title: "nxnative Converter: \(options.kind.displayName) on the port of \(request.gameName)", line: line,
                                          marker: PortRules.sessionMarker(runFolder: runFolder, runID: runID))
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            alert = AlertItem(title: "The Terminal script could not be written", message: error.localizedDescription)
            return
        }
        updatePort(request.titleID) { $0.runs.append(newRunRecord(runID, options, sessionID: prepared.request.sessionID, status: .interactive, transcript: nil)) }
        terminalSessions.insert(request.titleID)   // until the app is active again and reads the session's marker
        selectedPortID = request.titleID
        selectedRunID = runID
        page = .ports
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    private func runUnattended(_ run: PortRun, _ request: PortSheetRequest, options: PortRunOptions, runFolder: URL, executable: String, keys: URL, guardCommand: String,
                               env: ShellEnvironment) async {
        let titleID = request.titleID, kind = options.kind
        run.set(phase: "Preparing the worktree…")
        let prepared: (port: PortRecord, workspace: PortWorkspace, request: AgentRunRequest, promptFile: URL)
        do { prepared = try await prepare(request, options: options, runID: run.id, runFolder: runFolder, executable: executable, keys: keys, guardCommand: guardCommand, env: env) } catch {
            run.note("The port could not be prepared: \(error.localizedDescription)")
            run.finish()
            alert = AlertItem(title: "The port could not be prepared", message: error.localizedDescription)
            return
        }
        let ws = prepared.workspace
        updatePort(titleID) { $0.runs.append(newRunRecord(run.id, options, sessionID: prepared.request.sessionID, status: .running, transcript: run.transcriptFile)) }
        let runNumber = (port(titleID)?.runs.count ?? 1)
        if run.stopRequested { return await conclude(run, ws, runNumber: runNumber, exit: nil, options: options) }

        let writer: TranscriptWriter
        do { writer = try TranscriptWriter(url: run.transcriptFile) } catch {
            run.note("The transcript file could not be opened: \(error.localizedDescription)")
            return await conclude(run, ws, runNumber: runNumber, exit: nil, options: options)
        }
        let batcher = Batcher<AgentChunk> { [weak run] chunks in run?.ingest(chunks) }
        let arguments = AgentCommand.arguments(for: prepared.request)
        let process = Subprocess(executable: executable, arguments: arguments, environment: AgentCommand.childEnvironment(env.variables, kind: kind),
                                 currentDirectory: ws.path)
        run.note("\(kind.displayName) in \(ws.path.path) (branch \(ws.branch))" + (prepared.request.resume ? ", resuming session \(prepared.request.sessionID)" : ""))
        do {
            try process.start { stream, line in
                switch stream {
                case .stdout:
                    writer.append(line)
                    let events = AgentEventDecoder.decode(line, kind: kind)
                    if !events.isEmpty { batcher.add(.events(events, Date())) }
                case .stderr:
                    batcher.add(.stderr(line, Date()))
                }
            }
        } catch {
            await writer.close()
            run.note("\(executable) could not be started: \(error.localizedDescription)")
            return await conclude(run, ws, runNumber: runNumber, exit: nil, options: options)
        }
        run.process = process
        if run.stopRequested { Task { await process.cancel() } }   // Stop while it was being spawned
        run.set(phase: "Running")
        let limit = options.timeLimitHours
        let timer = Task { [weak run] in
            guard limit > 0, (try? await Task.sleep(for: .seconds(limit * 3600))) != nil, let run, !run.finished, !run.stopRequested else { return }
            run.timedOut = true
            run.note("The time limit (\(Self.hours(limit))) is reached: stopping \(kind.displayName).")
            await process.cancel()
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "\(kind.displayName) is porting \(request.gameName)")
        let exit = await process.waitUntilExit()
        ProcessInfo.processInfo.endActivity(activity)
        timer.cancel()
        batcher.flush()
        await writer.close()
        run.process = nil
        await conclude(run, ws, runNumber: runNumber, exit: exit, options: options)
    }

    /// The run's status from how it ended, the checkpoint commit, the record, the notification
    private func conclude(_ run: PortRun, _ ws: PortWorkspace, runNumber: Int, exit: Int32?, options: PortRunOptions) async {
        let t = run.transcript, titleID = run.titleID, kind = run.kind
        var report = t.outcome?.report
        if report == nil, kind == .codex {
            let file = PortStore.runFolder(titleID: titleID).appendingPathComponent("\(run.id.uuidString)-last-message.txt")
            report = await Task.detached { (try? String(contentsOf: file, encoding: .utf8)).flatMap(AgentReport.parse) }.value
        }
        let status: AgentRunStatus
        var message: String?
        if run.timedOut {
            status = .timedOut; message = "Stopped at the time limit (\(Self.hours(options.timeLimitHours)))."
        } else if run.stopRequested {
            status = .cancelled; message = "Stopped."
        } else if let outcome = t.outcome, outcome.ok, exit == 0 {
            status = .succeeded
        } else {
            status = .failed
            let lastError = t.entries.last { $0.kind == .error }.map { $0.detail.isEmpty ? $0.title : $0.detail }
            var text = t.outcome?.error ?? lastError ?? exit.map { "\(kind.displayName) stopped with exit status \($0)." } ?? "\(kind.displayName) did not start."
            if kind == .codex, text.contains("model_not_found") || text.localizedCaseInsensitiveContains("model is not supported") {
                text += " Set a model your account can use, or turn on “Ignore my Codex settings”, in Settings › Agents."
            }
            if kind == .claudeCode, text.contains(Self.missingClaudeSession) { text += " Continue starts a new session." }
            message = text
        }
        if let message { run.note(message) }

        run.set(phase: "Saving a checkpoint…")
        var checkpoint: String?
        do {
            let result = try await ws.checkpoint(message: "Port \(titleID): \(kind.displayName) run \(runNumber) (\(report?.milestone.rawValue ?? status.rawValue))")
            checkpoint = result.commit
            run.note(result.commit.map { "Checkpoint \($0.prefix(9)) saved on \(ws.branch)." } ?? "Nothing changed in the worktree: no checkpoint.")
            run.checkpointed(leaving: result.skipped)
            if let leftOut = PortRules.leftOut(result.skipped) { run.note("Not in the checkpoint:\n" + leftOut) }
        } catch {
            run.note("The checkpoint could not be saved: \(error.localizedDescription)")
        }
        run.finish()

        let outcome = t.outcome
        updateRun(titleID, run.id) { r in
            r.finishedAt = Date(); r.status = status; r.usage = outcome?.usage; r.turns = outcome?.turns; r.report = report; r.message = message
            r.checkpoint = checkpoint
            if let session = t.sessionID, !session.isEmpty { r.sessionID = session }
        }
        // A session claude does not have (an interactive run whose Terminal was closed before it began) is not resumed again
        if kind == .claudeCode, message?.contains(Self.missingClaudeSession) == true, let dead = port(titleID)?.runs.first(where: { $0.id == run.id })?.sessionID, !dead.isEmpty {
            updatePort(titleID) { port in
                for i in port.runs.indices where port.runs[i].kind == .claudeCode && port.runs[i].sessionID == dead { port.runs[i].sessionID = "" }
            }
        }
        await refreshPortStatus(titleID)
        guard settings.notifyWhenDone else { return }
        switch status {
        case .succeeded, .timedOut:
            Notifier.post(title: "\(run.gameName): \(report?.milestone.title ?? (status == .timedOut ? "Time limit reached" : "Run finished"))",
                          body: report?.summary ?? message ?? "\(kind.displayName) has finished its run.")
        case .failed: Notifier.post(title: "\(run.gameName): the agent run failed", body: message ?? "See the transcript on the Ports page.")
        case .cancelled, .running, .interactive: break
        }
    }

    static let missingClaudeSession = "No conversation found with session ID"   // claude --resume of an id it has no session for (measured, 2.1.310)

    static func hours(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + " h" }

    func stopPortRun(_ titleID: String?) {
        guard let run = activeRun(titleID), run.canStop else { return }
        run.requestStop()
        run.note("Stopping…")
        if let process = run.process { Task { await process.cancel() } }
    }

    /// Before quitting: stop the agents and wait for their runs to end, checkpoints included (at most ~45 s, all of them together)
    func stopPortForQuit() async {
        let runs = activePortRuns, tasks = Array(portRunTasks.values)
        guard !runs.isEmpty else { return }
        for run in runs { run.requestStop() }
        let processes = runs.compactMap(\.process)
        if !processes.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withTaskGroup(of: Void.self) { all in
                        for process in processes { all.addTask { await process.cancel(grace: 5) } }
                    }
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)) }
                await group.next()
                group.cancelAll()
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { await task.value } }
            group.addTask { try? await Task.sleep(for: .seconds(30)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: The worktree

    private func operateOnPort(_ port: PortRecord, _ title: String, _ body: @MainActor (PortWorkspace) async throws -> Void) async {
        guard isReady, !isQuitting, let ws = workspace(for: port) else { return }
        if let block = operationBlock(port) {
            alert = AlertItem(title: block.title, message: block.message)
            return
        }
        portOperations[port.titleID] = title
        do { try await body(ws) } catch {
            alert = AlertItem(title: "\(title.replacingOccurrences(of: "…", with: "")) failed", message: error.localizedDescription)
        }
        portOperations[port.titleID] = nil
        await refreshPortStatus(port.titleID)
    }

    func showChanges(_ port: PortRecord) async {
        guard let ws = workspace(for: port), portOperations[port.titleID] == nil else { return }
        portOperations[port.titleID] = "Reading the changes…"
        do {
            let text = try await ws.diff()
            diffSheet = DiffSheetItem(title: "Changes on \(port.branch)", text: text)
        } catch {
            alert = AlertItem(title: "The changes could not be read", message: error.localizedDescription)
        }
        portOperations[port.titleID] = nil
    }

    func saveCheckpoint(_ port: PortRecord) async {
        await operateOnPort(port, "Saving a checkpoint…") { ws in
            let result = try await ws.checkpoint(message: "Port \(port.titleID): checkpoint")
            var text = result.commit.map { "Commit \($0.prefix(9)) on \(port.branch) holds the worktree's changes." } ?? "The worktree has no changes since the last checkpoint."
            if let leftOut = PortRules.leftOut(result.skipped) { text += "\n\nLeft out:\n" + leftOut }
            alert = AlertItem(title: result.commit == nil ? "Nothing to Save" : "Checkpoint Saved", message: text)
        }
    }

    /// Rebase onto nxnative: the port's branch moves onto the checkout's HEAD (after a checkpoint); a conflict leaves it as it was
    func rebasePort(_ port: PortRecord) async {
        guard let git = gitRepository else { return }
        await operateOnPort(port, "Rebasing onto nxnative…") { ws in
            let head = try await git.version().commit
            _ = try await ws.checkpoint(message: "Port \(port.titleID): checkpoint before rebase")
            switch try await ws.rebase(onto: head) {
            case .upToDate:
                alert = AlertItem(title: "Already Up to Date", message: "\(port.branch) already contains nxnative \(head.prefix(9)).")
            case .rebased(let newHead):
                updatePort(port.titleID) { $0.baseCommit = head }
                alert = AlertItem(title: "Rebased", message: "\(port.branch) is now on nxnative \(head.prefix(9)) (its head: \(newHead.prefix(9))).")
            case .conflicts(let files):
                alert = AlertItem(title: "The Rebase Has Conflicts",
                                  message: "It was undone; \(port.branch) is as it was. These files conflict with nxnative \(head.prefix(9)):\n" + files.joined(separator: "\n")
                                    + "\n\nContinue the port with instructions to rebase it and resolve them, or resolve them in Terminal.")
            }
        }
    }

    /// Build App: a conversion of the port's folder with the worktree's script and profiles
    func buildApp(_ port: PortRecord) {
        let folder = URL(fileURLWithPath: port.folder), worktree = URL(fileURLWithPath: port.workspace)
        if let block = buildBlock(port) {
            alert = AlertItem(title: block.title, message: block.message)
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            alert = AlertItem(title: "The game folder is gone", message: "\(port.folder) no longer exists.")
            return
        }
        guard FileManager.default.fileExists(atPath: ConversionCommand.script(in: worktree).path) else {
            alert = AlertItem(title: "The worktree is missing", message: "\(port.workspace) has no scripts/build_ipa_from_nsp.py. Continue the port to make it again.")
            return
        }
        addFolders([folder], repository: worktree)
    }

    /// Removes the worktree and its branch, the record, and moves the run files (transcripts, prompts) to the Trash
    func removePort(_ port: PortRecord) async {
        await operateOnPort(port, "Removing the port…") { ws in
            try await ws.remove()
            ports.removeAll { $0.titleID == port.titleID }
            portStatuses[port.titleID] = nil
            savePorts()
            if selectedPortID == port.titleID { selectedPortID = ports.first?.titleID; selectedRunID = nil }
            let runs = PortStore.runFolder(titleID: port.titleID)
            if FileManager.default.fileExists(atPath: runs.path) { try FileManager.default.trashItem(at: runs, resultingItemURL: nil) }
        }
    }

    /// The transcript of a run that is not in memory, read back from its raw JSONL file (stderr lines and the app's notes are not in it)
    nonisolated static func loadTranscript(file: URL, kind: AgentKind, date: Date) async -> AgentTranscript? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            var transcript = AgentTranscript()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let events = AgentEventDecoder.decode(String(line), kind: kind)
                if !events.isEmpty { transcript.apply(events, at: date) }
            }
            return transcript
        }.value
    }
}
