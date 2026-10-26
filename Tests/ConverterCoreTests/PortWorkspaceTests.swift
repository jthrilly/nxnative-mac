// PortWorkspace against a real repository in a temporary folder (GitRepositoryTests' fixture, the user's git configuration kept out): the worktree's creation and reuse,
// its status, checkpoints (what is left out before anything is staged, nothing to commit, no git identity, only on the branch), a worktree whose HEAD left the branch,
// rebases (clean, up to date, conflicting), the diff and removal
import Foundation
import Testing
@testable import ConverterCore

struct PortWorkspaceTests {
    static let titleID = "0100ABCD00000000"

    func workspace(_ f: GitRepositoryTests.Fixture, environment: ShellEnvironment? = nil) -> PortWorkspace {
        PortWorkspace(repository: f.other, path: PortWorkspace.defaultsDirectory(repository: f.other).appendingPathComponent(Self.titleID),
                      branch: PortWorkspace.branchName(titleID: Self.titleID), environment: environment ?? f.env)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func names() {
        #expect(PortWorkspace.branchName(titleID: Self.titleID) == "port/0100ABCD00000000")
        #expect(PortWorkspace.defaultsDirectory(repository: URL(fileURLWithPath: "/Users/player/src/nxnative/")).path == "/Users/player/src/nxnative-ports")
        #expect(PortWorkspace.parseShortstat(" 3 files changed, 10 insertions(+), 2 deletions(-)") == (3, 10, 2))
        #expect(PortWorkspace.parseShortstat(" 1 file changed, 1 deletion(-)") == (1, 0, 1))
        #expect(PortWorkspace.parseShortstat("") == (0, 0, 0))
    }

    @Test func lifecycle() async throws {
        let f = try GitRepositoryTests.Fixture(); defer { f.t.remove() }
        let ws = workspace(f), main = try f.git(f.other, "rev-parse", "HEAD")
        #expect(await ws.status().exists == false)
        try await ws.create()
        try await ws.create()   // already there: reused
        #expect(try f.git(ws.path, "symbolic-ref", "--short", "HEAD") == "port/0100ABCD00000000")
        var s = await ws.status()
        #expect(s.exists && s.base == main && s.head?.sha == main && s.commitsAhead == 0 && s.commitsBehind == 0 && s.uncommittedFiles.isEmpty && s.filesChanged == 0)

        try write("one\ntwo\n", to: ws.path.appendingPathComponent("README"))
        try write("title_id\t0100ABCD00000000\n", to: ws.path.appendingPathComponent("dm/games/\(Self.titleID)/game.tsv"))
        s = await ws.status()
        #expect(Set(s.uncommittedFiles) == ["README", "dm/games/0100ABCD00000000/game.tsv"])
        #expect(s.filesChanged == 2 && s.insertions == 1 && s.deletions == 0)   // the new file counts as changed; its lines show once it is committed

        let first = try await ws.checkpoint(message: "Port run 1")
        #expect(first.commit != nil && first.skippedLargeFiles.isEmpty)
        #expect(try f.git(ws.path, "log", "-1", "--format=%s|%an") == "Port run 1|Test Author")
        s = await ws.status()
        #expect(s.commitsAhead == 1 && s.commitsBehind == 0 && s.uncommittedFiles.isEmpty && s.filesChanged == 2 && s.insertions == 2 && s.head?.sha == first.commit)
        #expect(try await ws.checkpoint(message: "nothing") == CheckpointResult(commit: nil, skipped: []))

        try Data(count: 6_000_000).write(to: ws.path.appendingPathComponent("dump.bin"))
        try write("notes\n", to: ws.path.appendingPathComponent("notes.md"))
        let second = try await ws.checkpoint(message: "Port run 2")
        #expect(second.commit != nil && second.skippedLargeFiles == ["dump.bin"] && second.skipped == [SkippedFile(path: "dump.bin", reason: .large)])
        #expect(try f.git(ws.path, "ls-files", "dump.bin").isEmpty && !(try f.git(ws.path, "ls-files", "notes.md").isEmpty))
        #expect(await ws.status().uncommittedFiles == ["dump.bin"])

        // nxnative moves on: the port falls behind, then is rebased onto it
        try f.commit(f.other, "LICENSE", "MIT\n", "Add a license")
        let newer = try f.git(f.other, "rev-parse", "HEAD")
        #expect(await ws.status().commitsBehind == 1)
        guard case let .rebased(head) = try await ws.rebase(onto: newer) else { Issue.record("not rebased"); return }
        #expect(head == (try f.git(ws.path, "rev-parse", "HEAD")) && head != second.commit)
        s = await ws.status()
        #expect(s.commitsAhead == 2 && s.commitsBehind == 0 && s.base == newer)
        #expect(try await ws.rebase(onto: newer) == .upToDate)

        let diff = try await ws.diff()
        #expect(diff.contains("+two") && diff.contains("dm/games/0100ABCD00000000/game.tsv") && diff.contains("notes.md") && !diff.contains("LICENSE"))
        #expect(diff.contains("# New files, not committed yet\ndump.bin") && !diff.contains("# Not committed yet"))
        try write("one\ntwo\nthree\n", to: ws.path.appendingPathComponent("README"))
        let pending = try await ws.diff()
        #expect(pending.contains("# Not committed yet\n") && pending.contains("+three"))
        await #expect(throws: GitError.self) { try await ws.rebase(onto: newer) }   // tracked changes not committed
        try write("one\ntwo\n", to: ws.path.appendingPathComponent("README"))

        // the same line changed on both sides: the rebase is aborted and the branch is as it was
        try f.commit(f.other, "README", "one\nTWO\n", "Change the README")
        let conflicting = try f.git(f.other, "rev-parse", "HEAD")
        let before = try f.git(ws.path, "rev-parse", "HEAD")
        #expect(try await ws.rebase(onto: conflicting) == .conflicts(["README"]))
        #expect(try f.git(ws.path, "rev-parse", "HEAD") == before)
        #expect(try f.git(ws.path, "status", "--porcelain", "--untracked-files=no").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try f.git(ws.path, "rev-parse", "--path-format=absolute", "--git-path", "rebase-merge")))

        try await ws.remove()
        #expect(!FileManager.default.fileExists(atPath: ws.path.path))
        #expect((try? f.git(f.other, "rev-parse", "--verify", "--quiet", "refs/heads/port/0100ABCD00000000")) == nil)
        #expect(await ws.status().exists == false)
        try await ws.create()   // made again from scratch
        #expect(try f.git(ws.path, "rev-parse", "HEAD") == conflicting)
        try await ws.remove()
    }

    @Test func checkpointChoosesBeforeStaging() async throws {
        let f = try GitRepositoryTests.Fixture(); defer { f.t.remove() }
        let ws = workspace(f)
        try await ws.create()
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 1, 2])
        try binary.write(to: ws.path.appendingPathComponent("logo.bin"))
        try f.git(ws.path, "add", "logo.bin"); try f.git(ws.path, "commit", "-q", "-m", "A tracked binary file")
        try Data([0x89, 0x50, 0, 9]).write(to: ws.path.appendingPathComponent("logo.bin"))   // tracked: committed as it changes
        try Data(repeating: 0x41, count: 6_000_000).write(to: ws.path.appendingPathComponent("out[1].bin"))
        try write("small\n", to: ws.path.appendingPathComponent("out1.bin"))   // matched by the glob out[1].bin: still committed
        try write("notes\n", to: ws.path.appendingPathComponent("notes.md"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 7]).write(to: ws.path.appendingPathComponent("shot.png"))
        try write("text\n", to: ws.path.appendingPathComponent("work/main.nso"))
        try write("text\n", to: ws.path.appendingPathComponent("0100ABCD00000000-work/notes.txt"))
        try write("text\n", to: ws.path.appendingPathComponent("dump/RomFS/data.txt"))
        try write("header_key = " + String(repeating: "0f", count: 32) + "\nkey_area_key_application_00 = " + String(repeating: "a1", count: 16) + "\n",
                  to: ws.path.appendingPathComponent("scratch.txt"))
        try f.git(f.t.url, "init", "-q", ws.path.appendingPathComponent("vendor/sub").path)
        try binary.write(to: ws.path.appendingPathComponent("staged.bin"))
        try f.git(ws.path, "add", "staged.bin")   // staged by the agent: taken out again
        try f.git(ws.path, "rm", "-q", "README")   // a deletion and a new text file the agent staged itself: committed as they are
        try write("agent\n", to: ws.path.appendingPathComponent("agent.md"))
        try f.git(ws.path, "add", "agent.md")
        let large = try f.git(ws.path, "hash-object", "out[1].bin"), png = try f.git(ws.path, "hash-object", "shot.png")

