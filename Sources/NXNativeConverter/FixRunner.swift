// The Setup page's fixes: a shell command run in the app (output in the console), one that needs a password or a terminal (a .command file opened in
// Terminal), one that needs administrator rights (osascript), a web page, or a file/folder panel. The checks run again afterwards
import AppKit
import ConverterCore
import Foundation

extension FixAction {
    var title: String {
        switch self {
        case .run(let t, _), .terminal(let t, _), .admin(let t, _), .openURL(let t, _), .chooseFile(let t), .chooseFolder(let t): return t
        }
    }
    var symbol: String {
        switch self {
        case .run: return "play"
        case .terminal: return "apple.terminal"
        case .admin: return "lock"
        case .openURL: return "arrow.up.forward.app"
        case .chooseFile: return "doc"
        case .chooseFolder: return "folder"
        }
    }
    var help: String {
        switch self {
        case .run(_, let c): return "Runs: \(c)"
        case .terminal(_, let c): return "Opens Terminal to run: \(c)"
        case .admin(_, let c): return "Asks for an administrator password to run: \(c)"
        case .openURL(_, let u): return "Opens \(u.absoluteString)"
        case .chooseFile, .chooseFolder: return "Opens a panel"
        }
    }
    var isRunInApp: Bool { if case .run = self { return true } else { return false } }
}

extension AppModel {
    func perform(_ fix: FixAction) async {
        switch fix {
        case .run(let title, let command):
            await operate(title, { [self] in _ = await runShell(command) })
            await recheck()
        case .terminal(let title, let command):
            openInTerminal(title: title, command: command)
        case .admin(let title, let command):
            await operate(title, { [self] in
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                _ = await console.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
                                      environment: environment?.variables ?? [:], shown: "(administrator) " + command)
            })
            await recheck()
        case .openURL(_, let url):
            NSWorkspace.shared.open(url)
        case .chooseFile:
            chooseKeysFile()
        case .chooseFolder:
            chooseRepositoryFolder()
        }
    }

    /// Setup › Install Missing: every in-app fix of the failed required checks, in order, stopping at the first that fails
    func installMissing() async {
        let commands = checks.filter { $0.required && $0.state == .missing }.flatMap(\.fixes).compactMap { fix -> String? in
            if case .run(_, let c) = fix { return c } else { return nil }
        }
        guard !commands.isEmpty else { return }
        await operate("Installing what is missing", { [self] in
            for c in commands {
                guard !Task.isCancelled else { break }
                guard await runShell(c) == 0 else { console.append(Task.isCancelled ? "Stopped." : "Stopped: the command above failed.", .error); break }
            }
        })
        await recheck()
    }

    var missingRunFixes: Int {
        checks.filter { $0.required && $0.state == .missing }.flatMap(\.fixes).filter(\.isRunInApp).count
    }

    private func runShell(_ command: String) async -> Int32 {
        let fm = FileManager.default
        let repo = settings.repositoryURL
        let cwd = fm.fileExists(atPath: repo.path) ? repo : fm.homeDirectoryForCurrentUser
        return await console.run("/bin/zsh", ["-c", command], environment: environment?.variables ?? [:], currentDirectory: cwd, shown: command)
    }

    private func openInTerminal(title: String, command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-\(UUID().uuidString.prefix(8)).command")
        let text = AppScripts.setupFix(title: title, command: command)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            alert = AlertItem(title: "The Terminal script could not be written", message: error.localizedDescription)
            return
        }
        console.append("Opened in Terminal: \(command)", .command)
        console.append("When it has finished, come back here: the checks run again.", .note)
        recheckWhenActive = true
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    func chooseKeysFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose prod.keys"
        panel.message = "Choose the prod.keys file dumped from your Switch."
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let keys = settings.keysURL { panel.directoryURL = keys.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { settings.keysPath = url.path }
    }

    func chooseRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the nxnative Folder"
        panel.message = "Choose your nxnative checkout, or the folder to download it into."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = settings.repositoryURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { settings.repositoryPath = url.path }
    }

    func choosePython() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Python Interpreter"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings.pythonPath = url.path }
    }
}
