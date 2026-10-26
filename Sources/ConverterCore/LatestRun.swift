// Work that is asked for again before it has finished (a check per keystroke in a path field): each request cancels the one before, can wait a moment
// first so that a burst of requests runs once, and only the newest request's result is applied, whichever finishes last
import Foundation

@MainActor public final class LatestRun {
    private var generation = 0
    private var task: Task<Void, Never>?

    public init() {}

    /// Runs work after delay, cancelling the earlier request; apply gets its result only when no newer request was made meanwhile. The returned task ends
    /// when this request was applied or superseded
    @discardableResult
    public func run<T: Sendable>(after delay: Duration = .zero, _ work: @escaping @Sendable () async -> T, apply: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
        generation &+= 1
        let mine = generation
        task?.cancel()
        let next = Task { @MainActor [weak self] in
            if delay > .zero { guard (try? await Task.sleep(for: delay)) != nil else { return } }
            guard !Task.isCancelled else { return }
            let result = await work()
            guard let self, self.generation == mine else { return }
            apply(result)
        }
        task = next
        return next
    }
}
