// AgentReport: the schema both agents get, the report found in an agent's text (alone, fenced, after prose) and the order of the milestones
import Foundation
import Testing
@testable import ConverterCore

struct AgentReportTests {
    @Test func schema() throws {
        let o = try #require(try JSONSerialization.jsonObject(with: Data(AgentReport.jsonSchema.utf8)) as? [String: Any])
        let properties = try #require(o["properties"] as? [String: Any])
        let required = try #require(o["required"] as? [String])
        #expect(o["type"] as? String == "object" && o["additionalProperties"] as? Bool == false)
        #expect(Set(required) == Set(properties.keys) && required.count == 5)   // OpenAI's strict mode: every property required
        let milestone = try #require(properties["milestone"] as? [String: Any])
        #expect(milestone["enum"] as? [String] == ["blocked", "in_progress", "profile", "frame_loop", "first_frame", "playable"])
    }

    @Test func parsePlain() {
        let r = AgentReport.parse(#"{"milestone":"first_frame","summary":"The title screen renders","changed_files":["a"],"next_steps":["b"],"blockers":[]}"#)
        #expect(r == AgentReport(milestone: .firstFrame, summary: "The title screen renders", changedFiles: ["a"], nextSteps: ["b"]))
        #expect(AgentReport.parse(#"{"milestone":"profile"}"#) == AgentReport(milestone: .profile, summary: ""))   // lists left out
    }

    @Test func parseFencedAndAfterProse() {
        let fenced = """
            The game reaches its frame loop.

            ```json
            {
              "milestone": "frame_loop",
              "summary": "Boots; {braces} and \\"quotes\\" in strings are fine",
              "changed_files": ["dm/games/0100ABCD00000000/game.tsv"],
              "next_steps": [],
              "blockers": []
            }
            ```
            """
        #expect(AgentReport.parse(fenced)?.milestone == .frameLoop)
        #expect(AgentReport.parse(fenced)?.summary == #"Boots; {braces} and "quotes" in strings are fine"#)
        let two = #"First {"milestone":"blocked","summary":"old"} then {"milestone":"playable","summary":"new"} and {"not":"a report"}"#
        #expect(AgentReport.parse(two)?.summary == "new")   // the last report in the text
        #expect(AgentReport.parse("no report here") == nil)
        #expect(AgentReport.parse(#"{"milestone":"done"}"#) == nil)   // not a milestone
        #expect(AgentReport.parse(#"{"milestone":"blocked""#) == nil)   // not closed
    }

    @Test func milestoneOrder() {
        #expect(PortMilestone.blocked < .inProgress && PortMilestone.inProgress < .profile && PortMilestone.profile < .frameLoop)
        #expect(PortMilestone.frameLoop < .firstFrame && PortMilestone.firstFrame < .playable)
        #expect([PortMilestone.playable, .blocked, .profile].max() == .playable)
        #expect(Set(PortMilestone.allCases.map(\.title)).count == PortMilestone.allCases.count)
    }
}
