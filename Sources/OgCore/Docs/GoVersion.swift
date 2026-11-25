import Foundation

/// Parsed Go semantic version (e.g. `1.21`, `1.22.4`, `go1.23.0`).
public struct GoVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Strictly parses strings such as `"1.22"`, `"1.23.1"`, `"go1.22.0"`, or
    /// `"go version go1.23.2 darwin/arm64"`. Rejects malformed strings like `"1.x.3"` (L-4).
    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let token: String
        if let range = trimmed.range(of: #"(?:^|[\s(])go(\d+\.\d+(?:\.\d+)?)(?:$|[\s),])"#, options: .regularExpression) {
            let matched = String(trimmed[range]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),")))
            token = matched.hasPrefix("go") ? String(matched.dropFirst(2)) : matched
        } else if trimmed.range(of: #"^\d+\.\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            token = trimmed
        } else if trimmed.hasPrefix("go"),
                  String(trimmed.dropFirst(2)).range(of: #"^\d+\.\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            token = String(trimmed.dropFirst(2))
        } else {
            return nil
        }

        let rawParts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard rawParts.count == 2 || rawParts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in rawParts {
            guard let n = Int(p), n >= 0 else { return nil }
            nums.append(n)
        }
        self.major = nums[0]
        self.minor = nums[1]
        self.patch = nums.count == 3 ? nums[2] : 0
    }

    /// Pack-level minor version key (e.g. `"1.23"`).
    public var minorKey: String { "\(major).\(minor)" }

    /// Display form (e.g. `"go1.23"` or `"go1.23.1"`).
    public var description: String {
        patch > 0 ? "go\(major).\(minor).\(patch)" : "go\(major).\(minor)"
    }

    public static func < (lhs: GoVersion, rhs: GoVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// True if `self` is greater than or equal to `minimum` on `(major, minor, patch)`.
    public func isAtLeast(_ minimum: GoVersion) -> Bool {
        self >= minimum
    }
}

/// Source from which the target Go version was resolved (FR-2 / DOC-2).
public enum GoVersionSource: String, Sendable, Hashable, Codable {
    case goMod
    case goWork
    case toolchain
    case manualOverride
    case bundledDefault
}

/// Result of resolving a project's target Go version (FR-2).
public struct ResolvedGoVersion: Sendable, Hashable, Codable {
    public var version: GoVersion
    public var source: GoVersionSource

    public init(version: GoVersion, source: GoVersionSource) {
        self.version = version
        self.source = source
    }
}

/// Resolves the target Go version in a deterministic order (FR-2 / DOC-2, L-4):
/// 1. `go.mod` (`go X.Y[.Z]`, searching `projectRoot` and parent directories)
/// 2. `go.work` (`go X.Y[.Z]`, searching `projectRoot` and parent directories)
/// 3. Installed `go` toolchain (`go version`)
public enum GoVersionResolver {
    public static func resolve(
        projectRoot: URL?,
        toolchainVersionProvider: (@Sendable () -> GoVersion?)? = nil
    ) -> ResolvedGoVersion? {
        if let root = projectRoot {
            if let v = findDirectiveWalkingUp(from: root, fileName: "go.mod") {
                return ResolvedGoVersion(version: v, source: .goMod)
            }
            if let v = findDirectiveWalkingUp(from: root, fileName: "go.work") {
                return ResolvedGoVersion(version: v, source: .goWork)
            }
        }
        // S-2: when an explicit provider is supplied (e.g. cached UI value), never fall through to blocking detection.
        let detected: GoVersion? = if let provider = toolchainVersionProvider {
            provider()
        } else {
            detectInstalledToolchainVersion()
        }
        if let v = detected {
            return ResolvedGoVersion(version: v, source: .toolchain)
        }
        return nil
    }

    /// Async non-blocking version resolution (S-2: uses `detectInstalledToolchainVersionAsync` instead of semaphore wait).
    public static func resolveAsync(
        projectRoot: URL?,
        toolchainVersionProvider: (@Sendable () -> GoVersion?)? = nil
    ) async -> ResolvedGoVersion? {
        if let root = projectRoot {
            if let v = findDirectiveWalkingUp(from: root, fileName: "go.mod") {
                return ResolvedGoVersion(version: v, source: .goMod)
            }
            if let v = findDirectiveWalkingUp(from: root, fileName: "go.work") {
                return ResolvedGoVersion(version: v, source: .goWork)
            }
        }
        let detected: GoVersion? = if let provider = toolchainVersionProvider {
            provider()
        } else {
            await detectInstalledToolchainVersionAsync()
        }
        if let v = detected {
            return ResolvedGoVersion(version: v, source: .toolchain)
        }
        return nil
    }

