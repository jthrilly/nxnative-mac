// AgentCommand: claude's and codex's headless command lines (first run, resume, budget, model, settings, schema, sandbox), the Terminal line and the child environment
import Foundation
import Testing
@testable import ConverterCore

struct AgentCommandTests {
    let ws = URL(fileURLWithPath: "/Users/player/nxnative-ports/0100ABCD00000000"), games = URL(fileURLWithPath: "/Volumes/Games/Super Game")
    let schema = URL(fileURLWithPath: "/S/report-schema.json"), last = URL(fileURLWithPath: "/S/last.txt")

    func request(_ kind: AgentKind, prompt: String = "Port it.") -> AgentRunRequest {
        AgentRunRequest(kind: kind, executable: "/opt/bin/" + kind.executableName, workspace: ws, extraDirectories: [games], prompt: prompt)
    }

    @Test func claudeFirstRun() {
        var r = request(.claudeCode)
        r.sessionID = "f08374e9-793d-4a83-aba9-9a396dce73f7"
        #expect(AgentCommand.arguments(for: r) == ["-p", "Port it.", "--output-format", "stream-json", "--verbose", "--session-id", "f08374e9-793d-4a83-aba9-9a396dce73f7",
                                                   "--permission-mode", "acceptEdits", "--allowedTools", "Bash", "--permission-prompts", "none", "--add-dir", games.path])
    }

    @Test func claudeEveryOption() throws {
        var r = request(.claudeCode)
        r.sessionID = "s1"; r.resume = true; r.budgetUSD = 20; r.model = "claude-opus-5-5"; r.reportSchema = schema; r.claudeSettings = #"{"hooks":{}}"#
        let args = AgentCommand.arguments(for: r)
        #expect(args == ["-p", "Port it.", "--output-format", "stream-json", "--verbose", "--resume", "s1", "--permission-mode", "acceptEdits", "--allowedTools", "Bash",
                         "--permission-prompts", "none", "--add-dir", games.path, "--settings", #"{"hooks":{}}"#, "--json-schema", AgentReport.jsonSchema, "--max-budget-usd", "20",
                         "--model", "claude-opus-5-5"])
        #expect(args[1] == "Port it.")   // right after -p: never inside a variadic list
        r.budgetUSD = 2.5
        #expect(AgentCommand.arguments(for: r).contains("2.5"))
        var bare = request(.claudeCode); bare.extraDirectories = []
        #expect(!AgentCommand.arguments(for: bare).contains("--add-dir") && !AgentCommand.arguments(for: bare).contains("--session-id"))
    }

    @Test func codexFirstRun() {
        var r = request(.codex)
        #expect(AgentCommand.arguments(for: r) == ["exec", "--json", "-C", ws.path, "--add-dir", games.path, "-s", "workspace-write", "-c",
                                                   "sandbox_workspace_write.network_access=true", "Port it."])
        r.reportSchema = schema; r.lastMessageFile = last; r.model = "gpt-6.1"; r.codexIgnoreUserConfig = true; r.codexSandbox = .fullAccess
        r.extraDirectories = [games, URL(fileURLWithPath: "/k")]
        #expect(AgentCommand.arguments(for: r) == ["exec", "--json", "-C", ws.path, "--add-dir", games.path, "--add-dir", "/k", "--dangerously-bypass-approvals-and-sandbox",
                                                   "--output-schema", schema.path, "-o", last.path, "-m", "gpt-6.1", "--ignore-user-config", "Port it."])
    }

    @Test func codexResume() {
        var r = request(.codex)
        r.sessionID = "01a17370-b6e8-78e0-b2f9-174305fdfd55"; r.resume = true; r.reportSchema = schema; r.lastMessageFile = last
        r.extraDirectories = [games, URL(fileURLWithPath: #"/a "b"\c"#)]
        let args = AgentCommand.arguments(for: r)
        #expect(args == ["exec", "resume", "--json", "-c", #"sandbox_mode="workspace-write""#, "-c", "sandbox_workspace_write.network_access=true",
                         "-c", #"sandbox_workspace_write.writable_roots=["/Volumes/Games/Super Game", "/a \"b\"\\c"]"#,
                         "--output-schema", schema.path, "-o", last.path, "01a17370-b6e8-78e0-b2f9-174305fdfd55", "Port it."])
        #expect(!args.contains("-C") && !args.contains("-s") && !args.contains("--add-dir"))   // codex exec resume takes none of them
        r.codexSandbox = .fullAccess; r.model = "gpt-6.1"; r.codexIgnoreUserConfig = true
        #expect(AgentCommand.arguments(for: r) == ["exec", "resume", "--json", "--dangerously-bypass-approvals-and-sandbox", "--output-schema", schema.path, "-o", last.path,
                                                   "-m", "gpt-6.1", "--ignore-user-config", "01a17370-b6e8-78e0-b2f9-174305fdfd55", "Port it."])
        r.sessionID = ""   // nothing to resume: a first run
        #expect(AgentCommand.arguments(for: r).prefix(4) == ["exec", "--json", "-C", ws.path])
        #expect(AgentCommand.arguments(for: r).last == "Port it.")
    }

    @Test func tomlStrings() {
        #expect(AgentCommand.tomlString("plain") == #""plain""#)
        #expect(AgentCommand.tomlString("a\tb\u{7f}") == #""a\u0009b\u007F""#)
        #expect(AgentCommand.number(20) == "20" && AgentCommand.number(0.5) == "0.5")
    }

    @Test func interactiveClaude() {
        let ws = URL(fileURLWithPath: "/Users/player/it's ports/W"), prompt = URL(fileURLWithPath: "/S/prompt 1.txt")
        var r = AgentRunRequest(kind: .claudeCode, executable: "/Users/player/.local/bin/claude", workspace: ws, extraDirectories: [games], prompt: "Port it.")
        #expect(AgentCommand.interactiveArguments(for: r, promptFile: prompt)
                == #"cd '/Users/player/it'\''s ports/W' && exec '/Users/player/.local/bin/claude' '--add-dir' '/Volumes/Games/Super Game' '--' "$(cat '/S/prompt 1.txt')""#)
        r.sessionID = "s1"; r.resume = true; r.model = "claude-opus-5-5"; r.claudeSettings = "/S/settings.json"
        #expect(AgentCommand.interactiveArguments(for: r, promptFile: prompt)
                == #"cd '/Users/player/it'\''s ports/W' && exec '/Users/player/.local/bin/claude' '--add-dir' '/Volumes/Games/Super Game' '--resume' 's1' "#
                + #"'--settings' '/S/settings.json' '--model' 'claude-opus-5-5' "$(cat '/S/prompt 1.txt')""#)
        r.prompt = ""   // reopen the session as it is
        #expect(!AgentCommand.interactiveArguments(for: r, promptFile: prompt).contains("cat "))
    }

    @Test func interactiveCodex() {
        let prompt = URL(fileURLWithPath: "/S/prompt.txt")
        var r = request(.codex)
        #expect(AgentCommand.interactiveArguments(for: r, promptFile: prompt)
                == "cd '\(ws.path)' && exec '/opt/bin/codex' '-C' '\(ws.path)' '--add-dir' '/Volumes/Games/Super Game' '-s' 'workspace-write' '-c' "
                + #"'sandbox_workspace_write.network_access=true' "$(cat '/S/prompt.txt')""#)
        r.sessionID = "t1"; r.resume = true; r.codexSandbox = .fullAccess; r.model = "gpt-6.1"; r.prompt = ""
        #expect(AgentCommand.interactiveArguments(for: r, promptFile: prompt)
                == "cd '\(ws.path)' && exec '/opt/bin/codex' 'resume' '-C' '\(ws.path)' '--add-dir' '/Volumes/Games/Super Game' "
                + "'--dangerously-bypass-approvals-and-sandbox' '-m' 'gpt-6.1' 't1'")
    }

    @Test func childEnvironment() {
        let host = ["PATH": "/usr/bin", "HOME": "/Users/player", "CLAUDECODE": "1", "CLAUDE_PID": "123", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts",
                    "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/s", "CLAUDE_AGENT_SDK_VERSION": "0.3", "CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_MODEL": "m", "CLAUDE_CONFIG_DIR": "/c"]
        #expect(AgentCommand.childEnvironment(host, kind: .claudeCode)
                == ["PATH": "/usr/bin", "HOME": "/Users/player", "CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_MODEL": "m", "CLAUDE_CONFIG_DIR": "/c"])
        #expect(AgentCommand.childEnvironment(host, kind: .codex) == host)
    }
}
