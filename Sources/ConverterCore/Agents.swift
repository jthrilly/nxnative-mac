// The coding agents a port is handed to (Claude Code's `claude`, OpenAI's `codex`) and their command lines: headless, one JSON event per stdout line (claude -p … --output-format
// stream-json, codex exec --json), or interactive in Terminal. The prompt is never left where a variadic flag (claude's --allowedTools, --add-dir) would swallow it: it follows -p
// directly for claude and is the last argument for codex. codex's workspace-write sandbox has no network unless sandbox_workspace_write.network_access is set, and
// `codex exec resume` takes no -C / -s / --add-dir, so a resumed run gets its sandbox from -c overrides and its working folder from the process's cwd
import Foundation

public enum AgentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case claudeCode, codex

    public var id: String { rawValue }
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var executableName: String { self == .claudeCode ? "claude" : "codex" }
}

public enum CodexSandbox: String, Sendable, Codable, CaseIterable { case workspaceWrite, fullAccess }

// How a Claude Code port runs: sandboxed is Claude Code's own OS sandbox (configured in the --settings JSON the app writes, KeysGuard.claudeSettings), the real boundary that
// keeps the key file unreadable and holds the agent's shell commands to the worktree, the game folder and what porting needs; fullAccess turns the sandbox off and leaves only
// the best-effort keys hook. Like CodexSandbox, but the mechanism is settings, not a flag
public enum ClaudeSandbox: String, Sendable, Codable, CaseIterable { case sandboxed, fullAccess }

/// The Claude models a port's agent can run on (claude --model), newest first, and the one a port uses unless another is chosen
public enum ClaudeModels {
    public static let defaultModel = "claude-opus-5-5"
    public static let all: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1"),
    ]
}

public struct AgentRunRequest: Sendable, Equatable {
    public var kind: AgentKind
    public var executable: String
    public var workspace: URL
    public var extraDirectories: [URL]
    public var prompt: String
    public var sessionID: String
    public var resume: Bool
    public var model: String
    public var budgetUSD: Double?
    public var reportSchema: URL?
    public var lastMessageFile: URL?
    public var claudeSettings: String?
    public var claudeSandbox: ClaudeSandbox
    public var codexSandbox: CodexSandbox
    public var codexIgnoreUserConfig: Bool

    public init(kind: AgentKind, executable: String, workspace: URL, extraDirectories: [URL] = [], prompt: String, sessionID: String = "", resume: Bool = false,
                model: String = "", budgetUSD: Double? = nil, reportSchema: URL? = nil, lastMessageFile: URL? = nil, claudeSettings: String? = nil,
                claudeSandbox: ClaudeSandbox = .sandboxed, codexSandbox: CodexSandbox = .workspaceWrite, codexIgnoreUserConfig: Bool = false) {
        self.kind = kind; self.executable = executable; self.workspace = workspace; self.extraDirectories = extraDirectories; self.prompt = prompt
        self.sessionID = sessionID; self.resume = resume; self.model = model; self.budgetUSD = budgetUSD; self.reportSchema = reportSchema
        self.lastMessageFile = lastMessageFile; self.claudeSettings = claudeSettings; self.claudeSandbox = claudeSandbox
        self.codexSandbox = codexSandbox; self.codexIgnoreUserConfig = codexIgnoreUserConfig
    }
}

public enum AgentCommand {
    static let codexNetwork = "sandbox_workspace_write.network_access=true"

    public static func arguments(for request: AgentRunRequest) -> [String] {
        request.kind == .claudeCode ? claudeArguments(request) : codexArguments(request)
    }

