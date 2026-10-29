// Which nxnative built what: the converter's own record of every conversion (library.json in its Application Support folder), and the nxnative game apps found on disk,
// whose Info.plist names the game (DMTitleID) and the nxnative commit that packed them (DMCommit: dm/mac/pack_app.py's source_commit, a short hash with +dirty for
// uncommitted changes; DMNxnativeCommit, DMNxnativeCommitDate and DMNxnativeModified from an older converter's packer).
// A game prepared as an Xcode project has no app: its record names the project and the workspace it is a scheme of
import Foundation

public enum ConversionStatus: String, Sendable, Codable { case succeeded, failed, cancelled }

public struct ConversionRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var folder: String
    public var titleID: String?; public var gameName: String; public var gameVersion: String?; public var package: String?
    public var profile: String?; public var provisional: Bool; public var derived: Bool
    public var builtAppPath: String?; public var installedAppPath: String?
    public var xcodeProjectPath: String?; public var xcodeWorkspacePath: String?
    public var startedAt: Date; public var finishedAt: Date?
    public var status: ConversionStatus; public var message: String?
    public var nxnative: NXNativeVersion?
    public var options: ConversionOptions

    public init(id: UUID = UUID(), folder: String, titleID: String? = nil, gameName: String, gameVersion: String? = nil, package: String? = nil, profile: String? = nil,
                provisional: Bool = false, derived: Bool = false, builtAppPath: String? = nil, installedAppPath: String? = nil, xcodeProjectPath: String? = nil,
                xcodeWorkspacePath: String? = nil, startedAt: Date, finishedAt: Date? = nil, status: ConversionStatus, message: String? = nil, nxnative: NXNativeVersion? = nil,
                options: ConversionOptions = ConversionOptions()) {
        self.id = id; self.folder = folder; self.titleID = titleID; self.gameName = gameName; self.gameVersion = gameVersion; self.package = package; self.profile = profile
        self.provisional = provisional; self.derived = derived; self.builtAppPath = builtAppPath; self.installedAppPath = installedAppPath
        self.xcodeProjectPath = xcodeProjectPath; self.xcodeWorkspacePath = xcodeWorkspacePath; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.status = status; self.message = message; self.nxnative = nxnative; self.options = options
    }

    // A record written by another converter version still loads: only the folder is required, a status this version does not know reads as failed
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(String.self, forKey: .folder)
        id = c.lenient(UUID.self, .id) ?? UUID()
        titleID = c.lenient(String.self, .titleID); gameName = c.lenient(String.self, .gameName) ?? URL(fileURLWithPath: folder).lastPathComponent
        gameVersion = c.lenient(String.self, .gameVersion); package = c.lenient(String.self, .package); profile = c.lenient(String.self, .profile)
        provisional = c.lenient(Bool.self, .provisional) ?? false; derived = c.lenient(Bool.self, .derived) ?? false
        builtAppPath = c.lenient(String.self, .builtAppPath); installedAppPath = c.lenient(String.self, .installedAppPath)
        xcodeProjectPath = c.lenient(String.self, .xcodeProjectPath); xcodeWorkspacePath = c.lenient(String.self, .xcodeWorkspacePath)
        startedAt = c.lenient(Date.self, .startedAt) ?? Date(timeIntervalSince1970: 0); finishedAt = c.lenient(Date.self, .finishedAt)
        status = c.lenient(ConversionStatus.self, .status) ?? .failed; message = c.lenient(String.self, .message)
        nxnative = c.lenient(NXNativeVersion.self, .nxnative); options = c.lenient(ConversionOptions.self, .options) ?? ConversionOptions()
    }
}

/// What a store file held. A record that cannot be read is left out, and the file as it was is copied beside it first (preserved); a file that cannot be read at all
/// is moved there instead, so a save never writes over records this version could not read
public struct StoreContents<Record: Sendable>: Sendable {
    public var records: [Record]; public var skipped: Int; public var unreadable: Bool; public var preserved: URL?

