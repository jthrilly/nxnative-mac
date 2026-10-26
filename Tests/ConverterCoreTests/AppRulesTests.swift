// The app's rules as pure functions: why a conversion failed (FailureTracker), the newest of repeated checks (LatestRun), what may run on a port at the same
// time and whether a Terminal session is open (PortRules), the scripts handed to Terminal and /bin/sh (AppScripts), the update advice (RepositoryAdvice),
// the quit prompt (QuitRules) and a folder added again (QueueRules)
import Darwin
import Foundation
import Testing
@testable import ConverterCore

struct FailureTrackerTests {
    @Test func warningOfAnEarlierStageIsNotTheFailure() {
        var t = FailureTracker()
        t.observe(.stage(k: 1, n: 3, name: "Profile", step: ""))
        t.observe(.say("[RED] no profile matches: a provisional one is guessed"))
        t.observe(.stageEnd(k: 1, name: "Profile", ok: true, summary: "", elapsed: 1))
        t.observe(.stage(k: 2, n: 3, name: "Shaders", step: ""))
        #expect(t.fatal == nil)
        #expect(t.message(status: 1, lastError: "Traceback: ValueError") == "Traceback: ValueError")
        #expect(t.message(status: 1, lastError: nil) == "The conversion stopped with exit status 1.")
    }

    @Test func errorAfterTheStageEndedIsTheFailure() {
        var t = FailureTracker()
        t.observe(.stage(k: 2, n: 3, name: "Shaders", step: ""))
        t.observe(.stageEnd(k: 2, name: "Shaders", ok: false, summary: "", elapsed: 3))
        t.observe(.say("[12:01:02] [RED] the translator failed on 3 shaders"))
        #expect(t.fatal == "the translator failed on 3 shaders")
        #expect(t.message(status: 1, lastError: "stderr line") == "the translator failed on 3 shaders")
    }

    @Test func signalStatusNamesTheSignal() {
        let t = FailureTracker()
        let killed = t.message(status: 128 + SIGKILL, lastError: "stale")
        #expect(killed.hasPrefix("The conversion was stopped by signal 9 ("))
        #expect(killed.contains("memory runs out"))
        let segv = t.message(status: 128 + SIGSEGV, lastError: nil)
        #expect(segv.contains("signal 11") && !segv.contains("memory"))
        #expect(t.message(status: 255, lastError: nil) == "The conversion stopped with exit status 255.")
    }
}

@MainActor struct LatestRunTests {
    @Test func onlyTheNewestRequestIsApplied() async {
        let latest = LatestRun()
        let applied = Box<Int>()
        let slow = latest.run({ try? await Task.sleep(for: .milliseconds(300)); return 1 }) { applied.add($0) }
        let fast = latest.run({ 2 }) { applied.add($0) }
        await fast.value
        await slow.value
        #expect(applied.all == [2])
    }

    @Test func aBurstWithADelayRunsOnce() async {
        let latest = LatestRun()
        let runs = Box<Int>()
        let applied = Box<Int>()
        var last: Task<Void, Never>?
        for i in 1...5 { last = latest.run(after: .milliseconds(100), { runs.add(i); return i }) { applied.add($0) } }
        await last?.value
        #expect(runs.all == [5])
        #expect(applied.all == [5])
    }
}

struct PortRulesTests {
    let port = PortRecord(titleID: "0100ABCD00000000", gameName: "Super Game", folder: "/Volumes/Games/Super Game", workspace: "/Users/p/nxnative-ports/0100ABCD00000000",
                          branch: "port/0100ABCD00000000", baseCommit: "abc", createdAt: Date(timeIntervalSince1970: 0))

    @Test func agentRunBlocks() {
        #expect(PortRules.runBlock(port, PortSituation()) == nil)
        #expect(PortRules.runBlock(port, PortSituation(agent: (titleID: "0100FFFF00000000", name: "Codex", game: "Other"))) == .agentRunning(agent: "Codex", game: "Other"))
        #expect(PortRules.runBlock(port, PortSituation(operation: "Saving a checkpoint…")) == .operation("Saving a checkpoint…"))
        #expect(PortRules.runBlock(port, PortSituation(terminalSession: true)) == .terminalSession)
        #expect(PortRules.runBlock(port, PortSituation(conversion: (name: "Super Game", folder: "/Volumes/Games/Super Game/", repository: nil))) == .converting("Super Game"))
        #expect(PortRules.runBlock(port, PortSituation(conversion: (name: "Other", folder: "/Volumes/Games/Other", repository: port.workspace))) == .converting("Other"))
        #expect(PortRules.runBlock(port, PortSituation(conversion: (name: "Other", folder: "/Volumes/Games/Other", repository: "/Users/p/nxnative"))) == nil)
    }

