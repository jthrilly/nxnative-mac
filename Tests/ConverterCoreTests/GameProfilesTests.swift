// GameProfiles: game.tsv parsing (as dm/games/game.py reads it), every profile in this repository, and how a folder matches a profile
import Foundation
import Testing
@testable import ConverterCore

struct GameProfilesTests {
    static let tsv = """
        # Game profile of a test game
        # Format: key <TAB> value

        title_id\t0100ABCD00000000
        program_id\t0100ABCD00000000
        name\tSuper Game\t(test)
          # an indented comment
        build\tv0\t1.0.0\tmain=cd6e42aee7934f4d8393cd43893ae25e\tsdk=3053b22935e32ddf15ef81997603e5c2
        build\tv327680\t1.2.1\tmain=ff773e90972d544eb79406eaa65396d5
        build\tbroken
        package\tv327680
        shader_versions\tv0 v327680\r
        modules\tmain sdk
        """

    static let profile = GameProfiles.parse(gameTSV: tsv, directory: URL(fileURLWithPath: "/repo/dm/games/0100ABCD00000000"))

    @Test func parse() throws {
        let p = try #require(Self.profile)
        #expect(p.id == "0100ABCD00000000" && p.titleID == 0x0100_ABCD_0000_0000)
        #expect(p.name == "Super Game\t(test)")
        #expect(p.builds == [ProfileBuild(version: "v0", display: "1.0.0"), ProfileBuild(version: "v327680", display: "1.2.1")])
        #expect(p.package == "v327680")
        #expect(p.shaderVersions == ["v0", "v327680"])
        #expect(p.directory.lastPathComponent == "0100ABCD00000000")
        #expect(GameProfiles.parse(gameTSV: "name\tNo title ID\n", directory: URL(fileURLWithPath: "/x")) == nil)
        #expect(GameProfiles.parse(gameTSV: "title_id\t0x0100ABCD00000000\n", directory: URL(fileURLWithPath: "/x"))?.titleID == 0x0100_ABCD_0000_0000)
        let bare = try #require(GameProfiles.parse(gameTSV: "title_id\t0100ABCD00000000", directory: URL(fileURLWithPath: "/x")))
        #expect(bare.builds.isEmpty && bare.shaderVersions.isEmpty && bare.package == nil && bare.name == "")
    }

    @Test func repositoryProfiles() throws {
        let games = repositoryRoot.appendingPathComponent("dm/games")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: games.path).filter { FileManager.default.fileExists(atPath: games.appendingPathComponent("\($0)/game.tsv").path) }
        let profiles = GameProfiles.load(repository: repositoryRoot)
        #expect(!dirs.isEmpty)
        #expect(Set(profiles.map(\.id)) == Set(dirs))
        #expect(profiles.map(\.id) == profiles.map(\.id).sorted())
        for p in profiles {
            #expect(NSPScanner.hex16(p.titleID) == p.id.uppercased() || !p.id.allSatisfy(\.isHexDigit), "\(p.id)")
            #expect(!p.builds.isEmpty, "\(p.id) has no build rows")
        }
        let mario = try #require(profiles.first { $0.id == "010015100B514000" })
        #expect(mario.builds.map(\.version) == ["v0", "v327680"] && mario.shaderVersions == ["v0", "v327680"])
        #expect(GameProfiles.load(repository: URL(fileURLWithPath: "/nonexistent")) == [])
    }

    func scan(_ versions: [Int?], app: UInt64 = 0x0100_ABCD_0000_0000) -> NSPFolderScan {
        let dir = URL(fileURLWithPath: "/g")
        let base = NSPFile(url: dir.appendingPathComponent("base.nsp"), titleID: app, version: nil, kind: .base, size: 1, compressed: false)
        let ups = versions.enumerated().map { NSPFile(url: dir.appendingPathComponent("u\($0.offset).nsp"), titleID: app | 0x800, version: $0.element, kind: .update, size: 1, compressed: false) }
        return NSPFolderScan(folder: dir, files: [base] + ups, applicationID: app, base: base, updates: ups, dlc: [], errors: [], warnings: [])
    }

    @Test func match() throws {
        let p = try #require(Self.profile)
        #expect(GameProfiles.match(scan([327680]), in: [p]) == .tested(profile: p, display: "1.2.1"))
        #expect(GameProfiles.match(scan([65536, 327680]), in: [p]) == .tested(profile: p, display: "1.2.1"))
        #expect(GameProfiles.match(scan([nil]), in: [p]) == .tested(profile: p, display: "1.2.1"))   // a single untagged update: the newest registered
        #expect(GameProfiles.match(scan([]), in: [p]) == .untestedVersion(profile: p, version: "v0", tested: p.builds))   // v327680's shaders are missing
        #expect(GameProfiles.match(scan([393216]), in: [p]) == .untestedVersion(profile: p, version: "v393216", tested: p.builds))
        #expect(GameProfiles.match(scan([nil, 65536]), in: [p]) == .untestedVersion(profile: p, version: "v65536", tested: p.builds))
        #expect(GameProfiles.match(scan([327680], app: 0x0100_1111_0000_0000), in: [p]) == .noProfile)
        var none = scan([]); none.applicationID = nil
        #expect(GameProfiles.match(none, in: [p]) == .noProfile)
        // the version chosen with -p, as the script packs it
        #expect(GameProfiles.match(scan([65536, 327680]), in: [p], package: "v65536") == .untestedVersion(profile: p, version: "v65536", tested: p.builds))
        #expect(GameProfiles.match(scan([327680, 393216]), in: [p], package: "v327680") == .tested(profile: p, display: "1.2.1"))
        #expect(GameProfiles.match(scan([327680]), in: [p], package: "v0") == .tested(profile: p, display: "1.0.0"))
        #expect(GameProfiles.match(scan([]), in: [p], package: "v0") == .untestedVersion(profile: p, version: "v0", tested: p.builds))   // v327680's shaders are missing
        #expect(GameProfiles.match(scan([327680]), in: [p], package: "v999") == .untestedVersion(profile: p, version: "v999", tested: p.builds))   // not in the folder
        #expect(GameProfiles.match(scan([327680]), in: [p], package: " ") == .tested(profile: p, display: "1.2.1"))
    }
}
