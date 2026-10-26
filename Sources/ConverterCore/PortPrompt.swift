// What a port's agent is told: the game, where its files and the key file are, the worktree it works in, what exists already (survey, provisional profile, the last
// conversion's logs), the goal in milestones, the rules (AGENTS.md first; no commits; the key file is never read) and the report it ends with. The repository's own guide
// (AGENTS.md → docs/agents) is the method: the prompt points at it instead of repeating it
import Foundation

public struct PortContext: Sendable, Equatable {
    public var titleID: String; public var gameName: String; public var versions: [Int]; public var nspFolder: URL; public var keysFile: URL
    public var workspace: URL; public var branch: String; public var survey: URL?; public var provisionalProfile: URL?
    public var lastLogs: URL?; public var lastError: String?; public var agent: AgentKind; public var sandboxed: Bool

    public init(titleID: String, gameName: String, versions: [Int], nspFolder: URL, keysFile: URL, workspace: URL, branch: String, survey: URL? = nil,
                provisionalProfile: URL? = nil, lastLogs: URL? = nil, lastError: String? = nil, agent: AgentKind, sandboxed: Bool = false) {
        self.titleID = titleID; self.gameName = gameName; self.versions = versions; self.nspFolder = nspFolder; self.keysFile = keysFile; self.workspace = workspace
        self.branch = branch; self.survey = survey; self.provisionalProfile = provisionalProfile; self.lastLogs = lastLogs; self.lastError = lastError; self.agent = agent
        self.sandboxed = sandboxed
    }
}

public enum PortPrompt {
    public static func initial(_ c: PortContext, instructions: String) -> String {
        let folder = c.nspFolder.path, keys = c.keysFile.path
        var lines = [
            "You are porting the Nintendo Switch game \"\(c.gameName)\" (title ID \(c.titleID); versions in the folder: \(versionList(c.versions))) to nxnative, the repository in your working directory.",
            "This working directory (\(c.workspace.path)) is a git worktree of nxnative on branch \(c.branch), made for this port by the nxnative Converter app.",
            "",
            "Read AGENTS.md first and follow it: it is the repository's rulebook. Then read docs/agents/README.md and work through its checklist for a new title.",
            "The game's files are in \(folder). Do extraction, runs and analysis in \(c.nspFolder.appendingPathComponent("\(c.titleID)-work").path), as AGENTS.md says; never put game files in the repository.",
            "",
        ]
        lines += keyRules(c)
        lines += ["", "What exists already:"]
        lines += existing(c)
        lines += [
            "",
            "The goal, in this order, as far as you get:",
            "1. A game profile dm/games/\(c.titleID)/: game.tsv from the provisional one, its note README.md and its row in the games table (AGENTS.md says what goes where).",
            "2. The game boots on the Mac host and reaches its frame loop.",
            "3. Its first frame renders correctly.",
            "4. Playable: `python3 scripts/build_ipa_from_nsp.py \(quote(folder)) -k \(quote(keys)) --platform mac-app` builds an app that starts and shows the game.",
            "Prefer general fixes to game-specific rules (AGENTS.md), and write each finding where AGENTS.md says it goes.",
            "",
            "Do not commit, push, sign or install anything, and do not change files outside this worktree and \(folder): the app saves a checkpoint commit of this worktree after each run.",
            "Give long commands a timeout, and stop every host process you started before you finish.",
            "",
        ]
        lines += reportRules
        return finish(lines, instructions)
    }

    public static func continuation(_ c: PortContext, previous: AgentReport?, instructions: String) -> String {
        var lines = [
            "Continue the port of the Nintendo Switch game \"\(c.gameName)\" (title ID \(c.titleID)) to nxnative, in this worktree (\(c.workspace.path), branch \(c.branch)).",
            "The game's files: \(c.nspFolder.path) (work folder \(c.nspFolder.appendingPathComponent("\(c.titleID)-work").path)). AGENTS.md and docs/agents/README.md are the method, as before.",
            "",
        ]
        if let p = previous {
            lines += ["The previous run reported:", "- Milestone: \(p.milestone.rawValue) (\(p.milestone.title))", "- Summary: \(p.summary)"]
            if !p.nextSteps.isEmpty { lines += ["- Next steps:"] + p.nextSteps.map { "  - " + $0 } }
            if !p.blockers.isEmpty { lines += ["- Blockers:"] + p.blockers.map { "  - " + $0 } }
        } else {
            lines.append("The previous run ended without a report: look at the worktree's state (git log, git status) and the notes it wrote to see where it stopped.")
        }
        lines += ["", "What exists:"] + existing(c) + [""]
        lines += keyRules(c)
        lines += ["Do not commit, push, sign or install anything: the app saves a checkpoint commit after each run. Stop every host process you started before you finish.", ""]
        lines += reportRules
        return finish(lines, instructions)
    }

    static let reportRules = [
        "When you stop (done, blocked, or out of time), end with the report: a JSON object with milestone (the highest reached: blocked, in_progress, profile, frame_loop,",
        "first_frame, playable), summary, changed_files, next_steps and blockers.",
    ]

    static func keyRules(_ c: PortContext) -> [String] {
        var lines = ["Keys: \(c.keysFile.path). Pass this path to the repository's tools (-k). Never read, print, copy or upload the key file or any key value."]
        switch (c.agent, c.sandboxed) {
        case (.claudeCode, true):
            lines += ["Your commands run in a sandbox in which the key file cannot be read, not even by the repository's tools, and a guard catches common ways to read it;",
                      "do not try to work around either. The NSP script reuses the game files already extracted in the game's folder (the survey's and the last conversion's).",
                      "If a step needs the keys (a version or DLC not extracted yet, an NSZ not converted yet), stop and report it as a blocker: the app extracts it outside the sandbox."]
        case (.claudeCode, false): lines.append("A guard catches common ways to read the key file; do not try to work around it.")
        case (.codex, _): lines.append("The app cannot enforce this for you: it is your responsibility.")
        }
        return lines
    }

    static func existing(_ c: PortContext) -> [String] {
        var lines = ["- The survey: " + (c.survey?.path ?? "none yet: step 1 of the checklist makes it."),
                     "- The provisional profile: " + (c.provisionalProfile?.path ?? "none.")]
        if let logs = c.lastLogs { lines.append("- The logs of the last conversion: \(logs.path)") }
        if let e = c.lastError, !e.isEmpty { lines.append("- Its error: \(e)") }
        return lines
    }

    static func finish(_ lines: [String], _ instructions: String) -> String {
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return (lines + (extra.isEmpty ? [] : ["", "The user's instructions for this run:", extra])).joined(separator: "\n") + "\n"
    }

    static func versionList(_ versions: [Int]) -> String { versions.isEmpty ? "v0" : versions.map { "v\($0)" }.joined(separator: ", ") }

    static func quote(_ s: String) -> String { PrerequisiteChecker.shellQuote(s) }
}
