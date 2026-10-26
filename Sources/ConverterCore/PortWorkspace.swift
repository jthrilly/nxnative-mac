// The git worktree of nxnative a port's agent works in (branch port/<title ID>, by default in <repository's parent>/nxnative-ports): made from the repository's HEAD, compared
// with it, checkpointed after each run, rebased onto a newer nxnative, shown as a diff, removed. A checkpoint chooses what to stage before git reads anything: no file over a size
// limit (a dump or a build output the agent left in the tree), and of the new files only text that is not a game or key file (AGENTS.md: game files never go into the
// repository), so git never hashes what it leaves out. It commits only on the port's branch, runs no commit hooks and never signs; without a git identity it commits as
// "nxnative Converter"
import Darwin
import Foundation

public struct PortWorkspaceStatus: Sendable, Equatable {
    public var exists: Bool; public var head: CommitInfo?; public var base: String?
    public var commitsAhead: Int; public var commitsBehind: Int
    public var uncommittedFiles: [String]; public var filesChanged: Int; public var insertions: Int; public var deletions: Int
}

public enum CheckpointSkipReason: String, Sendable, Equatable { case large, binary, gameFile, repository }

/// A file a checkpoint left out: over the size limit, or new and binary, a game or key file (game-file extensions, RomFS / ExeFS / <id>-work folders, key = value lines)
/// or a git repository of its own
public struct SkippedFile: Sendable, Equatable { public var path: String; public var reason: CheckpointSkipReason }

public struct CheckpointResult: Sendable, Equatable {
    public var commit: String?; public var skipped: [SkippedFile]
    var skippedLargeFiles: [String] { skipped.filter { $0.reason == .large }.map(\.path) }
}

public enum RebaseOutcome: Sendable, Equatable { case upToDate, rebased(newHead: String), conflicts([String]) }

public struct PortWorkspace: Sendable {
    static let maxDiffBytes = 2 << 20
    static let fallbackIdentity = ["-c", "user.name=nxnative Converter", "-c", "user.email=converter@localhost"]
    static let noSigning = ["-c", "commit.gpgsign=false"]
    static let gameFileExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz", "nca", "ncz", "nso", "nro", "nrr", "npdm", "tik", "cert", "keys"]
    static let binaryProbeBytes = 8000   // git's own test: a NUL in the first 8000 bytes

    public var repository: URL; public var path: URL; public var branch: String; public var environment: ShellEnvironment

    public init(repository: URL, path: URL, branch: String, environment: ShellEnvironment) {
        self.repository = repository; self.path = path; self.branch = branch; self.environment = environment
    }

    public static func branchName(titleID: String) -> String { "port/\(titleID)" }

    public static func defaultsDirectory(repository: URL) -> URL {
        repository.standardized.deletingLastPathComponent().appendingPathComponent("nxnative-ports", isDirectory: true)
    }

