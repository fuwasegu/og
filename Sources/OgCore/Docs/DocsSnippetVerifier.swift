import Foundation

/// Protocol for local Go snippet verification (DES-A3, DOC-11).
public protocol DocsSnippetVerifying: Sendable {
    func verify(snippet: String, targetVersion: GoVersion) async -> DocsSnippetVerificationStatus
    func verify(
        snippet: String,
        targetVersion: GoVersion,
        knownExternalPackageIdents: Set<String>
    ) async -> DocsSnippetVerificationStatus
}

public extension DocsSnippetVerifying {
    func verify(
        snippet: String,
        targetVersion: GoVersion,
        knownExternalPackageIdents: Set<String>
    ) async -> DocsSnippetVerificationStatus {
        await verify(snippet: snippet, targetVersion: targetVersion)
    }
}

/// Verifies generated Go snippets locally in a temporary module pinned to `targetVersion`
/// with `GOPROXY=off` and `CGO_ENABLED=0` (zero network access, zero C compiler invocation, DES-A3, Issue #24).
public struct DocsSnippetVerifier: DocsSnippetVerifying, Sendable {
    public let locator: ToolLocator
    public let timeoutSeconds: TimeInterval

    private static let stdlibPackageByIdent: [String: String] = [
        "bufio": "bufio",
        "bytes": "bytes",
        "context": "context",
        "errors": "errors",
        "filepath": "path/filepath",
        "fmt": "fmt",
        "http": "net/http",
        "io": "io",
        "json": "encoding/json",
        "maps": "maps",
        "os": "os",
        "regexp": "regexp",
        "slices": "slices",
        "slog": "log/slog",
        "sort": "sort",
        "strconv": "strconv",
        "strings": "strings",
        "sync": "sync",
        "time": "time",
        "url": "net/url"
    ]

    public init(locator: ToolLocator = .shared, timeoutSeconds: TimeInterval = 20) {
        self.locator = locator
        self.timeoutSeconds = timeoutSeconds
    }

    public func verify(snippet: String, targetVersion: GoVersion) async -> DocsSnippetVerificationStatus {
        await verify(snippet: snippet, targetVersion: targetVersion, knownExternalPackageIdents: [])
    }

