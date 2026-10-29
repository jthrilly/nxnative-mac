// What may run on a port at the same time. Agents run side by side on different games, one per port (and per game folder), and a port's worktree has one
// user at a time: its agent (in the app, or in a Terminal session), a git operation on it (checkpoint, rebase, diff, removal) or a conversion built from it. A conversion of the game's folder from the nxnative
// checkout shares the folder and not the worktree, so it keeps only agent runs out. A Terminal session is open while the .command script's shell lives:
// the script writes its PID into a marker file and removes it when it exits (a stale marker names a process that is gone)
import Darwin
import Foundation

public enum PortBlock: Sendable, Equatable {
    case agentRunning(agent: String, game: String), operation(String), converting(String), terminalSession

    public var title: String {
        switch self {
        case .agentRunning: return "An agent is running"
        case .operation: return "A worktree operation is running"
        case let .converting(name): return "\(name) is being converted"
        case .terminalSession: return "An agent session is open in Terminal"
        }
    }

    public var message: String {
        switch self {
        case let .agentRunning(agent, game): return "\(agent) is working on \(game). A game has one agent at a time: stop it or wait until it has finished."
        case let .operation(title): return "\(title.replacingOccurrences(of: "…", with: "")) on this port's worktree: wait until it has finished."
        case let .converting(name): return "\(name) is being converted from this game folder or worktree: wait until the conversion has finished."
        case .terminalSession: return "An agent session is open in Terminal in this port's worktree: end it there first."
        }
    }
}

/// What is running now, as far as one port is concerned
public struct PortSituation: Sendable {
    public var agent: (titleID: String, name: String, game: String)?   // the agent run in the app on this port, or on its game folder
    public var operation: String?                                      // the git operation on this port's worktree
    public var conversion: (name: String, folder: String, repository: String?)?   // the conversion running now
    public var terminalSession: Bool

    public init(agent: (titleID: String, name: String, game: String)? = nil, operation: String? = nil,
                conversion: (name: String, folder: String, repository: String?)? = nil, terminalSession: Bool = false) {
        self.agent = agent; self.operation = operation; self.conversion = conversion; self.terminalSession = terminalSession
    }
}

public enum PortRules {
    /// Why an agent run of the port cannot start now, nil when it can
    public static func runBlock(_ port: PortRecord, _ s: PortSituation) -> PortBlock? {
        if let a = s.agent { return .agentRunning(agent: a.name, game: a.game) }
        if let op = s.operation { return .operation(op) }
        if s.terminalSession { return .terminalSession }
        if let c = s.conversion, samePath(c.folder, port.folder) || c.repository.map({ samePath($0, port.workspace) }) == true { return .converting(c.name) }
        return nil
    }

    /// Why a git operation on the port's worktree (checkpoint, rebase, removal) cannot start now, nil when it can
    public static func operationBlock(_ port: PortRecord, _ s: PortSituation) -> PortBlock? {
        if let a = s.agent, a.titleID == port.titleID { return .agentRunning(agent: a.name, game: a.game) }
        if let op = s.operation { return .operation(op) }
        if s.terminalSession { return .terminalSession }
        if let c = s.conversion, c.repository.map({ samePath($0, port.workspace) }) == true { return .converting(c.name) }
        return nil
    }

    /// Why a conversion built from the port's worktree (Build App) cannot start now, nil when it can (another conversion only makes it wait in the queue)
    public static func buildBlock(_ port: PortRecord, _ s: PortSituation) -> PortBlock? {
        if let a = s.agent, a.titleID == port.titleID { return .agentRunning(agent: a.name, game: a.game) }
        if let op = s.operation { return .operation(op) }
        return s.terminalSession ? .terminalSession : nil
    }

    public static func samePath(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// The title ID of a port branch (port/<title ID>), nil for any other branch
    public static func titleID(fromBranch branch: String?) -> String? {
        guard let branch, branch.hasPrefix("port/") else { return nil }
        let id = branch.dropFirst(5)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    public static func sessionMarker(runFolder: URL, runID: UUID) -> URL { runFolder.appendingPathComponent("\(runID.uuidString).session") }

    static let sessionStartGrace: TimeInterval = 60

    /// The marker names a process that still runs (EPERM: it runs as another user, which still counts). A session started less than a minute ago has no marker
    /// yet while Terminal opens it
    public static func sessionIsOpen(marker: URL, startedAt: Date, now: Date = Date()) -> Bool {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return now.timeIntervalSince(startedAt) < sessionStartGrace }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The files a checkpoint left out, one per line with the reason, at most limit of them
    public static func leftOut(_ skipped: [SkippedFile], limit: Int = 20) -> String? {
        guard !skipped.isEmpty else { return nil }
        var lines = skipped.prefix(limit).map { "\($0.path) (\(reason($0.reason)))" }
        if skipped.count > limit { lines.append("… and \(skipped.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    public static func reason(_ r: CheckpointSkipReason) -> String {
        switch r {
        case .large: return "larger than 5 MB"
        case .binary: return "a new binary file"
        case .gameFile: return "a game or key file"
        case .repository: return "a git repository of its own"
        }
    }
}
