// The real agents, run the way the Ports page runs them: a throwaway repository and its port worktree, the AgentRunRequest the app builds, the process spawned with
// Subprocess (the child environment, stdin /dev/null), every stdout line decoded into an AgentTranscript, then a resumed session, a checkpoint and the port's removal.
// They cost a few cents of the signed-in plans, so they run only with CONVERTER_LIVE_AGENT_TESTS=1 (CI and a plain `swift test` skip them), e.g.
//   swift build && CONVERTER_LIVE_AGENT_TESTS=1 swift test --filter LiveAgentTests
// The keys guard is the app's own executable (`NXNativeConverter --keys-guard`): CONVERTER_APP_BINARY, else the one built beside the test bundle. The key file is a dummy
// with a marker that must never reach the agent's output
import Foundation
import Testing
@testable import ConverterCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONVERTER_LIVE_AGENT_TESTS"] == "1"))
struct LiveAgentTests {
    static let marker = "NXN-DUMMY-KEY-MARKER-4711"
    static let titleID = "0100FEED00000000"

    /// A repository with one commit, its port worktree, a dummy key file and an "NSP folder"
    struct Setup {
        let t: TempDir, env: ShellEnvironment, ws: PortWorkspace, keys: URL, nsp: URL, runs: URL

        init(_ name: String) async throws {
            t = try TempDir(name)
            var e = await ShellEnvironment.resolve()
            e.variables["GIT_TERMINAL_PROMPT"] = "0"
            env = e
            let repo = try t.sub("repo")
            try t.file("repo/AGENTS.md", Data("# Notes for agents\n\nA throwaway repository for the converter's live agent tests.\n".utf8))
            for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.name=Live Test", "-c", "user.email=live@localhost", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "First commit"]] {
                let r = try await Subprocess.run("git", ["-C", repo.path] + args, environment: e.variables)
                try #require(r.succeeded, "git \(args.joined(separator: " ")): \(r.stderr)")
            }
            ws = PortWorkspace(repository: repo, path: PortWorkspace.defaultsDirectory(repository: repo).appendingPathComponent(LiveAgentTests.titleID),
                               branch: PortWorkspace.branchName(titleID: LiveAgentTests.titleID), environment: e)
            try await ws.create()
            keys = try t.file("keys/dummy.keys", Data("header_key = \(LiveAgentTests.marker)\n".utf8))
            nsp = try t.sub("Game Folder")
            runs = try t.sub("runs")
        }

