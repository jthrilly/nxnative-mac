// The nxnative checkout: its state against its upstream, updating it (fetch, fast-forward pull, reset to the upstream), cloning it, and the version recorded with each conversion.
// Every git call is `git -C <path> …` with GIT_TERMINAL_PROMPT=0, so a remote that asks for credentials fails instead of waiting for a terminal that is not there; the folder must be
// the top of its work tree (a folder inside another repository is not taken for the checkout). Reading the state takes no index lock (--no-optional-locks), and a transfer that
// stalls is given up (http.lowSpeedLimit) or stopped by cancelling its task
import Foundation

public struct CommitInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String { sha }
    public var sha: String; public var shortSHA: String; public var subject: String; public var date: Date; public var author: String
}

public struct NXNativeVersion: Sendable, Equatable, Codable {
    public var commit: String; public var shortCommit: String; public var subject: String; public var commitDate: Date?
    public var branch: String?; public var describe: String?; public var modified: Bool
}

public struct RepositoryStatus: Sendable, Equatable {
    public var path: URL
    public var exists: Bool
    public var isNXNative: Bool
    public var isGitRepository: Bool
    public var branch: String?
    public var upstream: String?
    public var remoteURL: String?
    public var head: CommitInfo?
    public var modifiedFiles: [String]
    public var ahead: Int; public var behind: Int
    public var incoming: [CommitInfo]
    public var outgoing: [CommitInfo]   // the local commits not on the upstream (newest first), which a reset to the upstream takes off the branch
    public var lastFetched: Date?
}

public enum GitError: Error, LocalizedError, Equatable {
    case notARepository(String), command(String, String), noUpstream

    public var errorDescription: String? {
        switch self {
        case let .notARepository(path): return "\(path) is not a git repository"
        case let .command(args, stderr): return "git \(args) failed" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .noUpstream: return "the current branch has no upstream branch"
        }
    }
}

public struct GitRepository: Sendable {
    public static let defaultRemote = "https://github.com/seedds/nxnative.git"
    static let commitFormat = "%H%x1f%h%x1f%s%x1f%cI%x1f%an%x1e"
    static let maxIncoming = 200
    static let readOnly = ["--no-optional-locks"]
    static let network = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=60"]   // a transfer slower than 1 kB/s for a minute fails
    static let networkTimeout: TimeInterval = 1800

    public var path: URL; public var environment: ShellEnvironment

    public init(path: URL, environment: ShellEnvironment) { self.path = path; self.environment = environment }

