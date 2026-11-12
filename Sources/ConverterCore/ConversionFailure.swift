// Why a conversion failed, from the script's events as they arrive. On an error, cli() ends the running stage and then says "[RED] <error>", so only a [RED]
// line after the newest stage started can be the failure: one from an earlier stage was a warning (the provisional profile's, a left-out update). A process
// killed by a signal says nothing more, and its exit status (128 + the signal, as Subprocess reports it) is the reason. Exit status 2 is an argument the script
// refused, and 130 (an interrupt) or 143 (SIGTERM, which the script turns into an exit) is a stop (docs/frontends.md, Building)
import Darwin

public struct FailureTracker: Sendable, Equatable {
    public private(set) var fatal: String?   // the newest [RED] message of the current stage

    public init() {}

    /// Whether the script's exit status says it was stopped: 130 after an interrupt, 143 after a SIGTERM (nxnative 0b12448)
    public static func isStop(status: Int32) -> Bool { status == 128 + SIGINT || status == 128 + SIGTERM }

    public mutating func observe(_ event: BuildEvent) {
        switch event {
        case .stage: fatal = nil
        case .say(let message): if let warning = BuildState.warningText(message) { fatal = warning }
        default: break
        }
    }

    /// The message for a run that ended with a non-zero exit status that is not a stop (isStop), given the last line the script wrote to stderr
    public func message(status: Int32, lastError: String?) -> String {
        if status > 128, status < 128 + NSIG {
            let signal = status - 128
            let name = String(cString: strsignal(signal))
            let hint = signal == SIGKILL ? " macOS stops a process this way when memory runs out." : ""
            return "The conversion was stopped by signal \(signal) (\(name)).\(hint)"
        }
        // 2: the script's argument parser refused the command line, before its JSON events start; its usage and error are on stderr
        if status == 2, fatal == nil { return "The NSP script refused its arguments" + (lastError.map { ": \($0)" } ?? ".") }
        return fatal ?? lastError ?? "The conversion stopped with exit status \(status)."
    }
}
