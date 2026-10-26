// GitRepository against real repositories in a temporary folder: a bare "remote", the checkout under test and a second clone that pushes to it.
// The user's git configuration is kept out (GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM, a temporary HOME); names and dates come from the environment
import Foundation
import Testing
@testable import ConverterCore

struct GitRepositoryTests {
    struct Fixture {
        let t: TempDir, env: ShellEnvironment, remote: URL, local: URL, other: URL

        init() throws {
            t = try TempDir("git")
            env = ShellEnvironment(variables: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": t.url.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Test Author", "GIT_AUTHOR_EMAIL": "author@example.com", "GIT_COMMITTER_NAME": "Test Committer", "GIT_COMMITTER_EMAIL": "c@example.com",
                "GIT_AUTHOR_DATE": "2026-10-01T12:00:00+02:00", "GIT_COMMITTER_DATE": "2026-10-01T12:00:00+02:00",
            ])
            remote = t.url.appendingPathComponent("remote.git"); local = t.url.appendingPathComponent("local"); other = t.url.appendingPathComponent("other")
            let seed = try t.sub("seed")
            try git(t.url, "init", "-q", "--bare", "-b", "main", remote.path)
            try git(t.url, "init", "-q", "-b", "main", seed.path)
            try t.file("seed/scripts/build_ipa_from_nsp.py", Data("print('hi')\n".utf8))
            try t.file("seed/dm/tools/nx_extract/Program.cs", Data("// x\n".utf8))
            try t.file("seed/README", Data("one\n".utf8))
            try git(seed, "add", "-A")
            try git(seed, "commit", "-q", "-m", "First commit")
            try git(seed, "push", "-q", remote.path, "main")
            try git(t.url, "clone", "-q", remote.path, other.path)
        }

        @discardableResult
        func git(_ dir: URL, _ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", dir.path] + args
            p.environment = env.variables
            p.currentDirectoryURL = t.url
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run(); p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus != 0 {
                throw GitError.command(args.joined(separator: " "), String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            return text
        }

        func commit(_ dir: URL, _ file: String, _ text: String, _ message: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(file))
            try git(dir, "add", "-A")
            try git(dir, "commit", "-q", "-m", message)
        }
    }

    @Test func lifecycle() async throws {
        let f = try Fixture(); defer { f.t.remove() }
        let lines = Box<String>()
        try await GitRepository.clone(remote: f.remote.path, to: f.local, environment: f.env) { lines.add($0) }
        #expect(lines.all.contains { $0.hasPrefix("Cloning into") })
        let repo = GitRepository(path: f.local, environment: f.env)
        let first = try f.git(f.local, "rev-parse", "HEAD")

        var s = await repo.status()
        #expect(s.exists && s.isNXNative && s.isGitRepository)
        #expect(s.branch == "main" && s.upstream == "origin/main" && s.remoteURL == f.remote.path)
        #expect(s.head?.sha == first && s.head?.subject == "First commit" && s.head?.author == "Test Author")
        #expect(s.head?.date == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        #expect(s.head?.shortSHA.count ?? 0 >= 7 && first.hasPrefix(s.head?.shortSHA ?? "x"))
        #expect(s.ahead == 0 && s.behind == 0 && s.incoming.isEmpty && s.modifiedFiles.isEmpty)
        #expect(s.lastFetched == nil)   // a clone writes no FETCH_HEAD

        try f.commit(f.other, "README", "two\n", "Upstream change")
        try f.git(f.other, "push", "-q", "origin", "main")
        try await repo.fetch()
        s = await repo.status()
        #expect(s.behind == 1 && s.ahead == 0)
        #expect(s.incoming.map(\.subject) == ["Upstream change"])
        #expect(s.lastFetched.map { abs($0.timeIntervalSinceNow) < 120 } == true)

        try f.commit(f.local, "local.txt", "mine\n", "Local change")
        try Data("edited\n".utf8).write(to: f.local.appendingPathComponent("README"))
        try Data("new\n".utf8).write(to: f.local.appendingPathComponent("untracked.txt"))
        s = await repo.status()
        #expect(s.ahead == 1 && s.behind == 1)
        #expect(s.outgoing.map(\.subject) == ["Local change"] && s.incoming.map(\.subject) == ["Upstream change"])
        #expect(s.modifiedFiles == ["README"])
        let v = try await repo.version(), localHead = try f.git(f.local, "rev-parse", "HEAD")
        #expect(v.commit == localHead && v.subject == "Local change" && v.branch == "main" && v.modified && v.describe == nil)
        #expect(v.commitDate != nil && v.commit.hasPrefix(v.shortCommit))

        await #expect(throws: GitError.self) { try await repo.pullFastForward() }   // diverged, and README is modified
        try await repo.resetHardToUpstream()
        s = await repo.status()
        #expect(s.ahead == 0 && s.behind == 0 && s.modifiedFiles.isEmpty && s.outgoing.isEmpty)
        #expect(s.head?.subject == "Upstream change")

        try f.commit(f.other, "README", "three\n", "Second upstream change")
        try f.git(f.other, "push", "-q", "origin", "main")
        try await repo.fetch()
        let (old, new) = try await repo.pullFastForward(), otherHead = try f.git(f.other, "rev-parse", "HEAD")
        #expect(old != new && new == otherHead)
        #expect(await repo.commitCount(from: first) == 2)
        #expect(await repo.commitCount(from: "no-such-ref") == nil)
        #expect(await repo.isAncestor(first, of: "HEAD"))
        #expect(await !repo.isAncestor("HEAD", of: first))
        #expect(await repo.lastCommit(touching: ["scripts", "dm/tools"]) == first)
        #expect(await repo.lastCommit(touching: ["README"]) == new)
        #expect(await repo.lastCommit(touching: ["nothing/here"]) == nil)

        try f.git(f.local, "tag", "v1")
        #expect(try await repo.version().describe == "v1")
        #expect(try await repo.version().modified == false)
    }

