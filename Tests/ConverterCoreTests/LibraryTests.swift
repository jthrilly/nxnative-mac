// LibraryStore (library.json): a round trip, records from another converter version, an unreadable file kept aside; InstalledAppScanner on synthesized app bundles
import Foundation
import Testing
@testable import ConverterCore

struct LibraryTests {
    @Test func roundTrip() throws {
        let t = try TempDir(); defer { t.remove() }
        let store = LibraryStore(fileURL: t.url.appendingPathComponent("nested/folder/library.json"))
        #expect(try store.load() == [])
        var options = ConversionOptions(); options.language = "ja"
        let version = NXNativeVersion(commit: String(repeating: "a", count: 40), shortCommit: "aaaaaaa", subject: "Fix it", commitDate: Date(timeIntervalSince1970: 1_790_848_800),
                                      branch: "main", describe: nil, modified: true)
        let records = [
            ConversionRecord(folder: "/Games/A", titleID: "0100ABCD00000000", gameName: "A", gameVersion: "1.2.1", package: "v327680", profile: "0100ABCD00000000",
                             provisional: false, derived: true, builtAppPath: "/Games/A/A.app", installedAppPath: "/Applications/A.app",
                             startedAt: Date(timeIntervalSince1970: 1_790_000_000.25), finishedAt: Date(timeIntervalSince1970: 1_790_000_600), status: .succeeded,
                             nxnative: version, options: options),
            ConversionRecord(folder: "/Games/B", gameName: "B", startedAt: Date(timeIntervalSince1970: 1_790_001_000), status: .failed, message: "tools not found: dotnet"),
        ]
        try store.save(records)
        #expect(try store.load() == records)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"startedAt\" : \"2026-09-21T") && text.contains(".250Z\""))
        #expect(text.contains("\"status\" : \"failed\""))
        try store.save([])
        #expect(try store.load() == [])
        #expect(LibraryStore.defaultURL.path.hasSuffix("Library/Application Support/nxnative Converter/library.json"))
    }