    public var notice: String? {
        let kept = preserved.map { " The file as it was is kept at \($0.path)." } ?? ""
        if unreadable { return "The file could not be read, so a new one is started." + kept }
        return skipped == 0 ? nil : "\(skipped) record\(skipped == 1 ? "" : "s") could not be read and \(skipped == 1 ? "is" : "are") left out." + kept
    }
}

public enum StoreError: Error, LocalizedError, Equatable {
    case movedAside(file: String, to: String), unreadable(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .movedAside(file, to): return "\(file) could not be read. It was moved to \(to), and a new one is started."
        case let .unreadable(file, reason): return "\(file) could not be read, and it could not be moved aside to keep it (\(reason)); nothing is saved over it"
        }
    }
}

public struct LibraryStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        converterSupport.appendingPathComponent("library.json")
    }

    public func read() throws -> StoreContents<ConversionRecord> { try Self.read(ConversionRecord.self, from: fileURL) }

    /// The records that could be read; throws StoreError.movedAside when the whole file could not be (read() tells more)
    public func load() throws -> [ConversionRecord] { try Self.records(of: read(), file: fileURL) }

    public func save(_ records: [ConversionRecord]) throws { try Self.write(records, to: fileURL) }

    static func records<T>(of contents: StoreContents<T>, file: URL) throws -> [T] {
        if contents.unreadable, let to = contents.preserved { throw StoreError.movedAside(file: file.path, to: to.path) }
        return contents.records
    }

    static func read<T: Decodable & Sendable>(_ type: T.Type, from url: URL) throws -> StoreContents<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreContents(records: [], skipped: 0, unreadable: false, preserved: nil) }
        guard let data = try? Data(contentsOf: url), let items = try? decoder().decode([Lenient<T>].self, from: data) else {
            return StoreContents(records: [], skipped: 0, unreadable: true, preserved: try preserve(url, data: nil))
        }
        let records = items.compactMap(\.value)
        let skipped = items.count - records.count
        return StoreContents(records: records, skipped: skipped, unreadable: false, preserved: skipped == 0 ? nil : try? preserve(url, data: data))
    }

    /// Keeps a store file as <name>.unreadable-<date>: moved there when data is nil (the file could not be read), else a copy of data, made once for the same bytes
    static func preserve(_ url: URL, data: Data?) throws -> URL {
        let fm = FileManager.default, dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".unreadable-"
        if let data {
            let earlier = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
            if let same = earlier.first(where: { (try? Data(contentsOf: dir.appendingPathComponent($0))) == data }) { return dir.appendingPathComponent(same) }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = prefix + f.string(from: Date())
        var dest = dir.appendingPathComponent(stamp), n = 1
        while fm.fileExists(atPath: dest.path) { n += 1; dest = dir.appendingPathComponent("\(stamp)-\(n)") }
        do {
            if let data { try data.write(to: dest, options: .withoutOverwriting) } else { try fm.moveItem(at: url, to: dest) }
        } catch { throw StoreError.unreadable(file: url.path, reason: error.localizedDescription) }
        return dest
    }

    /// ISO 8601 dates, with or without fractional seconds
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = GitRepository.parseISODate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return d
    }

    /// Pretty JSON with sorted keys and ISO 8601 dates (milliseconds), written atomically into a folder made when missing. A file there that is not a JSON array
    /// (one a load never read) is moved aside first
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        let encoded = try e.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path), !((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } is [Any]) {
            _ = try preserve(url, data: nil)
        }
        try encoded.write(to: url, options: .atomic)
    }

    static var converterSupport: URL { applicationSupport.appendingPathComponent("nxnative Converter", isDirectory: true) }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

/// An element of a store's array: nil when it cannot be decoded, so one bad record does not lose the others
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The value, nil when it is missing or does not decode
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

public struct InstalledGameApp: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL; public var name: String; public var titleID: String; public var version: String?; public var bundleID: String?
    public var language: String?; public var nxnativeCommit: String?; public var nxnativeCommitDate: Date?; public var nxnativeModified: Bool?
    public var modified: Date?
}

