// Why a conversion failed, from the script's events as they arrive. On an error, cli() ends the running stage and then says "[RED] <error>", so only a [RED]
// line after the newest stage started can be the failure: one from an earlier stage was a warning (the provisional profile's, a left-out update). A process
// killed by a signal says nothing more, and its exit status (128 + the signal, as Subprocess reports it) is the reason
import Darwin

public struct FailureTracker: Sendable, Equatable {
    public private(set) var fatal: String?   // the newest [RED] message of the current stage

    public init() {}

    public mutating func observe(_ event: BuildEvent) {
        switch event {
        case .stage: fatal = nil
        case .say(let message): if let warning = BuildState.warningText(message) { fatal = warning }
        default: break
        }
    }

    /// The message for a run that ended with a non-zero exit status other than 130 (an interrupt), given the last line the script wrote to stderr
    public func message(status: Int32, lastError: String?) -> String {
        if status > 128, status < 128 + NSIG {
            let signal = status - 128
            let name = String(cString: strsignal(signal))
            let hint = signal == SIGKILL ? " macOS stops a process this way when memory runs out." : ""
            return "The conversion was stopped by signal \(signal) (\(name)).\(hint)"
        }
        return fatal ?? lastError ?? "The conversion stopped with exit status \(status)."
    }
}
