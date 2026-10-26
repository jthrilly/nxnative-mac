// How the app's work fits together: what quitting asks while something runs (a conversion stops, an install is waited for, an agent saves its checkpoint
// first, git operations and fixes stop or finish), and what happens to a job already in the queue when its folder is added again
import Foundation

public struct QuitPrompt: Sendable, Equatable {
    public var message: String; public var informative: String; public var button: String
}

public enum QuitRules {
    /// nil when nothing runs; operations are the git operations and fixes running now (their titles)
    public static func prompt(conversion: String?, installing: Bool, agent: (name: String, game: String)?, operations: [String]) -> QuitPrompt? {
        var stops: [String] = [], notes: [String] = []
        if let conversion, !installing {
            stops.append("converting \(conversion)")
            notes.append("The conversion stops; you can start it again later.")
        }
        if let agent {
            stops.append("the agent porting \(agent.game)")
            notes.append("\(agent.name) stops, and its work is saved as a checkpoint of its worktree first; you can continue the port later.")
        }
        let titles = operations.map { "\u{201C}\($0.replacingOccurrences(of: "…", with: ""))\u{201D}" }
        if !titles.isEmpty {
            stops.append(titles.joined(separator: ", "))
            notes.append("A git operation or a fix is stopped; one that must not stop halfway (a rebase, a worktree removal) is waited for.")
        }
        if let conversion, installing {
            notes.append("\(conversion) is being installed: quitting waits until the install has finished, so that the app is complete and recorded.")
            if stops.isEmpty { return QuitPrompt(message: "Quit when \(conversion) is installed?", informative: notes.joined(separator: " "), button: "Quit After the Install") }
        }
        guard !stops.isEmpty else { return nil }
        let list = stops.count == 1 ? stops[0] : stops.dropLast().joined(separator: ", ") + " and " + (stops.last ?? "")
        return QuitPrompt(message: "Stop \(list)?", informative: notes.joined(separator: " "), button: "Stop and Quit")
    }
}

public enum QueueRules {
    public enum Reuse: Sendable, Equatable { case keep, switchTo(URL), busy }

    /// A folder added again while an unfinished job of it is in the queue (a drop, Convert Again, Build App of its port). A queued job takes the repository
    /// asked for; added without one, it keeps its own (a port's worktree stays). A job that runs cannot change: busy when another repository was asked for
    public static func reuse(existing: URL?, active: Bool, requested: URL?) -> Reuse {
        guard let requested, requested.standardizedFileURL.path != existing?.standardizedFileURL.path else { return .keep }
        return active ? .busy : .switchTo(requested)
    }
}
