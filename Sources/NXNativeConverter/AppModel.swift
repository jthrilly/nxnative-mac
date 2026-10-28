// AppModel: the app's state (settings, the login shell's environment, the nxnative checkout, prerequisite checks, the conversion queue, the library of
// what was built, the ports agents attempt) and the operations on it. One conversion runs at a time, and never together with a git operation or a Setup
// fix (both use the console); one agent run at a time, and never together with a conversion of the same game folder (PortRules). The launch-time fetch runs
// in the background and gives way to any git operation; quitting holds the queue and waits for what must not stop halfway (an install)
import AppKit
import ConverterCore
import Foundation
import Observation

enum Page: String, CaseIterable, Identifiable, Hashable {
    case convert, library, ports, repository, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .library: return "Library"
        case .ports: return "Ports"
        case .repository: return "nxnative"
        case .setup: return "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.down.app"
        case .library: return "square.grid.2x2"
        case .ports: return "hammer"
        case .repository: return "arrow.triangle.branch"
        case .setup: return "checklist"
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct LibraryEntry: Identifiable {
    var app: InstalledGameApp          // a game prepared as an Xcode project: the project, as its record names it (InstalledGameApp(xcodeProjectOf:))
    var record: ConversionRecord?      // the newest record of this app (by path, else by title ID)
    var xcodeWorkspace: URL? = nil     // the workspace an Xcode project is a scheme of; nil for a Mac app
    var id: URL { app.id }
    var isXcodeProject: Bool { xcodeWorkspace != nil }
    var commit: String? { app.nxnativeCommit ?? record?.nxnative?.commit }
    var commitDate: Date? { app.nxnativeCommitDate ?? record?.nxnative?.commitDate }
    var modified: Bool { app.nxnativeModified ?? record?.nxnative?.modified ?? false }
}

@MainActor @Observable final class AppModel {
    let settings = AppSettings()
    let console = ConsoleModel()
    var page: Page? = .convert
    private(set) var environment: ShellEnvironment?
    private(set) var profiles: [GameProfile] = []
    private(set) var repository: RepositoryStatus?
    private(set) var refreshingRepository = false
    private(set) var checks: [PrerequisiteCheck] = []
    private(set) var checking = false
    private(set) var jobs: [ConversionJob] = []
    var selectedJobID: UUID?
    private(set) var records: [ConversionRecord] = []
    private(set) var library: [LibraryEntry] = []
    private(set) var commitsBehind: [String: Int] = [:]   // nxnative commit a game was built with → commits from it to HEAD
    private(set) var pullBlockedByLocalChanges = false
    private(set) var lastGitError: String?
    private(set) var fetchingInBackground = false   // the launch-time fetch: it does not hold the console, and any git operation stops it first
    private(set) var isQuitting = false             // from the quit prompt on: nothing new starts
    var alert: AlertItem?
    var libraryNotice: String?                      // why some of the conversion history could not be read: the Library shows it until dismissed
    var portsNotice: PortsStoreNotice?              // the same for the ports, with the file kept as it was: the Ports page shows it until dismissed
    // Ports (PortRunner): set from its file too, hence not private(set)
    var ports: [PortRecord] = []
    var portStatuses: [String: PortWorkspaceStatus] = [:]   // by title ID
    var selectedPortID: String?
    var selectedRunID: UUID?
    var activePortRun: PortRun?
    var finishedRuns: [PortRun] = []                         // the last few runs of this session, newest first
    var portOperations: [String: String] = [:]                // title ID → the git operation running on its worktree
    var portSheet: PortSheetRequest?
    var diffSheet: DiffSheetItem?
    var settingsSheet: LibraryEntry?   // Game Settings of a game app
    var portToRemove: PortRecord?                            // Remove Port… asks first
    var terminalSessions: Set<String> = []                   // title IDs of the ports with an agent session open in Terminal
    @ObservationIgnored var portRunTask: Task<Void, Never>?
    @ObservationIgnored private var installedApps: [InstalledGameApp] = []
    @ObservationIgnored private var preparedProjects: Set<String> = []   // the Xcode projects and workspaces of the records that exist
    @ObservationIgnored private var launched = false
    @ObservationIgnored var recheckWhenActive = false   // a fix runs in Terminal: check again when the user comes back
    @ObservationIgnored private var backgroundFetch: Task<Void, Never>?
    @ObservationIgnored private let rechecks = LatestRun()

