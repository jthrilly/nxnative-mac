// Prerequisites: the modules each Python needs, the pip commands for missing or broken ones, the real Python probe, the coding agents' checks (stand-in executables) and a full
// check run
import Foundation
import Testing
@testable import ConverterCore

struct PrerequisitesTests {
    let absent = "ModuleNotFoundError: No module named 'lz4'"

    @Test func requiredModules() {
        #expect(PrerequisiteChecker.requiredModules(pythonVersion: "3.13.6") == ["lz4.block", "capstone", "fontTools", "backports.zstd"])
        #expect(PrerequisiteChecker.requiredModules(pythonVersion: "3.14.0") == ["lz4.block", "capstone", "fontTools", "compression.zstd"])
        #expect(PrerequisiteChecker.requiredModules(pythonVersion: "3.15.0a1") == ["lz4.block", "capstone", "fontTools", "compression.zstd"])
        #expect(PrerequisiteChecker.requiredModules(pythonVersion: "3.9.6") == ["lz4.block", "capstone", "fontTools", "backports.zstd"])
        #expect(PrerequisiteChecker.requiredModules(pythonVersion: "") == ["lz4.block", "capstone", "fontTools", "backports.zstd"])
    }

    @Test func pipInVirtualEnv() {
        let p = PythonProbe(executable: "/v/bin/python", version: "3.13.6", modules: ["lz4.block": absent, "capstone": "ModuleNotFoundError: No module named 'capstone'",
                                                                                   "fontTools": "", "backports.zstd": "ModuleNotFoundError: No module named 'backports'", "nsz": "x"],
                            inVirtualEnv: true, externallyManaged: false)
        #expect(PrerequisiteChecker.pipCommands(for: p) == ["PYLZ4_USE_SYSTEM_LZ4=0 '/v/bin/python' -m pip install --no-binary lz4 lz4",
                                                           "'/v/bin/python' -m pip install capstone backports.zstd"])
    }

    @Test func pipExternallyManagedBrokenLZ4() {
        let p = PythonProbe(executable: "/opt/homebrew/opt/python@3.14/bin/python3.14", version: "3.14.0",
                            modules: ["lz4.block": "ImportError: dlopen(…/_block.cpython-314-darwin.so): symbol not found in flat namespace '_LZ4_compress_fast'",
                                      "capstone": "", "fontTools": "", "compression.zstd": ""], inVirtualEnv: false, externallyManaged: true)
        #expect(PrerequisiteChecker.pipCommands(for: p)
                == ["PYLZ4_USE_SYSTEM_LZ4=0 '/opt/homebrew/opt/python@3.14/bin/python3.14' -m pip install --user --break-system-packages --force-reinstall --no-binary lz4 lz4"])
    }

    @Test func pipQuoting() {
        let p = PythonProbe(executable: "/Users/a b/it's/python3", version: "3.12.1", modules: ["lz4.block": "", "capstone": "", "fontTools": ""],
                            inVirtualEnv: false, externallyManaged: false)
        #expect(PrerequisiteChecker.pipCommands(for: p) == [#"'/Users/a b/it'\''s/python3' -m pip install --user backports.zstd"#])
        #expect(PrerequisiteChecker.shellQuote("plain") == "'plain'")
    }

    @Test func pipNothingToDo() {
        let ok = PythonProbe(executable: "/usr/bin/python3", version: "3.13.0", modules: ["lz4.block": "", "capstone": "", "fontTools": "", "backports.zstd": ""],
                             inVirtualEnv: false, externallyManaged: false)
        #expect(PrerequisiteChecker.pipCommands(for: ok) == [])
        let noZstd = PythonProbe(executable: "/usr/bin/python3", version: "3.14.0",   // compression.zstd needs a Python built with it: no pip fix
                                 modules: ["lz4.block": "", "capstone": "", "fontTools": "", "compression.zstd": "ModuleNotFoundError: No module named '_zstd'"],
                                 inVirtualEnv: false, externallyManaged: false)
        #expect(PrerequisiteChecker.pipCommands(for: noZstd) == [])
    }

    @Test func probeRealPython() async throws {
        let env = ShellEnvironment(variables: ProcessInfo.processInfo.environment).withToolPaths()
        let checker = PrerequisiteChecker(environment: env, python: "python3", repository: repositoryRoot, keys: nil)
        let p = try #require(await checker.probePython())
        #expect(p.version.split(separator: ".").count >= 2 && p.version.hasPrefix("3."))
        #expect(p.executable.hasPrefix("/"))
        #expect(Set(p.modules.keys).isSuperset(of: PrerequisiteChecker.requiredModules(pythonVersion: p.version)))
        let missing = PrerequisiteChecker(environment: env, python: "/nonexistent/python3", repository: repositoryRoot, keys: nil)
        #expect(await missing.probePython() == nil)
    }

    @Test func checkAll() async throws {
        let t = try TempDir(); defer { t.remove() }
        let keys = try t.file("prod.keys", Data("header_key = 00\n".utf8))
        var env = ShellEnvironment(variables: ProcessInfo.processInfo.environment).withToolPaths()
        let bin = try fakeAgents(t, signedIn: false)   // never the real claude or codex
        env.variables["PATH"] = bin.path + ":" + (env.variables["PATH"] ?? "")
        let checks = await PrerequisiteChecker(environment: env, python: "python3", repository: repositoryRoot, keys: keys).checkAll()
        #expect(checks.map(\.id) == PrerequisiteID.allCases)
        #expect(checks.allSatisfy { !$0.title.isEmpty })
        #expect(checks.first { $0.id == .repository }?.state == .ok)
        #expect(checks.first { $0.id == .keys }?.state == .ok)
        #expect(checks.first { $0.id == .python }?.state == .ok)
        #expect(checks.filter { $0.state == .ok }.allSatisfy { $0.fixes.isEmpty })
        #expect(checks.first { $0.id == .glslang }?.required == false && checks.first { $0.id == .nsz }?.required == false)
        #expect(checks.filter { $0.id == .claudeCode || $0.id == .codex }.map(\.required) == [false, false])
        #expect(checks.first { $0.id == .codex }?.detail == "codex-cli 0.145.0, not signed in")

        let empty = try t.file("empty.keys", Data())
        let bad = await PrerequisiteChecker(environment: env, python: "python3", repository: t.url.appendingPathComponent("missing"), keys: empty).checkAll()
        let repo = try #require(bad.first { $0.id == .repository })
        #expect(repo.state == .missing)
        #expect(repo.fixes.contains(.chooseFolder(title: "Choose the nxnative Folder…")))
        #expect(repo.fixes.contains { if case let .run(_, cmd) = $0 { cmd.hasPrefix("git clone --progress https://github.com/seedds/nxnative.git '") } else { false } })
        #expect(bad.first { $0.id == .keys }?.state == .missing)
        #expect(bad.first { $0.id == .keys }?.fixes == [.chooseFile(title: "Choose prod.keys…")])
    }

    /// claude and codex stand-ins answering --version and the sign-in check as the real ones do
    func fakeAgents(_ t: TempDir, signedIn: Bool) throws -> URL {
        let bin = try t.sub(signedIn ? "bin-in" : "bin-out")
        let claude = """
            #!/bin/sh
            case "$1" in
              --version) echo '2.1.310 (Claude Code)' ;;
              auth) echo '{"loggedIn": \(signedIn), "authMethod": "claude.ai"}'; exit \(signedIn ? 0 : 1) ;;
              *) exit 2 ;;
            esac
            """
        let codex = """
            #!/bin/sh
            case "$1" in
              --version) echo 'codex-cli 0.145.0' ;;
              login) \(signedIn ? "echo 'Logged in using ChatGPT' >&2" : "echo 'Not logged in' >&2; exit 1") ;;
              *) exit 2 ;;
            esac
            """
        for (name, text) in [("claude", claude), ("codex", codex)] {
            let u = try t.file("\(bin.lastPathComponent)/\(name)", Data((text + "\n").utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        return bin
    }

    func checkAgent(_ kind: AgentKind, path: String, brew: Bool = true, home: String = "/nonexistent", executables: [AgentKind: String] = [:]) async -> PrerequisiteCheck {
        let id: PrerequisiteID = kind == .claudeCode ? .claudeCode : .codex
        let checker = PrerequisiteChecker(environment: ShellEnvironment(variables: ["PATH": path, "HOME": home]), python: "python3", repository: repositoryRoot,
                                          keys: nil, agentExecutables: executables)
        return await checker.checkAgent(kind, brew: brew) { state, detail, fixes in
            PrerequisiteCheck(id: id, title: PrerequisiteChecker.title(id), state: state, detail: detail, required: false, fixes: state == .ok ? [] : fixes)
        }
    }

    @Test func agentSignedIn() async throws {
        let t = try TempDir(); defer { t.remove() }
        let bin = try fakeAgents(t, signedIn: true)
        let claude = await checkAgent(.claudeCode, path: bin.path), codex = await checkAgent(.codex, path: bin.path)
        #expect(claude.state == .ok && claude.detail == "2.1.310 (Claude Code), signed in" && claude.fixes.isEmpty)
        #expect(codex.state == .ok && codex.detail == "codex-cli 0.145.0, signed in")
    }

    @Test func agentNotSignedIn() async throws {
        let t = try TempDir(); defer { t.remove() }
        let bin = try fakeAgents(t, signedIn: false)
        let claude = await checkAgent(.claudeCode, path: bin.path), codex = await checkAgent(.codex, path: bin.path)
        #expect(claude.state == .warning && claude.detail == "2.1.310 (Claude Code), not signed in")
        #expect(claude.fixes.first == .terminal(title: "Sign In to Claude Code", shellCommand: "claude auth login"))
        #expect(codex.state == .warning && codex.fixes.first == .terminal(title: "Sign In to Codex", shellCommand: "codex login"))
        #expect(codex.fixes.contains { if case .openURL = $0 { true } else { false } })
    }

    @Test func agentWhereTheAppFindsIt() async throws {
        let t = try TempDir(); defer { t.remove() }
        let empty = try t.sub("empty"), bin = try fakeAgents(t, signedIn: true)
        let configured = await checkAgent(.claudeCode, path: empty.path, executables: [.claudeCode: bin.appendingPathComponent("claude").path])   // Settings › Agents
        #expect(configured.state == .ok && configured.detail == "2.1.310 (Claude Code), signed in")
        let home = try t.sub("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin"), withDestinationURL: bin)   // the installer's folder, not on the PATH
        #expect(await checkAgent(.codex, path: empty.path, home: home.path).state == .ok)
        let gone = await checkAgent(.claudeCode, path: bin.path, executables: [.claudeCode: t.url.appendingPathComponent("nothing/claude").path])
        #expect(gone.detail.hasPrefix("Not installed"))   // the configured one is what the app runs, even with another on the PATH
    }

    @Test func probeRunsInTheRepository() async throws {
        let t = try TempDir(); defer { t.remove() }
        let repo = try t.sub("nxnative")
        let python = try t.file("bin/python3", Data("""
            #!/bin/sh
            printf '{"executable": "%s", "version": "3.13.6", "modules": {}, "venv": false, "externally_managed": false}\\n' "$(pwd -P)"
            """.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let env = ShellEnvironment(variables: ["PATH": "/usr/bin:/bin"])
        let p = await PrerequisiteChecker(environment: env, python: python.path, repository: repo, keys: nil).probePython()
        #expect(p?.executable == repo.path)   // where a pyenv shim looks for .python-version, as for a conversion
        let none = await PrerequisiteChecker(environment: env, python: python.path, repository: t.url.appendingPathComponent("missing"), keys: nil).probePython()
        #expect(none?.executable == "/")
    }

    @Test func toolsInTheScriptsOrder() {
        let checker = PrerequisiteChecker(environment: ShellEnvironment(variables: ["PATH": "/Users/x/bin:/usr/bin"]), python: "python3", repository: repositoryRoot, keys: nil)
        #expect(Array(checker.tools.path.prefix(ShellEnvironment.toolPaths.count + 1)) == ShellEnvironment.toolPaths + ["/Users/x/bin"])
    }

    @Test func agentMissing() async throws {
        let t = try TempDir(); defer { t.remove() }
        let empty = try t.sub("empty")
        let claude = await checkAgent(.claudeCode, path: empty.path), codex = await checkAgent(.codex, path: empty.path)
        #expect(claude.state == .warning && claude.detail == "Not installed: only porting a game with Claude Code needs it")
        #expect(claude.fixes.first == .terminal(title: "Install Claude Code", shellCommand: "curl -fsSL https://claude.ai/install.sh | bash"))
        #expect(codex.fixes.first == .run(title: "Install Codex", shellCommand: "brew install --cask codex"))
        let noBrew = await checkAgent(.codex, path: empty.path, brew: false)
        #expect(noBrew.fixes.count == 1 && noBrew.fixes.allSatisfy { if case .openURL = $0 { true } else { false } })
    }
}
