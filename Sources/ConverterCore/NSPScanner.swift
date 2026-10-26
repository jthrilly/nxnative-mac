// What a dropped folder holds: its game files grouped as the NSP script groups them (scripts/build_ipa_from_nsp.py scan_nsps, title_of, version_of), so a folder the script
// would refuse is shown as such before a conversion starts. The title ID comes from the ticket inside a PFS0 (NSP / NSZ), else from a "[0100…]" tag in the file name
import Foundation

public enum NSPKind: String, Sendable, Codable { case base, update, dlc, unknown }

public struct NSPFile: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL; public var titleID: UInt64?; public var version: Int?; public var kind: NSPKind; public var size: Int64; public var compressed: Bool
}

public struct NSPFolderScan: Sendable, Equatable {
    public var folder: URL
    public var files: [NSPFile]
    public var applicationID: UInt64?
    public var base: NSPFile?
    public var updates: [NSPFile]
    public var dlc: [NSPFile]
    public var errors: [String]
    public var warnings: [String]

    public var isConvertible: Bool { errors.isEmpty && base != nil }
    public var versions: [Int] { Array(Set([0] + updates.compactMap(\.version))).sorted() }
    public var newestVersion: Int { versions.last ?? 0 }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var titleIDString: String? { applicationID.map(NSPScanner.hex16) }

    public var displayName: String {
        guard let base else { return folder.lastPathComponent }
        var name = "", depth = 0, closer: Character = " "
        for c in base.url.deletingPathExtension().lastPathComponent {
            if depth > 0 {
                if c == closer { depth -= 1 }
            } else if c == "[" || c == "(" {
                depth = 1; closer = c == "[" ? "]" : ")"
            } else { name.append(c) }
        }
        let clean = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? folder.lastPathComponent : clean
    }
}