extension InstalledGameApp {
    /// A game prepared as an Xcode project, as its record names it: the project in place of the app; nil for a record of anything else
    public init?(xcodeProjectOf record: ConversionRecord) {
        guard record.status == .succeeded, record.options.output == .xcodeProject, let project = record.xcodeProjectPath, let titleID = record.titleID else { return nil }
        let language = record.options.language
        self.init(url: URL(fileURLWithPath: project, isDirectory: true), name: record.options.appName.isEmpty ? record.gameName : record.options.appName, titleID: titleID,
                  version: record.gameVersion, bundleID: record.options.bundleID.isEmpty ? nil : record.options.bundleID, language: language.isEmpty ? nil : language,
                  nxnativeCommit: record.nxnative?.commit, nxnativeCommitDate: record.nxnative?.commitDate, nxnativeModified: record.nxnative?.modified,
                  modified: record.finishedAt)
    }
}

/// Copies of one game's Mac app: the same build installed under another name (a dash or a numeral in the name that changed between builds) or left in the
/// game folder. They share a bundle ID, so their settings and saves too; the Library shows one of them
public struct GameAppCopies: Sendable, Equatable {
    public var app: InstalledGameApp        // the newest, by its bundle's modification date
    public var others: [InstalledGameApp]   // newest first

    /// One group per bundle ID (the title ID when an app has none), in the order of their first app
    public static func group(_ apps: [InstalledGameApp]) -> [GameAppCopies] {
        var keys: [String] = [], groups: [String: [InstalledGameApp]] = [:]
        for app in apps {
            let key = (app.bundleID ?? app.titleID).lowercased()
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(app)
        }
        return keys.compactMap { key in
            let sorted = (groups[key] ?? []).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return sorted.first.map { GameAppCopies(app: $0, others: Array(sorted.dropFirst())) }
        }
    }
}

public enum InstalledAppScanner {
    static func read(app url: URL) -> InstalledGameApp? {
        let app = AppInstaller.realPath(url)
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), let info = plist as? [String: Any],
              let tid = info["DMTitleID"] as? String, !tid.isEmpty else { return nil }
        func string(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let date: Date? = (info["DMNxnativeCommitDate"] as? Date) ?? string("DMNxnativeCommitDate").flatMap(GitRepository.parseISODate)
        let stamped = string("DMCommit").map { stamp in (commit: String(stamp.prefix { $0 != "+" }), dirty: stamp.hasSuffix("+dirty")) }
        return InstalledGameApp(url: app, name: string("CFBundleDisplayName") ?? string("CFBundleName") ?? app.deletingPathExtension().lastPathComponent, titleID: tid,
                                version: string("CFBundleShortVersionString"), bundleID: string("CFBundleIdentifier"), language: string("DMLanguage"),
                                nxnativeCommit: stamped.flatMap { $0.commit.isEmpty ? nil : $0.commit } ?? string("DMNxnativeCommit"), nxnativeCommitDate: date,
                                nxnativeModified: stamped.map(\.dirty) ?? info["DMNxnativeModified"] as? Bool,
                                modified: try? app.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    public static func scan(directories: [URL]) -> [InstalledGameApp] {
        var out: [InstalledGameApp] = [], seen = Set<String>()
        func add(_ url: URL) {
            guard let app = read(app: url), seen.insert(app.url.path).inserted else { return }
            out.append(app)
        }
        for dir in directories {
            for item in children(of: dir) {
                if item.pathExtension == "app" { add(item); continue }
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                for sub in children(of: item) where sub.pathExtension == "app" { add(sub) }
            }
        }
        return out
    }

    public static func saveFolder(titleID: String) -> URL {
        LibraryStore.applicationSupport.appendingPathComponent("nxnative", isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    public static func logFile(titleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative", isDirectory: true).appendingPathComponent("\(titleID).log")
    }

    private static func children(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
