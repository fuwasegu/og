import Foundation

/// Protocol for local Go snippet verification (DES-A3, DOC-11).
public protocol DocsSnippetVerifying: Sendable {
    func verify(snippet: String, targetVersion: GoVersion) async -> DocsSnippetVerificationStatus
}

/// Verifies generated Go snippets locally in a temporary module pinned to `targetVersion`
/// with `GOPROXY=off` (zero network access, DES-A3, Issue #24).
public struct DocsSnippetVerifier: DocsSnippetVerifying, Sendable {
    public let locator: ToolLocator
    public let timeoutSeconds: TimeInterval

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
        let mainGo = Self.wrapSnippetAsGoFile(trimmed)
        do {
            try goMod.write(to: tempDir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            try mainGo.write(to: tempDir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        } catch {
            return .unverified(reason: "検証ファイル書き込み失敗")
        }

        let result = await runGoBuild(
            executable: goExe,
            workingDirectory: tempDir,
            baseEnvironment: locator.environment,
            timeoutSeconds: timeoutSeconds
        )

        if result.timedOut {
            return .unverified(reason: "検証タイムアウト")
        }
        if result.cancelled {
            return .unverified(reason: "cancelled")
        }
        if result.exitCode == 0 {
            return .verified
        }
        return Self.classifyFailure(stderr: result.stderr)
    }

    /// Wraps a snippet into a valid `package main` file, inferring common stdlib imports when omitted.
    public static func wrapSnippetAsGoFile(_ snippet: String) -> String {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("package ") {
            return trimmed + "\n"
        }

        let needsFuncWrap = !trimmed.hasPrefix("func ") && !trimmed.hasPrefix("type ") && !trimmed.hasPrefix("import ")
        var body = trimmed
        var importsBlock = ""

        if !trimmed.contains("import ") && !trimmed.contains("import(") {
            let inferred = inferStdlibImports(in: trimmed)
            if !inferred.isEmpty {
                let quoted = inferred.sorted().map { "\t\"\($0)\"" }.joined(separator: "\n")
                importsBlock = "import (\n\(quoted)\n)\n\n"
            }
        }

        if needsFuncWrap {
            body = "func _ogVerify() {\n\(trimmed)\n}"
        }

        return "package ogverify\n\n\(importsBlock)\(body)\n"
    }

    static func inferStdlibImports(in code: String) -> Set<String> {
        let map: [String: String] = [
            "bufio.": "bufio",
            "bytes.": "bytes",
            "context.": "context",
            "errors.": "errors",
            "filepath.": "path/filepath",
            "fmt.": "fmt",
            "http.": "net/http",
            "io.": "io",
            "json.": "encoding/json",
            "os.": "os",
            "regexp.": "regexp",
            "slices.": "slices",
            "sort.": "sort",
            "strconv.": "strconv",
            "strings.": "strings",
            "sync.": "sync",
            "time.": "time"
        ]
        var result = Set<String>()
        for (prefix, pkg) in map where code.contains(prefix) {
            result.insert(pkg)
        }
        return result
    }

    static func classifyFailure(stderr: String) -> DocsSnippetVerificationStatus {
        let lower = stderr.lowercased()
        if lower.contains("mise error") || lower.contains("no version is set for shim") {
            return .unverified(reason: "Go バージョンが未有効化 (mise)")
        }
        if lower.contains("no required module provides package")
            || lower.contains("cannot find package")
            || lower.contains("missing go.sum entry")
            || lower.contains("goproxy=off") {
            return .unverified(reason: "外部依存がオフラインキャッシュにありません")
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
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: "", timedOut: false, cancelled: true))
                    return
                }
                let finished = LockedFlag()
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeoutSeconds) * 1_000_000_000))
                    if finished.trySet() {
                        if proc.isRunning { proc.terminate() }
                        continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: "", timedOut: true, cancelled: false))
                    }
                }
                proc.terminationHandler = { p in
                    timeoutTask.cancel()
                    if finished.trySet() {
                        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errText = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: BuildOutcome(
                            exitCode: p.terminationStatus,
                            stderr: errText,
                            timedOut: false,
                            cancelled: Task.isCancelled
                        ))
                    }
                }
                do {
                    try proc.run()
                } catch {
                    timeoutTask.cancel()
                    if finished.trySet() {
                        continuation.resume(returning: BuildOutcome(exitCode: -1, stderr: error.localizedDescription, timedOut: false, cancelled: false))
                    }
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }
}
