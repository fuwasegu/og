import Foundation
import GoEditorCore

enum TestWorkspaceHelper {
    static func withTempGoFile(initialContent: String, body: (String, String) async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("server.go")
        try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)
        try await body(fileURL.path, fileURL.absoluteString)
    }

    static func readFile(atPath path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    static func buildPreview(
        manager: TransactionalRenameManager,
        edit: LSPWorkspaceEdit,
        filePath: String,
        buffer: TextBuffer
    ) async throws -> [FileRenameDiffPreview] {
        let url = URL(fileURLWithPath: filePath)
        return try await manager.buildPreview(for: edit, inMemoryBuffers: [url: buffer])
    }

    static func measureMilliseconds(_ block: () -> Void) -> Double {
        let start = ContinuousClock.now
        block()
        let elapsed = start.duration(to: .now)
        return (Double(elapsed.components.seconds) * 1000.0) + (Double(elapsed.components.attoseconds) / 1e15)
    }

    @MainActor
    static func verifyNativePTYSessionLifecycle() async -> Bool {
        let session = NativePTYSession(workingDirectory: FileManager.default.temporaryDirectory)
        session.startIfNeeded()
        guard session.isRunning else { return false }
        session.sendInput("echo og_pty_ok\r")
        try? await Task.sleep(for: .milliseconds(150))
        session.stop()
        return !session.isRunning
    }
}