    @Test func notARepository() async throws {
        let t = try TempDir(); defer { t.remove() }
        let env = ShellEnvironment(variables: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CEILING_DIRECTORIES": t.url.path])
        let plain = try t.sub("plain")
        let s = await GitRepository(path: plain, environment: env).status()
        #expect(s.exists && !s.isGitRepository && !s.isNXNative && s.head == nil)
        let missing = await GitRepository(path: t.url.appendingPathComponent("missing"), environment: env).status()
        #expect(!missing.exists && !missing.isGitRepository)
        await #expect(throws: GitError.notARepository(plain.path)) { try await GitRepository(path: plain, environment: env).fetch() }
        await #expect(throws: GitError.notARepository(plain.path)) { try await GitRepository(path: plain, environment: env).version() }
    }

    @Test func folderInsideAnotherRepository() async throws {
        let f = try Fixture(); defer { f.t.remove() }
        try f.t.file("other/vendor/nxnative/scripts/build_ipa_from_nsp.py", Data("print('hi')\n".utf8))
        try f.t.file("other/vendor/nxnative/dm/tools/nx_extract/Program.cs", Data("// x\n".utf8))
        let inner = f.other.appendingPathComponent("vendor/nxnative"), repo = GitRepository(path: inner, environment: f.env)
        let s = await repo.status()
        #expect(s.exists && s.isNXNative && !s.isGitRepository && s.branch == nil && s.head == nil)
        await #expect(throws: GitError.notARepository(inner.path)) { try await repo.fetch() }
        await #expect(throws: GitError.notARepository(inner.path)) { try await repo.resetHardToUpstream() }
        await #expect(throws: GitError.notARepository(inner.path)) { try await repo.version() }
        let link = f.t.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.other)
        #expect(await GitRepository(path: link, environment: f.env).status().isGitRepository)   // the checkout through a symbolic link is still the checkout
    }

    @Test func statusLeavesTheIndexAlone() async throws {
        let f = try Fixture(); defer { f.t.remove() }
        let readme = f.other.appendingPathComponent("README"), index = f.other.appendingPathComponent(".git/index")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: readme.path)   // new stat data: a refresh would rewrite the index
        let before = try Data(contentsOf: index), repo = GitRepository(path: f.other, environment: f.env)
        #expect(await repo.status().modifiedFiles.isEmpty)
        #expect(try await repo.version().modified == false)
        #expect(try Data(contentsOf: index) == before)
        _ = try f.git(f.other, "status", "--porcelain")
        #expect(try Data(contentsOf: index) != before)   // as a plain git status does
    }

    @Test func noUpstream() async throws {
        let f = try Fixture(); defer { f.t.remove() }
        try f.git(f.other, "checkout", "-q", "-b", "topic")
        let repo = GitRepository(path: f.other, environment: f.env)
        await #expect(throws: GitError.noUpstream) { try await repo.pullFastForward() }
        await #expect(throws: GitError.noUpstream) { try await repo.resetHardToUpstream() }
        let s = await repo.status()
        #expect(s.branch == "topic" && s.upstream == nil && s.remoteURL == f.remote.path)
        try f.git(f.other, "checkout", "-q", "--detach")
        #expect(await repo.status().branch == nil)
    }

    @Test func cloneFailure() async throws {
        let t = try TempDir(); defer { t.remove() }
        let env = ShellEnvironment(variables: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": t.url.path])
        do {
            try await GitRepository.clone(remote: t.url.appendingPathComponent("nothing.git").path, to: t.url.appendingPathComponent("dest"), environment: env) { _ in }
            Issue.record("the clone did not fail")
        } catch let GitError.command(args, stderr) {
            #expect(args.hasPrefix("clone ") && !stderr.isEmpty)
        }
    }

    @Test func parseCommits() {
        let text = "aaaa\u{1f}aa\u{1f}Subject one\u{1f}2026-10-01T12:00:00+02:00\u{1f}Ann\u{1e}\nbbbb\u{1f}bb\u{1f}Two: with \u{1f}\u{1f}x\u{1e}\ncccc\u{1f}cc\u{1f}Three\u{1f}2026-10-02T08:30:00Z\u{1f}Bob\u{1e}\n"
        let c = GitRepository.parseCommits(text)
        #expect(c.map(\.sha) == ["aaaa", "cccc"])
        #expect(c[0] == CommitInfo(sha: "aaaa", shortSHA: "aa", subject: "Subject one", date: Date(timeIntervalSince1970: 1_790_848_800), author: "Ann"))
        #expect(c[1].date == Date(timeIntervalSince1970: 1_790_929_800))
        #expect(GitRepository.parseCommits("") == [])
    }

    @Test func parsePorcelain() {
        #expect(GitRepository.parsePorcelain(" M README\0M  dm/x.c\0R  new name.txt\0old name.txt\0?? untracked\0 D gone\0") == ["README", "dm/x.c", "new name.txt", "gone"])
        #expect(GitRepository.parsePorcelain("") == [])
    }

    @Test func parseAheadBehind() {
        #expect(GitRepository.parseAheadBehind("2\t5") ?? (0, 0) == (2, 5))
        #expect(GitRepository.parseAheadBehind("x\t5") == nil)
        #expect(GitRepository.parseAheadBehind("3") == nil)
    }
}
