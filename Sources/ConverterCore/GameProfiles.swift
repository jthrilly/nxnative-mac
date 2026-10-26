// The repository's game profiles (dm/games/<id>/game.tsv, read as dm/games/game.py reads them) and how a scanned folder matches one, as the NSP script decides it in main:
// the version asked for (-p), else the newest in the folder, is packed from the profile as it is when the profile registers that version and every version its shader tables
// were made from is there, else from a profile derived from it (nsp_versions, derive_profile)
import Foundation

public struct ProfileBuild: Sendable, Equatable { public var version: String; public var display: String }

public struct GameProfile: Sendable, Equatable, Identifiable {
    public var id: String; public var titleID: UInt64; public var name: String; public var builds: [ProfileBuild]
    public var package: String?; public var shaderVersions: [String]; public var directory: URL
}

public enum ProfileMatch: Sendable, Equatable {
    case tested(profile: GameProfile, display: String)
    case untestedVersion(profile: GameProfile, version: String, tested: [ProfileBuild])
    case noProfile
}

public enum GameProfiles {
    public static func load(repository: URL) -> [GameProfile] {
        let games = repository.appendingPathComponent("dm/games", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: games, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { dir in
            guard let text = try? String(contentsOf: dir.appendingPathComponent("game.tsv"), encoding: .utf8) else { return nil }
            return parse(gameTSV: text, directory: dir)
        }
    }

    public static func parse(gameTSV text: String, directory: URL) -> GameProfile? {
        var rows: [(key: String, values: [String])] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            rows.append((cells[0], Array(cells.dropFirst())))
        }
        func get(_ key: String) -> String? { rows.first { $0.key == key }.map { $0.values.joined(separator: "\t") } }
        guard let tid = get("title_id").flatMap(parseHex) else { return nil }
        let builds = rows.filter { $0.key == "build" && $0.values.count >= 2 }.map { ProfileBuild(version: $0.values[0], display: $0.values[1]) }
        return GameProfile(id: directory.lastPathComponent, titleID: tid, name: get("name") ?? "", builds: builds, package: get("package").flatMap { $0.isEmpty ? nil : $0 },
                           shaderVersions: (get("shader_versions") ?? "").split(whereSeparator: \.isWhitespace).map(String.init), directory: directory)
    }

    public static func match(_ scan: NSPFolderScan, in profiles: [GameProfile], package: String = "") -> ProfileMatch {
        guard let app = scan.applicationID, let profile = profiles.first(where: { $0.titleID == app }) else { return .noProfile }
        var have = Set(["v0"] + scan.updates.compactMap { $0.version.map { "v\($0)" } })
        // a single update without a [v<N>] tag is taken for the newest update the profile registers (its build IDs are checked once extracted)
        let registered = profile.builds.map(\.version).filter { $0 != "v0" }.sorted { versionNumber($0) < versionNumber($1) }
        if scan.updates.count == 1, scan.updates[0].version == nil, let newest = registered.last { have.insert(newest) }
        let asked = package.trimmingCharacters(in: .whitespaces)
        let package = asked.isEmpty ? (have.max(by: { versionNumber($0) < versionNumber($1) }) ?? "v0") : asked
        guard have.contains(package), let build = profile.builds.first(where: { $0.version == package }), profile.shaderVersions.allSatisfy(have.contains) else {
            return .untestedVersion(profile: profile, version: package, tested: profile.builds)
        }
        return .tested(profile: profile, display: build.display)
    }

    static func versionNumber(_ v: String) -> Int { Int(v.dropFirst()) ?? 0 }

    // Python's int(text, 16): an optional 0x prefix
    static func parseHex(_ text: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return UInt64(t.lowercased().hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16)
    }
}