    public func verify(
        snippet: String,
        targetVersion: GoVersion,
        knownExternalPackageIdents: Set<String>
    ) async -> DocsSnippetVerificationStatus {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(errorSummary: "empty snippet")
        }
        guard !Task.isCancelled else {
            return .unverified(reason: "cancelled")
        }
        // Y-7: Never invoke a host C compiler on untrusted LLM output.
        if Self.containsCgoImport(trimmed) {
            return .unverified(reason: "CGO (import \"C\") はローカル検証対象外です")
        }
        guard let goExe = locator.find("go") else {
            return .unverified(reason: "Go ツールチェーン未検出")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return .unverified(reason: "一時ディレクトリ作成失敗")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let goMod = "module ogverify\n\ngo \(targetVersion.minorKey)\n"
        do {
            try goMod.write(to: tempDir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            try Self.wrapSnippetAsGoFile(trimmed).write(to: tempDir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        } catch {
            return .unverified(reason: "検証ファイル書き込み失敗")
        }

        var result = await runGoBuild(
            executable: goExe,
            workingDirectory: tempDir,
            baseEnvironment: locator.environment,
            timeoutSeconds: timeoutSeconds
        )

        // Y-9 / (c): When the compiler reports `undefined: <stdlib_ident>`, inject the missing
        // stdlib imports (into either an omitted or existing import block) and retry once.
        if result.exitCode != 0 && !result.timedOut && !result.cancelled {
            let missing = Self.extractMissingStdlibImports(from: result.stderr)
            if !missing.isEmpty {
                do {
                    let retriedGo = Self.wrapSnippetAsGoFile(trimmed, extraImports: missing)
                    try retriedGo.write(to: tempDir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
                    result = await runGoBuild(
                        executable: goExe,
                        workingDirectory: tempDir,
                        baseEnvironment: locator.environment,
                        timeoutSeconds: timeoutSeconds
                    )
                } catch {
                    return .unverified(reason: "検証ファイル書き込み失敗")
                }
            }
        }

        if result.cancelled {
            return .unverified(reason: "cancelled")
        }
        if result.timedOut {
            return .unverified(reason: "検証タイムアウト")
        }
        if result.exitCode == 0 {
            return .verified
        }
        return Self.classifyFailure(
            stderr: result.stderr,
            targetVersion: targetVersion,
            knownExternalPackageIdents: knownExternalPackageIdents
        )
    }

    static func containsCgoImport(_ snippet: String) -> Bool {
        snippet.range(of: #"(?m)(?:import\s+"C"|^\s*"C"\s*$)"#, options: .regularExpression) != nil
    }

    /// (d) Matches an actual top-level `import` declaration at line start (ignoring comments/strings).
    static func hasExplicitImport(_ snippet: String) -> Bool {
        snippet.range(of: #"(?m)^\s*import(?:\s+"|\s*\()"#, options: .regularExpression) != nil
    }

    /// Wraps a snippet into a valid `package ogverify` file without speculative string-matching imports (Y-9).
    /// When `extraImports` are provided from compiler `undefined:` diagnostics, inserts them safely.
    public static func wrapSnippetAsGoFile(_ snippet: String, extraImports: [String] = []) -> String {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"(?m)^\s*package\s+"#, options: .regularExpression) != nil {
            return injectImportsIfNeeded(extraImports, into: trimmed) + "\n"
        }

        let isTopLevelDecl = trimmed.range(of: #"(?m)^\s*(?:func|type|import)\b"#, options: .regularExpression) != nil
        if hasExplicitImport(trimmed) {
            let withImports = injectImportsIfNeeded(extraImports, into: trimmed)
            return "package ogverify\n\n\(withImports)\n"
        }

        var importsBlock = ""
        if !extraImports.isEmpty {
            let quoted = Set(extraImports).sorted().map { "\t\"\($0)\"" }.joined(separator: "\n")
            importsBlock = "import (\n\(quoted)\n)\n\n"
        }

        let body = isTopLevelDecl ? trimmed : "func _ogVerify() {\n\(trimmed)\n}"
        return "package ogverify\n\n\(importsBlock)\(body)\n"
    }

    /// (e) Inserts missing stdlib imports only at line-start `import` / `package` declarations.
    static func injectImportsIfNeeded(_ extraImports: [String], into source: String) -> String {
        let unique = Set(extraImports).filter { pkg in
            source.range(of: #"(?m)^\s*(?:import\s+)?"\#(NSRegularExpression.escapedPattern(for: pkg))"\s*$"#, options: .regularExpression) == nil
        }.sorted()
        guard !unique.isEmpty else { return source }
        let addedLines = unique.map { "\t\"\($0)\"" }.joined(separator: "\n")
        if let range = source.range(of: #"(?m)^\s*import\s*\("#, options: .regularExpression) {
            var copy = source
            copy.insert(contentsOf: "\n" + addedLines, at: range.upperBound)
            return copy
        }
        if let range = source.range(of: #"(?m)^\s*import\s+"[^"]+"\s*$"#, options: .regularExpression) {
            let existing = String(source[range])
            let singlePkg = existing.replacingOccurrences(of: "import", with: "").trimmingCharacters(in: .whitespaces)
            let replacement = "import (\n\t\(singlePkg)\n\(addedLines)\n)"
            var copy = source
            copy.replaceSubrange(range, with: replacement)
            return copy
        }
        if let pkgRange = source.range(of: #"(?m)^\s*package\s+\S+\s*$"#, options: .regularExpression) {
            var copy = source
            copy.insert(contentsOf: "\n\nimport (\n\(addedLines)\n)", at: pkgRange.upperBound)
            return copy
        }
        return "import (\n\(addedLines)\n)\n\n" + source
    }

    static func extractMissingStdlibImports(from stderr: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for line in stderr.split(separator: "\n") {
            guard let range = line.range(of: "undefined: ") else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let ident = String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if let pkg = stdlibPackageByIdent[ident], seen.insert(pkg).inserted {
                found.append(pkg)
            }
        }
        return found
    }

    static func classifyFailure(
        stderr: String,
        targetVersion: GoVersion = GoVersion(major: 1, minor: 23),
        knownExternalPackageIdents: Set<String> = []
    ) -> DocsSnippetVerificationStatus {
        let lower = stderr.lowercased()
        if lower.contains("mise error") || lower.contains("no version is set for shim") {
            return .unverified(reason: "Go バージョンが未有効化 (mise)")
        }
        // Y-10: Host toolchain older than project targetVersion is an environment mismatch, not a snippet error.
        if lower.contains("go.mod requires go >=")
            || lower.contains("note: module requires go")
            || lower.contains("requires go1.")
            || lower.contains("compile: version") {
            return .unverified(reason: "導入済み Go toolchain が対象バージョン \(targetVersion.minorKey) より古いため未検証")
        }
        if lower.contains("no required module provides package")
            || lower.contains("cannot find package")
            || lower.contains("missing go.sum entry")
            || lower.contains("goproxy=off")
            || lower.contains("build constraints exclude all go files") {
            return .unverified(reason: "外部依存または cgo がオフライン環境で利用できません")
        }
        let summary = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(2)
            .joined(separator: " | ")
        if let undef = extractUndefinedNonStdlibSymbol(from: stderr) {
            // U-2: Do not misclassify an omitted external dependency package selector (e.g. `undefined: chi`) as `.failed`.
            if knownExternalPackageIdents.contains(undef) {
                return .unverified(reason: "外部依存パッケージ '\(undef)' を含むため単体モジュール検証の対象外です")
            }
            return .failed(errorSummary: "未定義シンボル '\(undef)'（文脈依存の変数または未定義識別子の可能性: \(summary.prefix(120))）")
        }
        return .failed(errorSummary: summary.isEmpty ? "go build failed" : String(summary.prefix(180)))
    }

    static func extractUndefinedNonStdlibSymbol(from stderr: String) -> String? {
        for line in stderr.split(separator: "\n") {
            guard let range = line.range(of: "undefined: ") else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let ident = String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if !ident.isEmpty && stdlibPackageByIdent[ident] == nil {
                return ident
            }
        }
        return nil
    }

    private struct BuildOutcome: Sendable {
        var exitCode: Int32
        var stderr: String
        var timedOut: Bool
        var cancelled: Bool
    }

    private func runGoBuild(
        executable: String,
        workingDirectory: URL,
        baseEnvironment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> BuildOutcome {
        guard !Task.isCancelled else {
            return BuildOutcome(exitCode: -1, stderr: "", timedOut: false, cancelled: true)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["build", "-mod=readonly", "./..."]
        proc.currentDirectoryURL = workingDirectory

        var env = baseEnvironment
        env["GOPROXY"] = "off"
        env["GOSUMDB"] = "off"
        env["GOWORK"] = "off"
        env["GOTOOLCHAIN"] = "local"
        env["CGO_ENABLED"] = "0"
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        // Z-10: Drain stderr incrementally with a 64 KB cap to prevent pipe-buffer deadlock or unbounded growth.
        let maxStderrBytes = 65_536
        let stderrBuffer = Locked<Data>(Data())
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.withLock { buf in
                    let remaining = maxStderrBytes - buf.count
                    if remaining > 0 {
                        buf.append(chunk.prefix(remaining))
                    }
                }
            }
        }

        let cancelledFlag = Locked<Bool>(false)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    cancelledFlag.withLock { $0 = true }
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: "", timedOut: false, cancelled: true))
                    return
                }
                let finished = LockedFlag()
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeoutSeconds) * 1_000_000_000))
                    if finished.trySet() {
                        if proc.isRunning {
                            proc.terminate()
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            if proc.isRunning {
                                kill(proc.processIdentifier, SIGKILL)
                            }
                        }
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: "", timedOut: true, cancelled: false))
                    }
                }
                proc.terminationHandler = { p in
                    timeoutTask.cancel()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let tail = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty {
                        stderrBuffer.withLock { $0.append(tail) }
                    }
                    if finished.trySet() {
                        let errText = String(data: stderrBuffer.withLock { $0 }, encoding: .utf8) ?? ""
                        continuation.resume(returning: BuildOutcome(
                            exitCode: p.terminationStatus,
                            stderr: errText,
                            timedOut: false,
                            cancelled: cancelledFlag.current || Task.isCancelled
                        ))
                    }
                }
                do {
                    try proc.run()
                } catch {
                    timeoutTask.cancel()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if finished.trySet() {
                        continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: error.localizedDescription, timedOut: false, cancelled: false))
                    }
                }
            }
        } onCancel: {
            cancelledFlag.withLock { $0 = true }
            if proc.isRunning { proc.terminate() }
        }
    }
}
