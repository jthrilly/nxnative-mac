// Child processes in their own session and process group, with their output as lines. Foundation.Process cannot start a child in a new process group, and the NSP script's
// children (dotnet, make, clang, xcodebuild) must stop with it: posix_spawn with POSIX_SPAWN_SETSID, which also leaves the child without a controlling terminal, so an interactive
// shell or a prompt on /dev/tty cannot stop it when the app was started from a terminal. Every inherited descriptor is closed (POSIX_SPAWN_CLOEXEC_DEFAULT; the dup2'd 0/1/2
// survive it), stdin is /dev/null, the environment is as given. One thread reaps the child, one per pipe reads it. run() stops the child when its task is cancelled
import Darwin
import Foundation

public enum OutputStream: Sendable { case stdout, stderr }

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32; public var stdout: String; public var stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum SubprocessError: Error, LocalizedError, Equatable {
    case executableNotFound(String), spawnFailed(String, Int32), timedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(name): return "\(name) not found"
        case let .spawnFailed(name, code): return "\(name) could not be started: \(String(cString: strerror(code)))"
        case let .timedOut(name): return "\(name) did not finish in time"
        }
    }
}

public final class Subprocess: @unchecked Sendable {
    private enum Condition { case finished, drained }
    private struct State {
        var started = false, pid: pid_t = 0, status: Int32?, eofs = 0, strayTimeout = false
        var waiters: [Int: (Condition, CheckedContinuation<Bool, Never>)] = [:], nextWaiter = 0
        var drained: Bool { status != nil && eofs == 2 }
        var finished: Bool { status != nil && (eofs == 2 || strayTimeout) }
        func holds(_ c: Condition) -> Bool { c == .finished ? finished : drained }
    }

    /// A process that outlived the child (a server it left running) may keep a pipe open: waitUntilExit returns this long after the exit all the same
    static let strayGrace: TimeInterval = 5

