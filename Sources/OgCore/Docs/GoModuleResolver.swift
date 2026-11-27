import CryptoKit
import Foundation

/// Unique identifier for a Go module dependency at an exact version (Issue #27, DOC-12).
/// For local `replace` directives, `localSourcePath` is included so two projects replacing the same
/// module with different local directories never collide on a shared pack directory.
public struct GoModuleKey: Sendable, Hashable, Codable, Comparable {
    public var modulePath: String
    public var version: String
    public var localSourcePath: String?

    public init(modulePath: String, version: String, localSourcePath: String? = nil) {
        self.modulePath = modulePath
        self.version = version
        self.localSourcePath = localSourcePath
    }

    /// Human-readable `"module@version"` label.
    public var displayID: String {
        "\(modulePath)@\(version)"
    }

    /// Filesystem-safe deterministic directory name for storing a dependency pack.
    public var storageKey: String {
        let hashInput = localSourcePath.map { "\(displayID)|local:\($0)" } ?? displayID
        let digest = SHA256.hash(data: Data(hashInput.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let rawTail = modulePath.split(separator: "/").last.map(String.init) ?? "mod"
        let safeTail = rawTail.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")) ? ch : "_"
        }
        let safeVer = version.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_")) ? ch : "_"
        }
        return "\(String(safeTail))-\(String(safeVer))-\(hex)"
    }

    public static func < (lhs: GoModuleKey, rhs: GoModuleKey) -> Bool {
        if lhs.modulePath != rhs.modulePath { return lhs.modulePath < rhs.modulePath }
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        return (lhs.localSourcePath ?? "") < (rhs.localSourcePath ?? "")
    }
}

/// Target of a `replace` directive in `go.mod` or `go.work`.
public enum GoModuleReplaceTarget: Sendable, Hashable {
    case module(path: String, version: String)
    case localPath(URL)
}

/// Resolved project dependency from `go.mod` / `go.work` and its exact local cache location (Issue #27).
public struct GoModuleDependency: Sendable, Hashable {
    /// Import path prefix declared in `require` (used as the package import prefix).
    public var modulePath: String
    /// Exact version required by `go.mod` / `go.work` (or module replacement target version; for local path replace, retains the required version while `localReplaceDirectory` holds the source path).
    public var version: String
    /// Whether the dependency is marked `// indirect` in all referencing `go.mod` files.
    public var isIndirect: Bool
    /// Actual module path in GOMODCACHE when redirected by a module-to-module `replace`; equals `modulePath` otherwise.
    public var sourceModulePath: String
    /// Actual module version in GOMODCACHE when redirected by a module-to-module `replace`; equals `version` otherwise.
    public var sourceVersion: String
    /// Local directory when redirected by a local path `replace` directive.
    public var localReplaceDirectory: URL?
    /// Exact verified directory on disk containing this dependency's source, or `nil` if absent from module cache.
    /// Never populated with a different version (DOC-12b).
    public var cacheDirectory: URL?

    public init(
        modulePath: String,
        version: String,
        isIndirect: Bool = false,
        sourceModulePath: String? = nil,
        sourceVersion: String? = nil,
        localReplaceDirectory: URL? = nil,
        cacheDirectory: URL? = nil
    ) {
        self.modulePath = modulePath
        self.version = version
        self.isIndirect = isIndirect
        self.sourceModulePath = sourceModulePath ?? modulePath
        self.sourceVersion = sourceVersion ?? version
        self.localReplaceDirectory = localReplaceDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// True only when the exact requested version exists locally on disk.
    public var isCached: Bool {
        cacheDirectory != nil
    }

    /// Pack key under which this dependency's documentation pack is stored.
    public var packKey: GoModuleKey {
        GoModuleKey(
            modulePath: modulePath,
            version: version,
            localSourcePath: localReplaceDirectory?.standardizedFileURL.path
        )
    }

    /// Human-readable `"module@version"` string.
    public var displayID: String {
        packKey.displayID
    }
}

/// Parsed representation of a single `go.mod` file.
public struct ParsedGoMod: Sendable, Hashable {
    public struct RequireEntry: Sendable, Hashable {
        public var path: String
        public var version: String
        public var isIndirect: Bool
    }

