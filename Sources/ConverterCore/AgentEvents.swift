// One stream of events for both agents' headless output, and the transcript the Ports page shows. Claude Code (`claude -p … --output-format stream-json --verbose`): system/init,
// assistant messages (text and tool_use blocks), user messages (tool_result blocks; a PreToolUse hook that exits 2 makes one an error "PreToolUse:<tool> hook error: [<cmd>]:
// <stderr>"), rate_limit_event and the final result (cost, turns, usage, structured_output). Codex (`codex exec --json`): thread.started (the id `codex exec resume` takes),
// item.started / item.completed (agent_message, command_execution, file_change, error, …), turn.completed with usage, turn.failed, and error, whose message may itself be
// an API error as JSON. Hook events, thinking and reasoning are left out
import Foundation

public struct AgentUsage: Sendable, Equatable, Codable {
    public var costUSD: Double?; public var inputTokens: Int?; public var outputTokens: Int?; public var cachedInputTokens: Int?

    public init(costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil) {
        self.costUSD = costUSD; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedInputTokens = cachedInputTokens
    }
}

public struct AgentOutcome: Sendable, Equatable {
    public var ok: Bool; public var text: String; public var report: AgentReport?; public var turns: Int?; public var usage: AgentUsage?; public var error: String?
}

public enum AgentEvent: Sendable, Equatable {
    case session(id: String, model: String?)
    case text(String)
    case toolStarted(id: String, name: String, detail: String)
    case toolFinished(id: String, ok: Bool, output: String)
    case filesChanged([String])
    case warning(String)
    case finished(AgentOutcome)
    case failure(String)
}

public enum AgentEventDecoder {
    static let maxOutput = 4_000
    static let maxDetail = 500
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public static func decode(_ line: String, kind: AgentKind) -> [AgentEvent] {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let o = object as? [String: Any],
              let type = o["type"] as? String else { return [] }
        return kind == .claudeCode ? claude(type, o) : codex(type, o)
    }

    // ---- Claude Code ----

