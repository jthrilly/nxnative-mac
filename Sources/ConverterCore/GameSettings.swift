// A game app's settings as nxnative's front-end guidance has them (docs/frontends.md): the list the app carries (Contents/Resources/dm/launcher.json, schema 1,
// docs/launcher.schema.json), the player's saved choices in the app's own preferences domain (launcher.<VAR>, kept only when they differ from the tested
// default) and the env.txt lines that win over them. The rules are those of nxnative's own settings screens (dm/ios/Sources/LauncherSettings.swift) and of
// the Mac launcher's check of a saved value (dm/mac/launcher.c saved_accepted), so the app, the game's own window and a start from Finder agree
import CoreFoundation
import Foundation

public enum SettingKind: String, Sendable, Equatable { case choice, range, toggle }

public struct GameSetting: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable, Hashable { public var value: String; public var label: String }
    /// The render scale's 3D views at 1.0, [width, height] docked and handheld
    public struct Base: Sendable, Equatable { public var docked: [Int]; public var handheld: [Int] }

    public var env: String
    public var kind: SettingKind
    public var section: String
    public var label: String
    public var note: String
    public var defaultValue: String
    public var options: [Option] = []                  // choice
    public var min: Double?, max: Double?, step: Double?   // range
    public var on = "1", off = "0"                     // toggle: the values the variable takes
    public var base: Base?
    public var basic = false                           // level basic: shown first
    public var needsKey: String?, needsValue: String?  // needs <VAR>=<value>: a sub-setting, drawn only while <VAR> has that value
    public var id: String { env }

    /// A range compares as numbers (a slider gives 1.00 for 1.0)
    public func isDefault(_ value: String) -> Bool {
        kind == .range ? Self.sameNumber(value, defaultValue) : value == defaultValue
    }

    /// A value this build still offers: one of a choice's options, a toggle's on or off, a number from a range's min to max. No leading space, hex or NaN,
    /// as the launcher checks it
    public func accepts(_ value: String) -> Bool {
        switch kind {
        case .choice: return options.contains { $0.value == value }
        case .toggle: return value == on || value == off
        case .range:
            guard let lo = min, let hi = max, !value.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(value), n.isFinite else { return false }
            return n >= lo && n <= hi
        }
    }

    static func sameNumber(_ a: String, _ b: String) -> Bool {
        guard let x = Double(a), let y = Double(b) else { return a == b }
        return abs(x - y) < 1e-6
    }
}

public struct GameSettingsList: Sendable, Equatable {
    public static let schema = 1
    public var game: String
    public var settings: [GameSetting]

    public init(game: String, settings: [GameSetting]) { self.game = game; self.settings = settings }

    /// The sections in the order of their first rows
    public var sections: [String] { settings.reduce(into: []) { if !$0.contains($1.section) { $0.append($1.section) } } }
    public var hasBasic: Bool { settings.contains(where: \.basic) }
}

/// What an app says about its settings
public enum GameSettingsSource: Sendable, Equatable {
    case missing                     // no launcher.json: the app has no settings to offer, and is started as it is
    case list(GameSettingsList)
    case unsupported(String)         // a newer schema or a kind this app cannot draw, or a file it cannot read: why

    public static func file(app: URL) -> URL { app.appendingPathComponent("Contents/Resources/dm/launcher.json") }

    public static func load(app: URL) -> GameSettingsSource {
        let url = file(app: app)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unsupported("\(url.path) could not be read.") }
        return decode(data)
    }

    /// Schema 1 grows only by optional fields: a field this app does not know is ignored, a section it does not know is drawn like the others. A list without
    /// "schema" is 1; a higher schema, or a kind other than choice, range and toggle, needs a newer app
    public static func decode(_ data: Data) -> GameSettingsSource {
        guard let object = try? JSONSerialization.jsonObject(with: data), let o = object as? [String: Any], let rows = o["settings"] as? [Any] else {
            return .unsupported("The game's settings list (launcher.json) is not one this app can read.")
        }
        if let schema = o["schema"] as? NSNumber, schema.intValue != GameSettingsList.schema {
            return .unsupported("The game's settings list is schema \(schema.intValue), and this app reads schema \(GameSettingsList.schema). Update nxnative Converter.")
        }
        var settings: [GameSetting] = []
        for case let row as [String: Any] in rows {
            func string(_ key: String) -> String? { row[key] as? String }
            func number(_ key: String) -> Double? { (row[key] as? NSNumber).map(\.doubleValue) }
            guard let env = string("env"), !env.isEmpty, let kindName = string("kind"), let label = string("label"), let def = string("default") else { continue }
            guard let kind = SettingKind(rawValue: kindName) else {
                return .unsupported("The game's settings list has a kind of setting this app cannot draw (\(kindName)). Update nxnative Converter.")
            }
            var s = GameSetting(env: env, kind: kind, section: string("section") ?? "Game", label: label, note: string("note") ?? "", defaultValue: def)
            switch kind {
            case .choice:
                s.options = (row["options"] as? [Any] ?? []).compactMap { pair in
                    guard let p = pair as? [Any], p.count == 2, let v = p[0] as? String, let l = p[1] as? String else { return nil }
                    return GameSetting.Option(value: v, label: l)
                }
                guard !s.options.isEmpty else { continue }
            case .range:
                s.min = number("min"); s.max = number("max"); s.step = number("step")
                guard let lo = s.min, let hi = s.max, lo <= hi else { continue }
            case .toggle:
                s.on = string("on") ?? "1"; s.off = string("off") ?? "0"
            }
            if let b = row["base"] as? [String: Any], let d = b["docked"] as? [NSNumber], let h = b["handheld"] as? [NSNumber], d.count == 2, h.count == 2 {
                s.base = GameSetting.Base(docked: d.map(\.intValue), handheld: h.map(\.intValue))
            }
            s.basic = string("level") == "basic"
            if let needs = string("needs"), let eq = needs.firstIndex(of: "="), eq != needs.startIndex {
                s.needsKey = String(needs[..<eq]); s.needsValue = String(needs[needs.index(after: eq)...])
            }
            settings.append(s)
        }
        return .list(GameSettingsList(game: o["game"] as? String ?? "", settings: settings))
    }
}

