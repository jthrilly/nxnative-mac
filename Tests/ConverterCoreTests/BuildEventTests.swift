// BuildEvent.decode on lines shaped as the NSP script's Progress._json and Progress.event write them
import Foundation
import Testing
@testable import ConverterCore

struct BuildEventTests {
    @Test func stage() {
        #expect(BuildEvent.decode(#"{"ev": "stage", "k": 1, "n": 2, "name": "extract v327680", "step": "", "t": 1792936806.777}"#)
                == .stage(k: 1, n: 2, name: "extract v327680", step: ""))
    }

    @Test func progressWithCount() {
        let line = #"{"ev": "progress", "k": 1, "name": "extract v327680", "step": "", "done": 2040109465, "total": 4831838208, "unit": "B", "est": true, "note": "1,203 files", "frac": 0.4222222220980459, "eta": 12.5, "elapsed": 3.25, "t": 1792936806.778}"#
        guard case let .progress(p) = BuildEvent.decode(line) else { Issue.record("not a progress event"); return }
        #expect(p == ProgressSample(k: 1, name: "extract v327680", step: "", done: 2040109465, total: 4831838208, unit: "B", estimated: true, note: "1,203 files",
                                    fraction: 0.4222222220980459, eta: 12.5, elapsed: 3.25))
    }

    @Test func progressNulls() {
        let line = #"{"ev": "progress", "k": 2, "name": "rewrite", "step": "main", "done": null, "total": null, "unit": "", "est": false, "note": "", "frac": null, "eta": null, "elapsed": 0.0, "t": 1.0}"#
        guard case let .progress(p) = BuildEvent.decode(line) else { Issue.record("not a progress event"); return }
        #expect(p.done == nil && p.total == nil && p.fraction == nil && p.eta == nil)
        #expect(p.elapsed == 0 && p.step == "main" && !p.estimated)
    }

    @Test func missingFields() {
        guard case let .progress(p) = BuildEvent.decode(#"{"ev": "progress"}"#) else { Issue.record("not a progress event"); return }
        #expect(p == ProgressSample(k: 0, name: "", step: ""))
        #expect(BuildEvent.decode(#"{"ev": "stage_end", "k": 3}"#) == .stageEnd(k: 3, name: "", ok: true, summary: "", elapsed: 0))
        #expect(BuildEvent.decode(#"{"ev": "say"}"#) == .say(""))
    }

    @Test func stepStageEndSay() {
        #expect(BuildEvent.decode(#"{"ev": "step", "k": 2, "name": "rewrite", "step": "sdk", "t": 1.0}"#) == .step(k: 2, name: "rewrite", step: "sdk"))
        #expect(BuildEvent.decode(#"{"ev": "stage_end", "k": 2, "name": "rewrite", "ok": false, "summary": "", "elapsed": 0.5, "t": 1.0}"#)
                == .stageEnd(k: 2, name: "rewrite", ok: false, summary: "", elapsed: 0.5))
        #expect(BuildEvent.decode(#"{"ev": "say", "msg": "[12:00:01] [RED] two\nlines", "t": 1.0}"#) == .say("[12:00:01] [RED] two\nlines"))
        #expect(BuildEvent.decode(#"{"ev": "say", "msg": "Pokémon é", "t": 1.0}"#) == .say("Pokémon é"))
    }

    @Test func eventsTheGuidanceDoesNotListAreIgnored() {   // docs/frontends.md lists stage, step, progress, stage_end and say; anything else is unknown
        #expect(BuildEvent.decode(#"{"ev": "game", "title_id": "010015100B514000", "out": "/G/W.app", "t": 1.0}"#) == .unknown("game"))
        #expect(BuildEvent.decode(#"{"ev": "result", "ok": true, "path": "/G/W.app", "t": 1.0}"#) == .unknown("result"))
    }

    @Test func unknownAndNotEvents() {
        #expect(BuildEvent.decode(#"{"ev": "heartbeat", "t": 1.0}"#) == .unknown("heartbeat"))
        #expect(BuildEvent.decode("building the shaders…") == nil)
        #expect(BuildEvent.decode("") == nil)
        #expect(BuildEvent.decode("[1, 2]") == nil)
        #expect(BuildEvent.decode(#"{"ev": 3}"#) == nil)
        #expect(BuildEvent.decode(#"{"msg": "no ev"}"#) == nil)
        #expect(BuildEvent.decode(#"{"ev": "say", "msg": "cut"#) == nil)
    }

    @Test func booleansAreNotNumbers() {
        guard case let .progress(p) = BuildEvent.decode(#"{"ev": "progress", "k": 1, "done": true, "est": 1}"#) else { Issue.record("not a progress event"); return }
        #expect(p.done == nil && p.estimated)
    }
}
