// AgentEventDecoder and AgentTranscript on the agents' real output: lines from probes of Claude Code 2.1.310 (`claude -p … --output-format stream-json --verbose` with
// --json-schema, a PreToolUse hook, a Bash call and a blocked Read) and Codex CLI 0.145.0 (`codex exec --json`, a run with --output-schema and one with a model a ChatGPT
// login cannot use), shortened: hook output, thinking, the session's tool, skill and plugin lists are left out, paths are /Users/player/…
import Foundation
import Testing
@testable import ConverterCore

struct AgentEventsTests {
    static let claudeSession = "f08374e9-793d-4a83-aba9-9a396dce73f7"
    static let claude = [
        #"{"type":"system","subtype":"hook_started","hook_id":"h1","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"u0","session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7"}"#,
        #"{"type":"system","subtype":"hook_response","hook_id":"h1","hook_name":"SessionStart:startup","hook_event":"SessionStart","output":"","stdout":"","stderr":"","exit_code":0,"outcome":"success","uuid":"u1","session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7"}"#,
        #"{"type":"system","subtype":"init","cwd":"/Users/player/nxnative-ports/0100ABCD00000000","session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","tools":["Bash","Read"],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"acceptEdits","apiKeySource":"none","claude_code_version":"2.1.310","output_style":"default","uuid":"u2"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u3"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":""}],"usage":{"input_tokens":2,"output_tokens":6}},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u4"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Evos5XWBj8CT8APjbg7tuz","name":"Bash","input":{"command":"echo hello","description":"Print hello via echo"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"output_tokens":6}},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u5"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01QHFhqTMgKu4d5bVUmdLXiy","name":"Read","input":{"file_path":"/Users/player/probe/test.keys"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"output_tokens":6}},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u6"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792952400,"rateLimitType":"five_hour","isUsingOverage":false},"uuid":"u7","session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"PreToolUse:Read hook error: [/Users/player/probe/guard.sh]: blocked by the converter: key files must not be read or printed\n","is_error":true,"tool_use_id":"toolu_01QHFhqTMgKu4d5bVUmdLXiy"}]},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u8","tool_use_result":"Error: PreToolUse:Read hook error"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01Evos5XWBj8CT8APjbg7tuz","type":"tool_result","content":"hello","is_error":false}]},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u9","tool_use_result":{"stdout":"hello","stderr":"","interrupted":false}}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Both steps ran, but the file read was blocked.\n\n- **Bash `echo hello`:** succeeded."}],"usage":{"input_tokens":2,"output_tokens":3}},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u10"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[structured-output-enforce] You MUST call the StructuredOutput tool to complete this request. Call this tool now."}]},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u11","isSynthetic":true}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_3","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01AEqcueYsoDf5MPZQbzSxYz","name":"StructuredOutput","input":{"milestone":"blocked","summary":"Ran echo hello; the Read of test.keys was blocked."},"caller":{"type":"direct"}}]},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u12"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01AEqcueYsoDf5MPZQbzSxYz","type":"tool_result","content":"Structured output provided successfully"}]},"parent_tool_use_id":null,"session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","uuid":"u13"}"#,
        #"{"duration_api_ms":7024,"stop_reason":"tool_use","session_id":"f08374e9-793d-4a83-aba9-9a396dce73f7","total_cost_usd":0.00839604,"usage":{"input_tokens":8,"cache_creation_input_tokens":36578,"cache_read_input_tokens":72064,"output_tokens":718,"service_tier":"standard"},"permission_denials":[{"tool_name":"Read","tool_use_id":"toolu_01QHFhqTMgKu4d5bVUmdLXiy","tool_input":{"file_path":"/Users/player/probe/test.keys"}}],"terminal_reason":"completed","is_error":false,"num_turns":5,"subtype":"success","api_error_status":null,"result":"{\"milestone\":\"blocked\",\"summary\":\"Ran echo hello; the Read of test.keys was blocked.\",\"changed_files\":[],\"next_steps\":[\"Ask for the guard to be lifted\"],\"blockers\":[\"key file guard\"]}","structured_output":{"milestone":"blocked","summary":"Ran echo hello; the Read of test.keys was blocked.","changed_files":[],"next_steps":["Ask for the guard to be lifted"],"blockers":["key file guard"]},"type":"result","duration_ms":9869,"uuid":"u14"}"#,
    ]

