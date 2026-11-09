import Foundation
import Darwin

/// A child process in its own process group with streamed stdout/stderr.
///
/// `go run` / `go test` spawn further children (the built binary, test binaries),
/// so `stop()` signals the whole group. Events are delivered in order on
/// `queue`; `.exit` is always last, after both pipes reached EOF.
public final class RunProcess: @unchecked Sendable {
    public enum Stream: Sendable { case stdout, stderr }

    public enum Event: Sendable, Equatable {
        case output(Stream, String)
        /// Exit status (or 128 + signal when killed by a signal).
        case exit(Int32)
    }

    public enum LaunchError: Error, CustomStringConvertible {
        case notFound(String)
        case spawn(Int32)
        public var description: String {
            switch self {
            case .notFound(let tool): return "\(tool) not found in PATH"
            case .spawn(let code): return "failed to launch: \(String(cString: strerror(code)))"
            }
        }
    }

    public let executable: String
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]

    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var exited = false
    private let eventQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "og.run.io")

    public init(executable: String, arguments: [String], directory: URL,
                environment: [String: String] = ToolLocator.shared.environment,
                queue: DispatchQueue = DispatchQueue(label: "og.run.events")) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.eventQueue = queue
    }

    /// Convenience: `go <command.arguments>` in `command.directory`.
    public convenience init(command: RunCommand, queue: DispatchQueue) throws {
        guard let go = ToolLocator.shared.find("go") else { throw LaunchError.notFound("go") }
        self.init(executable: go, arguments: command.arguments, directory: command.directory, queue: queue)
    }

    public var pid: pid_t { lock.withLock { _pid } }
    public var isRunning: Bool { lock.withLock { _pid != 0 && !exited } }

    /// Launches the process. `handler` is called on `queue` for every event.
    public func start(_ handler: @escaping @Sendable (Event) -> Void) throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw LaunchError.spawn(errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw LaunchError.spawn(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group (pgid = pid) so stop() can kill the whole tree.
        posix_spawnattr_setpgroup(&attr, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var child: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnv in
                posix_spawn(&child, executable, &actions, &attr, cArgv, cEnv)
            }
        }
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw LaunchError.spawn(rc)
        }
        lock.withLock { _pid = child }
        let pid = child

        let group = DispatchGroup()
        let eventQueue = self.eventQueue
        for (fd, stream) in [(outPipe[0], Stream.stdout), (errPipe[0], Stream.stderr)] {
            group.enter()
            readLoop(fd: fd, stream: stream, handler: handler) { group.leave() }
        }
        group.enter()
        let status = StatusBox()
        Thread.detachNewThread { [weak self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            status.value = RunProcess.exitCode(fromWaitStatus: raw)
            self?.lock.withLock { self?.exited = true }
            group.leave()
        }
        group.notify(queue: eventQueue) { handler(.exit(status.value)) }
    }

    /// SIGTERM to the process group, then SIGKILL if it is still alive after `grace`.
    public func stop(grace: TimeInterval = 2) {
        let pid = self.pid
        guard pid > 0, isRunning else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.isRunning else { return }
            killpg(pid, SIGKILL)
        }
    }

    /// Exit code from a `waitpid` status (128 + signal for signalled processes).
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }

    private func readLoop(fd: Int32, stream: Stream, handler: @escaping @Sendable (Event) -> Void, done: @escaping @Sendable () -> Void) {
        let decoder = Locked(UTF8StreamDecoder())
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        let eventQueue = self.eventQueue
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let text = decoder.withLock { $0.decode(buffer[0..<n]) }
                if !text.isEmpty { eventQueue.async { handler(.output(stream, text)) } }
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(fd)
            let rest = decoder.withLock { $0.flush() }
            eventQueue.async {
                if !rest.isEmpty { handler(.output(stream, rest)) }
                done()
            }
        }
        source.resume()
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int32 = -1
        var value: Int32 {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    // Never empty (the trailing nil), so baseAddress is non-nil.
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Decodes a UTF-8 byte stream that may be split mid-character across chunks.
public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        let cut = UTF8StreamDecoder.completePrefixLength(pending)
        let text = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }

    /// Emits whatever is left (invalid bytes become U+FFFD).
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// Length of the prefix that does not end inside an incomplete multi-byte sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        var i = n - 1
        var back = 0
        // Walk back over at most 3 continuation bytes to the lead byte.
        while i >= 0 && back < 4 && bytes[i] & 0xC0 == 0x80 { i -= 1; back += 1 }
        guard i >= 0 else { return n }
        let lead = bytes[i]
        let need: Int
        if lead & 0x80 == 0 { need = 1 } else if lead & 0xE0 == 0xC0 { need = 2 } else if lead & 0xF0 == 0xE0 { need = 3 } else if lead & 0xF8 == 0xF0 { need = 4 } else { return n }
        return (n - i) < need ? i : n
    }
}