/// Where the player's saved choices live: one string per setting, launcher.<VAR>, in the game app's preferences domain
public protocol ChoiceStore {
    func value(forKey key: String) -> Any?
    /// nil removes the key
    func set(_ value: String?, forKey key: String)
}

/// The game app's own preferences domain (its bundle ID), which its launcher and settings window read and write. This app is outside the App Sandbox, as a front
/// end that writes another app's domain has to be
public struct AppPreferencesStore: ChoiceStore {
    public let domain: String

    public init(domain: String) { self.domain = domain }

    public func value(forKey key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain as CFString) }

    public func set(_ value: String?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value.map { $0 as CFString }, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// The variables an env.txt sets: KEY=VALUE lines, # starts a comment, as the launcher reads them. The first file that sets a variable wins
public enum EnvFile {
    private static let blanks = CharacterSet(charactersIn: " \t\r")

    public static func parse(_ text: String) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: Self.blanks)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = line[..<eq].trimmingCharacters(in: Self.blanks)
            guard !key.isEmpty else { continue }
            out.append((key, String(line[line.index(after: eq)...])))
        }
        return out
    }

    /// The variables the player's env.txt (~/Library/Application Support/nxnative/<title ID>/env.txt), then the bundle's dm/env.txt, set: a setting either
    /// sets is fixed, and the game's own window shows it greyed out too
    public static func fixedValues(app: URL, titleID: String) -> [String: String] {
        let files = [InstalledAppScanner.saveFolder(titleID: titleID).appendingPathComponent("env.txt"), app.appendingPathComponent("Contents/Resources/dm/env.txt")]
        var values: [String: String] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (key, value) in parse(text) where values[key] == nil { values[key] = value }
        }
        return values
    }
}

public struct GameSettingsSection: Sendable, Equatable, Identifiable {
    public var title: String
    public var rows: [GameSetting]
    public var id: String { title }
}

/// The settings a front end draws for one game app, from its list, its saved choices and its env.txt files
public struct GameSettingsForm: Sendable, Equatable {
    public let list: GameSettingsList
    public let fixed: [String: String]     // set by an env.txt: shown, not changed
    public let saved: [String: String]     // the saved choices this build still offers, when the form was made
    public var values: [String: String]

    public init(list: GameSettingsList, store: some ChoiceStore, fixed: [String: String] = [:]) {
        self.list = list
        self.fixed = fixed
        var saved: [String: String] = [:]
        for s in list.settings {
            // A string, as the launcher reads it; a value that is not one, or that this build no longer offers, falls back to the default
            if let v = store.value(forKey: Self.key(s.env)) as? String, s.accepts(v) { saved[s.env] = v }
        }
        self.saved = saved
        var values: [String: String] = [:]
        for s in list.settings { values[s.env] = fixed[s.env] ?? saved[s.env] ?? s.defaultValue }
        self.values = values
    }

    public static func key(_ env: String) -> String { "launcher." + env }

    public func value(_ s: GameSetting) -> String { values[s.env] ?? s.defaultValue }
    public func isFixed(_ s: GameSetting) -> Bool { fixed[s.env] != nil }

    /// A row with needs is drawn only while the row it names has that value; one naming a variable the list does not have stays drawn
    public func isVisible(_ s: GameSetting) -> Bool {
        guard let key = s.needsKey, let want = s.needsValue, let v = values[key] else { return true }
        return v == want
    }

