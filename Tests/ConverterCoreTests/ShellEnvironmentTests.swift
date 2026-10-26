// ShellEnvironment: the marked `env -0` output, PATH handling and the login shell itself
import Foundation
import Testing
@testable import ConverterCore

struct ShellEnvironmentTests {
    @Test func parseMarked() {
        var d = Data("Last login: today\nwelcome banner\n".utf8)
        d.append(Data(ShellEnvironment.startMarker.utf8))
        d.append(Data("PATH=/opt/homebrew/bin:/usr/bin\0MULTI=one\ntwo\0EQ=a=b\0EMPTY=\0=nokey\0junk\0".utf8))
        d.append(Data(ShellEnvironment.endMarker.utf8))
        d.append(Data("\nbye\n".utf8))
        let v = ShellEnvironment.parse(markedOutput: d)
        #expect(v == ["PATH": "/opt/homebrew/bin:/usr/bin", "MULTI": "one\ntwo", "EQ": "a=b", "EMPTY": ""])
    }

    @Test func parseNeedsBothMarkers() {
        #expect(ShellEnvironment.parse(markedOutput: Data("PATH=/usr/bin\0".utf8)) == nil)
        #expect(ShellEnvironment.parse(markedOutput: Data((ShellEnvironment.startMarker + "PATH=/usr/bin\0").utf8)) == nil)
        #expect(ShellEnvironment.parse(markedOutput: Data(("PATH=/usr/bin\0" + ShellEnvironment.endMarker).utf8)) == nil)
        #expect(ShellEnvironment.parse(markedOutput: Data((ShellEnvironment.startMarker + ShellEnvironment.endMarker).utf8)) == [:])
    }

    @Test func toolPaths() {
        let env = ShellEnvironment(variables: ["PATH": "/Users/x/.pyenv/shims:/usr/bin:/opt/homebrew/bin"]).withToolPaths()
        #expect(env.path.prefix(3) == ["/Users/x/.pyenv/shims", "/usr/bin", "/opt/homebrew/bin"])
        #expect(env.path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        for p in ShellEnvironment.toolPaths + ["/bin", "/usr/sbin", "/sbin"] { #expect(env.path.contains(p)) }
        #expect(ShellEnvironment.toolPaths.last?.hasSuffix("/.dotnet") == true && ShellEnvironment.toolPaths.last?.hasPrefix("/") == true)
        #expect(ShellEnvironment(variables: [:]).withToolPaths().path.contains("/usr/bin"))
    }

    @Test func scriptToolPaths() {   // build_ipa_from_nsp.py: PATH = TOOL_PATHS + the PATH it is given
        let env = ShellEnvironment(variables: ["PATH": "/Users/x/.dotnet-10:/usr/bin:/opt/homebrew/bin"]).withToolPaths().withScriptToolPaths()
        #expect(Array(env.path.prefix(ShellEnvironment.toolPaths.count)) == ShellEnvironment.toolPaths)
        #expect(Array(env.path.dropFirst(ShellEnvironment.toolPaths.count).prefix(2)) == ["/Users/x/.dotnet-10", "/usr/bin"])
        #expect(Set(env.path).count == env.path.count)
    }

    @Test(.enabled(if: nxnativeCheckout != nil, "NXNATIVE_REPO names no nxnative checkout")) func toolPathsMatchTheScript() throws {
        let text = try String(contentsOf: try #require(nxnativeCheckout).appendingPathComponent("scripts/build_ipa_from_nsp.py"), encoding: .utf8)
        #expect(text.contains("TOOL_PATHS = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/local/share/dotnet', os.path.expanduser('~/.dotnet')]"))
        #expect(text.contains("PATH=os.pathsep.join(TOOL_PATHS + ["))   // in front of the PATH the script gets
    }

    @Test func which() throws {
        let t = try TempDir(); defer { t.remove() }
        let tool = try t.file("bin/mytool", Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try t.file("bin2/mytool", Data("not executable".utf8))
        _ = try t.sub("bin3/mytool")   // a folder
        let env = ShellEnvironment(variables: ["PATH": [t.url.path + "/bin3", t.url.path + "/bin2", t.url.path + "/bin", "/bin"].joined(separator: ":")])
        #expect(env.which("mytool") == tool.path)
        #expect(env.which("sh") == "/bin/sh")
        #expect(env.which("no-such-tool-here") == nil)
        #expect(env.which(tool.path) == tool.path)
        #expect(env.which(t.url.path + "/bin2/mytool") == nil)
    }

    @Test func resolve() async {
        let env = await ShellEnvironment.resolve()
        #expect(env.path.contains("/usr/bin"))
        #expect(env.which("sh") != nil)
    }
}
