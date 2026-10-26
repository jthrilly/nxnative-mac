// What the app tells about updating the checkout: whether a failed pull was stopped by local changes (git's own words; a diverged branch or a network
// error is not), and what `git reset --hard @{u}` would throw away: the changes to tracked files and the local commits that are not on the upstream
import Foundation

public enum RepositoryAdvice {
    public static func pullBlockedByLocalChanges(error: String) -> Bool {
        let lower = error.lowercased()
        return lower.contains("would be overwritten") || lower.contains("local changes")
    }

    public static func resetWarning(_ status: RepositoryStatus, limit: Int = 20) -> String {
        let upstream: String = status.upstream ?? "@{u}"
        let files: [String] = status.modifiedFiles
        let commits: [CommitInfo] = status.outgoing
        var parts: [String] = []
        if !files.isEmpty {
            let more: String = files.count > limit ? "\n… and \(files.count - limit) more" : ""
            parts.append("It throws away the changes to these files:\n" + files.prefix(limit).joined(separator: "\n") + more)
        }
        let ahead: Int = max(status.ahead, commits.count)
        if ahead > 0 {
            let listed: [String] = commits.prefix(limit).map { "\($0.shortSHA) \($0.subject)" }
            let more: String = ahead > listed.count ? "\n… and \(ahead - listed.count) more" : ""
            let noun: String = ahead == 1 ? "local commit" : "\(ahead) local commits"
            parts.append("It takes the \(noun) not on \(upstream) off the branch (only git's reflog keeps them):\n" + listed.joined(separator: "\n") + more)
        }
        if parts.isEmpty { parts.append("It throws away any changes to the tracked files.") }
        return "git reset --hard \(upstream) makes the checkout match \(upstream).\n\n" + parts.joined(separator: "\n\n") + "\n\nThis cannot be undone."
    }
}
