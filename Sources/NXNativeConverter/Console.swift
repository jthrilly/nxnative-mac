// The console of git operations and Setup fixes (shown on the nxnative and Setup pages), and Batcher / LineBatcher, which hand a process's output (lines, or
// what was decoded from them), read on background queues, to the main actor in batches so that a chatty command cannot flood the main thread
import ConverterCore
import Foundation
import Observation
import os

struct OutputLine: Sendable {
    var stream: ConverterCore.OutputStream
    var text: String
    var date: Date
}

/// Hands items produced on background queues to the main actor in batches, at most one delivery per interval
final class Batcher<Item: Sendable>: Sendable {
    private struct Pending: Sendable { var items: [Item] = []; var scheduled = false }
    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let interval: TimeInterval
    private let deliver: @MainActor @Sendable ([Item]) -> Void

    init(interval: TimeInterval = 0.1, deliver: @escaping @MainActor @Sendable ([Item]) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func add(_ item: Item) {
        let schedule = pending.withLock { p in
            p.items.append(item)
            if p.scheduled { return false }
            p.scheduled = true
            return true
        }
        if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + interval) { MainActor.assumeIsolated { self.flush() } } }
    }

    // Called by the timer, and once more after the process exited (both pipes at EOF) so that nothing is left behind
    @MainActor func flush() {
        let items = pending.withLock { p in
            defer { p.items = []; p.scheduled = false }
            return p.items
        }
        if !items.isEmpty { deliver(items) }
    }
}

final class LineBatcher: Sendable {
    private let batcher: Batcher<OutputLine>

    init(interval: TimeInterval = 0.1, deliver: @escaping @MainActor @Sendable ([OutputLine]) -> Void) {
        batcher = Batcher(interval: interval, deliver: deliver)
    }

    func add(_ stream: ConverterCore.OutputStream, _ text: String) { batcher.add(OutputLine(stream: stream, text: text, date: Date())) }

    @MainActor func flush() { batcher.flush() }
}

struct ConsoleLine: Identifiable, Equatable {
    enum Kind: Equatable { case output, error, command, note }
    let id: Int
    var text: String
    var kind: Kind
}

@MainActor @Observable final class ConsoleModel {
    static let maxLines = 5_000

    private(set) var lines: [ConsoleLine] = []
    private(set) var title: String?          // the operation running now
    private(set) var canStop = false         // it runs a command or a part that can be cancelled (a git transfer), and Stop was not pressed yet
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var process: Subprocess?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var stopping = false

    var isRunning: Bool { title != nil }

    func append(_ text: String, _ kind: ConsoleLine.Kind = .note) {
        lines.append(ConsoleLine(id: nextID, text: text, kind: kind)); nextID += 1
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    func clear() { lines.removeAll() }

    func begin(_ title: String) { self.title = title; stopping = false; updateStop() }
    func end() { title = nil; process = nil; work = nil; stopping = false; updateStop() }

    /// The part of the operation that Stop cancels (with the command it runs); what follows it (a refresh) is not cancelled
    func attach(_ task: Task<Void, Never>) { work = task; updateStop() }
    func detach() { work = nil; updateStop() }

    /// Runs a command with its output streamed into the console. Returns the exit status (-1 when it could not start, or the operation was stopped)
    func run(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL? = nil, shown: String? = nil) async -> Int32 {
        guard !Task.isCancelled else { return -1 }
        append("$ " + (shown ?? ([executable] + arguments).map(Shell.quoteIfNeeded).joined(separator: " ")), .command)
        let proc = Subprocess(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
        let batcher = LineBatcher { [weak self] batch in
            for line in batch { self?.append(line.text, line.stream == .stderr ? .error : .output) }
        }
        do { try proc.start { stream, line in batcher.add(stream, line) } } catch {
            append(error.localizedDescription, .error)
            return -1
        }
        process = proc; updateStop()
        let status = await proc.waitUntilExit()
        batcher.flush()
        process = nil; updateStop()
        if status != 0 { append("exit status \(status)", .error) }
        return status
    }

    func stop() {
        guard canStop else { return }
        stopping = true; updateStop()
        append("Stopping…", .note)
        work?.cancel()
        if let process { Task { await process.cancel(grace: 5) } }
    }

    /// Before quitting: stop what runs and wait until the operation has ended (at most timeout)
    func stopAndWait(timeout: Duration) async {
        stop()
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func updateStop() { canStop = !stopping && (process != nil || work != nil) }
}

enum Shell {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func quoteIfNeeded(_ s: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        return !s.isEmpty && s.unicodeScalars.allSatisfy(plain.contains) ? s : quote(s)
    }
}