    @Test func operationAndBuildBlocks() {
        let elsewhere = PortSituation(agent: (titleID: "0100FFFF00000000", name: "Codex", game: "Other"))
        let here = PortSituation(agent: (titleID: port.titleID, name: "Claude Code", game: "Super Game"))
        #expect(PortRules.operationBlock(port, elsewhere) == nil)
        #expect(PortRules.operationBlock(port, here) == .agentRunning(agent: "Claude Code", game: "Super Game"))
        #expect(PortRules.operationBlock(port, PortSituation(conversion: (name: "Super Game", folder: port.folder, repository: nil))) == nil)
        #expect(PortRules.operationBlock(port, PortSituation(conversion: (name: "Super Game", folder: port.folder, repository: port.workspace))) == .converting("Super Game"))
        #expect(PortRules.buildBlock(port, elsewhere) == nil)
        #expect(PortRules.buildBlock(port, here) != nil)
        #expect(PortRules.buildBlock(port, PortSituation(conversion: (name: "Other", folder: "/x", repository: port.workspace))) == nil)
        #expect(PortRules.buildBlock(port, PortSituation(terminalSession: true)) == .terminalSession)
        #expect(PortBlock.operation("Rebasing…").message.hasPrefix("Rebasing on this port"))
    }

    @Test func pathsAndBranches() {
        #expect(PortRules.samePath("/a/b/", "/a/./b"))
        #expect(!PortRules.samePath("", ""))
        #expect(!PortRules.samePath("/a/b", "/a/c"))
        #expect(PortRules.titleID(fromBranch: "port/0100ABCD00000000") == "0100ABCD00000000")
        #expect(PortRules.titleID(fromBranch: "main") == nil)
        #expect(PortRules.titleID(fromBranch: "port/") == nil)
        #expect(PortRules.titleID(fromBranch: "port/a/b") == nil)
        #expect(PortRules.titleID(fromBranch: nil) == nil)
    }

    @Test func sessionMarker() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let id = UUID()
        let marker = PortRules.sessionMarker(runFolder: dir.url, runID: id)
        #expect(marker.lastPathComponent == "\(id.uuidString).session")
        let now = Date()
        #expect(PortRules.sessionIsOpen(marker: marker, startedAt: now.addingTimeInterval(-10), now: now))       // Terminal is still opening it
        #expect(!PortRules.sessionIsOpen(marker: marker, startedAt: now.addingTimeInterval(-120), now: now))
        try dir.file(marker.lastPathComponent, Data("\(getpid())\n".utf8))
        #expect(PortRules.sessionIsOpen(marker: marker, startedAt: now.addingTimeInterval(-3600), now: now))
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        try dir.file(marker.lastPathComponent, Data("\(exited.processIdentifier)".utf8))
        #expect(!PortRules.sessionIsOpen(marker: marker, startedAt: now.addingTimeInterval(-3600), now: now))
        try dir.file(marker.lastPathComponent, Data("garbage".utf8))
        #expect(!PortRules.sessionIsOpen(marker: marker, startedAt: now, now: now))
    }

    @Test func leftOutFiles() {
        #expect(PortRules.leftOut([]) == nil)
        let skipped = [SkippedFile(path: "big.bin", reason: .large), SkippedFile(path: "prod.keys", reason: .gameFile), SkippedFile(path: "x.o", reason: .binary),
                       SkippedFile(path: "vendor/repo", reason: .repository)]
        #expect(PortRules.leftOut(skipped) == "big.bin (larger than 5 MB)\nprod.keys (a game or key file)\nx.o (a new binary file)\nvendor/repo (a git repository of its own)")
        #expect(PortRules.leftOut(skipped, limit: 2) == "big.bin (larger than 5 MB)\nprod.keys (a game or key file)\n… and 2 more")
    }
}

struct AppScriptsTests {
    @Test func gameNamesOnlyGoIntoCommentLines() {
        #expect(AppScripts.commentLine("Evil\nrm -rf ~\r\u{2028}x") == "# Evil rm -rf ~  x")
        let fix = AppScripts.setupFix(title: "Install\nthe tools", command: "brew install python")
        #expect(fix.components(separatedBy: "\n") == ["#!/bin/zsh -l", "# Install the tools", "brew install python", "echo; echo \"Done. You can close this window.\"", ""])
    }