    public struct ReplaceEntry: Sendable, Hashable {
        public var oldPath: String
        public var oldVersion: String?
        public var target: GoModuleReplaceTarget
    }

    public var modulePath: String?
    public var requires: [RequireEntry]
    public var replaces: [ReplaceEntry]

    public init(modulePath: String? = nil, requires: [RequireEntry] = [], replaces: [ReplaceEntry] = []) {
        self.modulePath = modulePath
        self.requires = requires
        self.replaces = replaces
    }
}

/// Parsed representation of a `go.work` file.
public struct ParsedGoWork: Sendable, Hashable {
    public var useDirectories: [URL]
    public var replaces: [ParsedGoMod.ReplaceEntry]

    public init(useDirectories: [URL] = [], replaces: [ParsedGoMod.ReplaceEntry] = []) {
        self.useDirectories = useDirectories
        self.replaces = replaces
    }
}

/// Resolves active Go module dependencies from `go.mod` / `go.work` and maps them strictly to local
/// `GOMODCACHE` directories without network access or version substitution (Issue #27, DOC-12).
public enum GoModuleResolver {
    // MARK: - Module cache path escaping (golang.org/x/mod/module.EscapePath)

    /// Escapes a Go module path or version for `GOMODCACHE` lookup: every ASCII uppercase letter `A`-`Z`
    /// becomes `!` followed by its lowercase equivalent (e.g. `github.com/Azure/go` -> `github.com/!azure/go`).
    public static func escapeModulePath(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 4)
        for scalar in raw.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                out.append("!")
                if let lower = UnicodeScalar(scalar.value + 32) {
                    out.append(Character(lower))
                }
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }

    /// Computes the exact expected directory inside `moduleCacheRoot` for `(modulePath, version)`.
    public static func cacheDirectoryURL(
        modulePath: String,
        version: String,
        moduleCacheRoot: URL
    ) -> URL {
        let escapedPath = escapeModulePath(modulePath)
        let escapedVer = escapeModulePath(version)
        return moduleCacheRoot.appendingPathComponent("\(escapedPath)@\(escapedVer)", isDirectory: true)
    }

    // MARK: - GOMODCACHE detection

