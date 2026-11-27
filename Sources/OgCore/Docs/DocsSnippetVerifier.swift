import Foundation

/// Protocol for local Go snippet verification (DES-A3, DOC-11).
public protocol DocsSnippetVerifying: Sendable {
    func verify(snippet: String, targetVersion: GoVersion) async -> DocsSnippetVerificationStatus
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

    public init(locator: ToolLocator = .shared, timeoutSeconds: TimeInterval = 10) {
        self.locator = locator
        self.timeoutSeconds = timeoutSeconds
    }

    public func verify(snippet: String, targetVersion: GoVersion) async -> DocsSnippetVerificationStatus {
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

        // Y-9: Only when the snippet omitted imports and failed with `undefined: <stdlib_ident>`,
        // retry once with the exact missing stdlib imports reported by the compiler.
        if result.exitCode != 0 && !result.timedOut && !result.cancelled && !Self.hasExplicitImport(trimmed) {
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
        return Self.classifyFailure(stderr: result.stderr, targetVersion: targetVersion)
    }

    static func containsCgoImport(_ snippet: String) -> Bool {
        snippet.range(of: #"(?m)(?:import\s+"C"|^\s*"C"\s*$)"#, options: .regularExpression) != nil
    }

    static func hasExplicitImport(_ snippet: String) -> Bool {
        snippet.contains("import ") || snippet.contains("import(")
    }

    /// Wraps a snippet into a valid `package ogverify` file without speculative string-matching imports (Y-9).
    public static func wrapSnippetAsGoFile(_ snippet: String, extraImports: [String] = []) -> String {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("package ") {
            return trimmed + "\n"
        }

        let needsFuncWrap = !trimmed.hasPrefix("func ") && !trimmed.hasPrefix("type ") && !trimmed.hasPrefix("import ")
        var importsBlock = ""
        if !extraImports.isEmpty && !hasExplicitImport(trimmed) {
            let quoted = Set(extraImports).sorted().map { "\t\"\($0)\"" }.joined(separator: "\n")
            importsBlock = "import (\n\(quoted)\n)\n\n"
        }

        let body = needsFuncWrap ? "func _ogVerify() {\n\(trimmed)\n}" : trimmed
        return "package ogverify\n\n\(importsBlock)\(body)\n"
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

    static func classifyFailure(stderr: String, targetVersion: GoVersion = GoVersion(major: 1, minor: 23)) -> DocsSnippetVerificationStatus {
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
        return .failed(errorSummary: summary.isEmpty ? "go build failed" : String(summary.prefix(180)))
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

        // Z-10: Drain stderr incrementally to prevent pipe-buffer deadlock on verbose compiler errors.
        let stderrBuffer = Locked<Data>(Data())
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.withLock { $0.append(chunk) }
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
                        if proc.isRunning { proc.terminate() }
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
