// ConversionCommand: the script's arguments (a Mac app at the path -o names, or an Xcode project), the Xcode project's paths, the folders it writes (logs, survey, provisional profile, work) and the game languages
import Foundation
import Testing
@testable import ConverterCore

struct ConversionTests {
    let script = URL(fileURLWithPath: "/repo/scripts/build_ipa_from_nsp.py"), folder = URL(fileURLWithPath: "/Games/Super Game"), keys = URL(fileURLWithPath: "/k/prod.keys")
    let base = ["-u", "/repo/scripts/build_ipa_from_nsp.py", "/Games/Super Game", "-k", "/k/prod.keys", "--platform", "mac-app", "--progress", "json"]

    @Test func argumentsWithoutOptions() {
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: ConversionOptions()) == base)
    }

    @Test func argumentsWithEveryOption() {
        var o = ConversionOptions()
        o.language = "ja"; o.package = "v327680"; o.appName = "My Game"; o.bundleID = "org.example.game"; o.allowDamaged = true
        o.signingIdentity = "Developer ID Application: A (TEAM)"
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o)
                == base + ["-l", "ja", "-p", "v327680", "--app-name", "My Game", "--bundle-id", "org.example.game", "--allow-damaged",
                           "--mac-sign", "Developer ID Application: A (TEAM)"])
    }

    @Test func argumentsForAnXcodeProject() {
        var o = ConversionOptions()
        o.output = .xcodeProject; o.bundleID = "org.example.game"; o.signingIdentity = "Developer ID Application: A (TEAM)"   // a Mac app's identity does not apply
        let xcode = ["-u", "/repo/scripts/build_ipa_from_nsp.py", "/Games/Super Game", "-k", "/k/prod.keys", "--platform", "ios", "--prepare-xcode", "--progress", "json",
                     "--bundle-id", "org.example.game"]
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o) == xcode)
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o, teamID: "A1B2C3D4E5") == xcode + ["--team-id", "A1B2C3D4E5"])
        o.output = .macApp   // a team ID is for Xcode projects only
        #expect(!ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o, teamID: "A1B2C3D4E5").contains("--team-id"))
    }

    @Test func outputDecodesLeniently() throws {   // options saved before the output existed are a Mac app's
        let old = try JSONDecoder().decode(ConversionOptions.self, from: Data(#"{"language":"ja"}"#.utf8))
        #expect(old.output == .macApp && old.language == "ja")
        let unknown = try JSONDecoder().decode(ConversionOptions.self, from: Data(#"{"output":"tvApp"}"#.utf8))
        #expect(unknown.output == .macApp)
        var o = ConversionOptions(); o.output = .xcodeProject
        #expect(try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(o)).output == .xcodeProject)
    }

    @Test func appOutput() {   // -o for a Mac app only; the name as the script's mac_app_name makes it
        let app = ConversionCommand.appOutput(folder: folder, name: "Zelda: Breath of the Wild")
        #expect(app.path == "/Games/Super Game/Zelda - Breath of the Wild.app")
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: ConversionOptions(), app: app) == base + ["-o", app.path])
        var o = ConversionOptions(); o.output = .xcodeProject
        #expect(!ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o, app: app).contains("-o"))
        #expect(ConversionCommand.macAppName("A/B : C") == "A - B - C")
        #expect(ConversionCommand.macAppName(" Game. ") == "Game")
        #expect(ConversionCommand.macAppName(":") == "nxnative")
    }

    @Test func envFileIsGone() throws {   // a record saved with the old env file option still loads; the option is not passed on
        let o = try JSONDecoder().decode(ConversionOptions.self, from: Data(#"{"language": "ja", "envFile": "/e/env.txt"}"#.utf8))
        #expect(o.language == "ja")
        #expect(!ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o).contains("--env-file"))
    }

    @Test func xcodeProjectPaths() {
        #expect(ConversionCommand.xcodeProject(folder: folder, titleID: "0100ABCD00000000").path == "/Games/Super Game/0100ABCD00000000_build/xcode/DmIOS.xcodeproj")
        #expect(ConversionCommand.xcodeWorkspace(folder: folder).path == "/Games/NxNative.xcworkspace")
    }

    @Test func scriptSupport() {
        func flags(_ s: ScriptSupport) -> [Bool] { [s.macApp, s.jsonProgress] }
        #expect(flags(ScriptSupport(script: scriptOptionLines)) == [true, true])
        #expect(ScriptSupport(script: scriptOptionLines).missing == [])
        let oldest = "ap.add_argument('--platform', choices=('ios', 'mac'), help='')\nap.add_argument('--progress', choices=('auto', 'off'))\n"
        #expect(ScriptSupport(script: oldest).missing == ["--platform mac-app", "--progress json"])
        #expect(ScriptSupport(script: scriptOptionLines).missing(for: .xcodeProject) == [])
        let noXcode = scriptOptionLines.split(separator: "\n").filter { !$0.contains("--prepare-xcode") }.joined(separator: "\n")
        #expect(ScriptSupport(script: noXcode).missing(for: .macApp) == [])
        #expect(ScriptSupport(script: noXcode).missing(for: .xcodeProject) == ["--prepare-xcode"])
        // only the parser's lines count: an option named in a comment or a message is not declared
        #expect(flags(ScriptSupport(script: "# --platform: 'json' 'mac-app'\nsay('--progress json')\n")) == [false, false])
        #expect(ScriptSupport(repository: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test(.enabled(if: nxnativeCheckout != nil, "NXNATIVE_REPO names no nxnative checkout")) func checkoutSupportsTheApp() throws {
        let repository = try #require(nxnativeCheckout)
        let support = try #require(ScriptSupport(repository: repository))
        #expect(support.missing == [])
    }

    @Test func scriptPath() {
        #expect(ConversionCommand.script(in: URL(fileURLWithPath: "/repo")).path == "/repo/scripts/build_ipa_from_nsp.py")
    }

    @Test func logsFolder() {
        #expect(ConversionCommand.logsFolder(folder: folder, titleID: "0100ABCD00000000").path == "/Games/Super Game/0100ABCD00000000_build/logs")
    }

    @Test func languages() {
        #expect(ConversionCommand.languages.count == 16)
        #expect(ConversionCommand.languages.first?.code == "en-US" && ConversionCommand.languages.last?.code == "pt-BR")
        #expect(Set(ConversionCommand.languages.map(\.code)).count == 16)
        #expect(ConversionCommand.languages[2] == (code: "ja", name: "Japanese"))
    }

    @Test(.enabled(if: nxnativeCheckout != nil, "NXNATIVE_REPO names no nxnative checkout")) func languagesMatchNACP() throws {
        let text = try String(contentsOf: try #require(nxnativeCheckout).appendingPathComponent("dm/tools/nacp.py"), encoding: .utf8)
        for (code, name) in ConversionCommand.languages { #expect(text.contains("('\(code)', '\(name)')"), "\(code)") }
    }

    @Test func optionsDecodeOlderJSON() throws {
        let o = try JSONDecoder().decode(ConversionOptions.self, from: Data(#"{"language": "fr"}"#.utf8))
        var want = ConversionOptions(); want.language = "fr"
        #expect(o == want)
        #expect(o.surveyOnly == false)
        var all = ConversionOptions(); all.allowDamaged = true; all.appName = "X"; all.surveyOnly = true
        #expect(try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(all)) == all)
    }

    @Test func surveyOnly() {
        var o = ConversionOptions(); o.surveyOnly = true; o.language = "ja"
        #expect(ConversionCommand.arguments(script: script, folder: folder, keys: keys, options: o) == base + ["-l", "ja", "--survey-only"])
    }

    @Test func portPaths() {
        #expect(ConversionCommand.surveyFile(folder: folder, titleID: "0100ABCD00000000").path == "/Games/Super Game/0100ABCD00000000_survey/survey.md")
        #expect(ConversionCommand.provisionalProfile(folder: folder, titleID: "0100ABCD00000000").path
                == "/Games/Super Game/0100ABCD00000000_build/profile/0100ABCD00000000")
        #expect(ConversionCommand.workFolder(folder: folder, titleID: "0100ABCD00000000").path == "/Games/Super Game/0100ABCD00000000-work")
        #expect(ConversionCommand.extractFolder(folder: folder, titleID: "0100ABCD00000000").path == "/Games/Super Game/0100ABCD00000000_build/extract")
    }
}
