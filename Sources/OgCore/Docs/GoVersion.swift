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

    /// Parses strings such as `"1.22"`, `"1.23.1"`, `"go1.22.0"`, or `"go version go1.23.2 darwin/arm64"`.
    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Handle `go version go1.23.2 darwin/arm64` or `go 1.22.1` or `go1.22` or `1.22`.
        let token: String
        if let range = trimmed.range(of: #"go\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) {
            token = String(trimmed[range].dropFirst(2))
        } else if let range = trimmed.range(of: #"\b\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) {
            token = String(trimmed[range])
        } else {
            return nil
        }
        let parts = token.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count >= 3 ? parts[2] : 0
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

/// Resolves the target Go version in a deterministic order (FR-2 / DOC-2):
/// 1. `go.mod` (`go X.Y[.Z]`)
/// 2. `go.work` (`go X.Y[.Z]`)
/// 3. Installed `go` toolchain (`go version`)
public enum GoVersionResolver {
    public static func resolve(
        projectRoot: URL?,
        toolchainVersionProvider: (() -> GoVersion?)? = nil
    ) -> ResolvedGoVersion? {
        if let root = projectRoot {
            let goMod = root.appendingPathComponent("go.mod")
            if let text = try? String(contentsOf: goMod, encoding: .utf8),
               let v = parseGoDirective(in: text) {
                return ResolvedGoVersion(version: v, source: .goMod)
            }
            let goWork = root.appendingPathComponent("go.work")
            if let text = try? String(contentsOf: goWork, encoding: .utf8),
               let v = parseGoDirective(in: text) {
                return ResolvedGoVersion(version: v, source: .goWork)
            }
        }
        let detected = toolchainVersionProvider?() ?? detectInstalledToolchainVersion()
        if let v = detected {
            return ResolvedGoVersion(version: v, source: .toolchain)
        }
        return nil
    }

    /// Extracts the `go 1.xx[.y]` directive from a `go.mod` or `go.work` file.
    public static func parseGoDirective(in text: String) -> GoVersion? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let commentIdx = line.range(of: "//") {
                line = String(line[..<commentIdx.lowerBound])
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("go ") || trimmed.hasPrefix("go\t") else { continue }
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let v = GoVersion(parsing: rest) {
                return v
            }
        }
        return nil
    }

    /// Runs `go version` via `ToolLocator` if available; returns nil offline/when `go` is absent.
    public static func detectInstalledToolchainVersion(locator: ToolLocator = .shared) -> GoVersion? {
        guard let goExe = locator.find("go") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: goExe)
        proc.arguments = ["version"]
        proc.environment = locator.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(10_000) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return GoVersion(parsing: output)
    }

    /// Runs `go env GOROOT` via `ToolLocator` if available.
    public static func detectGoroot(locator: ToolLocator = .shared) -> URL? {
        guard let goExe = locator.find("go") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: goExe)
        proc.arguments = ["env", "GOROOT"]
        proc.environment = locator.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(10_000) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
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
