// Foundation helpers for SearchTests.swift (AGENTS.md: never import Foundation and Testing in one file).
import Foundation

enum SearchFixtures {
    static let url = URL(fileURLWithPath: "/tmp/og-search-fixture.go")

    static func data(_ s: String) -> Data { Data(s.utf8) }

    /// Creates a temporary (non-git) project with the given relative paths and contents.
    static func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-search-\(UUID().uuidString)", isDirectory: true)
        for (rel, text) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    static func remove(_ root: URL) { try? FileManager.default.removeItem(at: root) }
}
