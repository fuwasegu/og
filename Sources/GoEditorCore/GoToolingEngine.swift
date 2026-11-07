import Foundation

public struct FileRenameDiffPreview: Sendable, Identifiable, Equatable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let originalContent: String
    public let modifiedContent: String
    public let unifiedDiffLines: [DiffLine]

    public struct DiffLine: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case context
            case removed
            case added
        }
        public let id: Int
        public let lineNumber: Int
        public let kind: Kind
        public let text: String
    }
}

public struct RenameTransactionSnapshot: Sendable {
    public let id: UUID
    public let symbolOldName: String
    public let symbolNewName: String
    public let timestamp: Date
    public let originalFiles: [URL: String]
}

public actor TransactionalRenameManager {
    private var transactionHistory: [RenameTransactionSnapshot] = []

    public init() {}

    public func buildPreview(
        for workspaceEdit: LSPWorkspaceEdit,
        inMemoryBuffers: [URL: TextBuffer] = [:]
    ) throws -> [FileRenameDiffPreview] {
        guard let changes = workspaceEdit.changes, !changes.isEmpty else {
            return []
        }

        var previews: [FileRenameDiffPreview] = []

        for (uriString, edits) in changes.sorted(by: { $0.key < $1.key }) {
            guard let fileURL = URL(string: uriString) else { continue }
            let originalText: String
            if let openBuf = inMemoryBuffers[fileURL] {
                originalText = openBuf.string
            } else {
                originalText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            }

            let tempBuffer = TextBuffer(originalText)
            let sortedEdits = edits.sorted { lhs, rhs in
                if lhs.range.start.line != rhs.range.start.line {
                    return lhs.range.start.line > rhs.range.start.line
                }
                return lhs.range.start.character > rhs.range.start.character
            }

            for edit in sortedEdits {
                let startPos = tempBuffer.position(forLSPPosition: edit.range.start)
                let endPos = tempBuffer.position(forLSPPosition: edit.range.end)
                tempBuffer.replace(
                    textRange: TextRange(start: startPos, end: endPos),
                    with: edit.newText,
                    recordUndo: false
                )
            }

            let modifiedText = tempBuffer.string
            let diffLines = Self.computeLineDiff(original: originalText, modified: modifiedText)
            previews.append(
                FileRenameDiffPreview(
                    fileURL: fileURL,
                    originalContent: originalText,
                    modifiedContent: modifiedText,
                    unifiedDiffLines: diffLines
                )
            )
        }

        return previews
    }

    @discardableResult
    public func commitRename(
        previews: [FileRenameDiffPreview],
        oldName: String,
        newName: String
    ) throws -> RenameTransactionSnapshot {
        var backup: [URL: String] = [:]
        for item in previews {
            backup[item.fileURL] = item.originalContent
        }

        do {
            for item in previews {
                try item.modifiedContent.write(to: item.fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            for (url, original) in backup {
                try? original.write(to: url, atomically: true, encoding: .utf8)
            }
            throw error
        }

        let snapshot = RenameTransactionSnapshot(
            id: UUID(),
            symbolOldName: oldName,
            symbolNewName: newName,
            timestamp: Date(),
            originalFiles: backup
        )
        transactionHistory.append(snapshot)
        return snapshot
    }

    @discardableResult
    public func rollbackLastRename() throws -> RenameTransactionSnapshot? {
        guard let last = transactionHistory.popLast() else { return nil }
        for (url, originalContent) in last.originalFiles {
            try originalContent.write(to: url, atomically: true, encoding: .utf8)
        }
        return last
    }

    public var canRollback: Bool {
        !transactionHistory.isEmpty
    }

    private static func computeLineDiff(
        original: String,
        modified: String
    ) -> [FileRenameDiffPreview.DiffLine] {
        let origLines = original.components(separatedBy: "\n")
        let modLines = modified.components(separatedBy: "\n")
        let maxCount = max(origLines.count, modLines.count)

        var result: [FileRenameDiffPreview.DiffLine] = []
        var idCounter = 0

        for idx in 0..<maxCount {
            let oLine = idx < origLines.count ? origLines[idx] : nil
            let mLine = idx < modLines.count ? modLines[idx] : nil

            if oLine == mLine, let same = oLine {
                let prevChanged = idx > 0 && (
                    (idx - 1 < origLines.count ? origLines[idx - 1] : "") !=
                    (idx - 1 < modLines.count ? modLines[idx - 1] : "")
                )
                let nextChanged = (idx + 1 < maxCount) && (
                    (idx + 1 < origLines.count ? origLines[idx + 1] : "") !=
                    (idx + 1 < modLines.count ? modLines[idx + 1] : "")
                )
                if prevChanged || nextChanged {
                    idCounter += 1
                    result.append(.init(id: idCounter, lineNumber: idx + 1, kind: .context, text: same))
                }
            } else {
                if let o = oLine {
                    idCounter += 1
                    result.append(.init(id: idCounter, lineNumber: idx + 1, kind: .removed, text: "- " + o))
                }
                if let m = mLine {
                    idCounter += 1
                    result.append(.init(id: idCounter, lineNumber: idx + 1, kind: .added, text: "+ " + m))
                }
            }
        }
        return result
    }
}

public struct GoTestRunResult: Sendable, Equatable, Identifiable {
    public var id: String { "\(functionName)-\(isBenchmark)" }
    public let functionName: String
    public let isBenchmark: Bool
    public let passed: Bool
    public let durationSeconds: Double
    public let allocsPerOp: String?
    public let nsPerOp: String?
    public let rawOutput: String
}

public actor GoTestRunner {
    public init() {}

    public func runFunction(
        named functionName: String,
        isBenchmark: Bool,
        packageDirectory: URL
    ) async -> GoTestRunResult {
        let start = ContinuousClock.now
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.resolveGoBinary())
        proc.currentDirectoryURL = packageDirectory

        if isBenchmark {
            proc.arguments = ["test", "-run=^$", "-bench=^\(functionName)$", "-benchmem"]
        } else {
            proc.arguments = ["test", "-v", "-run=^\(functionName)$"]
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let elapsed = start.duration(to: .now)
            let secs = Double(elapsed.components.seconds) + (Double(elapsed.components.attoseconds) / 1e18)

            let passed = proc.terminationStatus == 0 && !output.contains("FAIL")
            let (nsOp, allocsOp) = Self.parseBenchmarkMetrics(from: output)

            return GoTestRunResult(
                functionName: functionName,
                isBenchmark: isBenchmark,
                passed: passed,
                durationSeconds: max(0.001, secs),
                allocsPerOp: allocsOp,
                nsPerOp: nsOp,
                rawOutput: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return GoTestRunResult(
                functionName: functionName,
                isBenchmark: isBenchmark,
                passed: false,
                durationSeconds: 0,
                allocsPerOp: nil,
                nsPerOp: nil,
                rawOutput: "Failed to launch go toolchain: \(error.localizedDescription)"
            )
        }
    }

    private static func parseBenchmarkMetrics(from output: String) -> (nsPerOp: String?, allocsPerOp: String?) {
        var nsPerOp: String?
        var allocsPerOp: String?
        for line in output.components(separatedBy: "\n") where line.hasPrefix("Benchmark") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            for idx in 0..<parts.count {
                if parts[idx] == "ns/op", idx > 0 {
                    nsPerOp = "\(parts[idx - 1]) ns/op"
                }
                if parts[idx] == "allocs/op", idx > 0 {
                    allocsPerOp = "\(parts[idx - 1]) allocs/op"
                }
            }
        }
        return (nsPerOp, allocsPerOp)
    }

    private static func resolveGoBinary() -> String {
        let candidates = [
            "/usr/local/go/bin/go",
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/bin/go"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/local/go/bin/go"
    }
}
