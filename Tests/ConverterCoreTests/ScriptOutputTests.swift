// The NSP script's own --progress json output fed to BuildEvent.decode and BuildState: lines captured from scripts/build_ipa_from_nsp.py (the failing runs from the real
// script on an empty folder, a zero-byte NSP and a fake NSP that nx_extract rejects; the finished runs from main() with its steps stood in for, as test_nsp_progress.py's Main does),
// with the scratch folders and the checkout renamed to /Users/player/Games and /Users/player/nxnative
import Foundation
import Testing
@testable import ConverterCore

struct ScriptOutputTests {
    static let noNSP = [
        #"{"ev": "say", "msg": "[RED] no NSP with a readable title ID in /Users/player/Games/empty", "t": 1792937550.468}"#,
    ]
    static let emptyFile = [
        #"{"ev": "say", "msg": "[16:12:30] skipping an empty file: zero.nsp", "t": 1792937550.635}"#,
        #"{"ev": "say", "msg": "[RED] no NSP with a readable title ID in /Users/player/Games/empty", "t": 1792937550.635}"#,
    ]
    static let failedExtract = [
        #"{"ev": "say", "msg": "[16:12:40] game profile: 010015100B514000", "t": 1792937560.46}"#,
        #"{"ev": "say", "msg": "[16:12:40] the folder has no v327680, whose files game profile 010015100B514000's shader tables were made from: packing v0 from a profile derived from it", "t": 1792937560.46}"#,
        #"{"ev": "say", "msg": "[16:12:40] Mac app: the Mac shaders and the Mac host, packed into a Mac app; no iOS shaders, Xcode project or IPA", "t": 1792937560.46}"#,
        #"{"ev": "say", "msg": "[16:12:40] work folder (extracted game files in extract/, kept for the next build): /Users/player/Games/fake/010015100B514000_build", "t": 1792937560.46}"#,
        #"{"ev": "say", "msg": "[16:12:41] base: Game [010015100B514000][v0].nsp", "t": 1792937561.139}"#,
        #"{"ev": "stage", "k": 1, "n": 6, "name": "build nx_extract", "step": "", "t": 1792937561.139}"#,
        #"{"ev": "progress", "k": 1, "name": "build nx_extract", "step": "", "done": null, "total": null, "unit": "", "est": false, "note": "", "frac": null, "eta": null, "elapsed": 0.0, "t": 1792937561.14}"#,
        #"{"ev": "stage_end", "k": 1, "name": "build nx_extract", "ok": true, "summary": "", "elapsed": 3.54, "t": 1792937564.679}"#,
        #"{"ev": "stage", "k": 2, "n": 6, "name": "extract v0", "step": "", "t": 1792937564.679}"#,
        #"{"ev": "progress", "k": 2, "name": "extract v0", "step": "", "done": null, "total": 4096, "unit": "B", "est": true, "note": "", "frac": null, "eta": null, "elapsed": 0.0, "t": 1792937564.679}"#,
        #"{"ev": "progress", "k": 2, "name": "extract v0", "step": "", "done": 0, "total": 4096, "unit": "B", "est": true, "note": "0 files", "frac": 0.0, "eta": null, "elapsed": 0.0, "t": 1792937564.68}"#,
        #"{"ev": "stage_end", "k": 2, "name": "extract v0", "ok": false, "summary": "", "elapsed": 0.296, "t": 1792937564.976}"#,
        #"{"ev": "say", "msg": "---- last lines of /Users/player/Games/fake/010015100B514000_build/logs/extract_v0.log ----\nUnhandled exception. LibHac.Common.HorizonResultException: ResultFsPartitionSignatureVerificationFailed (2002-4644)\n   at LibHac.Common.ThrowHelper.ThrowResult(Result result)\n   at LibHac.Result.ThrowIfFailure()\n   at P.OpenNsp(KeySet ks, String path) in /Users/player/nxnative/dm/tools/nx_extract/Program.cs:line 105\n   at P.Main(String[] a) in /Users/player/nxnative/dm/tools/nx_extract/Program.cs:line 34", "t": 1792937564.976}"#,
        #"{"ev": "say", "msg": "[RED] nx_extract exit code -6 (full output: /Users/player/Games/fake/010015100B514000_build/logs/extract_v0.log)", "t": 1792937564.976}"#,
    ]
    static let macApp = [
        #"{"ev": "say", "msg": "[16:13:54] app name: Game: Test; version: 1.0.1; bundle ID: org.nxnative.0100bbbb00000000; app: /Users/player/Games/Test Game/Game - Test.app", "t": 1792937634.773}"#,
        #"{"ev": "say", "msg": "[16:13:54] done: /Users/player/Games/Test Game/Game - Test.app (0.0 GB); open it from Finder. Its save is in ~/Library/Application Support/nxnative/0100BBBB00000000/, its log in ~/Library/Logs/nxnative/0100BBBB00000000.log", "t": 1792937634.775}"#,
    ]
    static let macRun = [
        #"{"ev": "say", "msg": "[16:13:54] done: the game runs on the Mac with this command (its save in /Users/player/Games/Test Game/0100BBBB00000000_build/run/save, kept from run to run; DM_WINDOW=1 opens a window, DM_AUDIO=1 plays sound):", "t": 1792937634.797}"#,
    ]