    init() {
        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        do {
            let contents = try LibraryStore(fileURL: LibraryStore.defaultURL).read()
            records = contents.records
            libraryNotice = contents.notice
            if let notice = contents.notice { alert = AlertItem(title: "Some of the conversion history could not be read", message: notice) }
        } catch {
            libraryNotice = error.localizedDescription
            alert = AlertItem(title: "The conversion history could not be read", message: error.localizedDescription)
        }
        loadPorts()
    }

    // MARK: Derived state

    var activeJob: ConversionJob? { jobs.first { $0.state.isActive } }
    var isConverting: Bool { activeJob != nil }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    var selectedJob: ConversionJob? { jobs.first { $0.id == selectedJobID } }
    var isReady: Bool { environment != nil }
    var canOperate: Bool { isReady && !isQuitting && !isConverting && !console.isRunning }   // git operations and fixes
    var failedRequiredChecks: Int { checks.filter { $0.required && $0.state == .missing }.count }
    var incomingCount: Int { repository?.behind ?? 0 }
    var canStartAny: Bool { jobs.contains { canStart($0) } }

    func canStart(_ job: ConversionJob) -> Bool { job.state == .queued && startBlockReason(job) == nil }

    /// Why a queued job cannot start now, nil when it can
    func startBlockReason(_ job: ConversionJob) -> String? {
        if !isReady { return "The shell environment is not ready yet." }
        if isQuitting { return "nxnative Converter is quitting." }
        if let active = activeJob { return "\(active.name) is being converted: one conversion runs at a time." }
        if let title = console.title { return "\u{201C}\(title)\u{201D} is running: conversions wait until it has finished." }
        if let run = activePortRun, run.folder.path == job.folder.path { return "\(run.kind.displayName) is porting this game folder." }
        if let repo = job.repository, let port = ports.first(where: { PortRules.samePath($0.workspace, repo.path) }),
           let block = PortRules.buildBlock(port, situation(for: port)) { return block.message }
        return nil
    }

    var pythonExecutable: String? {
        let p = settings.pythonPath.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { return p.contains("/") ? (p as NSString).expandingTildeInPath : environment?.which(p) }
        return environment?.which("python3")
    }

    var gitRepository: GitRepository? { environment.map { GitRepository(path: settings.repositoryURL, environment: $0) } }

    // MARK: Launch

    func launch() {
        guard !launched else { return }
        launched = true
        Task {
            environment = await ShellEnvironment.resolve()
            await reloadProfiles()
            await refreshRepository()
            async let checked: Void = recheck()
            async let scanned: Void = refreshLibrary()
            _ = await (checked, scanned)
            if settings.checkForUpdatesAtLaunch, repository?.isGitRepository == true, repository?.upstream != nil { fetchInBackground() }
            startNextIfPossible()
        }
    }

    private func settingChanged(_ key: AppSettings.Key) {
        guard launched, isReady else { return }
        switch key {
        case .repositoryPath:
            pullBlockedByLocalChanges = false; lastGitError = nil
            Task { await reloadProfiles(); await refreshRepository(); await recheck() }
        case .keysPath: Task { await recheck() }
        case .pythonPath, .claudePath, .codexPath: scheduleRecheck(after: .milliseconds(600))   // typed: once the typing stops
        case .installDirectory: Task { await refreshLibrary() }
        case .startAutomatically: startNextIfPossible()
        default: break
        }
    }