    /// A zsh line for a Terminal .command file; the prompt is read from promptFile when the request has one (an empty prompt opens the session as it is)
    public static func interactiveArguments(for request: AgentRunRequest, promptFile: URL) -> String {
        let r = request
        var words: [String] = []
        switch r.kind {
        case .claudeCode:
            if !r.extraDirectories.isEmpty { words += ["--add-dir"] + r.extraDirectories.map(\.path) }
            let afterDirs = words.count
            if !r.sessionID.isEmpty { words += [r.resume ? "--resume" : "--session-id", r.sessionID] }
            if let s = r.claudeSettings { words += ["--settings", s] }
            if !r.model.isEmpty { words += ["--model", r.model] }
            if afterDirs > 0, words.count == afterDirs, !r.prompt.isEmpty { words.append("--") }   // nothing ends --add-dir's list before the prompt
        case .codex:
            let resuming = r.resume && !r.sessionID.isEmpty
            if resuming { words.append("resume") }
            words += ["-C", r.workspace.path] + r.extraDirectories.flatMap { ["--add-dir", $0.path] }
            words += r.codexSandbox == .fullAccess ? ["--dangerously-bypass-approvals-and-sandbox"] : ["-s", "workspace-write", "-c", codexNetwork]
            if !r.model.isEmpty { words += ["-m", r.model] }
            if resuming { words.append(r.sessionID) }
        }
        var line = "cd \(shellQuote(r.workspace.path)) && exec \(shellQuote(r.executable))" + words.map { " " + shellQuote($0) }.joined()
        if !r.prompt.isEmpty { line += " \"$(cat \(shellQuote(promptFile.path)))\"" }
        return line
    }

    /// The environment of an agent's process. A claude started from inside another Claude Code session (CLAUDECODE, CLAUDE_CODE_SESSION_ID, its messaging socket…) would
    /// attach to that session: those variables go, except the CLAUDE_CODE_USE_* provider choices a user sets on purpose
    public static func childEnvironment(_ variables: [String: String], kind: AgentKind) -> [String: String] {
        guard kind == .claudeCode else { return variables }
        return variables.filter { key, _ in
            if key == "CLAUDECODE" || key == "CLAUDE_PID" || key.hasPrefix("CLAUDE_AGENT_SDK_") { return false }
            return !key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_CODE_USE_")
        }
    }

    // ---- the headless command lines ----

    static func claudeArguments(_ r: AgentRunRequest) -> [String] {
        var args = ["-p", r.prompt, "--output-format", "stream-json", "--verbose"]
        if !r.sessionID.isEmpty { args += [r.resume ? "--resume" : "--session-id", r.sessionID] }
        args += ["--permission-mode", "acceptEdits", "--allowedTools", "Bash", "--permission-prompts", "none"]   // headless: deny, never hang, on anything that would ask
        if !r.extraDirectories.isEmpty { args += ["--add-dir"] + r.extraDirectories.map(\.path) }
        if let s = r.claudeSettings { args += ["--settings", s] }
        if r.reportSchema != nil { args += ["--json-schema", AgentReport.jsonSchema] }   // claude takes the schema's text; the file holds the same
        if let b = r.budgetUSD { args += ["--max-budget-usd", number(b)] }
        if !r.model.isEmpty { args += ["--model", r.model] }
        return args
    }

    static func codexArguments(_ r: AgentRunRequest) -> [String] {
        let resuming = r.resume && !r.sessionID.isEmpty
        var args = ["exec"]
        if resuming {
            args += ["resume", "--json"]
            if r.codexSandbox == .fullAccess {
                args.append("--dangerously-bypass-approvals-and-sandbox")
            } else {
                args += ["-c", #"sandbox_mode="workspace-write""#, "-c", codexNetwork]
                if !r.extraDirectories.isEmpty { args += ["-c", "sandbox_workspace_write.writable_roots=[" + r.extraDirectories.map { tomlString($0.path) }.joined(separator: ", ") + "]"] }
            }
        } else {
            args += ["--json", "-C", r.workspace.path] + r.extraDirectories.flatMap { ["--add-dir", $0.path] }
            args += r.codexSandbox == .fullAccess ? ["--dangerously-bypass-approvals-and-sandbox"] : ["-s", "workspace-write", "-c", codexNetwork]
        }
        if let s = r.reportSchema { args += ["--output-schema", s.path] }
        if let o = r.lastMessageFile { args += ["-o", o.path] }
        if !r.model.isEmpty { args += ["-m", r.model] }
        if r.codexIgnoreUserConfig { args.append("--ignore-user-config") }
        if resuming { args.append(r.sessionID) }
        args.append(r.prompt)
        return args
    }

    // "20", "2.5": what a person would type
    static func number(_ d: Double) -> String { d == d.rounded() && d.magnitude < 1e15 ? String(Int(d)) : String(d) }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where u.value < 0x20 || u.value == 0x7f: out += String(format: "\\u%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    static func shellQuote(_ s: String) -> String { PrerequisiteChecker.shellQuote(s) }
}