    public func create(base: String = "HEAD") async throws {
        if await isWorktree() {
            let head = await output(["symbolic-ref", "--short", "-q", "HEAD"])
            if head != branch { try await returnToBranch(head: head) }
            return
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? await git(["worktree", "prune"], in: repository)   // a worktree folder deleted by hand is still registered until pruned
        if await branchExists() {
            try await git(["worktree", "add", path.path, branch], in: repository)
        } else {
            try await git(["worktree", "add", "-b", branch, path.path, base], in: repository)
        }
    }

    public func status() async -> PortWorkspaceStatus {
        var s = PortWorkspaceStatus(exists: false, head: nil, base: nil, commitsAhead: 0, commitsBehind: 0, uncommittedFiles: [], filesChanged: 0, insertions: 0, deletions: 0)
        guard await isWorktree() else { return s }
        s.exists = true
        async let head = output(["log", "-1", "--format=" + GitRepository.commitFormat])
        async let porcelain = output(GitRepository.readOnly + ["status", "--porcelain", "-z", "--untracked-files=all"], trim: false)
        async let main = output(["rev-parse", "HEAD"], in: repository)
        s.head = await head.flatMap { GitRepository.parseCommits($0).first }
        let changes = await porcelain ?? ""
        s.uncommittedFiles = GitRepository.parsePorcelain(changes, includeUntracked: true)
        let untracked = s.uncommittedFiles.count - GitRepository.parsePorcelain(changes).count
        guard let main = await main, let base = await output(["merge-base", "HEAD", main]) else { return s }
        s.base = base
        async let counts = output(["rev-list", "--left-right", "--count", "HEAD...\(main)"])
        async let stat = output(GitRepository.readOnly + ["diff", "--shortstat", base])   // the working tree against the base: committed and uncommitted changes of tracked files
        if let (a, b) = await counts.flatMap(GitRepository.parseAheadBehind) { s.commitsAhead = a; s.commitsBehind = b }
        let (files, insertions, deletions) = Self.parseShortstat(await stat ?? "")
        s.filesChanged = files + untracked; s.insertions = insertions; s.deletions = deletions
        return s
    }

    public func checkpoint(message: String, maxFileBytes: Int64 = 5_000_000) async throws -> CheckpointResult {
        try await requireBranch()
        async let untracked = git(["ls-files", "-z", "--others", "--exclude-standard"], trim: false)
        async let changed = git(["diff", "-z", "--name-only", "--no-renames"], trim: false)   // tracked files changed or deleted in the tree
        async let staged = git(["diff", "--cached", "-z", "--name-status", "--no-renames"], trim: false)   // what the agent staged itself
        let new = Self.nulList(try await untracked), unstaged = Self.nulList(try await changed), stagedEntries = Self.nulList(try await staged)
        var stagedStatus: [String: String] = [:]
        for i in stride(from: 0, to: stagedEntries.count - 1, by: 2) { stagedStatus[stagedEntries[i + 1]] = stagedEntries[i] }
        let added = Set(new).union(stagedStatus.filter { $0.value == "A" }.keys), toAdd = Set(new + unstaged)
        var seen = Set<String>(), take: [String] = [], skipped: [SkippedFile] = []
        // a path staged and not changed since is in the index already: `git add` of a staged deletion would fail, as its pathspec matches no file
        for file in new + unstaged + stagedEntries.enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) where seen.insert(file).inserted {
            if let reason = skipReason(file, new: added.contains(file), maxFileBytes: maxFileBytes) {
                skipped.append(SkippedFile(path: file.hasSuffix("/") ? String(file.dropLast()) : file, reason: reason))
            } else if toAdd.contains(file) { take.append(file) }
        }
        try await withPathspecs(take) { try await git(["--literal-pathspecs", "add", "-A", "--pathspec-from-file=" + $0, "--pathspec-file-nul"]) }
        try await withPathspecs(skipped.map(\.path).filter { stagedStatus[$0] != nil }) {
            try await git(["--literal-pathspecs", "reset", "-q", "--pathspec-from-file=" + $0, "--pathspec-file-nul"])
        }
        if await succeeds(["diff", "--cached", "--quiet"]) { return CheckpointResult(commit: nil, skipped: skipped) }
        try await git(await identity() + Self.noSigning + ["commit", "-q", "--no-verify", "-m", message])
        return CheckpointResult(commit: try await git(["rev-parse", "HEAD"]), skipped: skipped)
    }