    func reloadProfiles() async {
        let repo = settings.repositoryURL
        profiles = await Task.detached { GameProfiles.load(repository: repo) }.value
    }

    // MARK: Queue

    func chooseGameFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Game Folder"
        panel.message = "Choose a folder with a game's NSP, XCI, NSZ or XCZ files (the base game, and any update and DLC)."
        panel.prompt = "Add"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    /// Folders, game files or folders of game folders (dropped, opened with the app, chosen) → one queued job per game folder
    /// With a repository (a port's worktree), the jobs run its script and match the game against its profiles
    func addFolders(_ urls: [URL], options: ConversionOptions? = nil, repository: URL? = nil) {
        page = .convert
        let folders = NSPScanner.gameFolders(from: urls)
        guard !folders.isEmpty else {
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            alert = AlertItem(title: "No game files found",
                              message: "\(names) holds no .nsp, .xci, .nsz or .xcz files, and no folders with them. Drop one folder per game: the base game's file, plus any update and DLC.")
            return
        }
        Task {
            var firstNew: UUID?
            for folder in folders {
                if let existing = jobs.first(where: { $0.folder == folder && !$0.state.isFinished }) {
                    switch QueueRules.reuse(existing: existing.repository, active: existing.state.isActive, requested: repository) {
                    case .keep: break
                    case .switchTo(let repo): existing.use(repository: repo, profiles: await profiles(of: repo))
                    case .busy:
                        alert = AlertItem(title: "\(existing.name) is being converted",
                                          message: "A conversion of its folder is running from \(existing.repository == nil ? "the nxnative folder" : "another worktree"). Add it again when that has finished.")
                    }
                    if let options, existing.isEditable { existing.options = options }
                    firstNew = firstNew ?? existing.id
                    continue
                }
                let scan = await Task.detached { NSPScanner.scan(folder: folder) }.value
                let known = await profiles(of: repository)
                var opts = options ?? ConversionOptions()
                if options == nil { opts.language = settings.defaultLanguage; opts.output = settings.defaultOutput }
                let job = ConversionJob(folder: folder, scan: scan, profiles: known, options: opts, repository: repository)
                jobs.append(job)
                firstNew = firstNew ?? job.id
            }
            if let firstNew { selectedJobID = firstNew }
            startNextIfPossible()
        }
    }

    /// The profiles a job built from this repository matches against: the nxnative folder's, or a port worktree's
    private func profiles(of repository: URL?) async -> [GameProfile] {
        guard let repository else {
            if profiles.isEmpty { await reloadProfiles() }
            return profiles
        }
        return await Task.detached { GameProfiles.load(repository: repository) }.value
    }

    func startNextIfPossible() {
        guard settings.startAutomatically, let next = jobs.first(where: { canStart($0) }) else { return }
        start(next)
    }

    func start(_ job: ConversionJob) {
        guard canStart(job) else { return }
        job.begin()   // preparing from here on: nothing else starts meanwhile
        Task {
            await run(job)
            startNextIfPossible()
        }
    }

    /// Conversion › Start: the selected job when it can start, else the first that can
    func startSelectedOrNext() {
        if let job = selectedJob, canStart(job) { start(job); return }
        if let job = jobs.first(where: { canStart($0) }) { selectedJobID = job.id; start(job) }
    }

    func cancel(_ job: ConversionJob) {
        guard job.state == .preparing || job.state == .running, !job.cancelRequested else { return }
        job.requestCancel()
        job.note("Cancelling…")
        if let process = job.process { Task { await process.cancel() } }
    }

    func cancelCurrent() { if let activeJob { cancel(activeJob) } }

    var canCancelCurrent: Bool { activeJob.map { ($0.state == .preparing || $0.state == .running) && !$0.cancelRequested } ?? false }

    func retry(_ job: ConversionJob) {
        job.requeue()
        if canStart(job) { start(job) }
    }

