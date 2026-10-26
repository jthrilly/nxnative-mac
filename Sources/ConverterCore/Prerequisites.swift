// What a conversion needs on this Mac (the tools the NSP script's check_prereqs and TOOL_PATHS look for, the AppleGamingWiki guide's requirements), each with the fixes the
// Setup view offers. Python modules are installed the way the guide does it: lz4 built from source with its own copy of liblz4 (a wheel linking Homebrew's fails with
// "symbol not found … LZ4"), --user outside a virtual environment, --break-system-packages for an externally managed Python. Tools are looked up in the order the script
// looks them up (ShellEnvironment.withScriptToolPaths), and Python runs in the repository folder, as for a conversion (a pyenv shim picks its version by the folder)
import Foundation

public enum PrerequisiteID: String, Sendable, CaseIterable, Codable {
    case appleSilicon, xcode, metalToolchain, homebrew, git, brewTools, glslang, dotnet, python, pythonModules, nsz, repository, keys, claudeCode, codex
}

public enum PrerequisiteState: Sendable, Equatable { case ok, missing, warning, unknown }

public enum FixAction: Sendable, Equatable {
    case run(title: String, shellCommand: String)
    case terminal(title: String, shellCommand: String)
    case admin(title: String, shellCommand: String)
    case openURL(title: String, url: URL)
    case chooseFile(title: String)
    case chooseFolder(title: String)
}

public struct PrerequisiteCheck: Sendable, Equatable, Identifiable {
    public var id: PrerequisiteID; public var title: String; public var state: PrerequisiteState; public var detail: String
    public var required: Bool; public var fixes: [FixAction]
}

public struct PythonProbe: Sendable, Equatable, Codable {
    public var executable: String; public var version: String
    public var modules: [String: String]
    public var inVirtualEnv: Bool; public var externallyManaged: Bool
}

public struct PrerequisiteChecker: Sendable {
    static let timeout: TimeInterval = 30
    static let probeTimeout: TimeInterval = 90   // the first import of fontTools compiles its modules
    static let probeScript = """
        import contextlib, importlib, io, json, os, platform, sys, sysconfig
        mods = ['lz4.block', 'capstone', 'fontTools', 'compression.zstd' if sys.version_info >= (3, 14) else 'backports.zstd', 'nsz']
        res = {}
        for m in mods:
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()): importlib.import_module(m)
                res[m] = ''
            except BaseException as e: res[m] = f'{type(e).__name__}: {e}'
        print(json.dumps({'executable': sys.executable, 'version': platform.python_version(), 'modules': res, 'venv': sys.prefix != sys.base_prefix,
                          'externally_managed': os.path.exists(os.path.join(sysconfig.get_path('stdlib'), 'EXTERNALLY-MANAGED'))}))
        """

    public var environment: ShellEnvironment; public var python: String; public var repository: URL; public var keys: URL?
    public var agentExecutables: [AgentKind: String]   // the agents the app runs (Settings › Agents); the others are looked for on the PATH and in ~/.local/bin
    var tools: ShellEnvironment { environment.withScriptToolPaths() }

    public init(environment: ShellEnvironment, python: String, repository: URL, keys: URL?, agentExecutables: [AgentKind: String] = [:]) {
        self.environment = environment; self.python = python; self.repository = repository; self.keys = keys; self.agentExecutables = agentExecutables
    }

    public func checkAll() async -> [PrerequisiteCheck] {
        let probe = Task { await probePython() }
        let results = await withTaskGroup(of: PrerequisiteCheck.self) { group in
            for id in PrerequisiteID.allCases { group.addTask { await check(id, probe: probe) } }
            var out: [PrerequisiteID: PrerequisiteCheck] = [:]
            for await c in group { out[c.id] = c }
            return out
        }
        return PrerequisiteID.allCases.map { results[$0] ?? PrerequisiteCheck(id: $0, title: Self.title($0), state: .unknown, detail: "", required: false, fixes: []) }
    }