    func preservedCopies(_ t: TempDir, _ name: String = "library.json") throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: t.url.path).filter { $0.hasPrefix(name + ".unreadable-") }.sorted().map { t.url.appendingPathComponent($0) }
    }

    @Test func xcodeProjectRecords() throws {
        var options = ConversionOptions(); options.output = .xcodeProject; options.language = "fr"
        let version = NXNativeVersion(commit: String(repeating: "b", count: 40), shortCommit: "bbbbbbb", subject: "x", commitDate: nil, branch: "main", describe: nil, modified: false)
        let record = ConversionRecord(folder: "/Games/A", titleID: "0100ABCD00000000", gameName: "A", gameVersion: "1.2.1",
                                      xcodeProjectPath: "/Games/A/0100ABCD00000000_build/xcode/DmIOS.xcodeproj", xcodeWorkspacePath: "/Games/NxNative.xcworkspace",
                                      startedAt: Date(timeIntervalSince1970: 1_790_000_000), finishedAt: Date(timeIntervalSince1970: 1_790_000_600), status: .succeeded,
                                      nxnative: version, options: options)
        let project = try #require(InstalledGameApp(xcodeProjectOf: record))
        #expect(project.url.path == "/Games/A/0100ABCD00000000_build/xcode/DmIOS.xcodeproj")
        #expect(project.name == "A" && project.titleID == "0100ABCD00000000" && project.version == "1.2.1" && project.language == "fr" && project.bundleID == nil)
        #expect(project.nxnativeCommit == version.commit && project.nxnativeModified == false)
        var named = record; named.options.appName = "Game A"
        #expect(InstalledGameApp(xcodeProjectOf: named)?.name == "Game A")
        var failed = record; failed.status = .failed
        var mac = record; mac.options.output = .macApp
        var noPath = record; noPath.xcodeProjectPath = nil
        for other in [failed, mac, noPath] { #expect(InstalledGameApp(xcodeProjectOf: other) == nil) }
        // the paths survive a round trip, and a record written before them still loads
        let t = try TempDir(); defer { t.remove() }
        let store = LibraryStore(fileURL: t.url.appendingPathComponent("library.json"))
        try store.save([record])
        #expect(try store.load() == [record])
        let f = try t.file("old.json", Data(#"[{"folder":"/Games/A","status":"succeeded","options":{"language":"ja"}}]"#.utf8))
        let old = try #require(try LibraryStore(fileURL: f).load().first)
        #expect(old.xcodeProjectPath == nil && old.options.output == .macApp)
    }

    @Test func unreadableLibraryIsMovedAside() throws {
        let t = try TempDir(); defer { t.remove() }
        let bytes = Data("{not json".utf8)
        let f = try t.file("library.json", bytes)
        let store = LibraryStore(fileURL: f)
        do { _ = try store.load(); Issue.record("no error") } catch let StoreError.movedAside(file, to) {
            #expect(file == f.path && to.hasPrefix(f.path + ".unreadable-"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.path))
        let kept = try preservedCopies(t)
        #expect(try kept.count == 1 && (try Data(contentsOf: kept[0])) == bytes)
        #expect(try store.read().records.isEmpty)   // a new library starts
        try store.save([ConversionRecord(folder: "/Games/A", gameName: "A", startedAt: Date(timeIntervalSince1970: 0), status: .succeeded)])
        #expect(try store.load().count == 1 && (try Data(contentsOf: kept[0])) == bytes)
    }

    @Test func badRecordsAreLeftOutAndKept() throws {
        let t = try TempDir(); defer { t.remove() }
        let json = #"""
            [{"folder": "/Games/A", "gameName": "A", "startedAt": "2026-10-25T12:00:00Z", "status": "interrupted", "options": {"language": 5}, "nxnative": "?"},
             {"gameName": "no folder"}, 7,
             {"folder": "/Games/B Game", "startedAt": "yesterday", "status": "succeeded", "futureField": true}]
            """#
        let f = try t.file("library.json", Data(json.utf8))
        let store = LibraryStore(fileURL: f)
        let contents = try store.read()
        #expect(contents.records.map(\.folder) == ["/Games/A", "/Games/B Game"] && contents.skipped == 2 && !contents.unreadable)
        #expect(contents.records[0].status == .failed && contents.records[0].options == ConversionOptions() && contents.records[0].nxnative == nil)
        #expect(contents.records[1].gameName == "B Game" && contents.records[1].startedAt == Date(timeIntervalSince1970: 0) && contents.records[1].status == .succeeded)
        let kept = try preservedCopies(t)
        #expect(try kept.count == 1 && (try Data(contentsOf: kept[0])) == Data(json.utf8) && contents.preserved?.path == kept[0].path)
        #expect(contents.notice?.contains("2 records could not be read") == true && contents.notice?.contains(kept[0].path) == true)
        #expect(try store.load().count == 2)
        #expect(try preservedCopies(t).count == 1)   // the same bytes are kept once
        #expect(try store.read().preserved?.path == kept[0].path)
    }

    @Test func saveMovesAnUnreadFileAside() throws {
        let t = try TempDir(); defer { t.remove() }
        let f = try t.file("library.json", Data("garbage".utf8))
        try LibraryStore(fileURL: f).save([])
        #expect(try LibraryStore(fileURL: f).read().records.isEmpty)
        let kept = try preservedCopies(t)
        #expect(try kept.count == 1 && (try String(contentsOf: kept[0], encoding: .utf8)) == "garbage")
        try LibraryStore(fileURL: f).save([])   // a JSON array now: written over
        #expect(try preservedCopies(t).count == 1)
    }

    @Test func unreadableAndNotMovableIsNeverWrittenOver() throws {
        let t = try TempDir(); defer { t.remove() }
        let dir = try t.sub("locked")
        let f = try t.file("locked/library.json", Data("garbage".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard !FileManager.default.isWritableFile(atPath: dir.path) else { return }   // running as root
        let store = LibraryStore(fileURL: f)
        #expect(throws: StoreError.self) { try store.read() }
        #expect(throws: StoreError.self) { try store.save([]) }
        #expect(try String(contentsOf: f, encoding: .utf8) == "garbage")
    }

    func makeApp(_ t: TempDir, _ path: String, _ info: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try t.file(path + "/Contents/Info.plist", data)
        return t.url.appendingPathComponent(path, isDirectory: true)
    }

    @Test func readApps() throws {
        let t = try TempDir(); defer { t.remove() }
        let game = try makeApp(t, "Apps/Super Game.app", [
            "CFBundleName": "Super Game", "CFBundleDisplayName": "Super Game!", "CFBundleIdentifier": "org.nxnative.0100abcd00000000", "CFBundleShortVersionString": "1.2.1",
            "DMTitleID": "0100ABCD00000000", "DMLanguage": "ja", "DMNxnativeCommit": "abc123", "DMNxnativeCommitDate": "2026-10-01T12:00:00+02:00", "DMNxnativeModified": true,
        ])
        let a = try #require(InstalledAppScanner.read(app: game))
        #expect(a.name == "Super Game!" && a.titleID == "0100ABCD00000000" && a.version == "1.2.1" && a.bundleID == "org.nxnative.0100abcd00000000")
        #expect(a.language == "ja" && a.nxnativeCommit == "abc123" && a.nxnativeCommitDate == Date(timeIntervalSince1970: 1_790_848_800) && a.nxnativeModified == true)
        #expect(a.modified != nil)
        // nxnative's own stamp (dm/mac/pack_app.py source_commit): a short hash, +dirty with uncommitted changes; it wins over an older converter's keys
        let stamped = try #require(InstalledAppScanner.read(app: try makeApp(t, "Apps/Stamped.app", ["DMTitleID": "0100222200000000", "DMCommit": "0123456789ab+dirty",
                                                                                                       "DMNxnativeCommit": "abc123"])))
        #expect(stamped.nxnativeCommit == "0123456789ab" && stamped.nxnativeModified == true)
        let clean = try #require(InstalledAppScanner.read(app: try makeApp(t, "Apps/Clean.app", ["DMTitleID": "0100333300000000", "DMCommit": "0123456789ab"])))
        #expect(clean.nxnativeCommit == "0123456789ab" && clean.nxnativeModified == false)
        let old = try #require(InstalledAppScanner.read(app: try makeApp(t, "Apps/Old Game.app", ["DMTitleID": "0100111100000000"])))
        #expect(old.name == "Old Game" && old.version == nil && old.nxnativeCommit == nil && old.nxnativeCommitDate == nil && old.nxnativeModified == nil)
        #expect(InstalledAppScanner.read(app: try makeApp(t, "Apps/Other.app", ["CFBundleName": "Other"])) == nil)
        #expect(InstalledAppScanner.read(app: t.url.appendingPathComponent("Apps/Missing.app")) == nil)
        let link = t.url.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: game)
        #expect(InstalledAppScanner.read(app: link)?.url.path == game.path)
    }

    @Test func scan() throws {
        let t = try TempDir(); defer { t.remove() }
        let top = try makeApp(t, "Applications/B Game.app", ["DMTitleID": "0100000000000B00"])
        _ = try makeApp(t, "Applications/Games/A Game.app", ["DMTitleID": "0100000000000A00"])
        _ = try makeApp(t, "Applications/Games/Deeper/C Game.app", ["DMTitleID": "0100000000000C00"])   // two levels down: not scanned
        _ = try makeApp(t, "Applications/Safari.app", ["CFBundleName": "Safari"])
        try FileManager.default.createSymbolicLink(at: t.url.appendingPathComponent("Applications/B Link.app"), withDestinationURL: top)
        let found = InstalledAppScanner.scan(directories: [t.url.appendingPathComponent("Applications"), t.url.appendingPathComponent("Applications"),
                                                            t.url.appendingPathComponent("missing")])
        #expect(found.map(\.titleID) == ["0100000000000B00", "0100000000000A00"])
    }

    @Test func gamePaths() {
        #expect(InstalledAppScanner.saveFolder(titleID: "0100ABCD00000000").path.hasSuffix("/Library/Application Support/nxnative/0100ABCD00000000"))
        #expect(InstalledAppScanner.logFile(titleID: "0100ABCD00000000").path.hasSuffix("/Library/Logs/nxnative/0100ABCD00000000.log"))
    }
}
