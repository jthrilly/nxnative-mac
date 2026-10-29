// Putting a finished app into the Applications folder (the AppleGamingWiki guide's last steps: copy it there, then `xattr -cr` it). The app is first put beside its destination
// as "<app>.partial": renamed there on the same volume (its game files stay APFS clones of the extracted ones), else copied, so a half-copied app never looks finished.
// Only then does the app it replaces go to the Trash, and only when it is an nxnative app of the same game (Info.plist DMTitleID); its saves are in
// ~/Library/Application Support/nxnative/<title ID>, which it does not touch. Any other app of that name is left as it is, and so is the new one.
// Older copies of the same game under other names (same title ID and bundle ID: an earlier build named "Game - Subtitle" or "Game 2") in the folders
// it is given go to the Trash too, once the new app is in place
import Darwin
import Foundation

public enum InstallMode: String, Sendable, Codable, CaseIterable { case move, copy, none }

public struct InstallOutcome: Sendable, Equatable {
    public var installedURL: URL; public var replaced: URL?; public var warnings: [String]
    public var oldCopies: [URL] = []   // older copies of the game under other names, now in the Trash (where they were)
}

public enum InstallError: Error, LocalizedError, Equatable {
    case sourceMissing(String), notWritable(String), insufficientSpace(needed: Int64, available: Int64), sameLocation(String), failed(String), foreignApp(String)

    public var errorDescription: String? {
        switch self {
        case let .sourceMissing(path): return "There is no app at \(path)"
        case let .notWritable(path): return "\(path) is not writable"
        case let .insufficientSpace(needed, available):
            return "Not enough free space: the app needs \(ProgressFormat.bytes(Double(needed))), \(ProgressFormat.bytes(Double(available))) are free"
        case let .sameLocation(path): return "The app is already at \(path)"
        case let .failed(message): return message
        case let .foreignApp(path): return "\(path) is already there and is not an nxnative app of this game, so it was left as it is"
        }
    }
}

public struct AppInstaller: Sendable {
    static let spaceMargin: Int64 = 1 << 30

    var trash: @Sendable (URL) throws -> URL?
    var clearAttributes: @Sendable (URL) async -> String?

    public init() {
        self.init(trash: { url in
            var out: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &out)
            return out?.absoluteURL
        }, clearAttributes: { url in
            do {
                let r = try await Subprocess.run("/usr/bin/xattr", ["-cr", url.path], environment: ProcessInfo.processInfo.environment, timeout: 300)
                return r.succeeded ? nil : "xattr -cr \(url.path) failed: " + (r.stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(r.status)")
            } catch { return "xattr -cr \(url.path) failed: \(error.localizedDescription)" }
        })
    }

    init(trash: @escaping @Sendable (URL) throws -> URL?, clearAttributes: @escaping @Sendable (URL) async -> String?) {
        self.trash = trash; self.clearAttributes = clearAttributes
    }

    /// `copiesIn`: the folders whose older copies of the game (other names, same title ID and bundle ID) go to the Trash once it is installed
    public func install(app: URL, into directory: URL, mode: InstallMode, copiesIn: [URL] = []) async throws -> InstallOutcome {
        let fm = FileManager.default
        let source = app.standardized
        guard fm.fileExists(atPath: source.path) else { throw InstallError.sourceMissing(source.path) }
        if mode == .none { return InstallOutcome(installedURL: source, replaced: nil, warnings: await clearAttributes(source).map { [$0] } ?? []) }

        let dir = directory.standardized
        let dest = dir.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        if Self.realPath(dest).path == Self.realPath(source).path { throw InstallError.sameLocation(dest.path) }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw InstallError.notWritable(dir.path) }
        guard fm.isWritableFile(atPath: dir.path) else { throw InstallError.notWritable(dir.path) }
        let sameVolume = Self.isSameVolume(source, dir)
        if !sameVolume {
            let needed = Self.allocatedSize(of: source) + Self.spaceMargin
            let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let available = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
            if let available, available < needed { throw InstallError.insufficientSpace(needed: needed, available: available) }
        }