    static let codexSuccess = [
        #"{"type":"thread.started","thread_id":"01a17370-b6e8-78e0-b2f9-174305fdfd55"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"milestone\":\"in_progress\",\"summary\":\"I’ll run the commands sequentially and report their exact outputs.\",\"changed_files\":[],\"next_steps\":[],\"blockers\":[]}"}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hello'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hello'","aggregated_output":"hello\n","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'curl -sS -o /dev/null -w %{http_code} https://github.com'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'curl -sS -o /dev/null -w %{http_code} https://github.com'","aggregated_output":"curl: (6) Could not resolve host: github.com\n000","exit_code":6,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"file_change","changes":[{"path":"/Users/player/nxnative-ports/0100ABCD00000000/dm/games/0100ABCD00000000/game.tsv","kind":"add"},{"path":"/Users/player/nxnative-ports/0100ABCD00000000/README.md","kind":"update"}],"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"{\"milestone\":\"profile\",\"summary\":\"`echo hello` → `hello` (exit 0); github.com did not resolve (exit 6).\",\"changed_files\":[\"dm/games/0100ABCD00000000/game.tsv\"],\"next_steps\":[\"Boot it on the Mac host\"],\"blockers\":[]}"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":53519,"cached_input_tokens":35072,"cache_write_input_tokens":0,"output_tokens":356,"reasoning_output_tokens":0}}"#,
    ]

    static let codexFailure = [
        #"{"type":"thread.started","thread_id":"01a17370-72d8-7603-a048-61307023ab85"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Configured service tier `priority` is not advertised as supported for model `gpt-6.1-sol` and will be omitted from requests."}}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.\",\"code\":\"model_not_found\"}}"}"#,
        #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.\",\"code\":\"model_not_found\"}}"}}"#,
    ]

