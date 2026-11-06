// What a dropped folder holds: its game files grouped as the NSP script groups them (scripts/build_ipa_from_nsp.py scan_nsps, title_of, version_of), so a folder the script
// would refuse is shown as such before a conversion starts. The title ID comes from the ticket inside a PFS0 (NSP / NSZ), else from a "[0100…]" tag in the file name.
// A folder of the game's files instead (a dump: base/ or exefs/ and romfs/ directly, updates/<version>/, dlc/<DLC title ID>/, scripts/pack_dump.py) is scanned as pack_dump.scan
// reads it: it needs no prod.keys. Neither does a folder holding one NUP container (a .nup file, scripts/pack_nup.py): its packages are read from its table of contents. A game
// with no profile is surveyed from either, as from NSPs
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
    public var isDump = false   // the game's files, not packages: base, updates and DLC are folders
    public var isNup = false    // one NUP container: base, updates and DLC are its packages
    public var hasBaseVersion = true   // false: a NUP with no base game (standalone updates), which has no v0

    /// A dump or a NUP: its files are not encrypted, so the script needs no prod.keys, and it packs only a game with a profile (the survey reads NSPs)
    public var isUnencrypted: Bool { isDump || isNup }

    public var isConvertible: Bool { errors.isEmpty && base != nil }
    public var versions: [Int] { Array(Set((hasBaseVersion ? [0] : []) + updates.compactMap(\.version))).sorted() }
    public var newestVersion: Int { versions.last ?? 0 }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var titleIDString: String? { applicationID.map(NSPScanner.hex16) }

    public var displayName: String {
        guard let base, !isUnencrypted else { return folder.lastPathComponent }
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
        if gameFiles(in: folder).isEmpty {   // the script's nup_file, then dump_folder: a NUP or a dump with no package beside it
            let nups = nupFiles(in: folder)
            if nups.count > 1 {
                return NSPFolderScan(folder: folder, files: [], applicationID: nil, base: nil, updates: [], dlc: [],
                                     errors: ["more than one NUP in \(folder.path), keep one game per folder: " + nups.map(\.lastPathComponent).joined(separator: ", ")], warnings: [], isNup: true)
            }
            if let nup = nups.first { return scanNup(nup, folder: folder) }
            if isDump(folder) { return scanDump(folder) }
        }
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
                if ext == "xci" || ext == "xcz" {   // a cartridge image holds the base game whatever its name's tag says; a merged one may bundle an update (its [v<N>] tag) and DLC
                    file.kind = .base; families[f].base = index   //   Animal Crossing's "[01006F8002326800][v1769472][Base][v2.0.5][3 DLC's].xci" is tagged with the update's title ID
                    if let v = file.version, v > 0 { families[f].updates.append(index) }
                } else if low == 0 { file.kind = .base; families[f].base = index }
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

    /// pack_dump.has_code / is_version: a version's folder (base/, updates/<version>/) holds exefs/main.npdm, and a whole version its romfs/ beside it
    static func hasCode(_ src: URL) -> Bool { isRegularFile(src.appendingPathComponent("exefs/main.npdm")) }
    static func isVersion(_ src: URL) -> Bool { hasCode(src) && isDirectory(src.appendingPathComponent("romfs")) }

    /// pack_dump.updates: updates/<version>/ by its decimal title version
    static func dumpUpdates(_ folder: URL) -> [(version: Int, url: URL)] {
        subfolders(of: folder.appendingPathComponent("updates")).compactMap { url in
            let name = url.lastPathComponent
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(name) else { return nil }
            return (v, url)
        }.sorted { $0.version < $1.version }
    }

    /// pack_dump.base_of: base/ with its code, else the folder itself when exefs/ and romfs/ sit directly in it (as `nup extract` writes them), else none
    static func dumpBase(_ folder: URL) -> URL? {
        let base = folder.appendingPathComponent("base", isDirectory: true)
        if hasCode(base) { return base }
        return isVersion(folder) ? folder : nil
    }

    /// pack_dump.is_dump: a base game's code with a RomFS beside it or in an update (an update's RomFS is whole, so the base's may be left out),
    /// or no base game and an update with its code and RomFS (the update's folder is the whole game)
    public static func isDump(_ folder: URL) -> Bool {
        let ups = dumpUpdates(folder)
        if let base = dumpBase(folder) {
            return isDirectory(base.appendingPathComponent("romfs")) || ups.contains { isDirectory($0.url.appendingPathComponent("romfs")) }
        }
        return ups.contains { isVersion($0.url) }
    }

    /// pack_dump.scan: the title ID is main.npdm's program ID, an update is updates/<version> (a decimal title version), a DLC dlc/<its title ID in hex>
    static func scanDump(_ folder: URL) -> NSPFolderScan {
        func entry(_ url: URL, _ kind: NSPKind, titleID: UInt64?, version: Int? = nil) -> NSPFile {
            NSPFile(url: url, titleID: titleID, version: version, kind: kind, size: 0, compressed: false)
        }
        var scan = NSPFolderScan(folder: folder, files: [], applicationID: nil, base: nil, updates: [], dlc: [], errors: [], warnings: [], isDump: true)
        let ups = dumpUpdates(folder), base = dumpBase(folder)
        guard let code = base ?? ups.last(where: { isVersion($0.url) })?.url else { scan.errors.append("\(folder.path): no base game and no whole update"); return scan }
        let npdm = code.appendingPathComponent("exefs/main.npdm")
        guard let app = programID(npdm: npdm) else {
            scan.errors.append("\(npdm.path): not an NPDM with a program ID"); return scan
        }
        guard app & 0xFFF == 0 else { scan.errors.append("\(folder.path): base program ID \(hex16(app)) is not a base title ID"); return scan }
        scan.applicationID = app
        scan.hasBaseVersion = base != nil   // no base/: an update's folder is the whole game, and there is no v0
        scan.base = entry(base ?? folder, .base, titleID: app)
        scan.updates = ups.map { entry($0.url, .update, titleID: app | 0x800, version: $0.version) }
        for url in subfolders(of: folder.appendingPathComponent("dlc")) {
            guard let tid = UInt64(url.lastPathComponent, radix: 16), tid > app + 0x1000, tid - app - 0x1000 <= 2000 else {
                scan.errors.append("\(url.path): not a DLC title ID of \(hex16(app))"); continue
            }
            scan.dlc.append(entry(url, .dlc, titleID: tid))
        }
        scan.files = (base == nil ? [] : [scan.base].compactMap { $0 }) + scan.updates + scan.dlc
        return scan
    }

    /// The .nup files in a folder that start with the NUP magic (pack_nup.is_nup)
    static func nupFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "nup" && isNup($0) }.map(\.standardized)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isNup(_ url: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 3)) == Data("NUP".utf8)
    }

    /// pack_nup.scan from the table of contents (NUP SPEC v1): the superblock (0x80: the TOC's offset at 8, the package count at 72), the TOC (0x30) and its package
    /// records (0x40: title ID at 0, ExeFS folder at 12, version at 20, kind at 24: 0 base, 1 update, 2 DLC, flags at 25). The title ID is the base package's, else an
    /// update's: a NUP may have no base game (updates marked standalone) or an empty base record, and then no v0. The script checks the title ID against main.npdm and
    /// every file against its SHA-256
    static func scanNup(_ nup: URL, folder: URL) -> NSPFolderScan {
        var scan = NSPFolderScan(folder: folder, files: [], applicationID: nil, base: nil, updates: [], dlc: [], errors: [], warnings: [], isNup: true)
        let size = fileSize(nup)
        guard let packages = nupPackages(nup) else { scan.errors.append("\(nup.lastPathComponent) is not a NUP this app can read"); return scan }
        let bases = packages.filter { $0.kind == 0 }, updates = packages.filter { $0.kind == 1 }
        guard bases.count <= 1 else { scan.errors.append("\(nup.lastPathComponent) has \(bases.count) base packages"); return scan }
        if bases.isEmpty && (updates.isEmpty || updates.contains { !$0.standalone }) {
            scan.errors.append("\(nup.lastPathComponent) has no base game: pack the base game and its update into one NUP, or mark its updates standalone_update")
            return scan
        }
        let base = bases.first.flatMap { $0.titleID != 0 && $0.exefs != 0xFFFF_FFFF ? $0 : nil }   // an empty base record (no code, title ID 0) is no base game
        scan.hasBaseVersion = base != nil
        let app = base?.titleID ?? (updates.first?.titleID ?? 0) & ~0xFFF
        guard app != 0, app & 0xFFF == 0 else { scan.errors.append("\(nup.lastPathComponent): \(hex16(app)) is not a base title ID"); return scan }
        scan.applicationID = app
        scan.base = NSPFile(url: nup, titleID: app, version: nil, kind: .base, size: size, compressed: false)
        scan.updates = updates.map { NSPFile(url: nup, titleID: app | 0x800, version: Int($0.version), kind: .update, size: 0, compressed: false) }.sorted { ($0.version ?? 0) < ($1.version ?? 0) }
        scan.dlc = packages.filter { $0.kind == 2 }.map { NSPFile(url: nup, titleID: $0.titleID, version: nil, kind: .dlc, size: 0, compressed: false) }
        scan.files = [scan.base].compactMap { $0 }   // one file: the container
        return scan
    }

    static func nupPackages(_ url: URL) -> [(titleID: UInt64, version: UInt32, kind: UInt8, exefs: UInt32, standalone: Bool)]? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 0x80), head.count == 0x80, head.prefix(3) == Data("NUP".utf8), head[head.startIndex + 3] == 1 else { return nil }
        let tocOffset = u64(head, 8), count = Int(u32(head, 72))
        guard count > 0, count <= 100_000, (try? h.seek(toOffset: tocOffset)) != nil, let toc = try? h.read(upToCount: 0x30 + count * 0x40),
              toc.count == 0x30 + count * 0x40, toc.prefix(4) == Data([0x54, 0x4F, 0x43, 0x01]), Int(u32(toc, 4)) == count else { return nil }
        return (0..<count).map { i in
            let p = 0x30 + i * 0x40
            return (u64(toc, p), u32(toc, p + 20), toc[toc.startIndex + p + 24], u32(toc, p + 12), toc[toc.startIndex + p + 25] & 1 != 0)   // flags bit 0: STANDALONE
        }
    }

    /// The ACI0 program ID of a main.npdm (pack_dump.program_id): "META", the ACI0 offset and size at 0x70, the program ID at ACI0 + 0x10
    static func programID(npdm: URL) -> UInt64? {
        guard let d = try? Data(contentsOf: npdm), d.count >= 0x78, d.prefix(4) == Data("META".utf8) else { return nil }
        let off = Int(u32(d, 0x70)), size = Int(u32(d, 0x74))
        guard size >= 0x18, off >= 0, off + 0x18 <= d.count, d[(d.startIndex + off)..<(d.startIndex + off + 4)] == Data("ACI0".utf8) else { return nil }
        return UInt64(u32(d, off + 0x10)) | UInt64(u32(d, off + 0x14)) << 32
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
                if fileExtensions.contains(u.pathExtension) || u.pathExtension == "nup" && isNup(u) { add(u.deletingLastPathComponent()) }
            } else if let dump = enclosingDump(u) {
                add(dump)   // a folder inside a dump: base/, exefs/, romfs/, updates/, updates/<version>/, dlc/
            } else if !gameFiles(in: u).isEmpty || !nupFiles(in: u).isEmpty || isDump(u) {
                add(u)
            } else {
                for sub in subfolders(of: u) where !gameFiles(in: sub).isEmpty || !nupFiles(in: sub).isEmpty || isDump(sub) { add(sub) }
            }
        }
        return out
    }

    /// The dump a folder is part of, when it is one of a dump's own folders (an update's folder is also a dump on its own, as the whole game)
    static func enclosingDump(_ u: URL) -> URL? {
        let parent = u.deletingLastPathComponent(), name = u.lastPathComponent
        if ["base", "updates", "dlc", "exefs", "romfs"].contains(name), isDump(parent) { return parent }
        if parent.lastPathComponent == "updates", isDump(parent.deletingLastPathComponent()) { return parent.deletingLastPathComponent() }
        return nil
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

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
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

    private static func u64(_ d: Data, _ at: Int) -> UInt64 { UInt64(u32(d, at)) | UInt64(u32(d, at + 4)) << 32 }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let b = [UInt8](d[(d.startIndex + at)..<(d.startIndex + at + 4)])
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