    func probePython() async -> PythonProbe? {
        var isDir: ObjCBool = false
        let dir = FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDir) && isDir.boolValue ? repository : URL(fileURLWithPath: "/")
        guard let r = try? await Subprocess.run(python, ["-c", Self.probeScript], environment: environment.variables, currentDirectory: dir, timeout: Self.probeTimeout), r.succeeded,
              let line = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else { return nil }
        struct Raw: Decodable { let executable: String; let version: String; let modules: [String: String]; let venv: Bool; let externally_managed: Bool }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else { return nil }
        return PythonProbe(executable: raw.executable, version: raw.version, modules: raw.modules, inVirtualEnv: raw.venv, externallyManaged: raw.externally_managed)
    }

    static func pipCommands(for probe: PythonProbe) -> [String] {
        let need = requiredModules(pythonVersion: probe.version).filter { probe.modules[$0] != "" }
        var out: [String] = []
        if need.contains("lz4.block") {
            let broken = !isAbsent(probe.modules["lz4.block"], package: "lz4")
            out.append("PYLZ4_USE_SYSTEM_LZ4=0 " + pipInstall(probe, (broken ? ["--force-reinstall"] : []) + ["--no-binary", "lz4", "lz4"]))
        }
        let packages = need.compactMap { ["capstone": "capstone", "fontTools": "fonttools", "backports.zstd": "backports.zstd"][$0] }
        if !packages.isEmpty { out.append(pipInstall(probe, packages)) }
        return out
    }

    static func requiredModules(pythonVersion: String) -> [String] {
        let v = pythonVersion.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let zstdBuiltIn = v.count >= 2 && (v[0], v[1]) >= (3, 14)   // compression.zstd is in the standard library from Python 3.14
        return ["lz4.block", "capstone", "fontTools", zstdBuiltIn ? "compression.zstd" : "backports.zstd"]
    }

    static func pipInstall(_ probe: PythonProbe, _ args: [String]) -> String {
        let flags = (probe.inVirtualEnv ? [] : ["--user"]) + (probe.externallyManaged ? ["--break-system-packages"] : [])
        return ([shellQuote(probe.executable), "-m", "pip", "install"] + flags + args).joined(separator: " ")
    }

    // A module that is not installed at all, as opposed to one that is there and fails to import (a broken build)
    static func isAbsent(_ error: String?, package: String) -> Bool {
        guard let error else { return true }
        return error.hasPrefix("ModuleNotFoundError: No module named '\(package)'")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func title(_ id: PrerequisiteID) -> String {
        switch id {
        case .appleSilicon: return "Apple silicon"
        case .xcode: return "Xcode"
        case .metalToolchain: return "Metal Toolchain"
        case .homebrew: return "Homebrew"
        case .git: return "Git"
        case .brewTools: return "zstd and SPIRV-Cross"
        case .glslang: return "glslang (OpenGL games)"
        case .dotnet: return ".NET SDK 10"
        case .python: return "Python 3"
        case .pythonModules: return "Python modules"
        case .nsz: return "nsz (NSZ / XCZ files)"
        case .repository: return "nxnative repository"
        case .keys: return "prod.keys"
        case .claudeCode: return "Claude Code (ports)"
        case .codex: return "Codex (ports)"
        }
    }

    // ---- the checks ----

    func check(_ id: PrerequisiteID, probe: Task<PythonProbe?, Never>) async -> PrerequisiteCheck {
        var c = PrerequisiteCheck(id: id, title: Self.title(id), state: .unknown, detail: "", required: true, fixes: [])
        func result(_ state: PrerequisiteState, _ detail: String, _ fixes: [FixAction] = []) -> PrerequisiteCheck {
            c.state = state; c.detail = detail; c.fixes = state == .ok ? [] : fixes; return c
        }
        let tools = tools, brew = tools.which("brew") != nil
        switch id {
        case .appleSilicon:
            var value: Int32 = 0, size = MemoryLayout<Int32>.size
            let arm = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
            return arm ? result(.ok, "This Mac runs the game's arm64 code natively") : result(.missing, "A Mac app of a game needs a Mac with Apple silicon; this Mac has an Intel processor")
        case .xcode: return await checkXcode(result)
        case .metalToolchain:
            let r = await run("xcrun", ["-sdk", "macosx", "metal", "--version"])
            if let r, r.succeeded { return result(.ok, firstLine(r.stdout + "\n" + r.stderr)) }
            return result(.missing, "The Metal compiler does not run" + (r.map { ": " + lastLine($0.stderr) } ?? ""),
                          [.run(title: "Install the Metal Toolchain", shellCommand: "xcodebuild -downloadComponent MetalToolchain")])
        case .homebrew:
            c.required = false
            guard brew, let r = await run("brew", ["--version"]), r.succeeded else {
                return result(.missing, "Homebrew installs the tools below", [.terminal(title: "Install Homebrew", shellCommand: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)])
            }
            return result(.ok, firstLine(r.stdout))
        case .git:
            guard tools.which("git") != nil, let r = await run("git", ["--version"]), r.succeeded else {
                return result(.missing, "git is not installed", brew ? [.run(title: "Install git", shellCommand: "brew install git")] : [])
            }
            return result(.ok, firstLine(r.stdout))
        case .brewTools:
            let missing = ["zstd", "spirv-cross"].filter { tools.which($0) == nil }
            if missing.isEmpty { return result(.ok, "zstd, spirv-cross") }
            return result(.missing, "Not found: " + missing.joined(separator: ", "), [.run(title: "Install " + missing.joined(separator: " and "), shellCommand: "brew install " + missing.joined(separator: " "))])
        case .glslang:
            c.required = false
            if let p = tools.which("glslangValidator") { return result(.ok, p) }
            return result(.warning, "Only OpenGL games need glslangValidator", [.run(title: "Install glslang", shellCommand: "brew install glslang")])
        case .dotnet:
            guard tools.which("dotnet") != nil, let r = await run("dotnet", ["--list-sdks"]) else {
                return result(.missing, ".NET is not installed", [.terminal(title: "Install the .NET SDK", shellCommand: "brew install --cask dotnet-sdk")])
            }
            let sdks = r.stdout.split(separator: "\n").map { String($0.prefix { $0 != " " }) }.filter { !$0.isEmpty }
            if let v = sdks.last(where: { $0.hasPrefix("10.") }) { return result(.ok, ".NET SDK " + v) }
            return sdks.isEmpty ? result(.missing, "No .NET SDK is installed", [.terminal(title: "Install the .NET SDK", shellCommand: "brew install --cask dotnet-sdk")])
                : result(.missing, "The installed .NET SDKs (\(sdks.joined(separator: ", "))) are older than 10", [.terminal(title: "Update the .NET SDK", shellCommand: "brew upgrade --cask dotnet-sdk")])
        case .python:
            guard let p = await probe.value else {
                return result(.missing, "\(python) does not run", Self.urlFix("Download Python", "https://www.python.org/downloads/macos/"))
            }
            let v = p.version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            let ok = v.count >= 2 && (v[0], v[1]) >= (3, 9)
            return result(ok ? .ok : .missing, "Python \(p.version) (\(p.executable))" + (ok ? "" : ": the script needs Python 3.9 or later"),
                          Self.urlFix("Download Python", "https://www.python.org/downloads/macos/"))
        case .pythonModules:
            guard let p = await probe.value else { return result(.unknown, "Python does not run") }
            let bad = Self.requiredModules(pythonVersion: p.version).filter { p.modules[$0] != "" }
            if bad.isEmpty { return result(.ok, Self.requiredModules(pythonVersion: p.version).joined(separator: ", ")) }
            let detail = bad.map { m in p.modules[m].map { "\(m): \($0)" } ?? m }.joined(separator: "\n")
            return result(.missing, detail, Self.pipCommands(for: p).map { .run(title: $0.hasPrefix("PYLZ4") ? "Install lz4" : "Install the Python modules", shellCommand: $0) })
        case .nsz:
            c.required = false
            guard let p = await probe.value else { return result(.unknown, "Python does not run") }
            if p.modules["nsz"] == "" { return result(.ok, "NSZ and XCZ files can be converted") }
            return result(.warning, "Only NSZ and XCZ files need nsz", [.run(title: "Install nsz", shellCommand: Self.pipInstall(p, ["nsz"]))])
        case .repository:
            let fm = FileManager.default
            let isNX = ["scripts/build_ipa_from_nsp.py", "dm/tools/nx_extract/Program.cs"].allSatisfy { fm.fileExists(atPath: repository.appendingPathComponent($0).path) }
            let choose = FixAction.chooseFolder(title: "Choose the nxnative Folder…")
            if isNX {
                guard let support = ScriptSupport(repository: repository) else { return result(.missing, "\(repository.path)\nIts NSP script cannot be read", [choose]) }
                if !support.missing.isEmpty {
                    return result(.missing, "\(repository.path)\nIts NSP script is older than this app: it has no \(support.missing.joined(separator: " or ")). "
                                  + "Update nxnative, or choose a newer checkout.", [choose])
                }
                if !support.ignoreSettings {
                    return result(.warning, "\(repository.path)\nIts NSP script has no --ignore-settings, so the Settings block at the top of the script applies to "
                                  + "the app's builds too. A newer nxnative has it.")
                }
                return result(.ok, repository.path)
            }
            let exists = fm.fileExists(atPath: repository.path)
            let clone = FixAction.run(title: "Download nxnative", shellCommand: "git clone --progress \(GitRepository.defaultRemote) " + Self.shellQuote(repository.path))
            return result(.missing, exists ? "\(repository.path) is not an nxnative checkout" : "\(repository.path) does not exist", [choose] + (exists ? [] : [clone]))
        case .keys:
            let size = keys.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) }
            if let keys, size?.isRegularFile == true, (size?.fileSize ?? 0) > 0 { return result(.ok, keys.path) }
            return result(.missing, keys.map { "\($0.path) is missing or empty" } ?? "No prod.keys file is chosen", [.chooseFile(title: "Choose prod.keys…")])
        case .claudeCode, .codex:
            c.required = false
            return await checkAgent(id == .claudeCode ? .claudeCode : .codex, brew: brew, result)
        }
    }

    /// An agent for ports: the one the app runs, else the one on the PATH or where its installer puts it (~/.local/bin); its version and whether it is signed in
    /// (claude auth status prints JSON with "loggedIn"; only that is read from it)
    func checkAgent(_ kind: AgentKind, brew: Bool, _ result: (PrerequisiteState, String, [FixAction]) -> PrerequisiteCheck) async -> PrerequisiteCheck {
        let claude = kind == .claudeCode
        let site = Self.urlFix("About \(kind.displayName)", claude ? "https://claude.com/claude-code" : "https://developers.openai.com/codex/cli")
        let install: [FixAction] = claude ? [.terminal(title: "Install Claude Code", shellCommand: "curl -fsSL https://claude.ai/install.sh | bash")]
            : brew ? [.run(title: "Install Codex", shellCommand: "brew install --cask codex")] : []
        let env = AgentCommand.childEnvironment(environment.variables, kind: kind)
        guard let exe = agentExecutable(kind), let v = try? await Subprocess.run(exe, ["--version"], environment: env, timeout: Self.timeout), v.succeeded else {
            return result(.warning, "Not installed: only porting a game with \(kind.displayName) needs it", install + site)
        }
        let version = firstLine(v.stdout)
        let signedIn: Bool
        if claude {
            let r = try? await Subprocess.run(exe, ["auth", "status"], environment: env, timeout: Self.timeout)
            let json = r.flatMap { try? JSONSerialization.jsonObject(with: Data($0.stdout.utf8)) } as? [String: Any]
            signedIn = json?["loggedIn"] as? Bool == true
        } else {
            let r = try? await Subprocess.run(exe, ["login", "status"], environment: env, timeout: Self.timeout)
            signedIn = r.map { $0.succeeded && ($0.stdout + "\n" + $0.stderr).contains("Logged in") } == true
        }
        if signedIn { return result(.ok, version + ", signed in", []) }
        let signIn = FixAction.terminal(title: "Sign In to \(kind.displayName)", shellCommand: claude ? "claude auth login" : "codex login")
        return result(.warning, version + ", not signed in", [signIn] + site)
    }

    func agentExecutable(_ kind: AgentKind) -> String? {
        if let configured = agentExecutables[kind] { return configured }
        if let found = environment.which(kind.executableName) { return found }
        let home = environment.variables["HOME"] ?? NSHomeDirectory()
        let local = NSString(string: home).appendingPathComponent(".local/bin/\(kind.executableName)")
        return ShellEnvironment.isExecutable(local) ? local : nil
    }

    private func checkXcode(_ result: (PrerequisiteState, String, [FixAction]) -> PrerequisiteCheck) async -> PrerequisiteCheck {
        let store = Self.urlFix("Get Xcode from the App Store", "macappstore://apps.apple.com/app/id497799835")
        let select: [FixAction] = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            ? [.admin(title: "Use /Applications/Xcode.app", shellCommand: "xcode-select -s /Applications/Xcode.app/Contents/Developer")] : []
        guard let sel = await run("xcode-select", ["-p"]), sel.succeeded else { return result(.missing, "Xcode is not installed", store + select) }
        let dir = sel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir.contains("CommandLineTools") { return result(.missing, "The developer folder is the Command Line Tools (\(dir)), not Xcode", select.isEmpty ? store : select) }
        guard let r = await run("xcodebuild", ["-version"]) else { return result(.missing, "xcodebuild does not run", store) }
        if !r.succeeded {
            let text = r.stdout + "\n" + r.stderr
            if text.lowercased().contains("license") {
                return result(.missing, "The Xcode license is not accepted", [.admin(title: "Accept the Xcode License", shellCommand: "xcodebuild -license accept")])
            }
            return result(.missing, lastLine(r.stderr), store + select)
        }
        return result(.ok, r.stdout.split(separator: "\n").map(String.init).joined(separator: ", ") + " (\(dir))", [])
    }

    private func run(_ tool: String, _ args: [String]) async -> ProcessOutput? {
        try? await Subprocess.run(tool, args, environment: tools.variables, timeout: Self.timeout)
    }

    private func firstLine(_ s: String) -> String { s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
    private func lastLine(_ s: String) -> String { s.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }

    static func urlFix(_ title: String, _ url: String) -> [FixAction] { URL(string: url).map { [.openURL(title: title, url: $0)] } ?? [] }
}
