// Subprocess: line splitting, output streams, exit statuses, environment and folder, cancelling a process group, timeouts
import Darwin
import Foundation
import Testing
@testable import ConverterCore

struct SubprocessTests {
    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    @Test func lineSplitter() {
        var s = LineSplitter()
        #expect(s.feed(Array("ab".utf8)) == [])
        #expect(s.feed(Array("c\r".utf8)) == [])
        #expect(s.feed(Array("\nd\n\ne".utf8)) == ["abc", "d", ""])
        #expect(s.feed([0xFF, 0x41, 0x0A]) == ["e\u{FFFD}A"])
        #expect(s.feed([0xC3]) == [])   // a character split between reads
        #expect(s.feed([0xA9, 0x0A]) == ["é"])
        #expect(s.feed(Array("tail".utf8)) == [])
        #expect(s.finish() == "tail")
        #expect(s.finish() == nil)
    }

    @Test func lineSplitterCarriageReturns() {
        var s = LineSplitter(splitsCarriageReturns: true)
        #expect(s.feed(Array("Receiving 10%\rReceiving 20%\r".utf8)) == ["Receiving 10%", "Receiving 20%"])
        #expect(s.feed(Array("\ndone\r\nnext\n".utf8)) == ["done", "next"])
    }

    @Test func outputStreams() async throws {
        let lines = Box<String>()
        let p = Subprocess(executable: "sh", arguments: ["-c", #"echo one; echo two >&2; printf '\377x\n'; printf 'five\n' >&2; printf 'three\r\nfour'"#], environment: env)
        try p.start { stream, line in lines.add((stream == .stdout ? "out " : "err ") + line) }
        #expect(p.processIdentifier > 0)
        #expect(await p.waitUntilExit() == 0)
        #expect(lines.all.filter { $0.hasPrefix("out ") } == ["out one", "out \u{FFFD}x", "out three", "out four"])
        #expect(lines.all.filter { $0.hasPrefix("err ") } == ["err two", "err five"])
    }

    @Test func run() async throws {
        let r = try await Subprocess.run("sh", ["-c", "echo a; echo b; echo c >&2; exit 3"], environment: env)
        #expect(r == ProcessOutput(status: 3, stdout: "a\nb", stderr: "c"))
        #expect(!r.succeeded)
        #expect(try await Subprocess.run("/usr/bin/true", [], environment: env).succeeded)
    }

    @Test func signalledExit() async throws {
        #expect(try await Subprocess.run("sh", ["-c", "kill -TERM $$"], environment: env).status == 128 + SIGTERM)
        #expect(try await Subprocess.run("sh", ["-c", "kill -KILL $$"], environment: env).status == 128 + SIGKILL)
    }

    @Test func environmentAndFolder() async throws {
        let t = try TempDir(); defer { t.remove() }
        let r = try await Subprocess.run("env", [], environment: ["PATH": "/usr/bin:/bin", "NXC_TEST": "a b=c"])
        #expect(r.stdout.split(separator: "\n").sorted() == ["NXC_TEST=a b=c", "PATH=/usr/bin:/bin"])
        let pwd = try await Subprocess.run("/bin/pwd", ["-P"], environment: env, currentDirectory: t.url)
        #expect(pwd.stdout == t.url.path)
        let stdin = try await Subprocess.run("cat", [], environment: env, timeout: 5)   // stdin is /dev/null
        #expect(stdin == ProcessOutput(status: 0, stdout: "", stderr: ""))
    }

    @Test func ownProcessGroup() async throws {
        let p = Subprocess(executable: "sh", arguments: ["-c", "ps -o pgid= -p $$"], environment: env)
        let lines = Box<String>()
        try p.start { _, line in lines.add(line.trimmingCharacters(in: .whitespaces)) }
        _ = await p.waitUntilExit()
        #expect(lines.all == ["\(p.processIdentifier)"])
    }

    @Test func ownSession() async throws {
        let p = Subprocess(executable: "sleep", arguments: ["1"], environment: env)
        try p.start { _, _ in }
        #expect(getsid(p.processIdentifier) == p.processIdentifier)   // a session of its own: no controlling terminal to be stopped by
        _ = await p.waitUntilExit()
    }

    @Test func runStopsWhenItsTaskIsCancelled() async throws {
        let env = env, start = Date()
        let task = Task { try await Subprocess.run("sleep", ["30"], environment: env) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func notFound() async {
        await #expect(throws: SubprocessError.executableNotFound("no-such-tool-xyz")) { try await Subprocess.run("no-such-tool-xyz", [], environment: env) }
        await #expect(throws: SubprocessError.executableNotFound("sh")) { try await Subprocess.run("sh", [], environment: ["PATH": "/nonexistent"]) }
        await #expect(throws: SubprocessError.executableNotFound("/nonexistent/sh")) { try await Subprocess.run("/nonexistent/sh", [], environment: env) }
        let p = Subprocess(executable: "sh", arguments: [], environment: env)
        #expect(await p.waitUntilExit() == -1)   // never started
        await p.cancel()
    }

    @Test func cancelStopsTheGroup() async throws {
        let p = Subprocess(executable: "sh", arguments: ["-c", "sleep 30 & sleep 30; wait"], environment: env)
        try p.start { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pgid = p.processIdentifier
        let start = Date()
        await p.cancel(grace: 1)   // the background sleep ignores SIGINT (a non-interactive shell's background job): SIGTERM stops it
        let status = await p.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(status != 0)
        var gone = false   // the killed background sleep may be a zombie for a moment, until launchd reaps it
        for _ in 0..<40 where !gone {
            gone = kill(-pgid, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone)
    }

    @Test func cancelEscalates() async throws {
        let p = Subprocess(executable: "sh", arguments: ["-c", "trap '' INT TERM; sleep 30"], environment: env)
        try p.start { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        await p.cancel(grace: 0.3)
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(await p.waitUntilExit() == 128 + SIGKILL)
    }

    @Test func interruptExitCode() async throws {
        let p = Subprocess(executable: "sh", arguments: ["-c", "trap 'exit 130' INT; while :; do sleep 0.05; done"], environment: env)
        try p.start { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        p.signalGroup(SIGINT)
        #expect(await p.waitUntilExit() == 130)
    }

    @Test func timeout() async throws {
        let start = Date()
        await #expect(throws: SubprocessError.timedOut("sleep")) { try await Subprocess.run("sleep", ["20"], environment: env, timeout: 0.3) }
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(try await Subprocess.run("sh", ["-c", "echo quick"], environment: env, timeout: 10).stdout == "quick")
    }

    @Test func exitStatus() {
        #expect(Subprocess.exitStatus(0) == 0)
        #expect(Subprocess.exitStatus(3 << 8) == 3)
        #expect(Subprocess.exitStatus(SIGINT) == 130)
        #expect(Subprocess.exitStatus(SIGKILL | 0x80) == 137)   // with a core dump flag
    }
}
