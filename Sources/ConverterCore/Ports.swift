// The record of ports: for each game handed to an agent, its worktree and branch, the nxnative commit it started from and every agent run (agent, session, status, cost,
// report, checkpoint commit). ports.json sits beside library.json; each port's run files (raw transcripts <run id>.jsonl, prompts, the report schema, Claude's settings) in
// ports/<title ID>. Records written by another converter version still load: every field but the title ID has a default, and a run that cannot be read is left out
import Foundation

public enum AgentRunStatus: String, Sendable, Codable { case running, succeeded, failed, cancelled, timedOut, interactive }

public struct AgentRunRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID; public var kind: AgentKind; public var sessionID: String; public var interactive: Bool
    public var startedAt: Date; public var finishedAt: Date?; public var status: AgentRunStatus
    public var usage: AgentUsage?; public var turns: Int?; public var report: AgentReport?; public var message: String?
    public var checkpoint: String?; public var transcriptFile: String?; public var instructions: String; public var model: String

    public init(id: UUID = UUID(), kind: AgentKind, sessionID: String = "", interactive: Bool = false, startedAt: Date, finishedAt: Date? = nil, status: AgentRunStatus,
                usage: AgentUsage? = nil, turns: Int? = nil, report: AgentReport? = nil, message: String? = nil, checkpoint: String? = nil, transcriptFile: String? = nil,
                instructions: String = "", model: String = "") {
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.interactive = interactive; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.status = status; self.usage = usage; self.turns = turns; self.report = report; self.message = message; self.checkpoint = checkpoint
        self.transcriptFile = transcriptFile; self.instructions = instructions; self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        kind = c.lenient(AgentKind.self, .kind) ?? .claudeCode
        sessionID = c.lenient(String.self, .sessionID) ?? ""
        interactive = c.lenient(Bool.self, .interactive) ?? false
        startedAt = c.lenient(Date.self, .startedAt) ?? Date(timeIntervalSince1970: 0)
        finishedAt = c.lenient(Date.self, .finishedAt)
        status = c.lenient(AgentRunStatus.self, .status) ?? .failed   // a status this version does not know
        usage = c.lenient(AgentUsage.self, .usage)
        turns = c.lenient(Int.self, .turns)
        report = c.lenient(AgentReport.self, .report)
        message = c.lenient(String.self, .message)
        checkpoint = c.lenient(String.self, .checkpoint)
        transcriptFile = c.lenient(String.self, .transcriptFile)
        instructions = c.lenient(String.self, .instructions) ?? ""
        model = c.lenient(String.self, .model) ?? ""
    }
}

public struct PortRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: String { titleID }
    public var titleID: String; public var gameName: String; public var folder: String; public var workspace: String; public var branch: String
    public var baseCommit: String; public var createdAt: Date; public var runs: [AgentRunRecord]

    public init(titleID: String, gameName: String, folder: String, workspace: String, branch: String, baseCommit: String, createdAt: Date, runs: [AgentRunRecord] = []) {
        self.titleID = titleID; self.gameName = gameName; self.folder = folder; self.workspace = workspace; self.branch = branch; self.baseCommit = baseCommit
        self.createdAt = createdAt; self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleID = try c.decode(String.self, forKey: .titleID)
        gameName = c.lenient(String.self, .gameName) ?? titleID
        folder = c.lenient(String.self, .folder) ?? ""
        workspace = c.lenient(String.self, .workspace) ?? ""
        branch = c.lenient(String.self, .branch) ?? PortWorkspace.branchName(titleID: titleID)
        baseCommit = c.lenient(String.self, .baseCommit) ?? ""
        createdAt = c.lenient(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0)
        runs = (c.lenient([Lenient<AgentRunRecord>].self, .runs) ?? []).compactMap(\.value)
    }

    private var newestFirst: [AgentRunRecord] { runs.enumerated().sorted { ($0.element.startedAt, $0.offset) > ($1.element.startedAt, $1.offset) }.map(\.element) }

    public var latestReport: AgentReport? { newestFirst.lazy.compactMap(\.report).first }

    public func lastSession(of kind: AgentKind) -> String? { newestFirst.first { $0.kind == kind && !$0.sessionID.isEmpty }?.sessionID }

    public var totalCostUSD: Double { runs.reduce(0) { $0 + ($1.usage?.costUSD ?? 0) } }
}

public struct PortStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL { LibraryStore.converterSupport.appendingPathComponent("ports.json") }

    public func read() throws -> StoreContents<PortRecord> { try LibraryStore.read(PortRecord.self, from: fileURL) }

    /// The ports that could be read; throws StoreError.movedAside when the whole file could not be (read() tells more)
    public func load() throws -> [PortRecord] { try LibraryStore.records(of: read(), file: fileURL) }

    public func save(_ ports: [PortRecord]) throws { try LibraryStore.write(ports, to: fileURL) }

    public static func runFolder(titleID: String) -> URL {
        LibraryStore.converterSupport.appendingPathComponent("ports", isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    /// Where the app writes a port's boot.sh launcher (bootLauncher): a path with no spaces, unlike Application Support and most game folders, so that
    /// Claude Code's sandbox exemption matches the command, and outside the agent's sandbox writes, so that the agent cannot change it
    public static func toolsFolder(titleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/org.nxnative.converter/port-tools", isDirectory: true)
            .appendingPathComponent(titleID, isDirectory: true)
    }

    /// The launcher's script: it runs the work folder's run/boot.sh with the arguments it is given
    public static func bootLauncher(workFolder: URL) -> String {
        "#!/bin/sh\n# Written by nxnative Converter: runs the game's boot.sh, outside the agent's sandbox (the sandbox has no Metal device)\n"
            + "exec \(PrerequisiteChecker.shellQuote(workFolder.appendingPathComponent("run/boot.sh").path)) \"$@\"\n"
    }
}
