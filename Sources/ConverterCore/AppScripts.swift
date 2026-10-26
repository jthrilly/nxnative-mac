// The shell scripts the app hands to Terminal or /bin/sh: a port's agent session (.command; its shell's PID in a marker file while it runs, see PortRules),
// and a Setup fix that needs a terminal. Names that come from a game (a folder name, its NACP title) only go into
// comment lines, with their control characters made spaces: a newline in them would start a command
import Foundation

public enum AppScripts {
    static func commentLine(_ text: String) -> String {
        "# " + String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0 }))
    }

    /// line runs in a subshell: it ends with exec, and the closing words must still be shown
    public static func portSession(title: String, line: String, marker: URL) -> String {
        "#!/bin/zsh -l\n" + commentLine(title) + "\n"
            + "nxnative_session=\(AgentCommand.shellQuote(marker.path)); echo $$ > \"$nxnative_session\"; trap 'rm -f -- \"$nxnative_session\"' EXIT\n"
            + "(\(line))\n"
            + "echo; echo \"Session ended. Save a checkpoint in nxnative Converter.\"\n"
    }

    public static func setupFix(title: String, command: String) -> String {
        "#!/bin/zsh -l\n" + commentLine(title) + "\n\(command)\necho; echo \"Done. You can close this window.\"\n"
    }
}