    /// Survey Only (a game with no profile): the script surveys the game and writes the provisional profile, and the job ends there
    func survey(_ job: ConversionJob) {
        guard job.canSurvey else { return }
        if job.state.isFinished { job.requeue() }
        job.options.surveyOnly = true
        if canStart(job) { start(job) }
    }

    /// A full conversion of a job that ran the survey only
    func convert(_ job: ConversionJob) {
        if job.state.isFinished { job.requeue() }
        job.options.surveyOnly = false
        if canStart(job) { start(job) }
    }

    func remove(_ job: ConversionJob) {
        guard !job.state.isActive else { return }
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { selectedJobID = jobs.first?.id }
    }

    func removeFinished() {
        jobs.removeAll { $0.state.isFinished }
        if selectedJob == nil { selectedJobID = jobs.first?.id }
    }

    /// From the quit prompt on, nothing new starts; cancelQuit() lets the queue go on when the user stays
    func beginQuit() { isQuitting = true }

    func cancelQuit() {
        isQuitting = false
        startNextIfPossible()
    }

    /// Before quitting: stop the git operation or fix (at most 30 s), the agent run (it saves its checkpoint first) and the conversion (its process at most
    /// ~15 s), wait for an install to finish (at most 30 min: it is copying the app) and for the port's worktree operations (at most 60 s)
    func stopForQuit() async {
        isQuitting = true
        await stopBackgroundFetch()
        await console.stopAndWait(timeout: .seconds(30))
        await stopPortForQuit()
        let clock = ContinuousClock()
        if let job = activeJob {
            if job.state != .installing {
                job.requestCancel()
                if let process = job.process {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await process.cancel(grace: 5) }
                        group.addTask { try? await Task.sleep(for: .seconds(15)) }
                        await group.next()
                        group.cancelAll()
                    }
                }
            }
            let start = clock.now
            while !job.state.isFinished, clock.now - start < (job.state == .installing ? .seconds(1800) : .seconds(2)) { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let start = clock.now
        while !portOperations.isEmpty, clock.now - start < .seconds(60) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Library

    func refreshLibrary() async {
        let fm = FileManager.default
        var dirs = [settings.installDirectoryURL] + AppInstaller.standardDestinations()
        for r in records { for p in [r.installedAppPath, r.builtAppPath].compactMap({ $0 }) { dirs.append(URL(fileURLWithPath: p).deletingLastPathComponent()) } }
        var seen = Set<String>()
        dirs = dirs.filter { seen.insert($0.standardizedFileURL.path).inserted && fm.fileExists(atPath: $0.path) }
        let scanDirs = dirs
        installedApps = await Task.detached { InstalledAppScanner.scan(directories: scanDirs) }.value
        let prepared = Set(records.flatMap { [$0.xcodeProjectPath, $0.xcodeWorkspacePath].compactMap { $0 } })
        preparedProjects = await Task.detached { prepared.filter { FileManager.default.fileExists(atPath: $0) } }.value
        rebuildLibrary()
        await refreshCommitsBehind()
    }

    private func rebuildLibrary() {
        func resolved(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        let apps = installedApps.map { app in
            let path = app.url.resolvingSymlinksInPath().path
            let byPath = records.last { resolved($0.installedAppPath) == path || resolved($0.builtAppPath) == path }
            return LibraryEntry(app: app, record: byPath ?? records.last { $0.status == .succeeded && $0.titleID == app.titleID && $0.options.output == .macApp })
        }
        // A game prepared as an Xcode project, once per project (its newest record), while the project and its workspace are there
        var projects: [LibraryEntry] = []
        for record in records.reversed() {
            guard let project = InstalledGameApp(xcodeProjectOf: record), let workspace = record.xcodeWorkspacePath,
                  preparedProjects.contains(project.url.path), preparedProjects.contains(workspace), !projects.contains(where: { $0.id == project.id }) else { continue }
            projects.append(LibraryEntry(app: project, record: record, xcodeWorkspace: URL(fileURLWithPath: workspace, isDirectory: true)))
        }
        library = (apps + projects).sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? !$0.isXcodeProject && $1.isXcodeProject : order == .orderedAscending
        }
    }

    private func refreshCommitsBehind() async {
        guard let git = gitRepository, repository?.head != nil else { commitsBehind = [:]; return }
        let commits = Set(library.compactMap(\.commit) + records.compactMap { $0.nxnative?.commit })
        var counts: [String: Int] = [:]
        for c in commits { if let n = await git.commitCount(from: c) { counts[c] = n } }
        commitsBehind = counts
    }

    func appendRecord(_ record: ConversionRecord) {
        records.append(record)
        saveLibrary()
    }

    func removeRecords(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        saveLibrary()
        rebuildLibrary()
    }

    private func saveLibrary() {
        do { try LibraryStore(fileURL: LibraryStore.defaultURL).save(records) } catch {
            alert = AlertItem(title: "The conversion history could not be saved", message: error.localizedDescription)
        }
    }

    /// Library › Rebuild: the record's folder again, with its options, built by the current nxnative
    func rebuild(_ record: ConversionRecord) {
        let folder = URL(fileURLWithPath: record.folder)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            alert = AlertItem(title: "The game folder is gone", message: "\(record.folder) no longer exists. Drop the game's folder on the window to convert it again.")
            return
        }
        var options = record.options
        options.surveyOnly = false
        var repository: URL?
        if let titleID = PortRules.titleID(fromBranch: record.nxnative?.branch) {   // built by Build App: again from the port's worktree
            let worktree = port(titleID).map { URL(fileURLWithPath: $0.workspace) }
            if let worktree, FileManager.default.fileExists(atPath: ConversionCommand.script(in: worktree).path) {
                repository = worktree
            } else if !profiles.contains(where: { $0.titleID == UInt64(titleID, radix: 16) }) {
                alert = AlertItem(title: "\(record.gameName) was built from its port",
                                  message: "It was built from the branch \(record.nxnative?.branch ?? titleID), whose worktree is gone, and the nxnative folder has no profile for it. "
                                    + "Converting it from there would replace the app with a provisional build that may not boot. Bring the port into nxnative first, or continue the port.")
                return
            }
        }
        addFolders([folder], options: options, repository: repository)
    }