        if Self.exists(dest) {
            let existing = InstalledAppScanner.read(app: dest)?.titleID, built = InstalledAppScanner.read(app: source)?.titleID
            guard let existing, existing == built else { throw InstallError.foreignApp(dest.path) }
        }

        let partial = dir.appendingPathComponent(source.lastPathComponent + ".partial", isDirectory: true)
        let rename = mode == .move && sameVolume
        if Self.exists(partial) { try? fm.removeItem(at: partial) }
        if rename {
            do { try fm.moveItem(at: source, to: partial) } catch { throw InstallError.failed("The app could not be moved to \(dir.path): \(error.localizedDescription)") }
        } else {
            do { try fm.copyItem(at: source, to: partial) } catch {
                try? fm.removeItem(at: partial)
                throw InstallError.failed("The app could not be copied to \(dir.path): \(error.localizedDescription)")
            }
        }
        // the new app back where it was built, or the partial copy removed
        func unstage() -> String {
            if !rename { try? fm.removeItem(at: partial); return "" }
            do { try fm.moveItem(at: partial, to: source); return "" } catch { return " The new app is at \(partial.path)." }
        }
        var replaced: URL?
        if Self.exists(dest) {
            do { replaced = try trash(dest) } catch {
                let left = unstage()
                throw InstallError.failed("The app already in \(dir.path) could not be moved to the Trash: \(error.localizedDescription).\(left)")
            }
        }
        do { try fm.moveItem(at: partial, to: dest) } catch {
            var restored = false
            if let replaced { restored = (try? fm.moveItem(at: replaced, to: dest)) != nil }
            let left = unstage()
            let previous = replaced.map { restored ? " The previous app is back in place." : " The previous app is in the Trash: \($0.path)." } ?? ""
            throw InstallError.failed("The app could not be renamed to \(dest.path): \(error.localizedDescription).\(previous)\(left)")
        }
        var warnings: [String] = []
        if mode == .move && !rename {
            do { try fm.removeItem(at: source) } catch { warnings.append("The original app could not be removed (\(source.path)): \(error.localizedDescription)") }
        }
        if let w = await clearAttributes(dest) { warnings.append(w) }
        var old: [URL] = []
        if let installed = InstalledAppScanner.read(app: dest) {
            let keep: Set<String> = [Self.realPath(dest).path, Self.realPath(source).path]
            for copy in InstalledAppScanner.scan(directories: copiesIn + [dir]) where Self.isOlderCopy(copy, of: installed) && !keep.contains(Self.realPath(copy.url).path) {
                do { _ = try trash(copy.url); old.append(copy.url) } catch {
                    warnings.append("An older copy could not be moved to the Trash (\(copy.url.path)): \(error.localizedDescription)")
                }
            }
        }
        return InstallOutcome(installedURL: dest, replaced: replaced, warnings: warnings, oldCopies: old)
    }

    /// Another app of the same game: the same title ID, and the same bundle ID when both have one (a build with its own bundle ID is kept)
    static func isOlderCopy(_ app: InstalledGameApp, of installed: InstalledGameApp) -> Bool {
        guard app.titleID.uppercased() == installed.titleID.uppercased() else { return false }
        guard let a = app.bundleID, let b = installed.bundleID else { return true }
        return a.lowercased() == b.lowercased()
    }

    /// Whether both are on one volume (a path that does not exist yet counts as its nearest existing folder's)
    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let da = device(a), let db = device(b) else { return false }
        return da == db
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func size(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total = size(url)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return total }
        while let u = e.nextObject() as? URL { total += size(u) }
        return total
    }

    public static func standardDestinations() -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// The path with every symbolic link resolved (realpath(3); URL.resolvingSymlinksInPath also turns /private/tmp into /tmp), else the path as it is
    static func realPath(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url.standardized }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: url.hasDirectoryPath)
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func device(_ url: URL) -> dev_t? {
        var p = url.standardized
        var st = stat()
        while stat(p.path, &st) != 0 {
            if p.path == "/" { return nil }
            p = p.deletingLastPathComponent()
        }
        return st.st_dev
    }
}