    let date = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func claudeEvents() throws {
        let e = Self.claude.map { AgentEventDecoder.decode($0, kind: .claudeCode) }
        #expect(e[0].isEmpty && e[1].isEmpty && e[3].isEmpty && e[4].isEmpty)   // hooks, thinking
        #expect(e[2] == [.session(id: Self.claudeSession, model: "claude-haiku-5-5")])
        #expect(e[5] == [.toolStarted(id: "toolu_01Evos5XWBj8CT8APjbg7tuz", name: "Bash", detail: "echo hello")])
        #expect(e[6] == [.toolStarted(id: "toolu_01QHFhqTMgKu4d5bVUmdLXiy", name: "Read", detail: "/Users/player/probe/test.keys")])
        #expect(e[7].isEmpty)   // allowed
        #expect(e[8] == [.toolFinished(id: "toolu_01QHFhqTMgKu4d5bVUmdLXiy", ok: false,
                                       output: "PreToolUse:Read hook error: [/Users/player/probe/guard.sh]: blocked by the converter: key files must not be read or printed\n"),
                         .warning("Blocked by a hook: blocked by the converter: key files must not be read or printed")])
        #expect(e[9] == [.toolFinished(id: "toolu_01Evos5XWBj8CT8APjbg7tuz", ok: true, output: "hello")])
        #expect(e[10] == [.text("Both steps ran, but the file read was blocked.\n\n- **Bash `echo hello`:** succeeded.")])
        #expect(e[11].isEmpty && e[12].isEmpty)   // the synthetic nudge; the report's tool call (the report comes with the result)
        #expect(e[13] == [.toolFinished(id: "toolu_01AEqcueYsoDf5MPZQbzSxYz", ok: true, output: "Structured output provided successfully")])
        let report = AgentReport(milestone: .blocked, summary: "Ran echo hello; the Read of test.keys was blocked.", nextSteps: ["Ask for the guard to be lifted"],
                                 blockers: ["key file guard"])
        guard case let .finished(o)? = e[14].first, e[14].count == 1 else { Issue.record("no outcome: \(e[14])"); return }
        #expect(o.ok && o.error == nil && o.turns == 5 && o.report == report)
        #expect(o.usage == AgentUsage(costUSD: 0.00839604, inputTokens: 8 + 36578 + 72064, outputTokens: 718, cachedInputTokens: 72064))
        #expect(o.text.hasPrefix(#"{"milestone":"blocked""#))
    }

    @Test func claudeEditsAndErrors() {
        let edit = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/dm/games/X/game.tsv","old_string":"a","new_string":"b"}},{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"svc_[0-9]+","path":"/w/dm/host"}}]}}"#
        #expect(AgentEventDecoder.decode(edit, kind: .claudeCode) == [.toolStarted(id: "t1", name: "Edit", detail: "/w/dm/games/X/game.tsv"), .filesChanged(["/w/dm/games/X/game.tsv"]),
                                                                       .toolStarted(id: "t2", name: "Grep", detail: "svc_[0-9]+ in /w/dm/host")])
        let blocks = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":[{"type":"text","text":"line 1"},{"type":"image"},{"type":"text","text":"line 2"}]}]}}"#
        #expect(AgentEventDecoder.decode(blocks, kind: .claudeCode) == [.toolFinished(id: "t3", ok: true, output: "line 1\nline 2")])
        let limited = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour"}}"#
        #expect(AgentEventDecoder.decode(limited, kind: .claudeCode) == [.warning("Usage limit (five_hour): rejected")])
        let budget = #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":40,"total_cost_usd":20.01,"usage":{"input_tokens":10,"output_tokens":5},"session_id":"s"}"#
        guard case let .finished(o)? = AgentEventDecoder.decode(budget, kind: .claudeCode).first else { Issue.record("no outcome"); return }
        #expect(!o.ok && o.error == "error_max_budget_usd" && o.turns == 40 && o.usage?.costUSD == 20.01 && o.report == nil)
        let long = String(repeating: "a", count: 5_000) + "END"
        let big = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"\#(long)"}]}}"#
        guard case let .toolFinished(_, _, output)? = AgentEventDecoder.decode(big, kind: .claudeCode).first else { Issue.record("no result"); return }
        #expect(output.count == 4_000 && output.hasSuffix("END") && output.hasPrefix("…"))
    }

    @Test func codexEvents() {
        let e = Self.codexSuccess.map { AgentEventDecoder.decode($0, kind: .codex) }
        #expect(e[0] == [.session(id: "01a17370-b6e8-78e0-b2f9-174305fdfd55", model: nil)])
        #expect(e[1].isEmpty)
        guard case let .text(first)? = e[2].first else { Issue.record("no text"); return }
        #expect(AgentReport.parse(first)?.milestone == .inProgress)
        #expect(e[3] == [.toolStarted(id: "item_1", name: "Shell", detail: "echo hello")])
        #expect(e[4] == [.toolStarted(id: "item_1", name: "Shell", detail: "echo hello"), .toolFinished(id: "item_1", ok: true, output: "hello\n")])
        #expect(e[6].last == .toolFinished(id: "item_2", ok: false, output: "curl: (6) Could not resolve host: github.com\n000"))
        let paths = ["/Users/player/nxnative-ports/0100ABCD00000000/dm/games/0100ABCD00000000/game.tsv", "/Users/player/nxnative-ports/0100ABCD00000000/README.md"]
        #expect(e[7] == [.toolStarted(id: "item_3", name: "Edit", detail: paths.joined(separator: ", ")),
                         .toolFinished(id: "item_3", ok: true, output: "add \(paths[0])\nupdate \(paths[1])"), .filesChanged(paths)])
        #expect(e[9] == [.finished(AgentOutcome(ok: true, text: "", report: nil, turns: 1, usage: AgentUsage(inputTokens: 53519, outputTokens: 356, cachedInputTokens: 35072),
                                                error: nil))])
        let f = Self.codexFailure.map { AgentEventDecoder.decode($0, kind: .codex) }
        #expect(f[1] == [.warning("Configured service tier `priority` is not advertised as supported for model `gpt-6.1-sol` and will be omitted from requests.")])
        let message = "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
        #expect(f[3] == [.failure(message)])
        #expect(f[4] == [.finished(AgentOutcome(ok: false, text: "", report: nil, turns: 1, usage: nil, error: message))])
        #expect(AgentEventDecoder.decode(#"{"type":"error","message":"stream disconnected"}"#, kind: .codex) == [.failure("stream disconnected")])
    }

    @Test func codexShellUnwrapped() {
        #expect(AgentEventDecoder.unwrapShell("/bin/zsh -lc 'echo hello'") == "echo hello")
        #expect(AgentEventDecoder.unwrapShell(#"/bin/zsh -lc 'echo '\''a b'\'''"#) == "echo 'a b'")
        // measured: a command holding single quotes comes in double quotes
        #expect(AgentEventDecoder.unwrapShell(#"/bin/zsh -lc "touch '/a b/x.txt' && curl -w '%{http_code}' \"\$URL\" \\n""#) == #"touch '/a b/x.txt' && curl -w '%{http_code}' "$URL" \n"#)
        #expect(AgentEventDecoder.unwrapShell("ls -l") == "ls -l")
        #expect(AgentEventDecoder.unwrapShell("/bin/zsh -lc 'unclosed") == "/bin/zsh -lc 'unclosed")
    }

    @Test func ignoredLines() {
        for line in ["", "not json", "[1, 2]", #"{"no":"type"}"#, #"{"type":"something.new"}"#, "{broken"] {
            #expect(AgentEventDecoder.decode(line, kind: .claudeCode).isEmpty && AgentEventDecoder.decode(line, kind: .codex).isEmpty, "\(line)")
        }
        #expect(AgentEventDecoder.decode(#"{"type":"item.completed","item":{"id":"r","type":"reasoning","text":"…"}}"#, kind: .codex).isEmpty)
    }

    @Test func claudeTranscript() {
        var t = AgentTranscript()
        for line in Self.claude { t.apply(AgentEventDecoder.decode(line, kind: .claudeCode), at: date) }
        #expect(t.sessionID == Self.claudeSession && t.model == "claude-haiku-5-5")
        #expect(t.toolCalls == 2)
        let tools = t.entries.filter { $0.kind == .tool }
        #expect(tools.map(\.title) == ["$ echo hello", "Read /Users/player/probe/test.keys"])
        #expect(tools[0].ok == true && tools[0].detail == "hello")
        #expect(tools[1].ok == false && tools[1].detail.contains("hook error"))
        #expect(t.entries.contains { $0.kind == .warning && $0.title.hasPrefix("Blocked by a hook") })
        #expect(t.entries.contains { $0.kind == .text && $0.title == "Both steps ran, but the file read was blocked." })
        #expect(t.outcome?.ok == true && t.outcome?.report?.milestone == .blocked)
        #expect(t.entries.last?.kind == .note && t.entries.last?.title == "Finished: Blocked")
        #expect(Set(t.entries.map(\.id)).count == t.entries.count)
    }

    @Test func codexTranscript() {
        var t = AgentTranscript()
        for line in Self.codexSuccess { t.apply(AgentEventDecoder.decode(line, kind: .codex), at: date) }
        #expect(t.sessionID == "01a17370-b6e8-78e0-b2f9-174305fdfd55")
        let tools = t.entries.filter { $0.kind == .tool }
        #expect(tools.map(\.title) == ["$ echo hello", "$ curl -sS -o /dev/null -w %{http_code} https://github.com",
                                       "Edit /Users/player/nxnative-ports/0100ABCD00000000/dm/games/0100ABCD00000000/game.tsv, /Users/player/nxnative-ports/0100ABCD00000000/README.md"])
        #expect(tools.map(\.ok) == [true, false, true])
        #expect(t.toolCalls == 3)
        #expect(t.changedFiles.count == 2)
        let report = t.outcome?.report
        #expect(report?.milestone == .profile && report?.nextSteps == ["Boot it on the Mac host"] && report?.changedFiles == ["dm/games/0100ABCD00000000/game.tsv"])
        #expect(t.outcome?.ok == true && t.outcome?.usage?.inputTokens == 53519 && t.outcome?.text.hasPrefix("{") == true)
        #expect(t.entries.filter { $0.kind == .text }.map(\.title) == ["In progress", "Profile written"])   // the report JSON shows as its summary

        var f = AgentTranscript()
        for line in Self.codexFailure { f.apply(AgentEventDecoder.decode(line, kind: .codex), at: date) }
        #expect(f.outcome?.ok == false && f.outcome?.error?.contains("not supported when using Codex with a ChatGPT account") == true)
        #expect(f.entries.filter { $0.kind == .error }.count == 1)   // the error event and turn.failed say the same
        #expect(f.entries.filter { $0.kind == .warning }.count == 1)
    }

    @Test func toolEntriesUpdateInPlace() {
        var t = AgentTranscript()
        t.apply([.toolStarted(id: "a", name: "Bash", detail: "make -C dm/host"), .toolStarted(id: "b", name: "Read", detail: "/w/x.c")], at: date)
        t.apply([.toolFinished(id: "a", ok: true, output: "built"), .toolFinished(id: "zz", ok: false, output: "unknown id")], at: date)
        #expect(t.entries.count == 2 && t.entries[0].ok == true && t.entries[0].detail == "built" && t.entries[1].ok == nil)
        t.apply([.filesChanged(["a", "b"]), .filesChanged(["b", "c"])], at: date)
        #expect(t.changedFiles == ["a", "b", "c"])
    }

    @Test func transcriptCap() {
        var t = AgentTranscript()
        for i in 0..<3_100 { t.apply([.text("line \(i)")], at: date) }
        #expect(t.entries.count == 3_000 && t.entries.first?.title == "line 100" && t.entries.last?.title == "line 3099")
        t.appendNote("note", at: date)
        #expect(t.entries.count == 3_000 && t.entries.last?.kind == .note)
    }

    @Test func stderrNoise() {
        var t = AgentTranscript()
        t.appendStderr("Reading additional input from stdin...", at: date)
        t.appendStderr("2026-10-25T14:21:51.090122Z ERROR codex_models_manager::cache: failed to load models cache: missing field `base_instructions` at line 139 column 5", at: date)
        t.appendStderr("2026-10-25T14:21:53.275147Z ERROR codex_memories_write::phase2: Phase 2 no changes", at: date)
        t.appendStderr("   ", at: date)
        #expect(t.entries.isEmpty)
        t.appendStderr("error: unexpected argument '--frob' found", at: date)
        #expect(t.entries.map(\.kind) == [.error] && t.entries.first?.title == "error: unexpected argument '--frob' found")
    }

    @Test func finishedWithoutReportUsesTheLastText() {
        var t = AgentTranscript()
        t.apply([.text("Working on it."), .text("Done.\n```json\n{\"milestone\": \"frame_loop\", \"summary\": \"boots\", \"changed_files\": [], \"next_steps\": [], \"blockers\": []}\n```")], at: date)
        t.apply([.finished(AgentOutcome(ok: true, text: "", report: nil, turns: 1, usage: nil, error: nil))], at: date)
        #expect(t.outcome?.report?.milestone == .frameLoop && t.outcome?.text.hasPrefix("Done.") == true)
    }
}