    @Test func portSessionWritesAndRemovesItsMarker() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let marker = dir.url.appendingPathComponent("it's.session")
        let script = AppScripts.portSession(title: "Super Game\n$(touch pwned)", line: "cat \"$nxnative_session\" > \(AgentCommand.shellQuote(dir.url.path))/seen; exec true",
                                            marker: marker)
        #expect(script.components(separatedBy: "\n")[1] == "# Super Game $(touch pwned)")
        let file = try dir.file("session.command", Data(script.utf8))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", file.path]
        shell.currentDirectoryURL = dir.url
        shell.standardOutput = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        let seen = try String(contentsOf: dir.url.appendingPathComponent("seen"), encoding: .utf8)
        #expect(pid_t(seen.trimmingCharacters(in: .whitespacesAndNewlines)) == shell.processIdentifier)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("pwned").path))
    }

    @Test func relaunchWaitsForTheProcess() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let bin = try dir.sub("bin")
        let log = dir.url.appendingPathComponent("opened")
        try dir.file("bin/open", Data("#!/bin/sh\necho \"$1\" > \(AgentCommand.shellQuote(log.path))\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("open").path)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.6"]
        try sleeper.run()
        let started = Date()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = AppScripts.relaunchArguments(bundle: "/Applications/My App.app", pid: sleeper.processIdentifier)
        relaunch.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        try relaunch.run()
        sleeper.waitUntilExit()   // reaped, so kill -0 sees it gone
        relaunch.waitUntilExit()
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(try String(contentsOf: log, encoding: .utf8) == "/Applications/My App.app\n")
    }
}

struct RepositoryAdviceTests {
    func status(files: [String] = [], ahead: Int = 0, outgoing: [CommitInfo] = []) -> RepositoryStatus {
        RepositoryStatus(path: URL(fileURLWithPath: "/r"), exists: true, isNXNative: true, isGitRepository: true, branch: "main", upstream: "origin/main", remoteURL: nil,
                         head: nil, modifiedFiles: files, ahead: ahead, behind: 1, incoming: [], outgoing: outgoing, lastFetched: nil)
    }

    func commit(_ sha: String, _ subject: String) -> CommitInfo {
        CommitInfo(sha: sha + "0000", shortSHA: sha, subject: subject, date: Date(timeIntervalSince1970: 0), author: "p")
    }

    @Test func pullBlockedOnlyByLocalChanges() {
        #expect(RepositoryAdvice.pullBlockedByLocalChanges(error: "error: Your local changes to the following files would be overwritten by merge"))
        #expect(!RepositoryAdvice.pullBlockedByLocalChanges(error: "fatal: Not possible to fast-forward, aborting."))
        #expect(!RepositoryAdvice.pullBlockedByLocalChanges(error: "fatal: unable to access 'https://github.com/': Could not resolve host"))
    }

    @Test func resetWarningNamesFilesAndCommits() {
        let w = RepositoryAdvice.resetWarning(status(files: ["README.md"], ahead: 2, outgoing: [commit("aaa1111", "My fix"), commit("bbb2222", "Another")]))
        #expect(w.hasPrefix("git reset --hard origin/main makes the checkout match origin/main."))
        #expect(w.contains("these files:\nREADME.md"))
        #expect(w.contains("2 local commits not on origin/main off the branch (only git's reflog keeps them):\naaa1111 My fix\nbbb2222 Another"))
        #expect(w.hasSuffix("This cannot be undone."))
        let more = RepositoryAdvice.resetWarning(status(ahead: 3, outgoing: [commit("aaa1111", "My fix")]), limit: 1)
        #expect(more.contains("aaa1111 My fix\n… and 2 more"))
        #expect(!more.contains("these files"))
        #expect(RepositoryAdvice.resetWarning(status()).contains("any changes to the tracked files"))
    }
}

struct CoordinationTests {
    @Test func quitPrompt() {
        #expect(QuitRules.prompt(conversion: nil, installing: false, agent: nil, operations: []) == nil)
        let converting = QuitRules.prompt(conversion: "Super Game", installing: false, agent: nil, operations: [])
        #expect(converting?.message == "Stop converting Super Game?" && converting?.button == "Stop and Quit")
        let installing = QuitRules.prompt(conversion: "Super Game", installing: true, agent: nil, operations: [])
        #expect(installing?.message == "Quit when Super Game is installed?" && installing?.button == "Quit After the Install")
        let all = QuitRules.prompt(conversion: "Super Game", installing: true, agent: (name: "Codex", game: "Other"), operations: ["Checking for updates…"])
        #expect(all?.message == "Stop the agent porting Other and \u{201C}Checking for updates\u{201D}?")
        #expect(all?.informative.contains("waits until the install has finished") == true)
        #expect(all?.button == "Stop and Quit")
    }

    @Test func folderAddedAgain() {
        let main = URL(fileURLWithPath: "/r/nxnative"), worktree = URL(fileURLWithPath: "/p/ports/0100ABCD00000000")
        #expect(QueueRules.reuse(existing: worktree, active: false, requested: nil) == .keep)
        #expect(QueueRules.reuse(existing: worktree, active: true, requested: URL(fileURLWithPath: "/p/ports/0100ABCD00000000/")) == .keep)
        #expect(QueueRules.reuse(existing: nil, active: false, requested: worktree) == .switchTo(worktree))
        #expect(QueueRules.reuse(existing: main, active: false, requested: worktree) == .switchTo(worktree))
        #expect(QueueRules.reuse(existing: main, active: true, requested: worktree) == .busy)
    }
}
