// What the conversion window shows of a build: its stages, the log, the game and the result, folded from the script's events (BuildEvent).
// PROG.plan() can run twice (NSZ decompression plans 1 stage, then main plans the rest), so k restarts: stages are identified by their arrival order
import Foundation

public enum StageStatus: Sendable, Equatable { case running, succeeded, failed }

public struct StageRecord: Sendable, Equatable, Identifiable {
    public let id: Int
    public var k: Int; public var n: Int; public var name: String; public var step: String
    public var status: StageStatus; public var summary: String; public var elapsed: Double?
    public var progress: ProgressSample?
    public var startedAt: Date
}

public enum LogKind: Sendable, Equatable { case info, warning, error }

public struct LogLine: Sendable, Equatable, Identifiable { public let id: Int; public var date: Date; public var text: String; public var kind: LogKind }

public struct BuildState: Sendable, Equatable {
    static let maxLogLines = 5_000

    public private(set) var stages: [StageRecord] = []
    public private(set) var plannedStages = 0
    public private(set) var log: [LogLine] = []
    public private(set) var game: GameInfo?
    public private(set) var result: BuildResult?
    private(set) var lastWarning: String?
    private var planStart = 0   // index in stages of the latest plan's first stage
    private var nextLogID = 0

    public init() {}

    public var currentStage: StageRecord? { stages.last.flatMap { $0.status == .running ? $0 : nil } }

    /// The stages of the latest plan: the script numbers a new plan's stages from 1 again
    public var currentPlan: ArraySlice<StageRecord> { stages[min(planStart, stages.count)...] }

    public var overallFraction: Double {
        if result?.ok == true { return 1 }
        let plan = currentPlan
        guard plannedStages > 0, !plan.isEmpty else { return 0 }
        let finished = plan.filter { $0.status != .running }.count
        let current = plan.last.flatMap { $0.status == .running ? $0.progress?.fraction : nil } ?? 0
        return min(max((Double(finished) + min(max(current, 0), 1)) / Double(plannedStages), 0), 1)
    }

    public mutating func apply(_ event: BuildEvent, at date: Date) {
        switch event {
        case let .stage(k, n, name, step):
            closeRunningStage()
            if stages.last.map({ k <= $0.k }) ?? true { planStart = stages.count }   // a new plan numbers its stages from 1 again
            stages.append(StageRecord(id: stages.count, k: k, n: n, name: name, step: step, status: .running, summary: "", elapsed: nil, progress: nil, startedAt: date))
            plannedStages = n
        case let .step(_, _, step):
            guard let i = runningIndex else { return }
            stages[i].step = step; stages[i].progress = nil
        case let .progress(sample):
            guard let i = runningIndex else { return }
            stages[i].step = sample.step; stages[i].progress = sample
        case let .stageEnd(_, _, ok, summary, elapsed):
            guard let i = runningIndex else { return }
            stages[i].status = ok ? .succeeded : .failed; stages[i].summary = summary; stages[i].elapsed = elapsed
        case let .say(message):
            let warning = Self.warningText(message)
            if let warning { lastWarning = warning }
            append(message, kind: warning == nil ? .info : .warning, at: date)
        case let .game(info): game = info
        case let .result(r):
            result = r
            if r.ok { closeRunningStage() }
        case .unknown: break
        }
    }

    public mutating func appendStderr(_ line: String, at date: Date) { append(line, kind: .error, at: date) }

    public mutating func appendNote(_ text: String, at date: Date) { append(text, kind: .info, at: date) }

    private var runningIndex: Int? { stages.isEmpty || stages[stages.count - 1].status != .running ? nil : stages.count - 1 }

    private mutating func closeRunningStage() {
        guard let i = runningIndex else { return }
        stages[i].status = .succeeded
    }

    private mutating func append(_ text: String, kind: LogKind, at date: Date) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            log.append(LogLine(id: nextLogID, date: date, text: String(line), kind: kind)); nextLogID += 1
        }
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    /// The message of a "[RED] " line without its prefixes (the script's say() adds "[HH:MM:SS] "), nil for any other message
    static func warningText(_ message: String) -> String? {
        var s = Substring(message)
        if s.count >= 11, s.hasPrefix("["), s.dropFirst(9).hasPrefix("] ") {
            let clock = s.dropFirst().prefix(8)
            if clock.enumerated().allSatisfy({ i, c in i == 2 || i == 5 ? c == ":" : c.isASCII && c.isNumber }) { s = s.dropFirst(11) }
        }
        return s.hasPrefix("[RED] ") ? String(s.dropFirst(6)) : nil
    }
}
