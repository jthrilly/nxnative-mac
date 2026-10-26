// Helpers shared by the ConverterCore tests: temporary folders, synthesized PFS0 files, the repository root, a thread-safe collector
import Foundation
@testable import ConverterCore

/// A fresh folder under CONVERTER_TEST_TMPDIR, else the temporary directory, removed by remove(); its path has no symbolic links (/var is /private/var)
struct TempDir {
    let url: URL

    init(_ name: String = #function) throws {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let root = ProcessInfo.processInfo.environment["CONVERTER_TEST_TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("ConverterCoreTests-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let real = realpath(dir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        url = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func sub(_ path: String) throws -> URL {
        let u = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ path: String, _ data: Data = Data("x".utf8)) throws -> URL {
        let u = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }
}

/// A PFS0 holding the given file names (each with a few bytes of data), as an NSP's header lays them out
func pfs0(_ names: [String]) -> Data {
    var table = Data(), offsets: [UInt32] = []
    for n in names { offsets.append(UInt32(table.count)); table.append(contentsOf: Array(n.utf8) + [0]) }
    while table.count % 0x20 != 0 { table.append(0) }
    var d = Data("PFS0".utf8)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    u32(UInt32(names.count)); u32(UInt32(table.count)); u32(0)
    for (i, o) in offsets.enumerated() { u64(UInt64(i * 16)); u64(16); u32(o); u32(0) }
    d.append(table)
    d.append(Data(repeating: 0xAB, count: names.count * 16))
    return d
}

func ticket(_ tid: UInt64) -> String { NSPScanner.hex16(tid) + "0000000000000000.tik" }

/// The repository this test file is in: <repo>/dm/mac/converter/Tests/ConverterCoreTests/TestSupport.swift
let repositoryRoot: URL = {
    var u = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { u = u.deletingLastPathComponent() }
    return u
}()

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}