public enum NSPScanner {
    static let fileExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]
    static let compressed = ["nsz": "nsp", "xcz": "xci"]   // nsz's compressed NSP / XCI and what nsz -D makes of them
    static let headerLimit = 8 << 20

    public static func scan(folder: URL) -> NSPFolderScan {
        let folder = folder.standardized
        var warnings: [String] = [], files: [NSPFile] = [], unknown: [Int] = []
        var families: [(app: UInt64, base: Int?, updates: [Int], dlc: [Int])] = []
        for url in gameFiles(in: folder) {
            let size = fileSize(url), ext = url.pathExtension
            if size == 0 { warnings.append("skipping an empty file: \(url.lastPathComponent)"); continue }
            if let plain = compressed[ext], isRegularFile(url.deletingPathExtension().appendingPathExtension(plain)) {
                warnings.append("skipping \(url.lastPathComponent): \(url.deletingPathExtension().appendingPathExtension(plain).lastPathComponent) is beside it"); continue
            }
            let tid = titleID(of: url), index = files.count
            var file = NSPFile(url: url, titleID: tid, version: version(fromName: url.lastPathComponent), kind: .unknown, size: size, compressed: compressed[ext] != nil)
            if let tid {
                let low = tid & 0xFFF   // base …000, update …800, DLC = base + 0x1000 + index
                let app = low == 0 ? tid : low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) &- 0x1000
                if !families.contains(where: { $0.app == app }) { families.append((app, nil, [], [])) }
                let f = families.firstIndex { $0.app == app } ?? 0
                if low == 0 { file.kind = .base; families[f].base = index }
                else if low == 0x800 { file.kind = .update; families[f].updates.append(index) }
                else { file.kind = .dlc; families[f].dlc.append(index) }
            } else { unknown.append(index) }
            files.append(file)
        }
        // a base game converted from a cartridge may have neither tags nor a ticket (the script checks build IDs afterwards)
        if families.count == 1, unknown.count == 1, families[0].base == nil { families[0].base = unknown[0]; files[unknown[0]].kind = .base }
        var scan = NSPFolderScan(folder: folder, files: files, applicationID: nil, base: nil, updates: [], dlc: [], errors: [], warnings: warnings)
        if families.isEmpty {
            scan.errors.append(files.isEmpty ? "no NSP, XCI, NSZ or XCZ file in \(folder.path)" : "no NSP with a readable title ID in \(folder.path)")
        } else if families.count > 1 {
            scan.errors.append("more than one game in the folder, keep one game per folder: " + families.map { hex16($0.app) }.joined(separator: ", "))
        } else {
            let f = families[0]
            scan.applicationID = f.app
            scan.base = f.base.map { files[$0] }
            scan.updates = f.updates.map { files[$0] }.sorted { ($0.version ?? -1, $0.url.lastPathComponent) < ($1.version ?? -1, $1.url.lastPathComponent) }
            scan.dlc = f.dlc.map { files[$0] }
            if f.base == nil { scan.errors.append("no base game NSP found in \(folder.path) (title ID \(hex16(f.app)))") }
            let loose = scan.updates.filter { $0.version == nil }
            if !loose.isEmpty {
                scan.warnings.append("update without a version tag ([v<N>]) in its name: " + loose.map(\.url.lastPathComponent).joined(separator: ", ")
                                     + (scan.updates.count == 1 ? " (taken for the newest update the game profile registers)" : " (left out)"))
            }
        }
        return scan
    }

    public static func titleID(of file: URL) -> UInt64? {
        for name in pfs0Names(file) where name.count == 36 && name.hasSuffix(".tik") && name.prefix(32).allSatisfy(isHex) {   // a file name's tag can be wrong, the ticket is not
            return UInt64(name.prefix(16), radix: 16)
        }
        let name = file.lastPathComponent
        var rest = name[...]
        while let open = rest.firstIndex(of: "[") {
            let tag = rest[rest.index(after: open)...].prefix(17)
            if tag.count == 17, tag.last == "]", tag.dropLast().allSatisfy(isHex) { return UInt64(tag.dropLast(), radix: 16) }
            rest = rest[rest.index(after: open)...]
        }
        return nil
    }

    public static func version(fromName name: String) -> Int? {
        var rest = name[...]
        while let r = rest.range(of: "[v") {
            let digits = rest[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, rest[digits.endIndex...].first == "]" { return Int(digits) }
            rest = rest[r.upperBound...]
        }
        return nil
    }

    public static func gameFolders(from dropped: [URL]) -> [URL] {
        var out: [URL] = [], seen = Set<String>()
        func add(_ url: URL) {
            let u = URL(fileURLWithPath: url.path, isDirectory: true).standardized
            if seen.insert(u.path).inserted { out.append(u) }
        }
        for url in dropped {
            let u = url.standardized
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if fileExtensions.contains(u.pathExtension) { add(u.deletingLastPathComponent()) }
            } else if !gameFiles(in: u).isEmpty {
                add(u)
            } else {
                for sub in subfolders(of: u) where !gameFiles(in: sub).isEmpty { add(sub) }
            }
        }
        return out
    }

    static func isHex(_ c: Character) -> Bool { c.isASCII && c.isHexDigit }

    static func hex16(_ v: UInt64) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }

    // The script's scan_nsps: glob('*.nsp') etc. (lower-case extensions) without the hidden files (hidden(): a name that starts with ".", such as the "._" AppleDouble files
    // macOS writes on exFAT and SMB volumes, or the hidden flag, which is what .skipsHiddenFiles leaves out), sorted by name
    static func gameFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && fileExtensions.contains($0.pathExtension) && isRegularFile($0) }.map(\.standardized)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: AppInstaller.realPath(url).path), let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    /// The names of the files inside a PFS0 (an NSP or NSZ): "PFS0", u32 count, u32 string table size, u32 reserved, count × 0x18-byte entries
    /// (u64 offset, u64 size, u32 name offset, u32 reserved), then the string table. [] for anything else
    static func pfs0Names(_ url: URL) -> [String] {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 16), head.count == 16, head.prefix(4) == Data("PFS0".utf8) else { return [] }
        let count = Int(u32(head, 4)), tableSize = Int(u32(head, 8))
        guard count * 0x18 + tableSize <= headerLimit, let body = try? h.read(upToCount: count * 0x18 + tableSize) else { return [] }
        guard body.count >= count * 0x18 else { return [] }
        let table = [UInt8](body.dropFirst(count * 0x18))
        var names: [String] = []
        for i in 0..<count {
            let offset = Int(u32(body, i * 0x18 + 0x10))
            guard offset < table.count else { continue }
            let end = table[offset...].firstIndex(of: 0) ?? table.count
            names.append(String(decoding: table[offset..<end], as: UTF8.self))
        }
        return names
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let b = [UInt8](d[(d.startIndex + at)..<(d.startIndex + at + 4)])
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
