// BuildState folding events: stage arrival order across two plans, implicit stage ends, failures, warnings, the overall fraction and the log cap
import Foundation
import Testing
@testable import ConverterCore

struct BuildStateTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func twoPlans() {
        var s = BuildState()
        s.apply(.stage(k: 1, n: 1, name: "decompress NSZ", step: ""), at: t0)
        s.apply(.stageEnd(k: 1, name: "decompress NSZ", ok: true, summary: "1 converted, 0 reused", elapsed: 4), at: t0)
        #expect(s.overallFraction == 1)
        #expect(s.currentPlan.map(\.name) == ["decompress NSZ"])
        s.apply(.stage(k: 1, n: 4, name: "extract v0", step: ""), at: t0)
        #expect(s.currentPlan.map(\.name) == ["extract v0"])
        #expect(s.stages.map(\.id) == [0, 1])
        #expect(s.stages.map(\.k) == [1, 1])
        #expect(s.plannedStages == 4)
        #expect(s.overallFraction == 0)
        s.apply(.progress(ProgressSample(k: 1, name: "extract v0", step: "reading", done: 1, total: 2, fraction: 0.5)), at: t0)
        #expect(s.overallFraction == 0.125)
        #expect(s.currentStage?.step == "reading")
        s.apply(.stage(k: 2, n: 4, name: "rewrite", step: "main"), at: t0)   // ends extract implicitly
        #expect(s.stages[1].status == .succeeded)
        #expect(s.stages[0].summary == "1 converted, 0 reused" && s.stages[0].elapsed == 4)
        #expect(s.overallFraction == 0.25)
        #expect(s.currentStage?.name == "rewrite")
    }

    @Test func failedStage() {
        var s = BuildState()
        s.apply(.stage(k: 1, n: 2, name: "shaders", step: ""), at: t0)
        s.apply(.stageEnd(k: 1, name: "shaders", ok: false, summary: "", elapsed: 2.5), at: t0)
        #expect(s.stages[0].status == .failed)
        #expect(s.currentStage == nil)
        s.apply(.progress(ProgressSample(k: 1, name: "shaders", step: "late")), at: t0)   // no running stage: ignored
        #expect(s.stages[0].progress == nil)
    }

    @Test func stepResetsCount() {
        var s = BuildState()
        s.apply(.stage(k: 1, n: 1, name: "rewrite", step: "main"), at: t0)
        s.apply(.progress(ProgressSample(k: 1, name: "rewrite", step: "main", done: 3, total: 4, fraction: 0.75)), at: t0)
        s.apply(.step(k: 1, name: "rewrite", step: "sdk"), at: t0)
        #expect(s.currentStage?.step == "sdk")
        #expect(s.currentStage?.progress == nil)
    }

    @Test func warnings() {
        var s = BuildState()
        s.apply(.say("[12:00:01] reusing the extracted v0"), at: t0)
        #expect(s.lastWarning == nil)
        s.apply(.say("[12:00:02] [RED] no game icon in the extraction"), at: t0)
        #expect(s.lastWarning == "no game icon in the extraction")
        s.apply(.say("[RED] tools not found: dotnet (.NET SDK 10)"), at: t0)
        #expect(s.lastWarning == "tools not found: dotnet (.NET SDK 10)")
        s.apply(.say("[1x:00:02] [RED] not a clock"), at: t0)
        #expect(s.lastWarning == "tools not found: dotnet (.NET SDK 10)")
        #expect(s.log.map(\.kind) == [.info, .warning, .warning, .info])
        #expect(s.log[1].text == "[12:00:02] [RED] no game icon in the extraction")
        #expect(BuildState.warningText("  [RED] indented") == nil)
        #expect(BuildState.warningText("[RED]x") == nil)
    }

    @Test func multilineMessageAndOtherLines() {
        var s = BuildState()
        s.apply(.say("---- last lines of x.log ----\nerror: one\nerror: two"), at: t0)
        s.appendStderr("Traceback (most recent call last):", at: t0)
        s.appendNote("Installing into /Applications", at: t0)
        #expect(s.log.map(\.text) == ["---- last lines of x.log ----", "error: one", "error: two", "Traceback (most recent call last):", "Installing into /Applications"])
        #expect(s.log.map(\.kind) == [.info, .info, .info, .error, .info])
        #expect(s.log.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func logCap() {
        var s = BuildState()
        for i in 0..<5_010 { s.appendNote("line \(i)", at: t0) }
        #expect(s.log.count == 5_000)
        #expect(s.log.first?.text == "line 10")
        #expect(s.log.last?.id == 5_009)
    }

    @Test func gameAndResult() {
        var s = BuildState()
        let g = GameInfo(titleID: "0100", profile: "0100", name: "G", version: "1.0", package: "v0", provisional: false, derived: false, platform: "mac-app", output: "/G.app", icon: "")
        s.apply(.game(g), at: t0)
        s.apply(.stage(k: 1, n: 3, name: "pack", step: ""), at: t0)
        s.apply(.result(BuildResult(ok: true, platform: "mac-app", path: "/G.app", sizeBytes: 10, command: "")), at: t0)
        s.apply(.unknown("later"), at: t0)
        #expect(s.game == g)
        #expect(s.result?.path == "/G.app")
        #expect(s.overallFraction == 1)
        #expect(s.stages[0].status == .succeeded)
    }

    @Test func fractionClamped() {
        var s = BuildState()
        #expect(s.overallFraction == 0)
        s.apply(.stage(k: 1, n: 2, name: "a", step: ""), at: t0)
        s.apply(.progress(ProgressSample(k: 1, name: "a", step: "", fraction: 7)), at: t0)
        #expect(s.overallFraction == 0.5)
    }
}