        let r = try await ws.checkpoint(message: "Port run 1")
        #expect(r.commit != nil)
        #expect(Set(r.skipped.map { "\($0.path):\($0.reason.rawValue)" }) == [
            "out[1].bin:large", "shot.png:binary", "work/main.nso:gameFile", "0100ABCD00000000-work/notes.txt:gameFile", "dump/RomFS/data.txt:gameFile",
            "scratch.txt:gameFile", "vendor/sub:repository", "staged.bin:binary",
        ])
        #expect(r.skippedLargeFiles == ["out[1].bin"])
        #expect(Set(try f.git(ws.path, "show", "--name-only", "--format=", "HEAD").split(separator: "\n").map(String.init)) == ["README", "agent.md", "logo.bin", "notes.md", "out1.bin"])
        #expect(throws: GitError.self) { try f.git(ws.path, "cat-file", "-e", large) }   // never hashed into the object store
        #expect(throws: GitError.self) { try f.git(ws.path, "cat-file", "-e", png) }
        #expect(try f.git(ws.path, "diff", "--cached", "--name-only").isEmpty)
        try await ws.remove()
    }

    @Test func worktreeOffItsBranch() async throws {
        let f = try GitRepositoryTests.Fixture(); defer { f.t.remove() }
        let ws = workspace(f)
        try await ws.create()
        try write("x\n", to: ws.path.appendingPathComponent("new.txt"))
        _ = try await ws.checkpoint(message: "Port run 1")

        try f.git(ws.path, "switch", "-q", "--detach")
        try write("y\n", to: ws.path.appendingPathComponent("new2.txt"))
        await #expect(throws: GitError.self) { try await ws.checkpoint(message: "off the branch") }
        try f.git(ws.path, "add", "new2.txt"); try f.git(ws.path, "commit", "-q", "-m", "Made with a detached HEAD")
        let detached = try f.git(ws.path, "rev-parse", "HEAD")
        try await ws.create()   // the branch takes the commit back
        #expect(try f.git(ws.path, "symbolic-ref", "--short", "HEAD") == ws.branch && (try f.git(ws.path, "rev-parse", "HEAD")) == detached)

        try f.git(ws.path, "switch", "-q", "-c", "other")
        await #expect(throws: GitError.self) { try await ws.create() }
        try f.git(ws.path, "switch", "-q", ws.branch)

        try f.commit(f.other, "README", "one\nTWO\n", "Change the README")
        let main = try f.git(f.other, "rev-parse", "HEAD")
        try write("one\nthree\n", to: ws.path.appendingPathComponent("README"))
        _ = try await ws.checkpoint(message: "Port run 2")
        _ = try? f.git(ws.path, "rebase", main)   // stops on the conflict, as an agent's rebase might be left
        do { try await ws.create(); Issue.record("prepared") } catch let GitError.command(_, message) { #expect(message.contains("a rebase is in progress")) }
        try f.git(ws.path, "rebase", "--abort")
        try await ws.create()
        #expect(try f.git(ws.path, "symbolic-ref", "--short", "HEAD") == ws.branch)
        try await ws.remove()
    }

    @Test func keyLines() {
        #expect(PortWorkspace.looksLikeKeys("header_key = \(String(repeating: "0", count: 64))\n\(String(repeating: "1", count: 32)) = \(String(repeating: "2", count: 32))\n"))
        #expect(!PortWorkspace.looksLikeKeys("header_key = \(String(repeating: "0", count: 64))\n"))   // one line is not a key file
        #expect(!PortWorkspace.looksLikeKeys("a = 1\nb = 2\nshader\t\(String(repeating: "f", count: 32))\n"))
    }

    @Test func reusesTheBranchAfterTheFolderIsGone() async throws {
        let f = try GitRepositoryTests.Fixture(); defer { f.t.remove() }
        let ws = workspace(f)
        try await ws.create()
        try write("x\n", to: ws.path.appendingPathComponent("new.txt"))
        let commit = try #require(try await ws.checkpoint(message: "Port run 1").commit)
        try FileManager.default.removeItem(at: ws.path)   // deleted by hand: still registered until pruned
        try await ws.create()
        #expect(try f.git(ws.path, "rev-parse", "HEAD") == commit)
        try await ws.remove()
    }

    @Test func checkpointWithoutAnIdentity() async throws {
        let f = try GitRepositoryTests.Fixture(); defer { f.t.remove() }
        var vars = f.env.variables.filter { !$0.key.hasPrefix("GIT_AUTHOR_") && !$0.key.hasPrefix("GIT_COMMITTER_") }
        vars["GIT_CONFIG_COUNT"] = "1"; vars["GIT_CONFIG_KEY_0"] = "user.useConfigOnly"; vars["GIT_CONFIG_VALUE_0"] = "true"   // no guessing a name from the host
        let ws = workspace(f, environment: ShellEnvironment(variables: vars))
        try await ws.create()
        try write("x\n", to: ws.path.appendingPathComponent("new.txt"))
        #expect(try await ws.checkpoint(message: "Port run 1").commit != nil)
        #expect(try f.git(ws.path, "log", "-1", "--format=%an <%ae>") == "nxnative Converter <converter@localhost>")
        try await ws.remove()
    }
}