    public func status() async -> RepositoryStatus {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
        let nx = ["scripts/build_ipa_from_nsp.py", "dm/tools/nx_extract/Program.cs"].allSatisfy { fm.fileExists(atPath: path.appendingPathComponent($0).path) }
        var s = RepositoryStatus(path: path, exists: exists, isNXNative: nx, isGitRepository: false, branch: nil, upstream: nil, remoteURL: nil, head: nil,
                                 modifiedFiles: [], ahead: 0, behind: 0, incoming: [], outgoing: [], lastFetched: nil)
        guard exists, await isTopLevel() else { return s }
        s.isGitRepository = true
        async let branch = output(["symbolic-ref", "--short", "-q", "HEAD"])
        async let upstream = output(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        async let head = output(["log", "-1", "--format=" + Self.commitFormat])
        async let porcelain = output(Self.readOnly + ["status", "--porcelain", "-z", "--untracked-files=no"], trim: false)
        async let fetchHead = output(["rev-parse", "--git-path", "FETCH_HEAD"])
        s.branch = await branch
        s.upstream = await upstream
        s.head = await head.flatMap { Self.parseCommits($0).first }
        s.modifiedFiles = await porcelain.map { Self.parsePorcelain($0) } ?? []
        if let p = await fetchHead {
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : path.appendingPathComponent(p)
            s.lastFetched = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        var remote: String?
        if let b = s.branch { remote = await output(["config", "--get", "branch.\(b).remote"]) }
        s.remoteURL = await output(["remote", "get-url", remote ?? "origin"])
        if s.upstream != nil {
            async let counts = output(["rev-list", "--left-right", "--count", "HEAD...@{u}"])
            async let incoming = output(["log", "--max-count=\(Self.maxIncoming)", "--format=" + Self.commitFormat, "HEAD..@{u}"])
            async let outgoing = output(["log", "--max-count=\(Self.maxIncoming)", "--format=" + Self.commitFormat, "@{u}..HEAD"])
            if let (a, b) = await counts.flatMap(Self.parseAheadBehind) { s.ahead = a; s.behind = b }
            s.incoming = await incoming.map(Self.parseCommits) ?? []
            s.outgoing = await outgoing.map(Self.parseCommits) ?? []
        }
        return s
    }

    public func fetch() async throws {
        try await requireRepository()
        try await git(Self.network + ["fetch", "--prune"], timeout: Self.networkTimeout)
    }

    public func pullFastForward() async throws -> (old: String, new: String) {
        try await requireRepository()
        guard await output(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) != nil else { throw GitError.noUpstream }
        let old = try await git(["rev-parse", "HEAD"])
        try await git(Self.network + ["pull", "--ff-only"], timeout: Self.networkTimeout)
        return (old, try await git(["rev-parse", "HEAD"]))
    }

    public func resetHardToUpstream() async throws {
        try await requireRepository()
        guard await output(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) != nil else { throw GitError.noUpstream }
        try await git(["reset", "--hard", "@{u}"])
    }

    public func version() async throws -> NXNativeVersion {
        try await requireRepository()
        let commit = try await git(["rev-parse", "HEAD"])
        async let head = output(["log", "-1", "--format=" + Self.commitFormat, commit])
        async let branch = output(["symbolic-ref", "--short", "-q", "HEAD"])
        async let describe = output(["describe", "--tags"])
        async let porcelain = output(Self.readOnly + ["status", "--porcelain", "-z", "--untracked-files=no"], trim: false)
        let info = await head.flatMap { Self.parseCommits($0).first }
        return NXNativeVersion(commit: commit, shortCommit: info?.shortSHA ?? String(commit.prefix(7)), subject: info?.subject ?? "", commitDate: info?.date,
                               branch: await branch, describe: await describe, modified: !(await porcelain.map { Self.parsePorcelain($0) } ?? []).isEmpty)
    }

    public func commitCount(from commit: String, to: String = "HEAD") async -> Int? {
        await output(["rev-list", "--count", "\(commit)..\(to)"]).flatMap { Int($0) }
    }

    public func isAncestor(_ ancestor: String, of descendant: String) async -> Bool {
        (try? await run(["merge-base", "--is-ancestor", ancestor, descendant]))?.status == 0
    }

    public func lastCommit(touching paths: [String]) async -> String? {
        await output(["log", "-1", "--format=%H", "--"] + paths)
    }

    public static func clone(remote: String, to destination: URL, environment: ShellEnvironment, onLine: @escaping @Sendable (String) -> Void) async throws {
        let p = Subprocess(executable: "git", arguments: network + ["clone", "--progress", remote, destination.path], environment: gitEnvironment(environment))
        p.splitsCarriageReturns = true
        let tail = Tail()
        try p.start { stream, line in
            if !line.isEmpty { tail.add(line) }
            onLine(line)
        }
        let status = await withTaskCancellationHandler { await p.waitUntilExit() } onCancel: { Task { await p.cancel(grace: 2) } }
        try Task.checkCancellation()
        if status != 0 { throw GitError.command("clone \(remote) \(destination.path)", tail.text) }
    }

    // ---- parsing (git's own output formats) ----

    /// Records of commitFormat: sha, short sha, subject, committer date (ISO 8601), author; separated by 0x1f, ended by 0x1e
    static func parseCommits(_ text: String) -> [CommitInfo] {
        text.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty, let date = parseISODate(f[3]) else { return nil }
            return CommitInfo(sha: f[0], shortSHA: f[1], subject: f[2], date: date, author: f[4])
        }
    }

    /// `git status --porcelain -z`: "XY path" entries separated by NUL; a rename or copy is followed by its original path. Untracked files ("??") only when asked for
    static func parsePorcelain(_ text: String, includeUntracked: Bool = false) -> [String] {
        var out: [String] = []
        var entries = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let line = entries.popFirst() {
            guard line.count > 3 else { continue }
            let xy = line.prefix(2)
            if xy.first == "R" || xy.first == "C" { _ = entries.popFirst() }
            if xy == "!!" || (xy == "??" && !includeUntracked) { continue }
            out.append(String(line.dropFirst(3)))
        }
        return out
    }

    /// `git rev-list --left-right --count HEAD...@{u}`: "<ahead>\t<behind>"
    static func parseAheadBehind(_ text: String) -> (ahead: Int, behind: Int)? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    static func parseISODate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    static func gitEnvironment(_ env: ShellEnvironment) -> [String: String] {
        var v = env.variables
        v["GIT_TERMINAL_PROMPT"] = "0"
        return v
    }

    // ---- running git ----

    private func run(_ args: [String], timeout: TimeInterval? = nil) async throws -> ProcessOutput {
        try await Self.run(args, in: path, environment: environment, timeout: timeout)
    }

    static func run(_ args: [String], in directory: URL, environment: ShellEnvironment, timeout: TimeInterval? = nil) async throws -> ProcessOutput {
        try await Subprocess.run("git", ["-C", directory.path] + args, environment: gitEnvironment(environment), timeout: timeout)
    }

    /// The trimmed output of a git call that must succeed
    @discardableResult
    private func git(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        let r = try await run(args, timeout: timeout)
        guard r.succeeded else { throw GitError.command(args.joined(separator: " "), r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The output of a git call, nil when it fails or prints nothing
    private func output(_ args: [String], trim: Bool = true) async -> String? {
        guard let r = try? await run(args), r.succeeded else { return nil }
        let s = trim ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : r.stdout
        return s.isEmpty ? nil : s
    }

    private func requireRepository() async throws {
        guard await isTopLevel() else { throw GitError.notARepository(path.path) }
    }

    /// The folder is the top of a work tree, not a folder inside one
    private func isTopLevel() async -> Bool {
        guard let top = await output(["rev-parse", "--show-toplevel"]) else { return false }
        return AppInstaller.realPath(URL(fileURLWithPath: top)).path == AppInstaller.realPath(path).path
    }
}

// The last lines git printed, for the error of a failed clone
private final class Tail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line); if lines.count > 5 { lines.removeFirst() } } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
