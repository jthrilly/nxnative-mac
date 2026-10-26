// The NSP script's `--progress json` events (scripts/build_ipa_from_nsp.py, Progress._json and Progress.event): one JSON object per stdout line, each with "ev" and "t".
// stage, step, progress, stage_end and say come from the console view of the build; game (the game, profile and output once they are known) and result (the finished build) from main
import Foundation

public struct ProgressSample: Sendable, Equatable {
    public var k: Int; public var name: String; public var step: String
    public var done: Double?; public var total: Double?; public var unit: String; public var estimated: Bool; public var note: String
    public var fraction: Double?; public var eta: Double?; public var elapsed: Double?

    init(k: Int, name: String, step: String, done: Double? = nil, total: Double? = nil, unit: String = "", estimated: Bool = false, note: String = "",
                fraction: Double? = nil, eta: Double? = nil, elapsed: Double? = nil) {
        self.k = k; self.name = name; self.step = step; self.done = done; self.total = total; self.unit = unit; self.estimated = estimated; self.note = note
        self.fraction = fraction; self.eta = eta; self.elapsed = elapsed
    }
}

public struct GameInfo: Sendable, Equatable, Codable {
    public var titleID: String; public var profile: String; public var name: String; public var version: String; public var package: String
    public var provisional: Bool; public var derived: Bool; public var platform: String; public var output: String; public var icon: String
}

public struct BuildResult: Sendable, Equatable, Codable {
    public var ok: Bool; public var platform: String; public var path: String; public var sizeBytes: Int64?; public var command: String
}

public enum BuildEvent: Sendable, Equatable {
    case stage(k: Int, n: Int, name: String, step: String)
    case step(k: Int, name: String, step: String)
    case progress(ProgressSample)
    case stageEnd(k: Int, name: String, ok: Bool, summary: String, elapsed: Double)
    case say(String)
    case game(GameInfo)
    case result(BuildResult)
    case unknown(String)

    /// nil for a line that is not a JSON object with a string "ev" (e.g. a stray print); tolerant of missing optional fields
    public static func decode(_ line: String) -> BuildEvent? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let o = object as? [String: Any],
              let ev = o["ev"] as? String else { return nil }
        let f = Fields(o)
        switch ev {
        case "stage": return .stage(k: f.int("k"), n: f.int("n"), name: f.string("name"), step: f.string("step"))
        case "step": return .step(k: f.int("k"), name: f.string("name"), step: f.string("step"))
        case "progress":
            return .progress(ProgressSample(k: f.int("k"), name: f.string("name"), step: f.string("step"), done: f.double("done"), total: f.double("total"),
                                            unit: f.string("unit"), estimated: f.bool("est"), note: f.string("note"), fraction: f.double("frac"),
                                            eta: f.double("eta"), elapsed: f.double("elapsed")))
        case "stage_end": return .stageEnd(k: f.int("k"), name: f.string("name"), ok: f.bool("ok", default: true), summary: f.string("summary"), elapsed: f.double("elapsed") ?? 0)
        case "say": return .say(f.string("msg"))
        case "game":
            return .game(GameInfo(titleID: f.string("title_id"), profile: f.string("profile"), name: f.string("name"), version: f.string("version"),
                                  package: f.string("package"), provisional: f.bool("provisional"), derived: f.bool("derived"), platform: f.string("platform"),
                                  output: f.string("out"), icon: f.string("icon")))
        case "result":
            return .result(BuildResult(ok: f.bool("ok"), platform: f.string("platform"), path: f.string("path"), sizeBytes: f.double("size").map { Int64($0) },
                                       command: f.string("command")))
        default: return .unknown(ev)
        }
    }
}

// JSONSerialization's values: numbers and booleans are NSNumber, null is NSNull (read here as a missing field)
private struct Fields {
    let o: [String: Any]
    init(_ o: [String: Any]) { self.o = o }

    func string(_ key: String) -> String {
        if let s = o[key] as? String { return s }
        if let n = o[key] as? NSNumber { return n.stringValue }
        return ""
    }
    func double(_ key: String) -> Double? {
        guard let n = o[key] as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    func int(_ key: String) -> Int {
        guard let d = double(key), d.magnitude < 1e15 else { return 0 }
        return Int(d)
    }
    func bool(_ key: String, default value: Bool = false) -> Bool {
        guard let n = o[key] as? NSNumber else { return value }
        return n.boolValue
    }
    private func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}
