// A game app's settings as nxnative's front-end guidance describes them (docs/frontends.md): its launcher.json read with schema 1's compatibility rules, the saved
// choices kept only away from the tested defaults and checked as the Mac launcher checks them, env.txt lines that fix a setting, sub-settings, and one-start overrides
import Foundation
import Testing
@testable import ConverterCore

/// A store in memory, standing in for the game app's preferences domain
final class MemoryStore: ChoiceStore {
    var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(forKey key: String) -> Any? { values[key] }
    func set(_ value: String?, forKey key: String) { if let value { values[key] = value } else { values.removeValue(forKey: key) } }
}

struct GameSettingsTests {
    // docs/frontends.md's Breath of the Wild list, with a sub-setting, a render base, a section this app has never seen and a field from a later schema 1
    static let list = #"""
    {"schema": 1, "game": "01007EF00011E000", "settings": [
     {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "…", "default": "60",
      "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"},
     {"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05,
      "base": {"docked": [1600, 900], "handheld": [1280, 720]}, "level": "basic"},
     {"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "options": [["1", "Docked"], ["0", "Handheld"]],
      "level": "basic"},
     {"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames when late", "note": "…", "default": "on", "on": "on", "off": "off"},
     {"env": "DM_RUMBLE", "kind": "toggle", "section": "Controls", "label": "Game rumble", "note": "", "default": "1", "on": "1", "off": "0"},
     {"env": "DM_RUMBLE_GAIN", "kind": "range", "section": "Controls", "label": "Rumble strength", "note": "", "default": "1.0", "min": 0.25, "max": 1.0, "step": 0.25,
      "needs": "DM_RUMBLE=1"},
     {"env": "DM_HUD", "kind": "toggle", "section": "Overlay", "label": "HUD", "note": "", "default": "0", "needs": "DM_NOT_HERE=1", "future": {"x": 1}}
    ], "later": true}
    """#

    static func decoded() throws -> GameSettingsList {
        guard case .list(let list) = GameSettingsSource.decode(Data(list.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        return list
    }

    @Test func readsTheList() throws {
        let list = try Self.decoded()
        #expect(list.game == "01007EF00011E000")
        #expect(list.settings.map(\.env) == ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_FPS_HOLD", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_HUD"])
        #expect(list.sections == ["Game", "Performance", "Controls", "Overlay"])   // in the order of their first rows; an unknown one is drawn like the others
        let fps = list.settings[0], scale = list.settings[1], hold = list.settings[3], hud = list.settings[6]
        #expect(fps.kind == .choice && fps.options.map(\.label) == ["30 fps", "60 fps"] && fps.basic)
        #expect(scale.kind == .range && scale.min == 0.5 && scale.max == 1.0 && scale.step == 0.05 && scale.base?.docked == [1600, 900])
        #expect(hold.on == "on" && hold.off == "off" && !hold.basic)
        #expect(hud.on == "1" && hud.off == "0")   // a toggle without on and off takes 1 and 0
        #expect(list.settings[5].needsKey == "DM_RUMBLE" && list.settings[5].needsValue == "1")
    }

    @Test func compatibility() {
        #expect(GameSettingsSource.decode(Data(#"{"game": "0100", "settings": []}"#.utf8)) == .list(GameSettingsList(game: "0100", settings: [])))   // no schema: 1
        guard case .unsupported = GameSettingsSource.decode(Data(#"{"schema": 2, "game": "0100", "settings": []}"#.utf8)) else { Issue.record("schema 2 read"); return }
        let newKind = #"{"schema": 1, "game": "0100", "settings": [{"env": "DM_X", "kind": "color", "section": "Game", "label": "X", "note": "", "default": "red"}]}"#
        guard case .unsupported = GameSettingsSource.decode(Data(newKind.utf8)) else { Issue.record("an unknown kind drawn"); return }
        guard case .unsupported = GameSettingsSource.decode(Data("not json".utf8)) else { Issue.record("garbage read"); return }
        let t = try? TempDir()
        if let t {
            #expect(GameSettingsSource.load(app: t.url.appendingPathComponent("Old.app")) == .missing)   // no launcher.json: start it as it is
            t.remove()
        }
    }

    @Test func savedValuesAreChecked() throws {   // as launcher.c's saved_accepted: an option, a toggle value, a number in range; no hex, NaN or leading space
        let list = try Self.decoded()
        let fps = list.settings[0], scale = list.settings[1], hold = list.settings[3]
        #expect(fps.accepts("30") && !fps.accepts("45"))
        #expect(hold.accepts("off") && !hold.accepts("0"))
        #expect(scale.accepts("0.75") && scale.accepts("1") && !scale.accepts("0.4") && !scale.accepts("0x1p-1") && !scale.accepts("nan") && !scale.accepts(" 0.75"))
        #expect(scale.isDefault("1.00") && !scale.isDefault("0.95"))
    }

    @Test func formStartsFromSavedChoicesAndDefaults() throws {
        let store = MemoryStore(["launcher.DM_FPS_TARGET": "30", "launcher.DM_RENDER_SCALE": "0.2", "launcher.DM_RUMBLE": 1, "launcher.DM_GONE": "x"])
        let form = GameSettingsForm(list: try Self.decoded(), store: store)
        #expect(form.values["DM_FPS_TARGET"] == "30")
        #expect(form.values["DM_RENDER_SCALE"] == "1.0")   // a value this build no longer offers: its default
        #expect(form.values["DM_RUMBLE"] == "1")           // not a string: ignored
        #expect(form.saved == ["DM_FPS_TARGET": "30"])
        #expect(form.differsFromDefaults && !form.hasChanges && form.launchOverrides.isEmpty)
    }

    @Test func saveKeepsOnlyChoicesAwayFromTheDefaults() throws {
        let store = MemoryStore(["launcher.DM_FPS_TARGET": "30", "launcher.DM_GONE": "x"])
        var form = GameSettingsForm(list: try Self.decoded(), store: store)
        form.values["DM_FPS_TARGET"] = "60"          // back to the default: its key goes
        form.values["DM_RENDER_SCALE"] = "0.75"
        form.values["DM_FPS_HOLD"] = "off"
        form.save(to: store)
        #expect(store.values["launcher.DM_FPS_TARGET"] == nil)
        #expect(store.values["launcher.DM_RENDER_SCALE"] as? String == "0.75" && store.values["launcher.DM_FPS_HOLD"] as? String == "off")
        #expect(store.values["launcher.DM_GONE"] as? String == "x")   // a key no setting has is left alone
        #expect(store.values.count == 3)

        var again = GameSettingsForm(list: try Self.decoded(), store: store)
        again.reset()
        #expect(!again.differsFromDefaults && again.hasChanges)
        again.save(to: store)
        #expect(store.values.keys.sorted() == ["launcher.DM_GONE"])
    }

    @Test func envFilesFixSettings() throws {
        let store = MemoryStore(["launcher.DM_FPS_TARGET": "30"])
        var form = GameSettingsForm(list: try Self.decoded(), store: store, fixed: ["DM_FPS_TARGET": "60", "DM_OTHER": "1"])
        let fps = form.list.settings[0]
        #expect(form.isFixed(fps) && form.value(fps) == "60")
        form.reset()
        form.values["DM_RENDER_SCALE"] = "0.5"
        form.save(to: store)
        #expect(store.values["launcher.DM_FPS_TARGET"] as? String == "30")   // a fixed setting keeps its saved choice
        #expect(form.launchOverrides == ["DM_RENDER_SCALE": "0.5"])
    }

    @Test func subSettingsAndSections() throws {
        var form = GameSettingsForm(list: try Self.decoded(), store: MemoryStore())
        #expect(form.sections(basic: true).map(\.title) == ["Game"])
        #expect(form.sections(basic: false).map(\.title) == ["Performance", "Controls", "Overlay"])
        #expect(form.sections(basic: false)[1].rows.map(\.env) == ["DM_RUMBLE", "DM_RUMBLE_GAIN"])
        form.values["DM_RUMBLE"] = "0"
        #expect(form.sections(basic: false)[1].rows.map(\.env) == ["DM_RUMBLE"])   // rumble strength only while rumble is on
        #expect(form.isVisible(form.list.settings[6]))   // needs a variable the list does not have: stays drawn
    }

    @Test func renderScaleLabel() throws {
        var form = GameSettingsForm(list: try Self.decoded(), store: MemoryStore())
        let scale = form.list.settings[1]
        #expect(form.rangeLabel(scale, 0.75) == "1200 × 675 (75 %)")
        form.values["DM_OPMODE"] = "0"
        #expect(form.rangeLabel(scale, 0.75) == "960 × 540 (75 %)")
        #expect(form.rangeLabel(form.list.settings[5], 0.5) == "50 %")
    }

    @Test func playOnceOverridesOnlyWhatDiffers() throws {
        let store = MemoryStore(["launcher.DM_FPS_TARGET": "30"])
        var form = GameSettingsForm(list: try Self.decoded(), store: store)
        form.values["DM_RENDER_SCALE"] = "1.00"   // the same number as the default
        form.values["DM_FPS_TARGET"] = "60"       // the default, but not what the app starts with
        #expect(form.launchOverrides == ["DM_FPS_TARGET": "60"])
        #expect(GameLaunch.environment(overrides: form.launchOverrides) == ["DM_FPS_TARGET": "60", "DM_LAUNCHER": "0"])
        #expect(GameLaunch.environment(overrides: ["DM_LAUNCHER": "1"]) == ["DM_LAUNCHER": "0"])
        #expect(store.values.count == 1)   // nothing kept
    }

    @Test func preferencesDomain() {
        #expect(GameLaunch.preferencesDomain(bundleID: "com.example.zelda", titleID: "01007EF00011E000") == "com.example.zelda")
        #expect(GameLaunch.preferencesDomain(bundleID: nil, titleID: "01007EF00011E000") == "org.nxnative.01007EF00011E000")
        #expect(GameLaunch.preferencesDomain(bundleID: "", titleID: "01007EF00011E000") == "org.nxnative.01007EF00011E000")
    }

    @Test func envFileLines() {
        let parsed = EnvFile.parse("# comment\n  DM_FPS_TARGET = 30\nDM_X=a=b\r\n=nokey\nnoequals\n\tDM_EMPTY=\n")
        #expect(parsed.map(\.key) == ["DM_FPS_TARGET", "DM_X", "DM_EMPTY"])
        #expect(parsed.map(\.value) == [" 30", "a=b", ""])
    }

    @Test func envFilesInTheAppAndTheGameFolder() throws {
        let t = try TempDir()
        defer { t.remove() }
        let app = try t.sub("Game.app")
        try t.file("Game.app/Contents/Resources/dm/env.txt", Data("DM_FPS_TARGET=30\nDM_RUMBLE=0\n".utf8))
        let fixed = EnvFile.fixedValues(app: app, titleID: "FFFFFFFFFFFFFFF0")   // a title ID no game has: no player env.txt
        #expect(fixed == ["DM_FPS_TARGET": "30", "DM_RUMBLE": "0"])
    }

    /// The app reads every field and kind nxnative's schema has: a new kind or field there is a change this app has to follow
    @Test(.enabled(if: nxnativeCheckout != nil, "NXNATIVE_REPO names no nxnative checkout")) func schemaMatchesNXNative() throws {
        let url = try #require(nxnativeCheckout).appendingPathComponent("docs/launcher.schema.json")
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(((properties["schema"] as? [String: Any])?["const"] as? Int) == GameSettingsList.schema)
        let setting = try #require(((schema["$defs"] as? [String: Any])?["setting"] as? [String: Any])?["properties"] as? [String: Any])
        let kinds = try #require((setting["kind"] as? [String: Any])?["enum"] as? [String])
        #expect(Set(kinds) == Set(["choice", "range", "toggle"]))
        let known: Set = ["env", "kind", "section", "label", "note", "default", "options", "min", "max", "step", "on", "off", "base", "level", "needs"]
        #expect(Set(setting.keys).subtracting(known).isEmpty, "fields this app does not read: \(Set(setting.keys).subtracting(known).sorted())")
    }

    // docs/frontends.md, The cloud saves folder: cloudSaves.folder in the same domain, no key or an empty string is off
    @Test func cloudSavesFolder() {
        let store = MemoryStore()
        #expect(CloudSaves.folder(in: store) == "")
        CloudSaves.setFolder("/Users/j/Library/Mobile Documents/com~apple~CloudDocs/Saves", in: store)
        #expect(store.values["cloudSaves.folder"] as? String == "/Users/j/Library/Mobile Documents/com~apple~CloudDocs/Saves")
        CloudSaves.setFolder("", in: store)
        #expect(store.values["cloudSaves.folder"] == nil)
        let drive = "/Users/j/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(CloudSaves.shown(drive + "/Documents/Saves", drive: drive) == "iCloud Drive › Documents › Saves")
        #expect(CloudSaves.shown("/Volumes/Saves", drive: drive) == "/Volumes/Saves")
        #expect(CloudSaves.shown("icloud", drive: drive) == "iCloud Drive › nxnative Saves")
        #expect(CloudSaves.shown("", drive: drive) == "Off")
        #expect(CloudSaves.launchOverride(shown: "/a", kept: "/a") == [:])
        #expect(CloudSaves.launchOverride(shown: "/b", kept: "/a") == ["DM_SAVE_SYNC": "/b"])
        #expect(CloudSaves.launchOverride(shown: "", kept: "/a") == ["DM_SAVE_SYNC": "0"])
    }

    @Test func cloudSavesNeedALauncherThatReadsTheKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, launcher: String) throws -> URL {
            let app = root.appendingPathComponent("\(name).app"), macos = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleExecutable": "launcher", "CFBundleIdentifier": "org.nxnative.\(name)", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data(launcher.utf8).write(to: macos.appendingPathComponent("launcher"))
            return app
        }
        #expect(CloudSaves.isSupported(app: try app("New", launcher: "\u{0}launcher.DM_FPS_TARGET\u{0}cloudSaves.folder\u{0}")))
        #expect(!CloudSaves.isSupported(app: try app("Old", launcher: "\u{0}launcher.DM_FPS_TARGET\u{0}")))
    }
}
