// The executable's entry point. `NXNativeConverter --keys-guard <key file>…` is the PreToolUse hook that keeps Claude Code from reading the key file
// during a port (it reads the hook's JSON on stdin, exits 2 with the reason on stderr to block the call, else 0); it returns before AppKit or SwiftUI
// start, because the agent runs it for every tool call. Anything else starts the app
import ConverterCore
import Foundation

@main enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == KeysGuard.hookFlag { exit(keysGuard(keyFiles: Array(arguments.dropFirst(2)))) }
        NXNativeConverterApp.main()
    }

    private static func keysGuard(keyFiles: [String]) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let reason = KeysGuard.reason(hookInput: input, keyFiles: keyFiles) else { return 0 }
        FileHandle.standardError.write(Data((reason + "\n").utf8))
        return 2
    }

    /// The hook command for the Claude settings: this executable, bundled or not
    static func keysGuardCommand(keysFile: URL) -> String? {
        Bundle.main.executablePath.map { KeysGuard.hookCommand(executable: $0, keyFile: keysFile.path) }
    }
}