    private static func findDirectiveWalkingUp(from start: URL, fileName: String) -> GoVersion? {
        var dir = start.standardizedFileURL
        var depth = 0
        while depth < 16 {
            let candidate = dir.appendingPathComponent(fileName)
            if let text = try? String(contentsOf: candidate, encoding: .utf8),
               let v = parseGoDirective(in: text) {
                return v
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
            depth += 1
        }
        return nil
    }

    /// Extracts the `go 1.xx[.y]` directive (or fallback `toolchain go1.xx[.y]`) from a `go.mod` / `go.work` file.
    public static func parseGoDirective(in text: String) -> GoVersion? {
        var toolchainFallback: GoVersion?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let commentIdx = line.range(of: "//") {
                line = String(line[..<commentIdx.lowerBound])
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("go ") || trimmed.hasPrefix("go\t") {
                let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let v = GoVersion(parsing: rest) {
                    return v
                }
            } else if toolchainFallback == nil,
                      trimmed.hasPrefix("toolchain ") || trimmed.hasPrefix("toolchain\t") {
                let rest = trimmed.dropFirst("toolchain".count).trimmingCharacters(in: .whitespaces)
                if let v = GoVersion(parsing: rest) {
                    toolchainFallback = v
                }
            }
        }
        return toolchainFallback
    }

    /// Runs `go version` via `ToolLocator` if available; returns nil offline/when `go` is absent.
    public static func detectInstalledToolchainVersion(locator: ToolLocator = .shared) -> GoVersion? {
        guard let goExe = locator.find("go") else { return nil }
        guard let output = runShortCommand(executable: goExe, arguments: ["version"], env: locator.environment) else {
            return nil
        }
        return GoVersion(parsing: output)
    }

    /// Async non-blocking `go version` detection (R-10a: never blocks a thread with semaphore wait).
    public static func detectInstalledToolchainVersionAsync(locator: ToolLocator = .shared) async -> GoVersion? {
        guard let goExe = locator.find("go") else { return nil }
        guard let output = await runShortCommandAsync(executable: goExe, arguments: ["version"], env: locator.environment) else {
            return nil
        }
        return GoVersion(parsing: output)
    }

    /// Runs `go env GOROOT` via `ToolLocator` if available.
    public static func detectGoroot(locator: ToolLocator = .shared) -> URL? {
        guard let goExe = locator.find("go") else { return nil }
        guard let output = runShortCommand(executable: goExe, arguments: ["env", "GOROOT"], env: locator.environment) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Async non-blocking `go env GOROOT` detection (R-10a).
    public static func detectGorootAsync(locator: ToolLocator = .shared) async -> URL? {
        guard let goExe = locator.find("go") else { return nil }
        guard let output = await runShortCommandAsync(executable: goExe, arguments: ["env", "GOROOT"], env: locator.environment) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func runShortCommandAsync(executable: String, arguments: [String], env: [String: String]) async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                let finished = LockedFlag()
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if finished.trySet() {
                        if proc.isRunning { proc.terminate() }
                        continuation.resume(returning: nil)
                    }
                }
                proc.terminationHandler = { _ in
                    timeoutTask.cancel()
                    if finished.trySet() {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: String(data: data, encoding: .utf8))
                    }
                }
                do {
                    try proc.run()
                    if Task.isCancelled, proc.isRunning {
                        proc.terminate()
                    }
                } catch {
                    timeoutTask.cancel()
                    if finished.trySet() {
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    private static func runShortCommand(executable: String, arguments: [String], env: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sema.signal() }
        do {
            try proc.run()
        } catch {
            return nil
        }
        if sema.wait(timeout: .now() + .seconds(2)) == .timedOut {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

/// Thread-safe one-shot flag used to guard continuation resumption on process completion/timeout.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

/// Evaluates whether a chunk with introduction version `since` is available in `target` (FR-10, UX-2).
public enum GoVersionGate {
    public enum Verdict: Sendable, Hashable {
        /// Allowed and usable in the target Go version.
        case allowed
        /// Requires a newer Go version than `target`; must not be shown as usable or inserted.
        case requiresNewer(since: GoVersion)
    }

    public static func evaluate(since: String?, target: GoVersion) -> Verdict {
        guard let since, !since.isEmpty, let sinceVer = GoVersion(parsing: since) else {
            // FR-8: unknown `since` stays recorded as unknown and is not guessed.
            return .allowed
        }
        if target.isAtLeast(sinceVer) {
            return .allowed
        }
        return .requiresNewer(since: sinceVer)
    }
}