    static func fold(_ lines: [String]) -> (events: [BuildEvent], state: BuildState) {
        var state = BuildState()
        let events = lines.compactMap(BuildEvent.decode)
        for (i, e) in events.enumerated() { state.apply(e, at: Date(timeIntervalSince1970: Double(i))) }
        return (events, state)
    }

    @Test func everyLineDecodes() {
        for lines in [Self.noNSP, Self.emptyFile, Self.failedExtract, Self.macApp, Self.macRun] {
            let events = lines.compactMap(BuildEvent.decode)
            #expect(events.count == lines.count)
            #expect(!events.contains { if case .unknown = $0 { true } else { false } })
        }
    }

    @Test func failsBeforeAnyStage() {
        let (_, state) = Self.fold(Self.noNSP)
        #expect(state.stages.isEmpty && state.overallFraction == 0)
        #expect(state.lastWarning == "no NSP with a readable title ID in /Users/player/Games/empty")
        let (_, skipped) = Self.fold(Self.emptyFile)
        #expect(skipped.log.map(\.kind) == [.info, .warning])
        #expect(skipped.log.first?.text == "[16:12:30] skipping an empty file: zero.nsp")
    }

    @Test func failedExtraction() {
        let (events, state) = Self.fold(Self.failedExtract)
        #expect(events.filter { if case .progress = $0 { true } else { false } }.count == 3)
        #expect(state.stages.map(\.name) == ["build nx_extract", "extract v0"])
        #expect(state.stages.map(\.status) == [.succeeded, .failed])
        #expect(state.stages.map(\.elapsed) == [3.54, 0.296])
        #expect(state.plannedStages == 6 && state.currentStage == nil)
        #expect(state.overallFraction == 2.0 / 6)
        #expect(state.stages[1].progress?.total == 4096 && state.stages[1].progress?.unit == "B" && state.stages[1].progress?.estimated == true)
        #expect(state.stages[1].progress.map(ProgressFormat.count) == "0.0/~4.0 KB")   // Python: Progress._count
        #expect(state.lastWarning == "nx_extract exit code -6 (full output: /Users/player/Games/fake/010015100B514000_build/logs/extract_v0.log)")
        // the log tail is one message of six lines; none of them is a warning
        #expect(state.log.count == 5 + 6 + 1)
        #expect(state.log.filter { $0.kind == .warning }.count == 1)
        #expect(state.log[5].text == "---- last lines of /Users/player/Games/fake/010015100B514000_build/logs/extract_v0.log ----")
        #expect(!state.succeeded)
    }

    @Test func finishedMacApp() {   // the app is where -o put it, named as the script names it: "Game: Test" makes "Game - Test.app"
        var (_, state) = Self.fold(Self.macApp)
        #expect(state.lastWarning == nil && !state.succeeded)
        state.finish()
        #expect(state.overallFraction == 1)
        #expect(ConversionCommand.appOutput(folder: URL(fileURLWithPath: "/Users/player/Games/Test Game"), name: "Game: Test").path
                == "/Users/player/Games/Test Game/Game - Test.app")
    }

    @Test func finishedMacRun() {
        let (_, state) = Self.fold(Self.macRun)
        #expect(state.log.count == 1 && state.lastWarning == nil)
    }
}