    func newestRecord(folder: String) -> ConversionRecord? { records.last { $0.folder == folder } }

    // MARK: Repository

    func refreshRepository() async {
        guard let git = gitRepository else { return }
        refreshingRepository = true
        repository = await git.status()
        refreshingRepository = false
    }

    /// Runs a git operation or a fix with the console as its output; nothing else of the kind (and no conversion) runs meanwhile. Stop cancels work (and the
    /// command it runs); then, which refreshes what work changed, runs either way. The launch-time fetch is stopped first
    func operate(_ title: String, startNext: Bool = true, _ work: @escaping @MainActor () async -> Void, then: @MainActor () async -> Void = {}) async {
        guard canOperate else { return }
        await stopBackgroundFetch()
        guard canOperate else { return }
        console.begin(title)
        let task = Task { @MainActor in await work() }
        console.attach(task)
        await task.value
        console.detach()
        await then()
        console.end()
        if startNext { startNextIfPossible() }
    }

    /// The launch-time fetch, in the background: conversions start meanwhile, and a git operation cancels it
    private func fetchInBackground() {
        guard let git = gitRepository, backgroundFetch == nil else { return }
        fetchingInBackground = true
        backgroundFetch = Task { [weak self] in
            var failure: String?
            do { try await git.fetch() } catch { failure = Task.isCancelled ? nil : error.localizedDescription }
            let cancelled = Task.isCancelled
            guard let self else { return }
            self.backgroundFetch = nil; self.fetchingInBackground = false
            guard !cancelled else { return }
            self.lastGitError = failure
            await self.refreshRepository()
        }
    }

