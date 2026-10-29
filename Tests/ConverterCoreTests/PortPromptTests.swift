// PortPrompt: what the first and later runs of a port tell the agent
import Foundation
import Testing
@testable import ConverterCore

struct PortPromptTests {
    let folder = URL(fileURLWithPath: "/Volumes/Games/Super Game")

    func context(_ agent: AgentKind, existing: Bool, sandboxed: Bool = true) -> PortContext {
        PortContext(titleID: "0100ABCD00000000", gameName: "Super Game", versions: [0, 65536], nspFolder: folder, keysFile: URL(fileURLWithPath: "/Users/player/.switch/prod.keys"),
                    workspace: URL(fileURLWithPath: "/Users/player/nxnative-ports/0100ABCD00000000"), branch: "port/0100ABCD00000000",
                    survey: existing ? ConversionCommand.surveyFile(folder: folder, titleID: "0100ABCD00000000") : nil,
                    provisionalProfile: existing ? ConversionCommand.provisionalProfile(folder: folder, titleID: "0100ABCD00000000") : nil,
                    lastLogs: existing ? ConversionCommand.logsFolder(folder: folder, titleID: "0100ABCD00000000") : nil, lastError: existing ? "Abort 0x2A2" : nil,
                    lastErrorSource: existing ? "the conversion of 29 Oct 2026 at 18:02 with nxnative 5654459abcde" : nil, agent: agent,
                    sandboxed: sandboxed, bootLauncher: URL(fileURLWithPath: "/Users/player/Library/Caches/org.nxnative.converter/port-tools/0100ABCD00000000/boot.sh"))
    }

    @Test func initial() {
        let p = PortPrompt.initial(context(.claudeCode, existing: true), instructions: "  Start with the title screen.\n")
        for s in ["\"Super Game\"", "0100ABCD00000000", "v0, v65536", "/Volumes/Games/Super Game", "/Volumes/Games/Super Game/0100ABCD00000000-work",
                  "Keys: /Users/player/.switch/prod.keys", "/Users/player/nxnative-ports/0100ABCD00000000", "port/0100ABCD00000000", "AGENTS.md", "docs/agents/README.md",
                  "/Volumes/Games/Super Game/0100ABCD00000000_survey/survey.md", "/Volumes/Games/Super Game/0100ABCD00000000_build/profile/0100ABCD00000000",
                  "/Volumes/Games/Super Game/0100ABCD00000000_build/logs", "Abort 0x2A2", "reproduce it before acting on it", "Do not commit", "the key file cannot be read",
                  "report it as a blocker", "`/Users/player/Library/Caches/org.nxnative.converter/port-tools/0100ABCD00000000/boot.sh …`", "no Metal device",
                  "--platform mac-app", "-k '/Users/player/.switch/prod.keys'", "'/Volumes/Games/Super Game'"] {
            #expect(p.contains(s), "\(s)")
        }
        for m in PortMilestone.allCases { #expect(p.contains(m.rawValue), "\(m)") }
        #expect(p.hasSuffix("The user's instructions for this run:\nStart with the title screen.\n"))
        #expect(!p.contains("it is your responsibility"))
    }

    @Test func initialWithNothingYet() {
        let p = PortPrompt.initial(context(.codex, existing: false), instructions: " ")
        #expect(p.contains("The survey: none yet") && p.contains("The provisional profile: none."))
        #expect(p.contains("The app cannot enforce this for you: it is your responsibility.") && !p.contains("sandbox"))
        #expect(!p.contains("instructions for this run") && !p.contains("logs of the last conversion"))
        #expect(PortPrompt.initial(PortContext(titleID: "T", gameName: "G", versions: [], nspFolder: folder, keysFile: folder, workspace: folder, branch: "b", agent: .codex),
                                   instructions: "").contains("versions in the folder: v0)"))
    }

    @Test func claudeWithoutSandbox() {
        let p = PortPrompt.initial(context(.claudeCode, existing: true, sandboxed: false), instructions: "")
        #expect(p.contains("A guard catches common ways to read the key file") && !p.contains("sandbox"))
    }

    @Test func continuation() {
        let report = AgentReport(milestone: .frameLoop, summary: "Boots to the frame loop", nextSteps: ["Fix the missing texture", "Check audio"], blockers: ["svc 0x7F"])
        let p = PortPrompt.continuation(context(.claudeCode, existing: true), previous: report, instructions: "Look at audio.")
        for s in ["Continue the port", "0100ABCD00000000", "frame_loop", "Boots to the frame loop", "  - Fix the missing texture", "  - Check audio", "  - svc 0x7F",
                  "Keys: /Users/player/.switch/prod.keys", "Do not commit", "/Volumes/Games/Super Game/0100ABCD00000000_survey/survey.md", "Look at audio."] {
            #expect(p.contains(s), "\(s)")
        }
        let none = PortPrompt.continuation(context(.codex, existing: false), previous: nil, instructions: "")
        #expect(none.contains("ended without a report") && none.contains("it is your responsibility") && none.contains("first_frame"))
    }
}
