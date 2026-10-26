// The user's login-shell environment: an app started from Finder or the Dock does not get the shell's PATH, and pyenv, Homebrew and the .NET SDK are set up there.
// Children get the shell's PATH with the NSP script's TOOL_PATHS and the system folders after it. The script itself puts TOOL_PATHS in front of the PATH it gets
// (scripts/build_ipa_from_nsp.py main), so the checks of the tools it runs look them up in that order (withScriptToolPaths)
import Foundation

public struct ShellEnvironment: Sendable, Equatable {
    static let startMarker = "__NXNATIVE_CONVERTER_ENV_BEGIN__\n"
    static let endMarker = "\n__NXNATIVE_CONVERTER_ENV_END__"
    static let systemPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public var variables: [String: String]

    public init(variables: [String: String]) { self.variables = variables }

    static let toolPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/share/dotnet", NSString(string: "~/.dotnet").expandingTildeInPath]

    public static func resolve() async -> ShellEnvironment {
        let base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '%s' '\(startMarker.dropLast())'; printf '\\n'; env -0; printf '\\n%s' '\(endMarker.dropFirst())'"
        if let out = try? await Subprocess.run(shell, ["-l", "-i", "-c", script], environment: base, timeout: 15),
           let vars = parse(markedOutput: Data(out.stdout.utf8)), !vars.isEmpty {
            return ShellEnvironment(variables: vars).withToolPaths()
        }
        return ShellEnvironment(variables: base).withToolPaths()
    }

    static func parse(markedOutput: Data) -> [String: String]? {
        guard let start = markedOutput.range(of: Data(startMarker.utf8)),
              let end = markedOutput.range(of: Data(endMarker.utf8), options: .backwards, in: start.upperBound..<markedOutput.endIndex) else { return nil }
        var out: [String: String] = [:]
        for entry in markedOutput[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")), eq > entry.startIndex else { continue }
            out[String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)] = String(decoding: entry[(eq + 1)...], as: UTF8.self)
        }
        return out
    }

    func withToolPaths() -> ShellEnvironment { withPath(path + Self.toolPaths + Self.systemPaths) }

    /// The PATH the NSP script runs its tools with: TOOL_PATHS, then the PATH it was given
    func withScriptToolPaths() -> ShellEnvironment { withPath(Self.toolPaths + path) }

    private func withPath(_ order: [String]) -> ShellEnvironment {
        var dirs: [String] = []
        for d in order where !dirs.contains(d) { dirs.append(d) }
        var copy = self
        copy.variables["PATH"] = dirs.joined(separator: ":")
        return copy
    }

    public func which(_ tool: String) -> String? {
        if tool.contains("/") {
            let p = NSString(string: tool).expandingTildeInPath
            return Self.isExecutable(p) ? p : nil
        }
        return path.lazy.map { NSString(string: $0).appendingPathComponent(tool) }.first(where: Self.isExecutable)
    }

    public var path: [String] { (variables["PATH"] ?? "").split(separator: ":").map(String.init) }

    static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
