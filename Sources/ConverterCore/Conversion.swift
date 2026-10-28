// The NSP script's command line for a Mac app (scripts/build_ipa_from_nsp.py --platform mac-app --progress json; its arguments win over the Settings block at the
// script's top) or an iPhone and iPad Xcode project (--platform ios --prepare-xcode), and where its output goes. nxnative's
// front-end guidance (docs/frontends.md, Building) promises the JSON events and the exit status, not the wording of its messages, so the app names the Mac app's
// path itself (-o) instead of reading it from a message
import Foundation

/// What a conversion makes: a Mac app, installed like any other, or an Xcode project for iPhone and iPad that Xcode signs and installs on a device
public enum ConversionOutput: String, Sendable, Codable, CaseIterable {
    case macApp, xcodeProject
}

public struct ConversionOptions: Sendable, Equatable, Codable {
    public var language: String = ""
    public var package: String = ""
    public var appName: String = ""
    public var bundleID: String = ""
    public var allowDamaged: Bool = false
    public var signingIdentity: String = ""
    public var surveyOnly: Bool = false
    public var output: ConversionOutput = .macApp

    public init() {}

    // A library written before an option existed still loads
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.lenient(String.self, .language) ?? ""
        package = c.lenient(String.self, .package) ?? ""
        appName = c.lenient(String.self, .appName) ?? ""
        bundleID = c.lenient(String.self, .bundleID) ?? ""
        allowDamaged = c.lenient(Bool.self, .allowDamaged) ?? false
        signingIdentity = c.lenient(String.self, .signingIdentity) ?? ""
        surveyOnly = c.lenient(Bool.self, .surveyOnly) ?? false
        output = c.lenient(ConversionOutput.self, .output) ?? .macApp
    }
}

/// What a checkout's NSP script supports of the options the app runs it with, read from its argument parser's lines. An older nxnative has no Mac app or
/// JSON progress, which a conversion cannot do without, or no --prepare-xcode, which an Xcode project needs
public struct ScriptSupport: Sendable {
    public var macApp: Bool
    public var jsonProgress: Bool
    public var xcodeProject: Bool

    public init(script: String) {
        let declared = script.split(separator: "\n").filter { $0.contains("add_argument(") }
        func has(_ flag: String, choice: String? = nil) -> Bool {
            declared.contains { line in line.contains("'\(flag)'") && (choice.map { line.contains("'\($0)'") } ?? true) }
        }
        macApp = has("--platform", choice: "mac-app")
        jsonProgress = has("--progress", choice: "json")
        xcodeProject = has("--prepare-xcode")
    }

    /// nil when the repository has no script it can read
    public init?(repository: URL) {
        guard let text = try? String(contentsOf: ConversionCommand.script(in: repository), encoding: .utf8) else { return nil }
        self.init(script: text)
    }

    /// The options a conversion cannot do without that the script lacks
    public var missing: [String] { [("--platform mac-app", macApp), ("--progress json", jsonProgress)].filter { !$0.1 }.map(\.0) }

    /// The same for a conversion that makes `output`: an Xcode project also needs --prepare-xcode
    public func missing(for output: ConversionOutput) -> [String] {
        missing + (output == .xcodeProject && !xcodeProject ? ["--prepare-xcode"] : [])
    }
}

public enum ConversionCommand {
    /// `teamID` is the Apple developer team an Xcode project is signed by (Settings); empty leaves it to the script (the team chosen in Xcode, else a placeholder)
    /// `app` is where a Mac app goes (appOutput); an Xcode project goes where --prepare-xcode puts it
    public static func arguments(script: URL, folder: URL, keys: URL, options: ConversionOptions, teamID: String = "", app: URL? = nil) -> [String] {
        let platform = options.output == .xcodeProject ? ["--platform", "ios", "--prepare-xcode"] : ["--platform", "mac-app"]
        var args = ["-u", script.path, folder.path, "-k", keys.path] + platform + ["--progress", "json"]
        if options.output == .macApp, let app { args += ["-o", app.path] }
        for (flag, value) in [("-l", options.language), ("-p", options.package), ("--app-name", options.appName), ("--bundle-id", options.bundleID)] where !value.isEmpty {
            args += [flag, value]
        }
        if options.allowDamaged { args.append("--allow-damaged") }
        switch options.output {
        case .macApp: if !options.signingIdentity.isEmpty { args += ["--mac-sign", options.signingIdentity] }
        case .xcodeProject: if !teamID.isEmpty { args += ["--team-id", teamID] }
        }
        if options.surveyOnly { args.append("--survey-only") }
        return args
    }

