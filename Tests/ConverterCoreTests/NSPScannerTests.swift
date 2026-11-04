// NSPScanner on synthesized folders: PFS0 files with tickets, name tags, the script's skip and error cases, and drop expansion
import Foundation
import Testing
@testable import ConverterCore

struct NSPScannerTests {
    let app: UInt64 = 0x0100_ABCD_0000_0000

    @Test func baseUpdateAndDLC() throws {
        let t = try TempDir(); defer { t.remove() }
        // the base file's tag is wrong (FFT's base NSP is tagged …0001): its ticket wins
        try t.file("Super Game [0100ABCD00000001][v0] (US).nsp", pfs0(["a.nca", ticket(app)]))
        try t.file("Super Game [0100ABCD00000800][v131072].nsp", pfs0([ticket(app | 0x800), "b.nca"]))
        try t.file("Super Game [0100ABCD00000800][v65536].nsp", pfs0([ticket(app | 0x800)]))
        try t.file("Super Game DLC [0100ABCD00001001][v0].nsp", pfs0([ticket(app + 0x1001)]))
        try t.file("notes.txt")
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.errors == [] && s.warnings == [])
        #expect(s.applicationID == app && s.titleIDString == "0100ABCD00000000")
        #expect(s.base?.url.lastPathComponent == "Super Game [0100ABCD00000001][v0] (US).nsp")
        #expect(s.base?.titleID == app && s.base?.kind == .base)
        #expect(s.updates.map(\.version) == [65536, 131072])
        #expect(s.updates.allSatisfy { $0.kind == .update })
        #expect(s.dlc.map(\.titleID) == [app + 0x1001])
        #expect(s.files.count == 4)
        #expect(s.files.map(\.url.lastPathComponent) == s.files.map(\.url.lastPathComponent).sorted())
        #expect(s.versions == [0, 65536, 131072] && s.newestVersion == 131072)
        #expect(s.isConvertible)
        #expect(s.displayName == "Super Game")
        #expect(s.totalBytes == s.files.reduce(0) { $0 + $1.size } && s.totalBytes > 0)
    }

    @Test func untaggedBase() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Cartridge.xci", Data(repeating: 1, count: 64))   // neither a PFS0 nor a tag
        try t.file("Update [v65536].nsp", pfs0([ticket(app | 0x800)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.errors == [])
        #expect(s.base?.url.lastPathComponent == "Cartridge.xci" && s.base?.kind == .base && s.base?.titleID == nil)
        #expect(s.applicationID == app)
        #expect(s.displayName == "Cartridge")
    }

    @Test func mergedXCI() throws {   // scan_nsps (test_nsp_xci): an XCI is the base game, and its [v<N>] tag stands for the update it bundles
        let t = try TempDir(); defer { t.remove() }
        let name = "Animal Crossing New Horizons [01006F8002326800][v1769472][Base][v2.0.5][3 DLC's].xci"
        try t.file(name, Data("HEAD".utf8))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.errors == [] && s.warnings == [])
        #expect(s.applicationID == 0x0100_6F80_0232_6000)
        #expect(s.base?.url.lastPathComponent == name && s.base?.kind == .base)
        #expect(s.updates.map(\.url.lastPathComponent) == [name] && s.versions == [0, 1769472])
        #expect(s.files.count == 1 && s.isConvertible)
        #expect(s.displayName == "Animal Crossing New Horizons")
    }

    @Test func cartridgeDumpWithoutUpdate() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Game [0100ABCD00000000][v0].xci", Data("HEAD".utf8))
        try t.file("Game [0100ABCD00000800][v65536].nsp", pfs0([ticket(app | 0x800)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.base?.url.lastPathComponent == "Game [0100ABCD00000000][v0].xci")
        #expect(s.updates.map(\.url.lastPathComponent) == ["Game [0100ABCD00000800][v65536].nsp"] && s.isConvertible)
    }

    @Test func twoGames() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("A.nsp", pfs0([ticket(app)]))
        try t.file("B [0100111100000000].nsp", Data(repeating: 2, count: 8))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.errors == ["more than one game in the folder, keep one game per folder: 0100ABCD00000000, 0100111100000000"])
        #expect(!s.isConvertible && s.applicationID == nil && s.base == nil)
        #expect(s.files.count == 2)
        #expect(s.displayName == t.url.lastPathComponent)
    }

    @Test func skippedFiles() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Game [0100ABCD00000000].nsp", pfs0([ticket(app)]))
        try t.file("Game [0100ABCD00000000].nsz", pfs0([ticket(app)]))
        try t.file("DLC [0100ABCD00001001].nsp", Data())
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.warnings == ["skipping an empty file: DLC [0100ABCD00001001].nsp", "skipping Game [0100ABCD00000000].nsz: Game [0100ABCD00000000].nsp is beside it"])
        #expect(s.files.map(\.url.lastPathComponent) == ["Game [0100ABCD00000000].nsp"])
        #expect(s.isConvertible && s.dlc.isEmpty)
    }

    @Test func hiddenFiles() throws {   // scan_nsps leaves out names that start with "." and files with the hidden flag (test_nsp_settings.Hidden)
        let t = try TempDir(); defer { t.remove() }
        try t.file("Game [0100ABCD00000000][v0].nsp", pfs0([ticket(app)]))
        try t.file("._Game [0100ABCD00000000][v0].nsp", Data(repeating: 0, count: 4096))   // AppleDouble companions on exFAT / SMB
        try t.file("._Game DLC [0100ABCD00001001][v0].nsp", Data(repeating: 0, count: 4096))
        var flagged = try t.file("Game DLC [0100ABCD00001001][v0].nsp", pfs0([ticket(app + 0x1001)]))
        var values = URLResourceValues(); values.isHidden = true
        try flagged.setResourceValues(values)
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.files.map(\.url.lastPathComponent) == ["Game [0100ABCD00000000][v0].nsp"])
        #expect(s.dlc.isEmpty && s.errors.isEmpty && s.warnings.isEmpty)
    }

    @Test func compressedAlone() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Game.nsz", pfs0([ticket(app)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isConvertible && s.base?.compressed == true)
    }

    @Test func noBase() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Update [v65536].nsp", pfs0([ticket(app | 0x800)]))
        try t.file("Loose update.nsp", pfs0([ticket(app | 0x800)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.errors == ["no base game NSP found in \(t.url.path) (title ID 0100ABCD00000000)"])
        #expect(s.warnings.count == 1 && s.warnings[0].contains("Loose update.nsp") && s.warnings[0].contains("left out"))
        #expect(s.updates.map(\.version) == [nil, 65536])
        #expect(!s.isConvertible)
    }

    @Test func emptyFolders() throws {
        let t = try TempDir(); defer { t.remove() }
        #expect(NSPScanner.scan(folder: t.url).errors == ["no NSP, XCI, NSZ or XCZ file in \(t.url.path)"])
        try t.file("Mystery.nsp", Data(repeating: 3, count: 32))
        #expect(NSPScanner.scan(folder: t.url).errors == ["no NSP with a readable title ID in \(t.url.path)"])
    }

    @Test func titleIDAndVersion() throws {
        let t = try TempDir(); defer { t.remove() }
        #expect(NSPScanner.titleID(of: try t.file("x [0100abcd00000800] [v3].nsp", Data(repeating: 0, count: 4))) == app | 0x800)
        #expect(NSPScanner.titleID(of: try t.file("x [0100ABCD0000080].nsp", Data(repeating: 0, count: 4))) == nil)
        #expect(NSPScanner.titleID(of: try t.file("t.nsp", pfs0(["0100ABCD00000800000000000000000.tik", "x.cnmt.nca"]))) == nil)   // 31 digits
        #expect(NSPScanner.titleID(of: try t.file("u.nsp", pfs0(["x.nca", "0100abcd000008000000000000000000.tik"]))) == app | 0x800)
        #expect(NSPScanner.titleID(of: t.url.appendingPathComponent("missing.nsp")) == nil)
        #expect(NSPScanner.version(fromName: "Game [0100ABCD00000800][v327680].nsp") == 327680)
        #expect(NSPScanner.version(fromName: "Game [v] [v12].nsp") == 12)
        #expect(NSPScanner.version(fromName: "Game v327680.nsp") == nil)
        #expect(NSPScanner.version(fromName: "Game [v12a].nsp") == nil)
    }

    @Test func truncatedPFS0() throws {
        let t = try TempDir(); defer { t.remove() }
        var d = pfs0([ticket(app)]); d = d.prefix(20)
        #expect(NSPScanner.titleID(of: try t.file("cut.nsp", d)) == nil)
        var huge = Data("PFS0".utf8); huge.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x0F, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(NSPScanner.pfs0Names(try t.file("huge.nsp", huge)) == [])
    }

    @Test func gameFolders() throws {
        let t = try TempDir(); defer { t.remove() }
        let root = try t.sub("Games")
        let a = try t.file("Games/A/a.nsp", pfs0([ticket(app)]))
        _ = try t.sub("Games/B")
        try t.file("Games/B/readme.txt")
        try t.file("Games/C/c.xci")
        try t.file("Games/D.app/Contents/x.nsp")
        try t.file("Games/D/E/deep.nsp")   // two levels down: not found
        let folders = NSPScanner.gameFolders(from: [root, a, root.appendingPathComponent("A"), t.url.appendingPathComponent("missing")])
        #expect(folders.map(\.lastPathComponent) == ["A", "C"])
        #expect(folders.allSatisfy { $0.isFileURL && $0.path.hasPrefix(t.url.path) })
        #expect(NSPScanner.gameFolders(from: [a]) == [root.appendingPathComponent("A", isDirectory: true).standardized])
        #expect(NSPScanner.gameFolders(from: [root.appendingPathComponent("A/../A")]).map(\.lastPathComponent) == ["A"])
        #expect(NSPScanner.gameFolders(from: [try t.file("Games/B/readme.txt")]) == [])
    }

    /// A main.npdm with an ACI0 section at 0x80 holding `program` (pack_dump.program_id's layout)
    static func npdm(_ program: UInt64) -> Data {
        var d = Data(count: 0x80 + 0x40)
        d.replaceSubrange(0..<4, with: Data("META".utf8))
        func put32(_ v: UInt32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<(at + 4), with: $0) } }
        put32(0x80, 0x70); put32(0x40, 0x74)
        d.replaceSubrange(0x80..<0x84, with: Data("ACI0".utf8))
        withUnsafeBytes(of: program.littleEndian) { d.replaceSubrange(0x90..<0x98, with: $0) }
        return d
    }

    // build_ipa_from_nsp.py takes a dump folder (pack_dump.py's layout) in place of NSPs: no prod.keys, the title ID from main.npdm
    @Test func dumpFolder() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("base/exefs/main.npdm", Self.npdm(app))
        try t.file("base/romfs/data.bin")
        try t.file("updates/458752/exefs/main")
        try t.file("updates/65536/exefs/main")
        try t.file("updates/notes/readme.txt")
        try t.file("dlc/0100ABCD00001001/0/romfs/a.bin")
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isDump && s.isConvertible && s.errors == [])
        #expect(s.titleIDString == "0100ABCD00000000")
        #expect(s.versions == [0, 65536, 458752])
        #expect(s.dlc.map(\.titleID) == [app + 0x1001])
        #expect(s.displayName == t.url.lastPathComponent)
        #expect(NSPScanner.gameFolders(from: [t.url]).map(\.path) == [t.url.standardized.path])
        #expect(NSPScanner.gameFolders(from: [t.url.appendingPathComponent("base")]).map(\.path) == [t.url.standardized.path])   // a folder inside the dump
        #expect(NSPScanner.gameFolders(from: [t.url.deletingLastPathComponent()]).map(\.path).contains(t.url.standardized.path))   // a folder of dumps
    }

    @Test func dumpWithPackagesBesideItIsAPackageFolder() throws {   // the script's dump_folder: NSPs in the folder are what the player asked for
        let t = try TempDir(); defer { t.remove() }
        try t.file("base/exefs/main.npdm", Self.npdm(app))
        try t.file("base/romfs/data.bin")
        try t.file("Game [0100ABCD00000000][v0].nsp", pfs0([ticket(app)]))
        #expect(!NSPScanner.scan(folder: t.url).isDump)
    }

    @Test func dumpOfAnUpdateProgram() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("base/exefs/main.npdm", Self.npdm(app | 0x800))
        try t.file("base/romfs/data.bin")
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isDump && !s.isConvertible && s.errors.count == 1)
    }

    @Test func dumpWithTheRomFSOnlyInAnUpdate() throws {   // pack_dump.is_dump: an update's RomFS is whole, so base/romfs may be left out
        let t = try TempDir(); defer { t.remove() }
        try t.file("base/exefs/main.npdm", Self.npdm(app))
        #expect(!NSPScanner.isDump(t.url))
        try t.file("updates/458752/romfs/data.bin")
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isDump && s.isConvertible && s.versions == [0, 458752])
    }

    /// A NUP with only its superblock, TOC header and package records (pack_nup.py's SUPER, TOC and PKG layouts)
    static func nup(_ packages: [(titleID: UInt64, version: UInt32, kind: UInt8)]) -> Data {
        var d = Data(count: 0x80 + 0x30 + packages.count * 0x40)
        func put<T: FixedWidthInteger>(_ v: T, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<(at + MemoryLayout<T>.size), with: $0) } }
        d.replaceSubrange(0..<4, with: Data([0x4E, 0x55, 0x50, 0x01]))
        put(UInt64(0x80), 8); put(UInt32(packages.count), 72)
        d.replaceSubrange(0x80..<0x84, with: Data([0x54, 0x4F, 0x43, 0x01])); put(UInt32(packages.count), 0x84)
        for (i, k) in packages.enumerated() {
            let p = 0xB0 + i * 0x40
            put(k.titleID, p); put(k.version, p + 20); put(k.kind, p + 24)
        }
        return d
    }

    // build_ipa_from_nsp.py takes one NUP container (a .nup file) in place of NSPs: no prod.keys; a base that is a placeholder (title ID 0) takes an update's
    @Test func nupContainer() throws {
        let t = try TempDir(); defer { t.remove() }
        let file = try t.file("Game.nup", Self.nup([(0, 0, 0), (app | 0x800, 655360, 1), (app + 0x1001, 0, 2)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isNup && s.isUnencrypted && s.isConvertible && s.errors == [])
        #expect(s.titleIDString == "0100ABCD00000000")
        #expect(s.versions == [0, 655360] && s.dlc.map(\.titleID) == [app + 0x1001])
        #expect(s.files.count == 1 && s.totalBytes == Int64(Self.nup([(0, 0, 0), (0, 0, 0), (0, 0, 0)]).count))
        #expect(NSPScanner.gameFolders(from: [file]).map(\.path) == [t.url.standardized.path])
        #expect(NSPScanner.gameFolders(from: [t.url]).map(\.path) == [t.url.standardized.path])
    }

    @Test func nupWithoutABaseAndTwoNups() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.file("Update.nup", Self.nup([(app | 0x800, 65536, 1)]))
        #expect(!NSPScanner.scan(folder: t.url).isConvertible)
        try t.file("Other.nup", Self.nup([(app, 0, 0)]))
        let s = NSPScanner.scan(folder: t.url)
        #expect(s.isNup && !s.isConvertible && s.errors.first?.hasPrefix("more than one NUP") == true)
    }
}