    let executable: String, arguments: [String], environment: [String: String], currentDirectory: URL?
    var splitsCarriageReturns = false   // a "\r" also ends a line (git's progress), set before start
    private let lock = NSLock()
    private var state = State()

    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.currentDirectory = currentDirectory
    }

    public func start(onLine: @escaping @Sendable (OutputStream, String) -> Void) throws {
        guard let path = Self.resolve(executable, path: environment["PATH"]) else { throw SubprocessError.executableNotFound(executable) }
        guard !lock.withLock({ state.started }) else { throw SubprocessError.spawnFailed(executable, EBUSY) }
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw SubprocessError.spawnFailed(executable, errno) }
        guard pipe(&err) == 0 else { let e = errno; close(out[0]); close(out[1]); throw SubprocessError.spawnFailed(executable, e) }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }   // not inherited by other spawns of this app (Foundation.Process keeps them otherwise)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        if let dir = currentDirectory { posix_spawn_file_actions_addchdir(&actions, dir.path) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2, SIGTSTP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, s) }   // an ignored signal stays ignored across exec
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.filter { !$0.key.isEmpty && !$0.key.contains("=") }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        close(out[1]); close(err[1])
        guard rc == 0 else { close(out[0]); close(err[0]); throw SubprocessError.spawnFailed(executable, rc) }
        let child = pid
        lock.withLock { state.started = true; state.pid = child }

        Thread.detachNewThread { [self] in
            var status: Int32 = 0, r: pid_t
            repeat { r = waitpid(child, &status, 0) } while r == -1 && errno == EINTR
            exited(r == child ? Self.exitStatus(status) : -1)
        }
        let splitCR = splitsCarriageReturns
        for (fd, stream) in [(out[0], OutputStream.stdout), (err[0], OutputStream.stderr)] {
            Thread.detachNewThread { [self] in
                Self.readLines(fd, splitCR: splitCR) { onLine(stream, $0) }
                close(fd)
                update { $0.eofs += 1 }
            }
        }
    }

    var processIdentifier: pid_t { lock.withLock { state.pid } }

    public func waitUntilExit() async -> Int32 {
        guard lock.withLock({ state.started }) else { return -1 }
        _ = await wait(for: .finished, timeout: nil)
        return lock.withLock { state.status ?? -1 }
    }

    func signalGroup(_ signal: Int32) {
        let pid = lock.withLock { state.started && !state.drained ? state.pid : 0 }
        if pid > 0 { kill(-pid, signal) }
    }

    public func cancel(grace: TimeInterval = 10) async {
        guard lock.withLock({ state.started }) else { return }
        for (signal, wait) in [(SIGINT, grace), (SIGTERM, 5), (SIGKILL, 5)] {
            signalGroup(signal)
            if await self.wait(for: .drained, timeout: wait) { return }
        }
    }

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
                           timeout: TimeInterval? = nil) async throws -> ProcessOutput {
        let p = Subprocess(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
        let collected = Collector()
        try p.start { stream, line in collected.add(stream, line) }
        let timer = timeout.map { t in
            Task { () -> Bool in
                do { try await Task.sleep(nanoseconds: UInt64(max(t, 0) * 1e9)) } catch { return false }
                await p.cancel(grace: 2); return true
            }
        }
        let status = await withTaskCancellationHandler { await p.waitUntilExit() } onCancel: { Task { await p.cancel(grace: 2) } }
        timer?.cancel()
        if let timer, await timer.value { throw SubprocessError.timedOut(executable) }
        try Task.checkCancellation()
        let (out, err) = collected.text
        return ProcessOutput(status: status, stdout: out, stderr: err)
    }

    // A bare name is looked up on the given PATH, not the app's own
    static func resolve(_ executable: String, path: String?) -> String? {
        if executable.contains("/") { return ShellEnvironment.isExecutable(executable) ? executable : nil }
        let dirs = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        return dirs.lazy.map { NSString(string: $0).appendingPathComponent(executable) }.first(where: ShellEnvironment.isExecutable)
    }

    // waitpid's status: the exit code, or 128 + the signal that killed the process (as a shell reports it)
    static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal == 0x7f ? -1 : 128 + signal
    }

    static func readLines(_ fd: Int32, splitCR: Bool, _ onLine: (String) -> Void) {
        var splitter = LineSplitter(splitsCarriageReturns: splitCR)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { splitter.feed(buffer[0..<n]).forEach(onLine) }
            else if n < 0 && errno == EINTR { continue }
            else { break }
        }
        splitter.finish().map(onLine)
    }

    private func exited(_ status: Int32) {
        update { $0.status = status }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.strayGrace) { [self] in update { $0.strayTimeout = true } }
    }

    private func update(_ change: (inout State) -> Void) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            change(&state)
            let ids = state.waiters.filter { state.holds($0.value.0) }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.1 }
        }
        for c in ready { c.resume(returning: true) }
    }

    private func wait(for condition: Condition, timeout: TimeInterval?) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let id: Int? = lock.withLock {
                if state.holds(condition) { return nil }
                let id = state.nextWaiter; state.nextWaiter += 1
                state.waiters[id] = (condition, c)
                return id
            }
            guard let id else { c.resume(returning: true); return }
            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.withLock { state.waiters.removeValue(forKey: id) }?.1.resume(returning: false)
            }
        }
    }
}

/// Bytes → lines: "\n" ends a line, a trailing "\r" is dropped, invalid UTF-8 is replaced (lossy), and a final line without "\n" comes from finish()
struct LineSplitter {
    var splitsCarriageReturns = false
    private var pending: [UInt8] = []
    private var afterCR = false

    init(splitsCarriageReturns: Bool = false) { self.splitsCarriageReturns = splitsCarriageReturns }

    mutating func feed<C: Collection>(_ bytes: C) -> [String] where C.Element == UInt8 {
        var lines: [String] = []
        for b in bytes {
            let wasCR = afterCR
            afterCR = false
            if b == 0x0A {
                if !(splitsCarriageReturns && wasCR) { lines.append(take()) }   // "\r\n" ended the line at "\r" already
            } else if b == 0x0D && splitsCarriageReturns {
                lines.append(take()); afterCR = true
            } else { pending.append(b) }
        }
        return lines
    }

    mutating func finish() -> String? { pending.isEmpty ? nil : take() }

    private mutating func take() -> String {
        if pending.last == 0x0D { pending.removeLast() }
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = [], err: [String] = []

    func add(_ stream: OutputStream, _ line: String) { lock.withLock { stream == .stdout ? out.append(line) : err.append(line) } }
    var text: (String, String) { lock.withLock { (out.joined(separator: "\n"), err.joined(separator: "\n")) } }
}