    public static func script(in repository: URL) -> URL { repository.appendingPathComponent("scripts/build_ipa_from_nsp.py") }

    /// Where a Mac app is made: <name>.app in the game folder, named as the script names it when -o is not given (mac_app_name: the characters Finder shows
    /// otherwise, ':' and '/', become ' - ')
    public static func appOutput(folder: URL, name: String) -> URL {
        folder.appendingPathComponent(macAppName(name) + ".app", isDirectory: true)
    }

    static func macAppName(_ name: String) -> String {
        let separated = name.replacingOccurrences(of: #"\s*[:/]\s*"#, with: " - ", options: .regularExpression)
        let trimmed = separated.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return trimmed.isEmpty ? "nxnative" : trimmed
    }

    /// The game's Xcode project, which --prepare-xcode generates in its build folder
    public static func xcodeProject(folder: URL, titleID: String) -> URL {
        folder.appendingPathComponent("\(titleID)_build", isDirectory: true).appendingPathComponent("xcode", isDirectory: true)
            .appendingPathComponent("DmIOS.xcodeproj", isDirectory: true)
    }

    /// The workspace --prepare-xcode adds each game's project to (a scheme per game): NxNative.xcworkspace beside the game folder
    public static func xcodeWorkspace(folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent("NxNative.xcworkspace", isDirectory: true)
    }

    public static func logsFolder(folder: URL, titleID: String) -> URL {
        folder.appendingPathComponent("\(titleID)_build", isDirectory: true).appendingPathComponent("logs", isDirectory: true)
    }

    /// Where the script extracts a game's files: v<N>/icon.jpg is the game's own icon, for each version it extracted
    public static func extractFolder(folder: URL, titleID: String) -> URL {
        folder.appendingPathComponent("\(titleID)_build", isDirectory: true).appendingPathComponent("extract", isDirectory: true)
    }

    /// The report of a game with no profile, written before anything else (and all a --survey-only run writes)
    public static func surveyFile(folder: URL, titleID: String) -> URL {
        folder.appendingPathComponent("\(titleID)_survey", isDirectory: true).appendingPathComponent("survey.md")
    }

    /// The folder of the provisional profile guessed from the survey (its game.tsv), outside the repository
    public static func provisionalProfile(folder: URL, titleID: String) -> URL {
        folder.appendingPathComponent("\(titleID)_build", isDirectory: true).appendingPathComponent("profile", isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    /// Where AGENTS.md has extraction, runs and analysis of a game done: beside the NSP script's build folder
    static func workFolder(folder: URL, titleID: String) -> URL { folder.appendingPathComponent("\(titleID)-work", isDirectory: true) }

    // dm/tools/nacp.py LANGUAGES: the order of the control data's languages
    public static let languages: [(code: String, name: String)] = [
        ("en-US", "American English"), ("en-GB", "British English"), ("ja", "Japanese"), ("fr", "French"), ("de", "German"), ("es-419", "Latin American Spanish"),
        ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"), ("fr-CA", "Canadian French"), ("pt", "Portuguese"), ("ru", "Russian"), ("ko", "Korean"),
        ("zh-Hant", "Traditional Chinese"), ("zh-Hans", "Simplified Chinese"), ("pt-BR", "Brazilian Portuguese"),
    ]
}