    /// Why a changed file stays out of a checkpoint, nil to stage it (a deletion, a symbolic link, a tracked file under the limit, a new text file)
    func skipReason(_ file: String, new: Bool, maxFileBytes: Int64) -> CheckpointSkipReason? {
        let url = path.appendingPathComponent(file)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return nil }
        if type == S_IFDIR { return .repository }   // ls-files lists a repository inside the tree as its folder
        if Int64(st.st_size) > maxFileBytes { return .large }
        guard new else { return nil }
        let parts = file.lowercased().split(separator: "/")
        if Self.gameFileExtensions.contains(url.pathExtension.lowercased()) || parts.dropLast().contains(where: { $0 == "romfs" || $0 == "exefs" || $0.hasSuffix("-work") }) {
            return .gameFile
        }
        guard let data = try? Data(contentsOf: url) else { return .binary }
        if data.prefix(Self.binaryProbeBytes).contains(0) { return .binary }
        return Self.looksLikeKeys(String(decoding: data, as: UTF8.self)) ? .gameFile : nil
    }

    /// prod.keys and title.keys lines ("name = <hex>", "<rights ID> = <hex>"), however the file is named
    static func looksLikeKeys(_ text: String) -> Bool {
        var found = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let halves = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard halves.count == 2, !halves[0].isEmpty, halves[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  halves[1].count >= 32, halves[1].allSatisfy(NSPScanner.isHex) else { continue }
            found += 1
            if found == 2 { return true }
        }
        return false
    }

    /// Replays the branch's commits onto commit (a SHA of the repository). Conflicts abort the rebase, so the branch is as it was
    public func rebase(onto commit: String) async throws -> RebaseOutcome {
        let dirty = GitRepository.parsePorcelain(try await git(GitRepository.readOnly + ["status", "--porcelain", "-z", "--untracked-files=no"], trim: false))
        guard dirty.isEmpty else { throw GitError.command("rebase \(commit)", "the worktree has uncommitted changes: " + dirty.joined(separator: ", ")) }
        if await succeeds(["merge-base", "--is-ancestor", commit, "HEAD"]) { return .upToDate }
        var env = environment
        env.variables["GIT_EDITOR"] = "true"
        let r = try await GitRepository.run(await identity() + Self.noSigning + ["rebase", commit], in: path, environment: env)
        if r.succeeded { return .rebased(newHead: try await git(["rev-parse", "HEAD"])) }
        let conflicts = (await output(["diff", "--name-only", "--diff-filter=U", "-z"], trim: false) ?? "").split(separator: "\0").map(String.init)
        _ = try? await git(["rebase", "--abort"])
        if conflicts.isEmpty { throw GitError.command("rebase \(commit)", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .conflicts(conflicts)
    }

    /// The branch's commits since it left nxnative, then what is not committed yet (and the names of new files), at most 2 MB
    public func diff() async throws -> String {
        let main = try await git(["rev-parse", "HEAD"], in: repository)
        let base = try await git(["merge-base", "HEAD", main])
        async let committed = git(["diff", "--no-color", "--no-ext-diff", "\(base)...HEAD"], trim: false)
        async let uncommitted = git(["diff", "--no-color", "--no-ext-diff", "HEAD"], trim: false)
        async let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], trim: false)
        var text = try await committed
        let pending = try await uncommitted, new = try await untracked.split(separator: "\0").map(String.init)
        if !pending.isEmpty { text += (text.isEmpty ? "" : "\n") + "# Not committed yet\n" + pending }
        if !new.isEmpty { text += (text.isEmpty ? "" : "\n") + "# New files, not committed yet\n" + new.joined(separator: "\n") }
        guard text.utf8.count > Self.maxDiffBytes else { return text }
        return String(decoding: Data(text.utf8.prefix(Self.maxDiffBytes)), as: UTF8.self)
            + "\n\n[The diff is longer than \(ProgressFormat.bytes(Double(Self.maxDiffBytes))); the rest is not shown]"
    }

    public func remove() async throws {
        var failure: Error?
        if FileManager.default.fileExists(atPath: path.path) {
            do { try await git(["worktree", "remove", "--force", path.path], in: repository) } catch { failure = error }
        }
        _ = try? await git(["worktree", "prune"], in: repository)
        if await branchExists() {
            do { try await git(["branch", "-D", branch], in: repository) } catch { failure = failure ?? error }
        }
        let left = FileManager.default.fileExists(atPath: path.path), branchLeft = await branchExists()
        if left || branchLeft { throw failure ?? GitError.command("worktree remove \(path.path)", left ? "the folder is still there" : "the branch is still there") }
    }

    /// `git diff --shortstat`: " 3 files changed, 10 insertions(+), 2 deletions(-)" (each part only when not zero)
    static func parseShortstat(_ text: String) -> (files: Int, insertions: Int, deletions: Int) {
        var out = (files: 0, insertions: 0, deletions: 0)
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let n = words.first.flatMap({ Int($0) }), let what = words.dropFirst().first else { continue }
            if what.hasPrefix("file") { out.files = n } else if what.hasPrefix("insertion") { out.insertions = n } else if what.hasPrefix("deletion") { out.deletions = n }
        }
        return out
    }

    // ---- git ----

    private func isWorktree() async -> Bool {
        guard FileManager.default.fileExists(atPath: path.path), let top = await output(["rev-parse", "--show-toplevel"]) else { return false }
        return AppInstaller.realPath(URL(fileURLWithPath: top)).path == AppInstaller.realPath(path).path
    }

    /// A worktree whose HEAD left the branch: a detached HEAD at the branch or ahead of it (commits made off it) takes the branch back; a rebase, merge or cherry-pick
    /// left in progress, uncommitted changes or another branch are reported instead, so nothing is lost
    private func returnToBranch(head: String?) async throws {
        func fail(_ why: String) -> GitError {
            .command("worktree \(path.path)", "the worktree is on \(head ?? "a detached HEAD") instead of \(branch): \(why)")
        }
        for (marker, what) in [("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"), ("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick")] {
            guard let p = await output(["rev-parse", "--git-path", marker]) else { continue }
            if FileManager.default.fileExists(atPath: p.hasPrefix("/") ? p : path.appendingPathComponent(p).path) {
                throw fail("\(what) is in progress there; finish it or abort it first")
            }
        }
        let dirty = GitRepository.parsePorcelain(try await git(GitRepository.readOnly + ["status", "--porcelain", "-z", "--untracked-files=no"], trim: false))
        guard dirty.isEmpty else { throw fail("it has uncommitted changes (\(dirty.joined(separator: ", ")))") }
        if head != nil { throw fail("switch it back with git switch \(branch)") }
        guard await branchExists() else { try await git(["switch", "-q", "-c", branch]); return }
        guard await succeeds(["merge-base", "--is-ancestor", "refs/heads/\(branch)", "HEAD"]) else {
            throw fail("its HEAD is not on the branch's history; switch it back with git switch \(branch)")
        }
        try await git(["switch", "-q", "-C", branch])
    }

    private func requireBranch() async throws {
        let head = await output(["symbolic-ref", "--short", "-q", "HEAD"])
        guard head == branch else { throw GitError.command("commit", "the worktree \(path.path) is on \(head ?? "a detached HEAD") instead of \(branch)") }
    }

    /// Runs body with a file of NUL-separated pathspecs (--pathspec-from-file: no limit on how many), nothing for none
    private func withPathspecs(_ paths: [String], _ body: (String) async throws -> Void) async throws {
        guard !paths.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-pathspecs-\(UUID().uuidString)")
        try Data(paths.joined(separator: "\0").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await body(file.path)
    }

    static func nulList(_ text: String) -> [String] { text.split(separator: "\0").map(String.init) }

    private func branchExists() async -> Bool { await succeeds(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository) }

    /// The user's git identity, else the converter's own (`git var` fails when git has no name or email to commit with)
    private func identity() async -> [String] {
        let author = await succeeds(["var", "GIT_AUTHOR_IDENT"]), committer = await succeeds(["var", "GIT_COMMITTER_IDENT"])
        return author && committer ? [] : Self.fallbackIdentity
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL? = nil, trim: Bool = true) async throws -> String {
        let r = try await GitRepository.run(args, in: directory ?? path, environment: environment)
        guard r.succeeded else { throw GitError.command(args.joined(separator: " "), r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return trim ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : r.stdout
    }

    private func output(_ args: [String], in directory: URL? = nil, trim: Bool = true) async -> String? {
        guard let s = try? await git(args, in: directory, trim: trim), !s.isEmpty else { return nil }
        return s
    }

    private func succeeds(_ args: [String], in directory: URL? = nil) async -> Bool {
        (try? await GitRepository.run(args, in: directory ?? path, environment: environment))?.succeeded == true
    }
}
