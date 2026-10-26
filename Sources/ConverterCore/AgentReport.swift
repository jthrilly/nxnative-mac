// What an agent reports at the end of a port run: the highest milestone it reached, a summary, the files it changed, what comes next and what blocks it. claude gets the schema
// with --json-schema (its result's structured_output), codex with --output-schema (every agent message is then the schema's JSON: the last one is the report). OpenAI's strict
// mode needs every property required and no others
import Foundation

public enum PortMilestone: String, Sendable, Codable, CaseIterable, Comparable {
    case blocked, inProgress = "in_progress", profile, frameLoop = "frame_loop", firstFrame = "first_frame", playable

    public var title: String {
        switch self {
        case .blocked: return "Blocked"
        case .inProgress: return "In progress"
        case .profile: return "Profile written"
        case .frameLoop: return "Boots to its frame loop"
        case .firstFrame: return "First frame"
        case .playable: return "Playable"
        }
    }

    public static func < (a: PortMilestone, b: PortMilestone) -> Bool { a.rank < b.rank }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct AgentReport: Sendable, Equatable, Codable {
    public var milestone: PortMilestone; public var summary: String; public var changedFiles: [String]; public var nextSteps: [String]; public var blockers: [String]

    enum CodingKeys: String, CodingKey { case milestone, summary, changedFiles = "changed_files", nextSteps = "next_steps", blockers }

    public init(milestone: PortMilestone, summary: String, changedFiles: [String] = [], nextSteps: [String] = [], blockers: [String] = []) {
        self.milestone = milestone; self.summary = summary; self.changedFiles = changedFiles; self.nextSteps = nextSteps; self.blockers = blockers
    }

    // An agent that left out a list still reports; the milestone is what the report is for
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        milestone = try c.decode(PortMilestone.self, forKey: .milestone)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        changedFiles = try c.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
    }

    public static let jsonSchema: String = {
        let list: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["milestone", "summary", "changed_files", "next_steps", "blockers"],
            "properties": ["milestone": ["type": "string", "enum": PortMilestone.allCases.map(\.rawValue)], "summary": ["type": "string"],
                           "changed_files": list, "next_steps": list, "blockers": list],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }()

    /// The report in an agent's text: a JSON object on its own, inside a ```json fence or after prose. The last object in the text that is a report wins
    public static func parse(_ text: String) -> AgentReport? {
        let chars = Array(text.unicodeScalars)
        let starts = chars.indices.filter { chars[$0] == "{" }.suffix(400)
        for start in starts.reversed() {
            guard let end = objectEnd(chars, from: start) else { continue }
            var s = String.UnicodeScalarView(); s.append(contentsOf: chars[start...end])
            if let report = try? JSONDecoder().decode(AgentReport.self, from: Data(String(s).utf8)) { return report }
        }
        return nil
    }

    /// The index of the "}" closing the object that opens at start (strings and their escapes skipped), nil when it is not closed
    static func objectEnd(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }
}