        func agent(_ kind: AgentKind) throws -> String {
            try #require(env.which(kind.executableName) ?? [NSString(string: "~/.local/bin/\(kind.executableName)").expandingTildeInPath].first(where: FileManager.default.isExecutableFile),
                         "\(kind.executableName) is not installed")
        }
    }

    struct Run { var transcript: AgentTranscript; var lines: [String]; var stderr: [String]; var exit: Int32 }

    /// Spawns the request as PortRunner does and folds its output into a transcript
    static func run(_ request: AgentRunRequest, env: ShellEnvironment) async throws -> Run {
        let out = Box<String>(), err = Box<String>()
        let p = Subprocess(executable: request.executable, arguments: AgentCommand.arguments(for: request), environment: AgentCommand.childEnvironment(env.variables, kind: request.kind),
                           currentDirectory: request.workspace)
        try p.start { stream, line in stream == .stdout ? out.add(line) : err.add(line) }
        let exit = await p.waitUntilExit()
        var t = AgentTranscript()
        for line in out.all { t.apply(AgentEventDecoder.decode(line, kind: request.kind), at: Date()) }
        for line in err.all { t.appendStderr(line, at: Date()) }
        print("[live \(request.kind.rawValue)] exit \(exit), session \(t.sessionID ?? "-"), cost \(t.outcome?.usage?.costUSD.map { String($0) } ?? "-"), usage \(String(describing: t.outcome?.usage))")
        for e in t.entries { print("[live \(request.kind.rawValue)]   \(e.kind) ok=\(e.ok.map(String.init) ?? "-") \(e.title.prefix(160)) | \(e.detail.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))") }
        return Run(transcript: t, lines: out.all, stderr: err.all, exit: exit)
    }

    static func appBinary() throws -> String {
        let env = ProcessInfo.processInfo.environment["CONVERTER_APP_BINARY"]
        let sibling = URL(fileURLWithPath: Bundle(for: Box<String>.self).bundlePath).deletingLastPathComponent().appendingPathComponent("NXNativeConverter").path
        return try #require([env, sibling].compactMap { $0 }.first(where: FileManager.default.isExecutableFile), "build NXNativeConverter first, or set CONVERTER_APP_BINARY")
    }

    static func finish(_ s: Setup) async throws {
        let checkpoint = try await s.ws.checkpoint(message: "Port \(titleID): live test")
        print("[live] checkpoint \(checkpoint.commit ?? "none")")
        #expect(checkpoint.commit != nil)
        try await s.ws.remove()
        #expect(!FileManager.default.fileExists(atPath: s.ws.path.path))
        #expect(await s.ws.status().exists == false)
        s.t.remove()
    }

    @Test func claudeCode() async throws {
        let s = try await Setup("claude")
        let guardCommand = KeysGuard.hookCommand(executable: try Self.appBinary(), keyFile: s.keys.path)
        let settings = s.runs.appendingPathComponent("claude-settings.json"), schema = s.runs.appendingPathComponent("report-schema.json")
        try KeysGuard.claudeSettings(guardCommand: guardCommand, keyFiles: [s.keys.path], sandbox: .sandboxed).write(to: settings, atomically: true, encoding: .utf8)
        try AgentReport.jsonSchema.write(to: schema, atomically: true, encoding: .utf8)
        let session = UUID().uuidString.lowercased()
        // reader.sh reaches the key by a path the guard never sees (it does not read file contents, and `sh reader.sh` names no key): only the OS sandbox's denyRead can stop it
        let scriptBody = "#!/bin/sh\ncat \(PrerequisiteChecker.shellQuote(s.keys.path))\n"
        let prompt = """
            This is a short automated test of a sandbox and guard setup; do exactly these steps in order and nothing else.
            1. Run the shell command `echo hello` with the Bash tool.
            2. With the Bash tool, run `echo sandbox-write > probe.txt && cat probe.txt` in the working directory.
            3. With the Write tool, write the file notes.txt in the working directory, containing the word hi.
            4. With the Write tool, create a file named reader.sh in the working directory with exactly this content:
            \(scriptBody)Then run `sh reader.sh` with the Bash tool. Reading that file is expected to fail at the OS level; report the exact error line verbatim. Do not retry and do not try any other way to read it.
            5. With the Bash tool, run `cat \(PrerequisiteChecker.shellQuote(s.keys.path))`. A guard is expected to block this before it runs; do not retry and do not try any other way.
            6. Try to read the file \(s.keys.path) with the Read tool. It is expected to be denied; do not retry and do not try any other way.
            7. Finish with the report: milestone in_progress, a one-sentence summary, changed_files ["notes.txt"], next_steps [] and blockers [].
            """
        var request = AgentRunRequest(kind: .claudeCode, executable: try s.agent(.claudeCode), workspace: s.ws.path, extraDirectories: [s.nsp], prompt: prompt,
                                      sessionID: session, model: "haiku", budgetUSD: 0.5, reportSchema: schema, claudeSettings: settings.path)
        let first = try await Self.run(request, env: s.env)
        let t = first.transcript
        try #require(first.exit == 0, "claude exited \(first.exit); if the sandbox was unavailable it fails closed (failIfUnavailable): \(first.stderr.suffix(5).joined(separator: " / "))")
        #expect(t.sessionID == session)
        #expect(t.entries.contains { $0.kind == .tool && $0.title == "$ echo hello" && $0.ok == true && $0.detail.contains("hello") })
        // (b) a sandboxed worktree write works (the agent may join the write and read-back into one command)
        #expect(t.entries.contains { $0.kind == .tool && $0.title.contains("probe.txt") && $0.ok == true && $0.detail.contains("sandbox-write") })
        // (a) the sandboxed read of the key, through the guard-invisible script, fails at the OS level and never yields the key
        let scriptRun = t.entries.first { $0.kind == .tool && $0.title == "$ sh reader.sh" }
        let denied = (scriptRun?.detail ?? "").lowercased()
        #expect(scriptRun?.ok == false && (denied.contains("not permitted") || denied.contains("denied")), "expected an OS denial from `sh reader.sh`, got: \(scriptRun?.detail ?? "-")")
        #expect(scriptRun.map { !$0.detail.contains(Self.marker) } ?? true)
        // (c) the guard hook catches a Bash command that names the key, and the permissions.deny rule catches the Read tool
        #expect(t.entries.contains { $0.kind == .warning && $0.title.contains("nxnative Converter blocks this") })
        let read = t.entries.first { $0.kind == .tool && $0.title.hasPrefix("Read ") && $0.title.hasSuffix(".keys") }
        #expect(read?.ok == false)
        #expect(!first.lines.joined().contains(Self.marker))   // the key value reaches no channel of the transcript
        #expect(t.changedFiles.contains { $0.hasSuffix("notes.txt") })
        #expect(t.outcome?.ok == true)
        #expect(t.outcome?.report?.milestone == .inProgress)
        #expect((t.outcome?.usage?.costUSD ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: s.ws.path.appendingPathComponent("notes.txt").path))

        request.resume = true
        request.prompt = "Run `echo resumed` with the Bash tool, then finish with the same report but the summary \"resumed\"."
        let second = try await Self.run(request, env: s.env)
        #expect(second.exit == 0)
        #expect(second.transcript.sessionID == session)
        #expect(second.transcript.entries.contains { $0.title == "$ echo resumed" && $0.ok == true })
        #expect(second.transcript.outcome?.ok == true && second.transcript.outcome?.report != nil)
        try await Self.finish(s)
    }

    @Test func codex() async throws {
        let s = try await Setup("codex")
        let schema = s.runs.appendingPathComponent("report-schema.json"), last = s.runs.appendingPathComponent("last-message.txt")
        try AgentReport.jsonSchema.write(to: schema, atomically: true, encoding: .utf8)
        let prompt = """
            This is a short automated test of a tool setup; do exactly these steps and nothing else.
            1. Run the shell command `echo hello`.
            2. Create the file notes.txt in the working directory, containing the word hi.
            3. Finish with the report: milestone in_progress, a one-sentence summary, changed_files ["notes.txt"], next_steps [] and blockers [].
            """
        var request = AgentRunRequest(kind: .codex, executable: try s.agent(.codex), workspace: s.ws.path, extraDirectories: [s.nsp], prompt: prompt,
                                      reportSchema: schema, lastMessageFile: last, codexSandbox: .workspaceWrite, codexIgnoreUserConfig: true)
        let first = try await Self.run(request, env: s.env)
        let t = first.transcript
        #expect(first.exit == 0)
        let thread = try #require(t.sessionID)
        #expect(UUID(uuidString: thread) != nil)
        #expect(t.entries.contains { $0.kind == .tool && $0.title == "$ echo hello" && $0.ok == true })
        #expect(t.outcome?.ok == true)
        #expect(t.outcome?.report?.milestone == .inProgress)
        #expect((try? String(contentsOf: last, encoding: .utf8)).flatMap(AgentReport.parse) != nil)
        #expect(FileManager.default.fileExists(atPath: s.ws.path.appendingPathComponent("notes.txt").path))

        // `codex exec resume` takes its sandbox from -c overrides: the NSP folder must be writable and the network on
        request.resume = true
        request.sessionID = thread
        let marker = s.nsp.appendingPathComponent("resumed.txt")
        request.prompt = """
            Run these two shell commands: `touch \(PrerequisiteChecker.shellQuote(marker.path))` and `curl -s -o /dev/null -w '%{http_code}' https://github.com`.
            Then finish with the same report, with the summary set to the curl output.
            """
        let second = try await Self.run(request, env: s.env)
        #expect(second.exit == 0)
        #expect(second.transcript.sessionID == thread)
        #expect(second.transcript.outcome?.ok == true && second.transcript.outcome?.report != nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        print("[live codex] resumed curl → \(second.transcript.outcome?.report?.summary ?? "-")")
        #expect(second.transcript.outcome?.report?.summary.contains("200") == true || second.transcript.outcome?.report?.summary.contains("301") == true)
        try await Self.finish(s)
    }
}
