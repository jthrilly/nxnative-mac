// AppInstaller with an injected Trash and attribute clearing: move, copy, replacing the same game's app, refusing another app of the name, no install, and its errors
import Foundation
import Testing
@testable import ConverterCore

struct InstallerTests {
    struct Setup {
        let t: TempDir, app: URL, dest: URL, trashDir: URL
        let trashed = Box<URL>(), cleared = Box<URL>()

        init(_ name: String = #function) throws {
            t = try TempDir(name)
            app = t.url.appendingPathComponent("Games/Super Game/Super Game.app", isDirectory: true)
            try t.file("Games/Super Game/Super Game.app/Contents/Info.plist", Self.plist("new"))
            try t.file("Games/Super Game/Super Game.app/Contents/Resources/game.bin", Data(repeating: 7, count: 20_000))
            dest = try t.sub("Applications")
            trashDir = try t.sub("Trash")
        }

        func installer(warning: String? = nil) -> AppInstaller {
            let trashDir = trashDir, trashed = trashed, cleared = cleared
            return AppInstaller(trash: { url in
                let to = trashDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: to)
                trashed.add(url)
                return to
            }, clearAttributes: { url in cleared.add(url); return warning })
        }

        /// An app's Info.plist: the game's title ID (nil for an app nxnative did not make) and a marker telling the copies apart
        static func plist(_ marker: String, titleID: String? = "0100ABCD00000000") -> Data {
            var info: [String: Any] = ["Marker": marker]
            if let titleID { info["DMTitleID"] = titleID }
            return (try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)) ?? Data()
        }

        struct Info: Decodable {
            var marker: String?
            enum CodingKeys: String, CodingKey { case marker = "Marker" }
        }

        func text(_ url: URL) -> String? {
            (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))).flatMap { try? PropertyListDecoder().decode(Info.self, from: $0).marker }
        }
    }

    @Test func moveSameVolume() async throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try await s.installer().install(app: s.app, into: s.dest, mode: .move)
        #expect(out.installedURL.path == s.dest.appendingPathComponent("Super Game.app").path)
        #expect(out.replaced == nil && out.warnings == [])
        #expect(!FileManager.default.fileExists(atPath: s.app.path))
        #expect(s.text(out.installedURL) == "new")
        #expect(s.cleared.all.map(\.path) == [out.installedURL.path])
        #expect(s.trashed.all.isEmpty)
    }

    @Test func copy() async throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try await s.installer(warning: "xattr -cr failed: nope").install(app: s.app, into: s.dest, mode: .copy)
        #expect(FileManager.default.fileExists(atPath: s.app.path))
        #expect(s.text(out.installedURL) == "new")
        #expect(!FileManager.default.fileExists(atPath: s.dest.appendingPathComponent("Super Game.app.partial").path))
        #expect(out.warnings == ["xattr -cr failed: nope"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.dest.path) == ["Super Game.app"])
    }

    @Test func replaceExisting() async throws {
        for mode in [InstallMode.move, .copy] {
            let s = try Setup("replace\(mode)"); defer { s.t.remove() }
            try s.t.file("Applications/Super Game.app/Contents/Info.plist", Setup.plist("old"))
            try s.t.file("Applications/Super Game.app.partial/stale", Data("x".utf8))
            let out = try await s.installer().install(app: s.app, into: s.dest, mode: mode)
            #expect(s.text(out.installedURL) == "new")
            #expect(out.replaced?.path == s.trashDir.appendingPathComponent("Super Game.app").path)
            #expect(s.text(s.trashDir.appendingPathComponent("Super Game.app")) == "old")
            #expect(s.trashed.all.map(\.path) == [s.dest.appendingPathComponent("Super Game.app").path])
            #expect(!FileManager.default.fileExists(atPath: s.dest.appendingPathComponent("Super Game.app.partial").path) || mode == .move)
        }
    }

    @Test func trashFailureKeepsOldApp() async throws {
        for mode in [InstallMode.move, .copy] {
            let s = try Setup("trashFailure\(mode)"); defer { s.t.remove() }
            try s.t.file("Applications/Super Game.app/Contents/Info.plist", Setup.plist("old"))
            let installer = AppInstaller(trash: { _ in throw CocoaError(.fileWriteNoPermission) }, clearAttributes: { _ in nil })
            await #expect(throws: InstallError.self) { try await installer.install(app: s.app, into: s.dest, mode: mode) }
            #expect(s.text(s.dest.appendingPathComponent("Super Game.app")) == "old")
            #expect(try FileManager.default.contentsOfDirectory(atPath: s.dest.path) == ["Super Game.app"])
            #expect(s.text(s.app) == "new")   // the new app is where it was built
        }
    }

    @Test func anotherAppOfTheNameIsLeftAlone() async throws {
        for (mode, titleID) in [(InstallMode.move, nil), (.copy, nil), (.move, "0100111100000000")] {
            let s = try Setup("foreign\(mode)\(titleID ?? "")"); defer { s.t.remove() }
            try s.t.file("Applications/Super Game.app/Contents/Info.plist", Setup.plist("native", titleID: titleID))
            await #expect(throws: InstallError.foreignApp(s.dest.appendingPathComponent("Super Game.app").path)) {
                try await s.installer().install(app: s.app, into: s.dest, mode: mode)
            }
            #expect(s.text(s.dest.appendingPathComponent("Super Game.app")) == "native" && s.text(s.app) == "new")
            #expect(s.trashed.all.isEmpty && s.cleared.all.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: s.dest.path) == ["Super Game.app"])
        }
    }

    @Test func failedRenameRestores() async throws {
        for mode in [InstallMode.move, .copy] {
            let s = try Setup("failedRename\(mode)"); defer { s.t.remove() }
            try s.t.file("Applications/Super Game.app/Contents/Info.plist", Setup.plist("old"))
            let trashDir = s.trashDir
            let installer = AppInstaller(trash: { url in   // something takes the name between the Trash and the rename
                let to = trashDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: to)
                try Data("squatter".utf8).write(to: url)
                return to
            }, clearAttributes: { _ in nil })
            do {
                _ = try await installer.install(app: s.app, into: s.dest, mode: mode)
                Issue.record("installed")
            } catch let InstallError.failed(message) {
                #expect(message.contains("The previous app is in the Trash: \(trashDir.appendingPathComponent("Super Game.app").path)"))
            }
            #expect(s.text(s.app) == "new" && s.text(trashDir.appendingPathComponent("Super Game.app")) == "old")
            #expect(!FileManager.default.fileExists(atPath: s.dest.appendingPathComponent("Super Game.app.partial").path))
        }
    }

    @Test func modeNone() async throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try await s.installer(warning: "w").install(app: s.app, into: s.dest, mode: .none)
        #expect(out.installedURL.path == s.app.path && out.replaced == nil && out.warnings == ["w"])
        #expect(s.cleared.all.map(\.path) == [s.app.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.dest.path) == [])
    }

    @Test func errors() async throws {
        let s = try Setup(); defer { s.t.remove() }
        await #expect(throws: InstallError.sameLocation(s.app.path)) {
            try await s.installer().install(app: s.app, into: s.app.deletingLastPathComponent(), mode: .move)
        }
        let missing = s.t.url.appendingPathComponent("Nope.app")
        await #expect(throws: InstallError.sourceMissing(missing.path)) { try await s.installer().install(app: missing, into: s.dest, mode: .copy) }
        await #expect(throws: InstallError.sourceMissing(missing.path)) { try await s.installer().install(app: missing, into: s.dest, mode: .none) }
        #expect(s.cleared.all.isEmpty)
        let created = s.t.url.appendingPathComponent("New Folder/Apps")
        let out = try await s.installer().install(app: s.app, into: created, mode: .copy)
        #expect(out.installedURL.deletingLastPathComponent().path == created.path)
    }

    @Test func notWritable() async throws {
        let s = try Setup(); defer { s.t.remove() }
        let locked = try s.t.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        guard !FileManager.default.isWritableFile(atPath: locked.path) else { return }   // running as root
        await #expect(throws: InstallError.notWritable(locked.path)) { try await s.installer().install(app: s.app, into: locked, mode: .copy) }
    }

    @Test func volumesAndSizes() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(AppInstaller.isSameVolume(s.app, s.dest))
        #expect(AppInstaller.isSameVolume(s.app, s.dest.appendingPathComponent("not/yet/there")))
        #expect(!AppInstaller.isSameVolume(s.app, URL(fileURLWithPath: "/dev")))
        #expect(AppInstaller.allocatedSize(of: s.app) >= 20_000)
        #expect(AppInstaller.allocatedSize(of: s.t.url.appendingPathComponent("missing")) == 0)
        #expect(AppInstaller.standardDestinations().map(\.lastPathComponent) == ["Applications", "Applications"])
        #expect(AppInstaller.standardDestinations().first?.path == "/Applications")
    }
}