    private func stopBackgroundFetch() async {
        guard let task = backgroundFetch else { return }
        task.cancel()
        await task.value
    }

    func checkForUpdates() async {
        guard let git = gitRepository else { return }
        await operate("Checking for updates", { [self] in
            console.append("$ git fetch", .command)
            do {
                try await git.fetch(); lastGitError = nil
                console.append("Fetched.", .note)
            } catch {
                gitFailed(error)
            }
        }, then: { [self] in
            await refreshRepository()
            if let n = repository?.behind { console.append(n == 0 ? "nxnative is up to date." : "\(n) new commit\(n == 1 ? "" : "s").", .note) }
        })
    }

    func update() async {
        guard let git = gitRepository else { return }
        await operate("Updating nxnative", { [self] in
            console.append("$ git pull --ff-only", .command)
            do {
                let (old, new) = try await git.pullFastForward()
                pullBlockedByLocalChanges = false; lastGitError = nil
                console.append(old == new ? "Already up to date." : "Updated \(old.prefix(9)) → \(new.prefix(9)).", .note)
            } catch {
                gitFailed(error)
                if !Task.isCancelled { pullBlockedByLocalChanges = RepositoryAdvice.pullBlockedByLocalChanges(error: error.localizedDescription) }
            }
        }, then: { [self] in await afterUpdate() })
    }

    func discardLocalChangesAndUpdate() async {
        guard let git = gitRepository else { return }
        await operate("Discarding local changes", { [self] in
            console.append("$ git reset --hard @{u}", .command)
            do {
                try await git.resetHardToUpstream()
                pullBlockedByLocalChanges = false; lastGitError = nil
                console.append("The checkout now matches \(repository?.upstream ?? "its upstream").", .note)
            } catch {
                gitFailed(error)
            }
        }, then: { [self] in await afterUpdate() })
    }

    func cloneRepository() async {
        guard let env = environment else { return }
        let dest = settings.repositoryURL
        await operate("Downloading nxnative", { [self] in
            console.append("$ git clone --progress \(GitRepository.defaultRemote) \(Shell.quoteIfNeeded(dest.path))", .command)
            let batcher = LineBatcher { [weak self] lines in for l in lines { self?.console.append(l.text, .output) } }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await GitRepository.clone(remote: GitRepository.defaultRemote, to: dest, environment: env) { line in batcher.add(.stderr, line) }
                batcher.flush()
                lastGitError = nil
                console.append("Downloaded into \(dest.path).", .note)
            } catch {
                batcher.flush()
                gitFailed(error)
                if Task.isCancelled { console.append("A stopped download can leave a partial folder at \(dest.path): remove it before downloading again.", .note) }
            }
        }, then: { [self] in
            await afterUpdate()
            await recheck()
        })
    }

    /// A stopped git operation is not an error to keep showing
    private func gitFailed(_ error: Error) {
        if Task.isCancelled {
            console.append("Stopped.", .note)
        } else {
            lastGitError = error.localizedDescription
            console.append(error.localizedDescription, .error)
        }
    }

    private func afterUpdate() async {
        await reloadProfiles()
        await refreshRepository()
        rebuildLibrary()
        await refreshCommitsBehind()
    }

    // MARK: Prerequisites

    /// Checks everything again; a newer check (another keystroke in a path field) supersedes this one, and only the newest sets checks
    func recheck() async { await scheduleRecheck(after: .zero)?.value }

    @discardableResult
    private func scheduleRecheck(after delay: Duration) -> Task<Void, Never>? {
        guard let env = environment else { return nil }
        checking = true
        let checker = PrerequisiteChecker(environment: env, python: pythonExecutable ?? "python3", repository: settings.repositoryURL, keys: settings.keysURL,
                                          agentExecutables: agentExecutables)
        return rechecks.run(after: delay, { await checker.checkAll() }) { [weak self] result in
            self?.checks = result
            self?.checking = false
        }
    }
}