    static func claude(_ type: String, _ o: [String: Any]) -> [AgentEvent] {
        switch type {
        case "system":
            guard o["subtype"] as? String == "init", let id = o["session_id"] as? String else { return [] }
            return [.session(id: id, model: o["model"] as? String)]
        case "assistant":
            var out: [AgentEvent] = []
            for block in blocks(o) {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(t)) }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String, name != "StructuredOutput" else { continue }   // the report: in the result
                    let input = block["input"] as? [String: Any] ?? [:]
                    out.append(.toolStarted(id: id, name: name, detail: toolDetail(name, input)))
                    if editTools.contains(name), let path = (input["file_path"] ?? input["notebook_path"]) as? String { out.append(.filesChanged([path])) }
                default: break
                }
            }
            return out
        case "user":
            guard o["isSynthetic"] as? Bool != true else { return [] }
            var out: [AgentEvent] = []
            for block in blocks(o) where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let output = resultText(block["content"]), failed = block["is_error"] as? Bool == true
                out.append(.toolFinished(id: id, ok: !failed, output: trimmed(output)))
                if failed, let blocked = hookBlock(output) { out.append(.warning(blocked)) }
            }
            return out
        case "rate_limit_event":
            guard let info = o["rate_limit_info"] as? [String: Any], let status = info["status"] as? String, status != "allowed" else { return [] }
            return [.warning("Usage limit" + ((info["rateLimitType"] as? String).map { " (\($0))" } ?? "") + ": \(status)")]
        case "result":
            let failed = o["is_error"] as? Bool == true || (o["subtype"] as? String).map { $0 != "success" } == true
            let text = o["result"] as? String ?? ""
            var report: AgentReport?
            if let s = o["structured_output"], JSONSerialization.isValidJSONObject(s), let data = try? JSONSerialization.data(withJSONObject: s) {
                report = try? JSONDecoder().decode(AgentReport.self, from: data)
            }
            if report == nil { report = AgentReport.parse(text) }
            let usage = o["usage"] as? [String: Any] ?? [:]
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { int(usage[$0]) }
            let u = AgentUsage(costUSD: double(o["total_cost_usd"]), inputTokens: input.isEmpty ? nil : input.reduce(0, +), outputTokens: int(usage["output_tokens"]),
                               cachedInputTokens: int(usage["cache_read_input_tokens"]))
            var error: String?
            if failed {
                let errors = (o["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
                error = !errors.isEmpty ? errors.joined(separator: "\n") : !text.isEmpty ? text : (o["subtype"] as? String ?? "the agent failed")
            }
            return [.finished(AgentOutcome(ok: !failed, text: text, report: report, turns: int(o["num_turns"]), usage: u, error: error))]
        default: return []
        }
    }

    static func blocks(_ o: [String: Any]) -> [[String: Any]] {
        ((o["message"] as? [String: Any])?["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// One line for a tool call: Bash's command, a file tool's path, a search's pattern (and where)
    static func toolDetail(_ name: String, _ input: [String: Any]) -> String {
        func s(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let detail: String
        switch name {
        case "Grep", "Glob": detail = [s("pattern"), s("path").map { "in " + $0 }].compactMap { $0 }.joined(separator: " ")
        default: detail = s("command") ?? s("file_path") ?? s("notebook_path") ?? s("pattern") ?? s("url") ?? s("query") ?? s("description") ?? s("path") ?? ""
        }
        return oneLine(detail)
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }.joined(separator: "\n") ?? ""
    }

    /// "PreToolUse:Read hook error: [<command>]: <reason>" → "Blocked by a hook: <reason>"
    static func hookBlock(_ output: String) -> String? {
        guard output.hasPrefix("PreToolUse:"), output.contains(" hook error: ") else { return nil }
        let reason = output.range(of: "]: ").map { String(output[$0.upperBound...]) } ?? output
        return "Blocked by a hook: " + reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- Codex ----

    static func codex(_ type: String, _ o: [String: Any]) -> [AgentEvent] {
        switch type {
        case "thread.started":
            guard let id = o["thread_id"] as? String else { return [] }
            return [.session(id: id, model: nil)]
        case "turn.completed":
            let u = o["usage"] as? [String: Any] ?? [:]
            let usage = AgentUsage(costUSD: nil, inputTokens: int(u["input_tokens"]), outputTokens: int(u["output_tokens"]), cachedInputTokens: int(u["cached_input_tokens"]))
            return [.finished(AgentOutcome(ok: true, text: "", report: nil, turns: 1, usage: usage, error: nil))]
        case "turn.failed":
            let message = ((o["error"] as? [String: Any])?["message"] as? String).map(innerMessage) ?? "the turn failed"
            return [.finished(AgentOutcome(ok: false, text: "", report: nil, turns: 1, usage: nil, error: message))]
        case "error":
            return [.failure((o["message"] as? String).map(innerMessage) ?? "unknown error")]
        case "item.started", "item.completed":
            guard let item = o["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
            return codexItem(item, id: id, completed: type == "item.completed")
        default: return []
        }
    }

    static func codexItem(_ item: [String: Any], id: String, completed: Bool) -> [AgentEvent] {
        let status = item["status"] as? String
        switch item["type"] as? String {
        case "agent_message":
            guard completed, let t = item["text"] as? String, !t.isEmpty else { return [] }
            return [.text(t)]
        case "command_execution":
            // a completed item repeats its start: the transcript merges the two, and an item reported only once still shows
            let started = AgentEvent.toolStarted(id: id, name: "Shell", detail: oneLine(unwrapShell(item["command"] as? String ?? "")))
            guard completed else { return [started] }
            let ok = status == "completed" && (int(item["exit_code"]) ?? 0) == 0
            return [started, .toolFinished(id: id, ok: ok, output: trimmed(item["aggregated_output"] as? String ?? ""))]
        case "file_change":
            guard completed else { return [] }
            let changes = (item["changes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let lines = changes.compactMap { c in (c["path"] as? String).map { ((c["kind"] as? String).map { $0 + " " } ?? "") + $0 } }
            let ok = status != "failed"
            return [.toolStarted(id: id, name: "Edit", detail: oneLine(paths.joined(separator: ", "))), .toolFinished(id: id, ok: ok, output: lines.joined(separator: "\n"))]
                + (ok && !paths.isEmpty ? [.filesChanged(paths)] : [])
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            let started = AgentEvent.toolStarted(id: id, name: "MCP", detail: name)
            return completed ? [started, .toolFinished(id: id, ok: status != "failed", output: "")] : [started]
        case "web_search":
            let started = AgentEvent.toolStarted(id: id, name: "WebSearch", detail: oneLine(item["query"] as? String ?? ""))
            return completed ? [started, .toolFinished(id: id, ok: status != "failed", output: "")] : [started]
        case "error":
            guard let m = item["message"] as? String else { return [] }
            return [.warning(m)]
        default: return []
        }
    }

    /// codex runs every command through the login shell: `/bin/zsh -lc 'echo hello'` → `echo hello`; a command holding single quotes comes in double quotes
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "/bin/sh -c "] where command.hasPrefix(prefix) {
            let rest = command.dropFirst(prefix.count)
            guard rest.count >= 2, let q = rest.first, q == "'" || q == "\"", rest.hasSuffix(String(q)) else { continue }
            let inner = rest.dropFirst().dropLast()
            if q == "'" { return inner.replacingOccurrences(of: #"'\''"#, with: "'") }
            var out = "", escaped = false
            for c in inner {
                if escaped { if !"\"\\$`".contains(c) { out.append("\\") }; out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
            }
            return out
        }
        return command
    }

    /// An error whose message is an API error as JSON ({"error": {"message": …}}): its inner message
    static func innerMessage(_ message: String) -> String {
        guard let data = message.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return message }
        if let m = (o["error"] as? [String: Any])?["message"] as? String { return m }
        return o["message"] as? String ?? message
    }

    // ---- values ----

    static func trimmed(_ s: String) -> String { s.count <= maxOutput ? s : "…" + String(s.suffix(maxOutput - 1)) }

    static func oneLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        return line.count <= maxDetail ? line : String(line.prefix(maxDetail - 1)) + "…"
    }

    static func int(_ v: Any?) -> Int? { double(v).flatMap { $0.magnitude < 1e15 ? Int($0) : nil } }

    static func double(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}

public enum AgentEntryKind: Sendable, Equatable { case text, tool, warning, error, note }

public struct AgentEntry: Sendable, Equatable, Identifiable {
    public let id: Int; public var date: Date; public var kind: AgentEntryKind; public var title: String; public var detail: String; public var ok: Bool?
    public var toolID: String?
}

public struct AgentTranscript: Sendable, Equatable {
    static let maxEntries = 3_000
    static let stderrNoise = ["Reading additional input from stdin...", "ERROR codex_models_manager::cache", "ERROR codex_memories_write::"]

    public private(set) var entries: [AgentEntry] = []
    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var changedFiles: [String] = []
    public private(set) var outcome: AgentOutcome?
    public private(set) var toolCalls = 0
    private var lastText: String?
    private var lastFailure: String?
    private var nextID = 0

    public init() {}

    public mutating func apply(_ events: [AgentEvent], at date: Date) {
        for e in events { apply(e, at: date) }
        trim()
    }

    public mutating func appendStderr(_ line: String, at date: Date) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !Self.stderrNoise.contains(where: { text.contains($0) }) else { return }
        append(.error, text, at: date)
        trim()
    }

    public mutating func appendNote(_ text: String, at date: Date) { append(.note, text, at: date); trim() }

    private mutating func apply(_ event: AgentEvent, at date: Date) {
        switch event {
        case let .session(id, model):
            sessionID = id
            if let model { self.model = model }
            append(.note, "Session \(id)" + (model.map { " · \($0)" } ?? ""), at: date)
        case let .text(text):
            lastText = text
            // codex with --output-schema sends every message as the report's JSON: its summary reads better
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), let r = AgentReport.parse(text) {
                append(.text, r.milestone.title, detail: r.summary, at: date)
            } else {
                append(.text, text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", detail: text, at: date)
            }
        case let .toolStarted(id, name, detail):
            let title = name == "Bash" || name == "Shell" ? "$ " + detail : detail.isEmpty ? name : name + " " + detail
            if let i = runningTool(id) { entries[i].title = title; return }
            toolCalls += 1
            append(.tool, title, at: date, toolID: id)
        case let .toolFinished(id, ok, output):
            guard let i = entries.lastIndex(where: { $0.toolID == id }) else { return }
            entries[i].ok = ok; entries[i].detail = output
        case let .filesChanged(paths):
            for p in paths where !changedFiles.contains(p) { changedFiles.append(p) }
        case let .warning(message): append(.warning, message, at: date)
        case let .failure(message):
            lastFailure = message
            append(.error, message, at: date)
        case let .finished(o):
            var o = o
            if o.text.isEmpty { o.text = lastText ?? "" }
            if o.report == nil { o.report = lastText.flatMap(AgentReport.parse) }
            if !o.ok, o.error == nil { o.error = lastFailure }
            outcome = o
            if o.ok {
                append(.note, "Finished" + (o.report.map { ": " + $0.milestone.title } ?? ""), at: date)
            } else if let error = o.error, error != lastFailure {
                append(.error, error, at: date)
            }
        }
    }

    private func runningTool(_ id: String) -> Int? {
        entries.lastIndex { $0.toolID == id && $0.ok == nil }
    }

    private mutating func append(_ kind: AgentEntryKind, _ title: String, detail: String = "", at date: Date, toolID: String? = nil) {
        entries.append(AgentEntry(id: nextID, date: date, kind: kind, title: title, detail: detail, ok: nil, toolID: toolID)); nextID += 1
    }

    private mutating func trim() {
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }
}
