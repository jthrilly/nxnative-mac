// PortStore and PortRecord: a round trip through ports.json, records from an older or newer converter, the latest report, the last session of each agent and the total cost
import Foundation
import Testing
@testable import ConverterCore

struct PortStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func record() -> PortRecord {
        let report = AgentReport(milestone: .profile, summary: "Profile written", changedFiles: ["dm/games/0100ABCD00000000/game.tsv"])
        return PortRecord(titleID: "0100ABCD00000000", gameName: "Super Game", folder: "/Volumes/Games/Super Game", workspace: "/Users/player/nxnative-ports/0100ABCD00000000",
                          branch: "port/0100ABCD00000000", baseCommit: "ec4ea16", createdAt: t0, runs: [
                              AgentRunRecord(kind: .claudeCode, sessionID: "c1", startedAt: t0, finishedAt: t0.addingTimeInterval(600), status: .succeeded,
                                             usage: AgentUsage(costUSD: 1.25, inputTokens: 100, outputTokens: 10), turns: 12, report: report, checkpoint: "abc",
                                             transcriptFile: "r1.jsonl", instructions: "Go", model: "claude-opus-5-5"),
                              AgentRunRecord(kind: .codex, sessionID: "x1", startedAt: t0.addingTimeInterval(1_000), status: .failed, usage: AgentUsage(inputTokens: 5),
                                             message: "model_not_found"),
                              AgentRunRecord(kind: .claudeCode, interactive: true, startedAt: t0.addingTimeInterval(2_000), status: .interactive, usage: AgentUsage(costUSD: 0.5)),
                          ])
    }

    @Test func roundTrip() throws {
        let t = try TempDir(); defer { t.remove() }
        let store = PortStore(fileURL: t.url.appendingPathComponent("sub/ports.json"))
        #expect(try store.load().isEmpty)
        let ports = [record()]
        try store.save(ports)
        #expect(try store.load() == ports)
    }

    @Test func derivedValues() {
        let r = record()
        #expect(r.latestReport?.milestone == .profile)   // the newer runs have none
        #expect(r.lastSession(of: .claudeCode) == "c1" && r.lastSession(of: .codex) == "x1")
        #expect(r.totalCostUSD == 1.75)
        var later = r
        later.runs.insert(AgentRunRecord(kind: .claudeCode, sessionID: "c2", startedAt: t0.addingTimeInterval(5_000), status: .cancelled), at: 0)   // order by date
        #expect(later.lastSession(of: .claudeCode) == "c2")
        #expect(PortRecord(titleID: "T", gameName: "G", folder: "", workspace: "", branch: "b", baseCommit: "", createdAt: t0).latestReport == nil)
    }

    @Test func tolerantDecoding() throws {
        let json = #"""
            [{"titleID": "0100ABCD00000000", "runs": [
              {"kind": "gemini", "status": "paused", "startedAt": "2026-10-25T12:00:00Z", "usage": {"costUSD": "lots"}, "report": {"milestone": "done"}},
              {"kind": "codex", "status": "succeeded", "sessionID": "x9", "startedAt": "2026-10-25T13:00:00Z", "futureField": 1}
            ]}, {"titleID": "0100000000010000", "gameName": "Other"}]
            """#
        let ports = try LibraryStore.decoder().decode([PortRecord].self, from: Data(json.utf8))
        #expect(ports.count == 2)
        let p = ports[0]
        #expect(p.gameName == "0100ABCD00000000" && p.branch == "port/0100ABCD00000000" && p.workspace.isEmpty && p.runs.count == 2)
        #expect(p.runs[0].kind == .claudeCode && p.runs[0].status == .failed && p.runs[0].usage == nil && p.runs[0].report == nil && p.runs[0].instructions.isEmpty)
        #expect(p.runs[1].status == .succeeded && p.runs[1].sessionID == "x9")
        #expect(p.lastSession(of: .codex) == "x9")
        #expect(ports[1].gameName == "Other" && ports[1].runs.isEmpty)
        #expect(throws: DecodingError.self) { try LibraryStore.decoder().decode([PortRecord].self, from: Data(#"[{"gameName": "no title ID"}]"#.utf8)) }
        let odd = #"[{"titleID": "0100ABCD00000000", "createdAt": "not a date", "runs": {"not": "an array"}}]"#
        let q = try LibraryStore.decoder().decode([PortRecord].self, from: Data(odd.utf8))
        #expect(q[0].createdAt == Date(timeIntervalSince1970: 0) && q[0].runs.isEmpty)
        let runs = #"[{"titleID": "0100ABCD00000000", "runs": [7, {"kind": "codex", "startedAt": 12, "finishedAt": "x", "turns": "many", "status": "succeeded"}]}]"#
        let r = try LibraryStore.decoder().decode([PortRecord].self, from: Data(runs.utf8))
        #expect(r[0].runs.count == 1 && r[0].runs[0].kind == .codex && r[0].runs[0].startedAt == Date(timeIntervalSince1970: 0) && r[0].runs[0].turns == nil)
    }

    @Test func storeKeepsWhatItCannotRead() throws {
        let t = try TempDir(); defer { t.remove() }
        let json = #"[{"titleID": "0100ABCD00000000"}, {"gameName": "no title ID"}]"#
        let f = try t.file("ports.json", Data(json.utf8))
        let store = PortStore(fileURL: f)
        let contents = try store.read()
        #expect(contents.records.map(\.titleID) == ["0100ABCD00000000"] && contents.skipped == 1)
        #expect(contents.preserved.map { (try? Data(contentsOf: $0)) == Data(json.utf8) } == true)
        try Data("[".utf8).write(to: f)
        #expect(throws: StoreError.self) { try store.load() }
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(try store.load().isEmpty)
    }

    @Test func locations() {
        #expect(PortStore.defaultURL.lastPathComponent == "ports.json")
        #expect(PortStore.defaultURL.deletingLastPathComponent() == LibraryStore.defaultURL.deletingLastPathComponent())
        #expect(PortStore.runFolder(titleID: "0100ABCD00000000").path.hasSuffix("/ports/0100ABCD00000000"))
    }
}