    /// The sections of the basic rows, or of the others, in the list's order, with only the rows drawn now
    public func sections(basic: Bool) -> [GameSettingsSection] {
        list.sections.compactMap { title in
            let rows = list.settings.filter { $0.section == title && $0.basic == basic && isVisible($0) }
            return rows.isEmpty ? nil : GameSettingsSection(title: title, rows: rows)
        }
    }

    /// A range's label: its percentage, with the 3D views' size for the chosen console mode when the list has it (the render scale)
    public func rangeLabel(_ s: GameSetting, _ v: Double) -> String {
        let percent = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return percent }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return percent }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(percent))"
    }

    /// Any setting the player can change is away from its tested default
    public var differsFromDefaults: Bool { list.settings.contains { !isFixed($0) && !$0.isDefault(value($0)) } }

    /// The values differ from what the app would start with now
    public var hasChanges: Bool { list.settings.contains { !isFixed($0) && !GameSetting.sameValue(value($0), effective($0), $0) } }

    /// What the app starts with when nothing overrides it: the saved choice, else the tested default
    public func effective(_ s: GameSetting) -> String { saved[s.env] ?? s.defaultValue }

    /// Every setting the player can change back to its tested default; Save then removes their keys
    public mutating func reset() { for s in list.settings where !isFixed(s) { values[s.env] = s.defaultValue } }

    /// Keeps the choices: a value at its tested default removes its key, so that setting follows a later build's defaults; any other is stored as a string.
    /// A setting an env.txt fixes keeps its saved choice as it is
    public func save(to store: some ChoiceStore) {
        for s in list.settings where !isFixed(s) {
            let v = value(s)
            store.set(s.isDefault(v) ? nil : v, forKey: Self.key(s.env))
        }
    }

    /// For one start only: the values that differ from what the app would use, as launch environment variables. They win over the env.txt files and the saved
    /// choices for that start, and change nothing that is kept
    public var launchOverrides: [String: String] {
        var env: [String: String] = [:]
        for s in list.settings where !isFixed(s) && !GameSetting.sameValue(value(s), effective(s), s) { env[s.env] = value(s) }
        return env
    }
}

extension GameSetting {
    static func sameValue(_ a: String, _ b: String, _ s: GameSetting) -> Bool { s.kind == .range ? sameNumber(a, b) : a == b }
}

/// Starting a game app as a front end that draws the settings itself: DM_LAUNCHER=0 skips the app's own settings window, and the saved choices still apply
public enum GameLaunch {
    public static func environment(overrides: [String: String]) -> [String: String] {
        overrides.merging(["DM_LAUNCHER": "0"]) { _, launcher in launcher }
    }

    /// The domain of the app's saved choices: its bundle ID, org.nxnative.<title ID> unless it was packed with another
    public static func preferencesDomain(bundleID: String?, titleID: String) -> String {
        bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "org.nxnative.\(titleID)"
    }
}

/// The folder a Mac game app's save is synced through (nxnative's docs/frontends.md, The cloud saves folder). It is no row of the settings list: it is
/// cloudSaves.folder in the same preferences domain, an absolute path, which the app's launcher reads at every start and passes to the host as DM_SAVE_SYNC.
/// No key, or an empty string, is off. A DM_SAVE_SYNC in the launch environment, then an env.txt, wins over it
public enum CloudSaves {
    public static let key = "cloudSaves.folder"
    public static let variable = "DM_SAVE_SYNC"

    public static func folder(in store: some ChoiceStore) -> String { (store.value(forKey: key) as? String) ?? "" }

    public static func setFolder(_ folder: String, in store: some ChoiceStore) { store.set(folder.isEmpty ? nil : folder, forKey: key) }

    /// iCloud Drive, as the Finder shows it
    public static var iCloudDrive: String { NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs" }

    /// A folder as the Finder and the Files app name it (iCloud Drive › Documents › Saves), and DM_SAVE_SYNC's own values: icloud, 0
    public static func shown(_ path: String, drive: String = iCloudDrive) -> String {
        switch path {
        case "": return "Off"
        case "0": return "Off"
        case "icloud": return "iCloud Drive › nxnative Saves"
        default:
            guard path == drive || path.hasPrefix(drive + "/") else { return path }
            return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
        }
    }

    /// The app's launcher reads the key: apps from an nxnative before cloud saves (PR #617) ignore it
    public static func isSupported(app: URL) -> Bool {
        guard let exe = Bundle(url: app)?.executableURL, let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { return false }
        return data.range(of: Data(key.utf8)) != nil
    }

    /// For one start only: DM_SAVE_SYNC when the folder shown differs from the kept one (0 turns it off for that start)
    public static func launchOverride(shown: String, kept: String) -> [String: String] {
        shown == kept ? [:] : [variable: shown.isEmpty ? "0" : shown]
    }
}
