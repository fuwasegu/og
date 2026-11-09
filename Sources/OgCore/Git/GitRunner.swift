import Foundation

/// Error thrown by git operations. `message` is git's own stderr (or og's refusal reason).
public struct GitError: Error, LocalizedError, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Output of one git process.
struct GitResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String
    var ok: Bool { status == 0 }
    var text: String { String(decoding: stdout, as: UTF8.self) }

    /// Git's message for a failed command (stderr, else stdout).
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "git exited with status \(status)" : out
    }
}

/// Runs git processes synchronously. Every call must happen on `queue`
/// (spec/design/vcs.fsl DES-1: one serial queue, so og never runs two git processes at once).
final class GitRunner: Sendable {
    let root: URL
    /// The single serial queue every git invocation goes through.
    let queue = DispatchQueue(label: "og.git.serial", qos: .userInitiated)
    /// Cached `git rev-parse --show-prefix` (project root relative to the repo root).
    private let prefixCache = Locked<String?>(nil)

    init(root: URL) { self.root = root }

    /// Runs a whole operation (possibly several git processes) on the serial queue.
    func serial<T: Sendable>(_ body: @escaping @Sendable (GitRunner) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                cont.resume(with: Result { try body(self) })
            }
        }
    }

    /// Like `serial`, for operations that never throw.
    func serial<T: Sendable>(_ body: @escaping @Sendable (GitRunner) -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async { cont.resume(returning: body(self)) }
        }
    }

    /// Runs `git <args>` in `root`. Must be called on `queue`.
    func run(_ args: [String], literalPathspecs: Bool = true) -> GitResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let git = ToolLocator.shared.find("git") else {
            return GitResult(status: -1, stdout: Data(), stderr: "git was not found on PATH")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: git)
        var full = ["-c", "color.ui=never", "-c", "core.quotepath=false"]
        if literalPathspecs { full.append("--literal-pathspecs") }
        proc.arguments = full + args
        proc.currentDirectoryURL = root
        var env = ToolLocator.shared.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_PAGER"] = "cat"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return GitResult(status: -1, stdout: Data(), stderr: "Could not run git: \(error.localizedDescription)")
        }
        // Drain stderr concurrently so a chatty process cannot block on a full pipe.
        let errData = Locked(Data())
        let group = DispatchGroup()
        let errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let d = errHandle.readDataToEndOfFile()
            errData.withLock { $0 = d }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        return GitResult(status: proc.terminationStatus, stdout: outData,
                         stderr: String(decoding: errData.current, as: UTF8.self))
    }

    /// Runs git and throws git's message on failure.
    @discardableResult
    func check(_ args: [String], literalPathspecs: Bool = true) throws -> GitResult {
        let r = run(args, literalPathspecs: literalPathspecs)
        guard r.ok else { throw GitError(r.message) }
        return r
    }

    /// Project root relative to the repository root ("" or "sub/dir/"), or nil if not a repository.
    func prefix() -> String? {
        if let p = prefixCache.current { return p }
        let r = run(["rev-parse", "--show-prefix"], literalPathspecs: false)
        guard r.ok else { return nil }
        let p = r.text.trimmingCharacters(in: .newlines)
        prefixCache.withLock { $0 = p }
        return p
    }

    func isRepository() -> Bool {
        let r = run(["rev-parse", "--is-inside-work-tree"], literalPathspecs: false)
        return r.ok && r.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func hasHead() -> Bool { run(["rev-parse", "--verify", "--quiet", "HEAD"]).ok }

    func hasStash() -> Bool { run(["rev-parse", "--verify", "--quiet", "refs/stash"]).ok }

    /// Fresh status of the real working tree (DES-2: never the cached one).
    func readStatus() -> GitStatusSnapshot? {
        guard let prefix = prefix() else { return nil }
        let r = run(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        guard r.ok else { return nil }
        var snap = GitStatusParser.parse(r.stdout, prefix: prefix)
        snap.hasStash = hasStash()
        return snap
    }

    /// Throws unless the working tree (including untracked files) is clean.
    func requireClean(_ action: String) throws {
        guard let snap = readStatus() else { throw GitError("Not a git repository") }
        let dirty = snap.entries.filter { $0.value.state != .ignored }
        guard dirty.isEmpty else {
            let names = dirty.keys.sorted().prefix(5).joined(separator: "\n  ")
            let more = dirty.count > 5 ? "\n  … and \(dirty.count - 5) more" : ""
            throw GitError("Cannot \(action): you have uncommitted changes.\nCommit, stash or roll them back first:\n  \(names)\(more)")
        }
    }
}