    /// Detects the local Go module cache root (`GOMODCACHE` or `$GOPATH/pkg/mod` or `~/go/pkg/mod`).
    public static func detectModuleCacheRoot(locator: ToolLocator = .shared) -> URL? {
        if let goExe = locator.find("go"),
           let raw = runShortCommand(executable: goExe, arguments: ["env", "GOMODCACHE"], env: locator.environment) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed, isDirectory: true)
            }
        }
        return fallbackModuleCacheRoot(environment: locator.environment)
    }

    /// Async non-blocking `GOMODCACHE` detection.
    public static func detectModuleCacheRootAsync(locator: ToolLocator = .shared) async -> URL? {
        if let goExe = locator.find("go"),
           let raw = await runShortCommandAsync(executable: goExe, arguments: ["env", "GOMODCACHE"], env: locator.environment) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed, isDirectory: true)
            }
        }
        return fallbackModuleCacheRoot(environment: locator.environment)
    }

    public static func fallbackModuleCacheRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let explicit = environment["GOMODCACHE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        if let gopath = environment["GOPATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !gopath.isEmpty {
            let firstEntry = gopath.split(separator: ":").first.map(String.init) ?? gopath
            if !firstEntry.isEmpty {
                return URL(fileURLWithPath: firstEntry, isDirectory: true)
                    .appendingPathComponent("pkg/mod", isDirectory: true)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("go/pkg/mod", isDirectory: true)
    }

    // MARK: - go.mod & go.work parsing

    /// Parses `module`, `require`, and `replace` directives from a `go.mod` file.
    public static func parseGoMod(text: String, baseDirectory: URL) -> ParsedGoMod {
        var result = ParsedGoMod()
        enum BlockKind { case none, require, replace, other }
        var block: BlockKind = .none

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let (code, comment) = splitLineComment(String(rawLine))
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if block != .none {
                if trimmed == ")" {
                    block = .none
                    continue
                }
                switch block {
                case .require:
                    if let entry = parseRequireTokens(tokenize(trimmed), comment: comment) {
                        result.requires.append(entry)
                    }
                case .replace:
                    if let entry = parseReplaceTokens(tokenize(trimmed), baseDirectory: baseDirectory) {
                        result.replaces.append(entry)
                    }
                case .other, .none:
                    break
                }
                continue
            }

            let tokens = tokenize(trimmed)
            guard let first = tokens.first else { continue }

            switch first {
            case "module":
                if tokens.count >= 2 {
                    result.modulePath = tokens[1]
                }
            case "require":
                if tokens.count >= 2 && tokens[1] == "(" {
                    block = .require
                } else if trimmed.hasSuffix("(") {
                    block = .require
                } else if let entry = parseRequireTokens(Array(tokens.dropFirst()), comment: comment) {
                    result.requires.append(entry)
                }
            case "replace":
                if tokens.count >= 2 && tokens[1] == "(" {
                    block = .replace
                } else if trimmed.hasSuffix("(") {
                    block = .replace
                } else if let entry = parseReplaceTokens(Array(tokens.dropFirst()), baseDirectory: baseDirectory) {
                    result.replaces.append(entry)
                }
            case "exclude", "retract", "tool", "ignore":
                if tokens.contains("(") && !tokens.contains(")") {
                    block = .other
                }
            default:
                break
            }
        }
        return result
    }

    /// Parses `use` and `replace` directives from a `go.work` file.
    public static func parseGoWork(text: String, baseDirectory: URL) -> ParsedGoWork {
        var result = ParsedGoWork()
        enum BlockKind { case none, use, replace, other }
        var block: BlockKind = .none

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let (code, _) = splitLineComment(String(rawLine))
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if block != .none {
                if trimmed == ")" {
                    block = .none
                    continue
                }
                switch block {
                case .use:
                    if let first = tokenize(trimmed).first {
                        result.useDirectories.append(resolveRelativePath(first, baseDirectory: baseDirectory))
                    }
                case .replace:
                    if let entry = parseReplaceTokens(tokenize(trimmed), baseDirectory: baseDirectory) {
                        result.replaces.append(entry)
                    }
                case .other, .none:
                    break
                }
                continue
            }

            let tokens = tokenize(trimmed)
            guard let first = tokens.first else { continue }

            switch first {
            case "use":
                if tokens.count >= 2 && tokens[1] == "(" {
                    block = .use
                } else if trimmed.hasSuffix("(") {
                    block = .use
                } else if tokens.count >= 2 {
                    result.useDirectories.append(resolveRelativePath(tokens[1], baseDirectory: baseDirectory))
                }
            case "replace":
                if tokens.count >= 2 && tokens[1] == "(" {
                    block = .replace
                } else if trimmed.hasSuffix("(") {
                    block = .replace
                } else if let entry = parseReplaceTokens(Array(tokens.dropFirst()), baseDirectory: baseDirectory) {
                    result.replaces.append(entry)
                }
            default:
                if tokens.contains("(") && !tokens.contains(")") {
                    block = .other
                }
            }
        }
        return result
    }

    // MARK: - Project dependency resolution

    /// Locates the governing `go.mod` / `go.work` file(s) for `projectRoot`.
    public static func findProjectModuleFiles(projectRoot: URL) -> [URL] {
        var files: [URL] = []
        if let work = findFileWalkingUp(from: projectRoot, fileName: "go.work") {
            files.append(work)
        }
        if let mod = findFileWalkingUp(from: projectRoot, fileName: "go.mod") {
            files.append(mod)
        }
        return files
    }

    /// Resolves all active dependencies for `projectRoot` from `go.work` and/or `go.mod`,
    /// applying MVS and `replace` directives and verifying exact presence in `moduleCacheRoot`.
    /// Never substitutes a missing version with another version from cache (DOC-12b).
    public static func resolveDependencies(
        projectRoot: URL,
        moduleCacheRoot: URL? = nil,
        locator: ToolLocator = .shared
    ) -> [GoModuleDependency] {
        let fm = FileManager.default
        // L-2: when moduleCacheRoot is not explicitly supplied, consult `go env GOMODCACHE` (covers `go env -w`) before env/default fallbacks.
        let resolvedCacheRoot = moduleCacheRoot ?? detectModuleCacheRoot(locator: locator)

        var parsedMods: [ParsedGoMod] = []
        var isWorkspaceMode = false
        var workReplaces: [ParsedGoMod.ReplaceEntry] = []
        var workspaceModulePaths = Set<String>()

        if let workURL = findFileWalkingUp(from: projectRoot, fileName: "go.work"),
           let workText = try? String(contentsOf: workURL, encoding: .utf8) {
            isWorkspaceMode = true
            let work = parseGoWork(text: workText, baseDirectory: workURL.deletingLastPathComponent())
            workReplaces = work.replaces
            for useDir in work.useDirectories {
                let modURL = useDir.appendingPathComponent("go.mod")
                if let text = try? String(contentsOf: modURL, encoding: .utf8) {
                    let parsed = parseGoMod(text: text, baseDirectory: useDir)
                    if let mp = parsed.modulePath { workspaceModulePaths.insert(mp) }
                    parsedMods.append(parsed)
                }
            }
        }

        if parsedMods.isEmpty,
           let modURL = findFileWalkingUp(from: projectRoot, fileName: "go.mod"),
           let modText = try? String(contentsOf: modURL, encoding: .utf8) {
            isWorkspaceMode = false
            let parsed = parseGoMod(text: modText, baseDirectory: modURL.deletingLastPathComponent())
            if let mp = parsed.modulePath { workspaceModulePaths.insert(mp) }
            parsedMods.append(parsed)
        }

        guard !parsedMods.isEmpty else { return [] }

        // Minimal Version Selection (MVS): highest version wins; direct beats indirect.
        struct SelectedReq {
            var version: String
            var isIndirect: Bool
        }
        var selected: [String: SelectedReq] = [:]
        var modReplaces: [ParsedGoMod.ReplaceEntry] = []

        for mod in parsedMods {
            modReplaces.append(contentsOf: mod.replaces)
            for req in mod.requires {
                if workspaceModulePaths.contains(req.path) { continue }
                if var existing = selected[req.path] {
                    if compareModuleVersions(req.version, existing.version) == .orderedDescending {
                        existing.version = req.version
                    }
                    existing.isIndirect = existing.isIndirect && req.isIndirect
                    selected[req.path] = existing
                } else {
                    selected[req.path] = SelectedReq(version: req.version, isIndirect: req.isIndirect)
                }
            }
        }

        // L-3: Per Go workspace semantics, in `go.work` mode only `go.work` `replace` directives apply
        // (individual module `go.mod` replaces are ignored in workspace mode).
        let activeReplaces = isWorkspaceMode ? workReplaces : modReplaces
        func matchReplace(path: String, version: String) -> GoModuleReplaceTarget? {
            if let exact = activeReplaces.first(where: { $0.oldPath == path && $0.oldVersion == version }) {
                return exact.target
            }
            if let generic = activeReplaces.first(where: { $0.oldPath == path && $0.oldVersion == nil }) {
                return generic.target
            }
            return nil
        }

        var deps: [GoModuleDependency] = []
        deps.reserveCapacity(selected.count)

        for (modPath, req) in selected {
            let replaceTarget = matchReplace(path: modPath, version: req.version)
            switch replaceTarget {
            case .localPath(let localDir):
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: localDir.path, isDirectory: &isDir) && isDir.boolValue
                deps.append(GoModuleDependency(
                    modulePath: modPath,
                    version: req.version,
                    isIndirect: req.isIndirect,
                    sourceModulePath: modPath,
                    sourceVersion: req.version,
                    localReplaceDirectory: localDir,
                    cacheDirectory: exists ? localDir : nil
                ))
            case .module(let newPath, let newVersion):
                let verifiedDir = verifyExactCacheDir(
                    modulePath: newPath,
                    version: newVersion,
                    moduleCacheRoot: resolvedCacheRoot
                )
                deps.append(GoModuleDependency(
                    modulePath: modPath,
                    version: newVersion,
                    isIndirect: req.isIndirect,
                    sourceModulePath: newPath,
                    sourceVersion: newVersion,
                    localReplaceDirectory: nil,
                    cacheDirectory: verifiedDir
                ))
            case nil:
                let verifiedDir = verifyExactCacheDir(
                    modulePath: modPath,
                    version: req.version,
                    moduleCacheRoot: resolvedCacheRoot
                )
                deps.append(GoModuleDependency(
                    modulePath: modPath,
                    version: req.version,
                    isIndirect: req.isIndirect,
                    sourceModulePath: modPath,
                    sourceVersion: req.version,
                    localReplaceDirectory: nil,
                    cacheDirectory: verifiedDir
                ))
            }
        }

        // Direct dependencies first, then alphabetical by module path.
        deps.sort {
            if $0.isIndirect != $1.isIndirect { return !$0.isIndirect }
            if $0.modulePath != $1.modulePath { return $0.modulePath < $1.modulePath }
            return $0.version < $1.version
        }
        return deps
    }

    /// Verifies that the exact `(modulePath, version)` directory exists in `moduleCacheRoot`.
    /// Never falls back to another version directory.
    private static func verifyExactCacheDir(
        modulePath: String,
        version: String,
        moduleCacheRoot: URL?
    ) -> URL? {
        guard let cacheRoot = moduleCacheRoot else { return nil }
        let candidate = cacheDirectoryURL(modulePath: modulePath, version: version, moduleCacheRoot: cacheRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return candidate
    }

    // MARK: - Lightweight SPDX-style License Detection (DES-DEP-4)

    /// Detects a concise SPDX-style license identifier (e.g. `"MIT"`, `"Apache-2.0"`, `"BSD-3-Clause"`)
    /// from standard license files at the module root. Returns `nil` if no license file or known pattern is found.
    public static func detectLicenseIdentifier(in moduleRoot: URL) -> String? {
        let fm = FileManager.default
        let candidates = [
            "LICENSE", "LICENSE.txt", "LICENSE.md", "LICENSE.MIT", "LICENSE.APACHE",
            "LICENCE", "LICENCE.txt", "LICENCE.md", "COPYING", "COPYING.txt"
        ]
        for name in candidates {
            let url = moduleRoot.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            if let detected = classifyLicenseText(text) {
                return detected
            }
        }
        return nil
    }

    public static func classifyLicenseText(_ rawText: String) -> String? {
        let lower = rawText.lowercased()
        if lower.contains("apache license") && lower.contains("version 2.0") {
            return "Apache-2.0"
        }
        if lower.contains("permission is hereby granted, free of charge")
            && lower.contains("without restriction") {
            return "MIT"
        }
        if lower.contains("redistribution and use in source and binary forms") {
            if lower.contains("neither the name") || lower.contains("nor the names of its contributors") {
                return "BSD-3-Clause"
            }
            return "BSD-2-Clause"
        }
        if lower.contains("permission to use, copy, modify, and/or distribute this software for any purpose")
            || lower.contains("isc license") {
            return "ISC"
        }
        if lower.contains("mozilla public license") && lower.contains("2.0") {
            return "MPL-2.0"
        }
        if lower.contains("gnu lesser general public license") {
            return lower.contains("version 3") ? "LGPL-3.0" : "LGPL-2.1"
        }
        if lower.contains("gnu general public license") {
            return lower.contains("version 3") ? "GPL-3.0" : "GPL-2.0"
        }
        if lower.contains("this is free and unencumbered software released into the public domain") {
            return "Unlicense"
        }
        if lower.contains("cc0 1.0 universal") {
            return "CC0-1.0"
        }
        return nil
    }

    // MARK: - Semver comparison for MVS

    public static func compareModuleVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        let l = parseSemver(lhs)
        let r = parseSemver(rhs)
        guard let l, let r else {
            return lhs.compare(rhs, options: .numeric)
        }
        if l.major != r.major { return l.major < r.major ? .orderedAscending : .orderedDescending }
        if l.minor != r.minor { return l.minor < r.minor ? .orderedAscending : .orderedDescending }
        if l.patch != r.patch { return l.patch < r.patch ? .orderedAscending : .orderedDescending }
        // No prerelease > prerelease (SemVer 2.0 §11)
        switch (l.prerelease, r.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lp?, let rp?):
            return comparePrerelease(lp, rp)
        }
    }

    /// SemVer 2.0 §11.4 dot-separated prerelease identifier comparison (L-4).
    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rParts = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let count = min(lParts.count, rParts.count)
        for i in 0..<count {
            let lp = lParts[i]
            let rp = rParts[i]
            if lp == rp { continue }
            let lNum = lp.allSatisfy(\.isNumber) ? Int(lp) : nil
            let rNum = rp.allSatisfy(\.isNumber) ? Int(rp) : nil
            switch (lNum, rNum) {
            case (let ln?, let rn?):
                return ln < rn ? .orderedAscending : .orderedDescending
            case (_?, nil):
                // Numeric identifiers always have lower precedence than non-numeric identifiers.
                return .orderedAscending
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                return lp < rp ? .orderedAscending : .orderedDescending
            }
        }
        if lParts.count != rParts.count {
            return lParts.count < rParts.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private struct ParsedSemver {
        var major: Int
        var minor: Int
        var patch: Int
        var prerelease: String?
    }

    private static func parseSemver(_ raw: String) -> ParsedSemver? {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        // Drop +incompatible or +build metadata
        if let plus = s.firstIndex(of: "+") {
            s = String(s[..<plus])
        }
        var prerelease: String?
        if let dash = s.firstIndex(of: "-") {
            prerelease = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".")
        guard parts.count == 3,
              let maj = Int(parts[0]),
              let min = Int(parts[1]),
              let pat = Int(parts[2]) else { return nil }
        return ParsedSemver(major: maj, minor: min, patch: pat, prerelease: prerelease)
    }

    // MARK: - Parsing helpers

    private static func findFileWalkingUp(from start: URL, fileName: String) -> URL? {
        var dir = start.standardizedFileURL
        var depth = 0
        let fm = FileManager.default
        while depth < 16 {
            let candidate = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
            depth += 1
        }
        return nil
    }

    private static func splitLineComment(_ line: String) -> (code: String, comment: String) {
        var inQuote = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            let next = line.index(after: idx)
            if ch == "\"" {
                inQuote.toggle()
            } else if !inQuote && ch == "/" && next < line.endIndex && line[next] == "/" {
                return (String(line[..<idx]), String(line[line.index(after: next)...]))
            }
            idx = next
        }
        return (line, "")
    }

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for ch in line {
            if inQuote {
                if ch == quoteChar {
                    inQuote = false
                    tokens.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "`" {
                if !current.isEmpty { tokens.append(current); current = "" }
                inQuote = true
                quoteChar = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func parseRequireTokens(_ tokens: [String], comment: String) -> ParsedGoMod.RequireEntry? {
        guard tokens.count >= 2 else { return nil }
        let path = tokens[0]
        let version = tokens[1]
        guard !path.isEmpty, !version.isEmpty, version.hasPrefix("v") else { return nil }
        let isIndirect = comment.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("indirect")
        return ParsedGoMod.RequireEntry(path: path, version: version, isIndirect: isIndirect)
    }

    private static func parseReplaceTokens(_ tokens: [String], baseDirectory: URL) -> ParsedGoMod.ReplaceEntry? {
        guard let arrowIdx = tokens.firstIndex(of: "=>"), arrowIdx >= 1, arrowIdx + 1 < tokens.count else {
            return nil
        }
        let lhs = Array(tokens[..<arrowIdx])
        let rhs = Array(tokens[(arrowIdx + 1)...])
        let oldPath = lhs[0]
        let oldVersion = lhs.count >= 2 ? lhs[1] : nil

        if rhs.count >= 2 && rhs[1].hasPrefix("v") {
            return ParsedGoMod.ReplaceEntry(
                oldPath: oldPath,
                oldVersion: oldVersion,
                target: .module(path: rhs[0], version: rhs[1])
            )
        } else if rhs.count == 1 {
            let dir = resolveRelativePath(rhs[0], baseDirectory: baseDirectory)
            return ParsedGoMod.ReplaceEntry(
                oldPath: oldPath,
                oldVersion: oldVersion,
                target: .localPath(dir)
            )
        }
        return nil
    }

    private static func resolveRelativePath(_ raw: String, baseDirectory: URL) -> URL {
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
        return baseDirectory.appendingPathComponent(raw, isDirectory: true).standardizedFileURL
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
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
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
                proc.terminationHandler = { p in
                    timeoutTask.cancel()
                    if finished.trySet() {
                        guard p.terminationStatus == 0 else {
                            continuation.resume(returning: nil)
                            return
                        }
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
}
