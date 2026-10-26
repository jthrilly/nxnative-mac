// Keeps the Switch key file out of a Claude Code agent's context. A best-effort guard, not the boundary: it is a PreToolUse hook (the converter's own executable with
// --keys-guard) that blocks a file tool aimed at the key file and a shell command that would show, copy or send its contents, while the repository's tools may still take its
// path (-k). A command is read the way a shell splits it (quotes, escapes, |, ;, &&, $( ), backticks, redirects, NAME=value assignments); a reader (cat, grep, python -c, a `<`
// redirect, xargs, a recursive walk of the key's folder) that reaches the key is blocked. It catches common mistakes, including globs and a variable that holds the path, but it
// still cannot see a path assembled at run time or a script written first and run later: the OS sandbox the app configures (KeysGuard.claudeSettings) is the real boundary
import Foundation

public enum KeysGuard {
    static let readers: Set<String> = [
        "cat", "head", "tail", "less", "more", "bat", "grep", "egrep", "fgrep", "rg", "ag", "awk", "gawk", "sed", "cut", "sort", "uniq", "nl", "tac", "rev", "strings", "xxd",
        "hexdump", "od", "base64", "diff", "cmp", "cp", "mv", "rsync", "scp", "ditto", "tar", "zip", "gzip", "curl", "wget", "nc", "open", "pbcopy", "tee", "dd", "vi", "vim",
        "nvim", "nano", "emacs", "paste", "fold", "column", "iconv", "jq", "plutil", "pr", "expand", "unexpand", "fmt", "look", "comm", "join", "csplit", "split", "zcat",
        "bzcat", "xzcat", "lzcat", "gzcat", "textutil", "pcregrep", "pcre2grep", "xargs", "find",
    ]
    static let recursiveReaders: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "tar", "zip", "cp", "rsync", "scp", "ditto", "find"]
    static let interpreterPrefixes = ["python", "perl", "ruby", "node", "bun", "deno", "php", "osascript"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    static let separators: Set<String> = ["|", "||", "|&", "&&", "&", ";", ";;", "(", ")", "\n"]
    // the search tools whose first operand is a pattern or script, not a path; the value-carrying options are scoped per tool so a boolean flag elsewhere (sort -f, rsync -a) is not mistaken for one
    static let patternTools: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "gawk"]
    static let patternValueFlags: Set<String> = ["-e", "--regexp", "-f", "--file", "--expression"]

    static func toolValueFlags(_ name: String) -> Set<String> {
        switch name {
        case "grep", "egrep", "fgrep", "rg", "ag": return ["-e", "--regexp", "-f", "--file", "-m", "--max-count", "--include", "--exclude", "--exclude-dir", "--include-dir"]
        case "sed", "awk", "gawk": return ["-e", "--expression", "-f", "--file"]
        case "rsync", "tar", "cp", "ditto", "scp", "zip": return ["--exclude", "--include", "--exclude-from", "--include-from", "--files-from", "--filter"]
        default: return []
        }
    }
    static let message = "nxnative Converter blocks this: it would show or copy the Switch key file. Pass the key file's path to the repository's tools (-k) instead; never read it."

    /// A key file resolved for comparison: its absolute path, its name, and its folder with every ancestor (for a recursive walk that would reach it)
    struct KeyInfo {
        let path: String, lower: String, name: String, nameLower: String, ancestorsLower: Set<String>

        init(_ raw: String) {
            path = NSString(string: NSString(string: raw).expandingTildeInPath).standardizingPath
            lower = path.lowercased()
            name = NSString(string: path).lastPathComponent
            nameLower = name.lowercased()
            var folder = NSString(string: path).deletingLastPathComponent, set: Set<String> = []
            while !folder.isEmpty, folder != "/" { set.insert(folder.lowercased()); folder = NSString(string: folder).deletingLastPathComponent }
            set.insert("/")
            ancestorsLower = set
        }
    }

    static func reason(toolName: String, command: String?, paths: [String], keyFiles: [String]) -> String? {
        let keys = keyFiles.filter { !$0.isEmpty }.map(KeyInfo.init)
        guard !keys.isEmpty else { return nil }
        for p in paths where operandNamesKey(p, keys) { return message }
        if toolName == "Grep" || toolName == "Glob" {   // a search of the key file's folder, or any ancestor of it, prints its lines too
            for p in paths where !p.isEmpty && walkReachesKey(p, keys) { return message }
        }
        if let command, blocks(command, keys, depth: 0) { return message }
        return nil
    }

    public static func reason(hookInput: Data, keyFiles: [String]) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any], let tool = o["tool_name"] as? String else { return nil }
        let input = o["tool_input"] as? [String: Any] ?? [:]
        let keys = ["file_path", "path", "notebook_path", "glob"] + (tool == "Grep" ? [] : ["pattern"])   // Grep's pattern is what it looks for, not where
        return reason(toolName: tool, command: input["command"] as? String, paths: keys.compactMap { input[$0] as? String }, keyFiles: keyFiles)
    }

    public static let hookFlag = "--keys-guard"

    /// The PreToolUse hook command: `executable --keys-guard keyFile`. It fails closed: if the executable is gone (the app was moved or deleted while
    /// a Terminal session outlived it), `test -x` makes the hook exit 2, which blocks the tool call, where a missing command would exit 127 and let it through
    public static func hookCommand(executable: String, keyFile: String) -> String {
        let q = PrerequisiteChecker.shellQuote, run = [executable, hookFlag, keyFile].map(q).joined(separator: " ")
        return "test -x \(q(executable)) || { echo 'nxnative keys guard missing' >&2; exit 2; }; exec \(run)"
    }

    // ---- the Claude Code settings the app writes for a port ----

    static let portingDomains = [
        "github.com", "*.github.com", "*.githubusercontent.com", "codeload.github.com",
        "pypi.org", "*.pypi.org", "files.pythonhosted.org", "*.pythonhosted.org",
        "api.nuget.org", "*.nuget.org", "*.nugetcdn.org",
        "dotnet.microsoft.com", "builds.dotnet.microsoft.com", "*.dot.net", "dotnetcli.azureedge.net", "dotnetbuilds.azureedge.net", "aka.ms",
    ]

    /// The `--settings` JSON for a headless (or Terminal) Claude Code port: the PreToolUse hook, `permissions.deny` Read rules that name the key file by absolute path, and,
    /// when sandboxed, the OS sandbox that is the real boundary (the key file unreadable, writes only to the game apps' log/save folders and the build tools' caches, network limited to
    /// what porting needs).
    /// In `-p` mode an invalid settings file is dropped silently, so this stays valid JSON; the live test proves the sandbox is actually on
    public static func claudeSettings(guardCommand: String, keyFiles: [String] = [], sandbox: ClaudeSandbox = .fullAccess) -> String {
        let keys = keyFiles.filter { !$0.isEmpty }.map { NSString(string: $0).expandingTildeInPath }
        var deny: [String] = []
        for k in keys {
            deny.append("Read(//" + dropLeadingSlashes(k) + ")")   // Read rules take '//' for an absolute path; a single leading '/' would be read against the settings folder
            let folder = NSString(string: k).deletingLastPathComponent
            if !folder.isEmpty, folder != "/" { deny.append("Read(//" + dropLeadingSlashes(folder) + "/*.keys)") }
        }
        deny += ["Read(//**/*.keys)", "Read(~/**/*.keys)"]
        deny = orderedUnique(deny)
        var settings: [String: Any] = [
            "hooks": ["PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": guardCommand]]]]],
            "permissions": ["deny": deny],
        ]
        if sandbox == .sandboxed {
            settings["sandbox"] = [
                "enabled": true, "failIfUnavailable": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
                "filesystem": ["denyRead": keys, "allowWrite": sandboxWriteFolders()],
                "network": ["allowedDomains": portingDomains, "strictAllowlist": true],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Beyond the worktree, the game folder and Claude Code's own temporary folder: the game apps' log and save folders, and the caches the build tools write. Without the
    /// per-user cache and temporary folders clang's module cache and xcrun fail, and without NuGet's and dotnet's folders nx_extract does not build
    static func sandboxWriteFolders() -> [String] {
        ["~/Library/Logs/nxnative", "~/Library/Application Support/nxnative", "~/.nuget", "~/.dotnet", "~/.local/share/NuGet", "~/.cache"]
            + [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap(userFolder)
    }

    static func userFolder(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    static func dropLeadingSlashes(_ p: String) -> String { String(p.drop { $0 == "/" }) }

    static func orderedUnique(_ xs: [String]) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }

    // ---- what names a key file ----

    /// A word that mentions the key anywhere: "….keys" ending the word or followed by a non-name character, the configured file's path, or its name as the last path component.
    /// Liberal on purpose, for code strings and redirect targets; it runs on command operands only after the search pattern and option values are set aside (operandNamesKey)
    static func namesKeyLoose(_ word: String, _ keys: [KeyInfo]) -> Bool {
        let lower = word.lowercased()
        var search = lower.startIndex
        while let r = lower.range(of: ".keys", range: search..<lower.endIndex) {
            if r.upperBound == lower.endIndex || !isNameCharacter(lower[r.upperBound]) { return true }
            search = r.upperBound
        }
        let last = NSString(string: word).lastPathComponent.lowercased()
        for k in keys {
            if lower.contains(k.lower) || !k.nameLower.isEmpty && last == k.nameLower { return true }
        }
        return false
    }

    /// A command operand that names the key: the loose test, the key path reached through `~`, or a glob that matches the key path or its name
    static func operandNamesKey(_ word: String, _ keys: [KeyInfo]) -> Bool {
        if namesKeyLoose(word, keys) { return true }
        let expanded = NSString(string: word).expandingTildeInPath
        guard expanded.contains(where: { "*?[".contains($0) }) else { return false }
        let pattern = expanded.lowercased()
        return keys.contains { globMatch(pattern, $0.lower) || globMatch(pattern, $0.nameLower) || globMatch(pattern, NSString(string: $0.lower).lastPathComponent) }
    }

    /// True when a recursive walk of `word` (the key's own folder, or any ancestor of it) would reach the key file
    static func walkReachesKey(_ word: String, _ keys: [KeyInfo]) -> Bool {
        let resolved = NSString(string: NSString(string: word).expandingTildeInPath).standardizingPath.lowercased()
        guard !resolved.isEmpty else { return false }
        return keys.contains { $0.ancestorsLower.contains(resolved) }
    }

    static func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }

    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        pattern.withCString { p in text.withCString { t in fnmatch(p, t, 0) == 0 } }
    }

    // ---- shell commands ----

    enum Token: Equatable { case word(String), op(String) }

    static func blocks(_ command: String, _ keys: [KeyInfo], depth: Int) -> Bool {
        guard depth < 4 else { return namesKeyLoose(command, keys) }
        let tokens = substituteAssignments(tokenize(command))
        var words: [String] = []
        for t in tokens { if case let .word(w) = t { words.append(w) } }
        let nested = words.flatMap(substitutions)
        if nested.contains(where: { blocks($0, keys, depth: depth + 1) }) { return true }
        for (i, t) in tokens.enumerated() where t == .op("<") || t == .op("<>") {   // a `<` redirect from the key file
            if i + 1 < tokens.count, case let .word(w) = tokens[i + 1], operandNamesKey(w, keys) { return true }
        }
        let heredoc = tokens.contains(.op("<<")) || tokens.contains(.op("<<-"))
        if heredoc, words.contains(where: { isInterpreter(commandName($0)) }), words.contains(where: { namesKeyLoose($0, keys) }) { return true }
        var segment: [String] = [], segments: [[String]] = []
        for t in tokens + [.op(";")] {
            switch t {
            case let .word(w): segment.append(w)
            case let .op(op):
                guard separators.contains(op) else { continue }
                if segmentBlocks(segment, keys, depth: depth) { return true }
                segments.append(segment); segment = []
            }
        }
        // `ls *.keys | xargs cat`: the name reaches the reader through xargs, in a later segment
        if segments.contains(where: { $0.contains { commandName($0) == "xargs" } && $0.contains { readers.contains(commandName($0)) } }),
           segments.contains(where: { $0.contains { operandNamesKey($0, keys) } }) { return true }
        return false
    }

    static func segmentBlocks(_ rawWords: [String], _ keys: [KeyInfo], depth: Int) -> Bool {
        var words = rawWords
        if words.first == "env" { words.removeFirst() }
        while let f = words.first, isAssignment(f) { words.removeFirst() }
        guard let first = words.first else { return false }
        for (i, w) in words.enumerated() {   // the code a shell or eval is given is read like any other command
            let name = commandName(w), rest = Array(words[(i + 1)...])
            if name == "eval", blocks(rest.joined(separator: " "), keys, depth: depth + 1) { return true }
            if shells.contains(name), let f = rest.firstIndex(where: { isShortFlag($0, containing: "c") }), f + 1 < rest.count,
               blocks(rest[f + 1], keys, depth: depth + 1) { return true }
        }
        // an interpreter given inline code (python -c, node -p, perl -e) that mentions the key
        if words.contains(where: { isInterpreter(commandName($0)) }), interpreterCode(words).contains(where: { namesKeyLoose($0, keys) }) { return true }
        let cmd = commandName(first)
        let ops = operands(words, name: cmd)
        // perl -n/-p and ruby -n/-p read their file operands as input, like a reader
        if (cmd.hasPrefix("perl") || cmd.hasPrefix("ruby")), words.contains(where: { isShortFlag($0, containing: "n") || isShortFlag($0, containing: "p") }),
           ops.contains(where: { operandNamesKey($0, keys) }) { return true }
        if readers.contains(cmd) {
            if ops.contains(where: { operandNamesKey($0, keys) }) { return true }
            if recursiveReaders.contains(cmd), isRecursiveCall(cmd, words), ops.contains(where: { walkReachesKey($0, keys) }) { return true }
            if cmd == "find", findReadsPaths(words), findPaths(words).contains(where: { walkReachesKey($0, keys) || operandNamesKey($0, keys) }) { return true }
        }
        return false
    }

    /// Operands of a reader, with the first search pattern or script of a pattern tool and the value-carrying options set aside
    static func operands(_ words: [String], name: String) -> [String] {
        let valueFlags = toolValueFlags(name)
        var out: [String] = [], sawPattern = false, i = 1
        while i < words.count {
            let w = words[i]
            if w == "--" { i += 1; continue }
            if w.hasPrefix("-"), w != "-" {
                if valueFlags.contains(w) { if patternValueFlags.contains(w) { sawPattern = true }; i += 2 } else { i += 1 }
                continue
            }
            if patternTools.contains(name), !sawPattern, !w.isEmpty { sawPattern = true; i += 1; continue }   // the inline pattern or sed/awk script (an empty arg, e.g. sed -i '', is not it)
            out.append(w); i += 1
        }
        return out
    }

    /// `find PATHS… EXPRESSION`: the leading path operands, before the first `-primary`
    static func findPaths(_ words: [String]) -> [String] { Array(words.dropFirst().prefix { !$0.hasPrefix("-") && $0 != "!" && $0 != "(" }) }

    static func findReadsPaths(_ words: [String]) -> Bool {
        words.contains { $0 == "-exec" || $0 == "-execdir" || $0 == "-delete" || $0 == "-fprint" || $0 == "-fprintf" || $0 == "-fprint0" }
    }

    static func isRecursiveCall(_ cmd: String, _ words: [String]) -> Bool {
        if cmd == "rg" || cmd == "ag" || cmd == "tar" || cmd == "zip" || cmd == "rsync" || cmd == "scp" || cmd == "ditto" { return true }
        return words.dropFirst().contains { $0 == "-r" || $0 == "-R" || $0 == "--recursive" || isShortFlag($0, containing: "r") || isShortFlag($0, containing: "R") }
    }

    /// The code a `python -c` / `node -p` / `perl -e` runs: the word after a short flag that carries c, e or p, or after --eval / --print / --exec
    static func interpreterCode(_ words: [String]) -> [String] {
        var out: [String] = []
        for (i, w) in words.enumerated() where i + 1 < words.count {
            let carries = isShortFlag(w, containing: "c") || isShortFlag(w, containing: "e") || isShortFlag(w, containing: "p")
            if carries || w == "--eval" || w == "--print" || w == "--exec" || w == "--expression" { out.append(words[i + 1]) }
        }
        return out
    }

    static func isInterpreter(_ name: String) -> Bool { interpreterPrefixes.contains { name == $0 || name.hasPrefix($0) } }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[word.startIndex..<eq]
        guard let f = name.first, f.isLetter || f == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Fills `$NAME` / `${NAME}` words from NAME=value assignments earlier in the same command (`K=…/prod.keys; cat "$K"`)
    static func substituteAssignments(_ tokens: [Token]) -> [Token] {
        var values: [String: String] = [:]
        for t in tokens {
            guard case let .word(w) = t, isAssignment(w), let eq = w.firstIndex(of: "=") else { continue }
            values[String(w[w.startIndex..<eq])] = String(w[w.index(after: eq)...])
        }
        guard !values.isEmpty else { return tokens }
        return tokens.map { if case let .word(w) = $0 { return .word(expandVariables(w, values)) } else { return $0 } }
    }

    static func expandVariables(_ word: String, _ values: [String: String]) -> String {
        var out = "", c = Array(word), i = 0
        while i < c.count {
            guard c[i] == "$", i + 1 < c.count else { out.append(c[i]); i += 1; continue }
            var j = i + 1, braced = false
            if c[j] == "{" { braced = true; j += 1 }
            let start = j
            while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
            let name = String(c[start..<j])
            if braced { if j < c.count, c[j] == "}" { j += 1 } else { out.append(c[i]); i += 1; continue } }
            if !name.isEmpty, let v = values[name] { out += v; i = j } else { out.append(c[i]); i += 1 }
        }
        return out
    }

    static func isShortFlag(_ word: String, containing letter: Character) -> Bool { word.hasPrefix("-") && !word.hasPrefix("--") && word.dropFirst().contains(letter) }

    static func commandName(_ word: String) -> String { word.split(separator: "/").last.map(String.init) ?? word }

    /// The commands inside $( … ) and ` … ` in a word (quotes inside them are kept for the nested read)
    static func substitutions(_ word: String) -> [String] {
        var out: [String] = []
        let c = Array(word)
        var i = 0
        while i < c.count {
            if c[i] == "$", i + 1 < c.count, c[i + 1] == "(" {
                var depth = 0, j = i + 1
                while j < c.count {
                    if c[j] == "(" { depth += 1 } else if c[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                out.append(String(c[(i + 2)..<min(j, c.count)]))
                i = j + 1
            } else if c[i] == "`" {
                let end = c[(i + 1)...].firstIndex(of: "`") ?? c.count
                out.append(String(c[(i + 1)..<end]))
                i = end + 1
            } else { i += 1 }
        }
        return out
    }

    /// Words and operators as a POSIX shell splits them: '…' literal, "…" with \-escapes, \ outside quotes, # comments, newlines as separators.
    /// A word keeps $( … ) and backticks inside it as text (substitutions reads them)
    static func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var word = "", inWord = false
        let c = Array(command)
        var i = 0
        func flush() { if inWord { tokens.append(.word(word)); word = ""; inWord = false } }
        while i < c.count {
            let ch = c[i]
            switch ch {
            case " ", "\t": flush()
            case "\n": flush(); tokens.append(.op("\n"))
            case "#" where !inWord:
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            case "'":
                inWord = true
                i += 1
                while i < c.count, c[i] != "'" { word.append(c[i]); i += 1 }
            case "\"":
                inWord = true
                i += 1
                while i < c.count, c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count, "\"\\$`".contains(c[i + 1]) { i += 1 }
                    word.append(c[i]); i += 1
                }
            case "\\":
                inWord = true
                if i + 1 < c.count { i += 1; if c[i] != "\n" { word.append(c[i]) } }
            case "$" where i + 1 < c.count && c[i + 1] == "(":
                inWord = true   // $( … ) stays in the word, parentheses balanced
                var depth = 0
                while i < c.count {
                    if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1 }
                    word.append(c[i])
                    if depth == 0, c[i] == ")" { break }
                    i += 1
                }
            case "`":
                inWord = true
                word.append(ch); i += 1
                while i < c.count, c[i] != "`" { word.append(c[i]); i += 1 }
                if i < c.count { word.append("`") }
            case "|", "&", ";", "(", ")", "<", ">":
                flush()
                var op = String(ch)
                for longer in ["<<<", "<<-", "<<", "<>", "<&", ">>", ">&", ">|", "&>", "&&", "||", "|&", ";;"] {
                    if longer.count > op.count, i + longer.count <= c.count, String(c[i..<(i + longer.count)]) == longer { op = longer; break }
                }
                tokens.append(.op(op))
                i += op.count
                continue
            default:
                inWord = true
                word.append(ch)
            }
            i += 1
        }
        flush()
        return tokens
    }
}
