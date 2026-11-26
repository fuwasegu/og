// Foundation helpers for tests live here (AGENTS.md: never import Foundation and Testing in one file).
import Darwin
import Foundation
import SQLite3
@testable import OgCore

// MARK: - Postfix

/// Expands the postfix template at the `|` marker; returns the new text with `‸` at the caret, or nil.
func expandPostfix(_ marked: String) -> String? {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    guard caret != NSNotFound else { return nil }
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
    guard let e = GoPostfix.expansion(in: text, caret: caret) else { return nil }
    let out = (text as NSString).replacingCharacters(in: e.replaceRange, with: e.text) as NSString
    let c = e.replaceRange.location + e.caretOffset
    return out.substring(to: c) + "‸" + out.substring(from: c)
}

/// The template name matched at the `|` marker.
func postfixTemplateName(_ marked: String) -> String? {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
    return GoPostfix.expansion(in: text, caret: caret)?.templateName
}

// MARK: - Text

func lineIndex(of needle: String, in text: String) -> Int {
    text.components(separatedBy: "\n").firstIndex { $0.contains(needle) } ?? -1
}

func textContains(_ text: String, _ needle: String) -> Bool { text.contains(needle) }

func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ t: String) -> LSPTextEdit {
    LSPTextEdit(range: LSPRange(start: LSPPosition(line: l1, character: c1), end: LSPPosition(line: l2, character: c2)), newText: t)
}

// MARK: - Files

/// A temporary directory removed by `cleanup()`.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("og-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String, _ content: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func subdir(_ name: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func cleanup() {
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in e {
                try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o755], ofItemAtPath: f.path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

func readFile(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
func listDir(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
func setReadOnlyDirectory(_ u: URL, _ readOnly: Bool) {
    try? FileManager.default.setAttributes([.posixPermissions: readOnly ? 0o555 : 0o755], ofItemAtPath: u.path)
}
func setImmutable(_ u: URL, _ on: Bool) {
    try? FileManager.default.setAttributes([.immutable: on], ofItemAtPath: u.path)
}
func uri(_ u: URL) -> String { u.absoluteString }
func preview(_ u: URL, _ newText: String) -> FileDiffPreview { FileDiffPreview(url: u, unifiedDiff: "", newText: newText) }
func standardized(_ u: URL) -> URL { u.standardizedFileURL }

/// File system whose commit fails for targets named `name`.
func failingCommitFileSystem(on name: String) -> RenameTransaction.FileSystem {
    var fs = RenameTransaction.FileSystem.live
    fs.replace = { temp, target in
        if target.lastPathComponent == name { throw CocoaError(.fileWriteUnknown) }
        try RenameTransaction.FileSystem.live.replace(temp, target)
    }
    return fs
}

// MARK: - Completion

func url(_ s: String) -> URL? { URL(string: s) }

func requestJSON(_ client: LocalCompletionClient, prefix: String, suffix: String, maxTokens: Int) -> [String: String] {
    let req = client.makeRequest(prefix: prefix, suffix: suffix, maxTokens: maxTokens)
    guard let body = req.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    var out: [String: String] = ["_path": req.url?.path ?? "", "_method": req.httpMethod ?? ""]
    for (k, v) in obj { out[k] = "\(v)" }
    return out
}

/// Feeds a canned SSE transcript through the parser and limiter like `complete` does.
func runCannedSSE(_ transcript: String) -> (text: String, error: String?) {
    var limiter = CompletionStreamLimiter()
    var text = ""
    for line in transcript.components(separatedBy: "\n") {
        guard let ev = SSEParser.parse(line: line) else { continue }
        switch ev {
        case .error(let m): return (text, m)
        case .done: return (text, nil)
        case .content(let c, let stop):
            let (emit, finished) = limiter.feed(c)
            text += emit
            if finished || stop { return (text, nil) }
        }
    }
    return (text, nil)
}

func sseLine(_ content: String, stop: Bool = false) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: ["content": content, "stop": stop])) ?? Data()
    return "data: " + String(decoding: data, as: UTF8.self)
}

/// GoErrCheck suggestion with the caret at the end of `src`.
func errCheckAtEnd(_ src: String, zeros: [String: String] = [:]) -> GoErrCheckSuggestion? {
    GoErrCheck.suggestion(in: src as NSString, caret: (src as NSString).length, externalZeros: zeros)
}

// MARK: - Go style (GoStyleTests)

/// `rule@line` (1-based) for every style finding.
func styleFindings(_ src: String, file: String = "x.go") -> [String] {
    GoStyle.check(src, fileName: file).map { "\($0.rule.id)@\($0.range.start.line + 1)" }
}

/// The new name of a rename fix for `rule`, or nil.
func styleRename(_ src: String, rule: String, file: String = "x.go") -> String? {
    guard let f = GoStyle.check(src, fileName: file).first(where: { $0.rule.id == rule })?.fix,
          case .rename(_, let name) = f.kind else { return nil }
    return name
}

/// The text after applying the edit fix for `rule`, or nil.
func styleApplyFix(_ src: String, rule: String, file: String = "x.go") -> String? {
    guard let f = GoStyle.check(src, fileName: file).first(where: { $0.rule.id == rule })?.fix,
          case .edits(let edits, _) = f.kind else { return nil }
    let ns = NSMutableString(string: src)
    let lines = TextLines(src)
    for r in edits.map({ (lines.nsRange(for: $0.range), $0.newText) }).sorted(by: { $0.0.location > $1.0.location }) {
        ns.replaceCharacters(in: r.0, with: r.1)
    }
    return ns as String
}

/// Style completions at the `|` marker.
func styleCompletionItems(_ marked: String, file: String = "x_test.go", package: [String] = [],
                          candidates: [(String, String?)] = []) -> [GoStyleCompletion] {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    guard caret != NSNotFound else { return [] }
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return GoStyleCompletions.items(in: text, caret: caret, fileName: file, packageSources: package,
                                    candidates: candidates.map { GoCompletionCandidate(label: $0.0, detail: $0.1) })
}

func styleLabels(_ marked: String, file: String = "x_test.go", package: [String] = [], candidates: [(String, String?)] = []) -> [String] {
    styleCompletionItems(marked, file: file, package: package, candidates: candidates).map(\.label)
}

/// Applies the style completion whose label contains `label` at the `|` marker; `‸` marks the caret.
func styleComplete(_ marked: String, label: String = "", file: String = "x_test.go", package: [String] = [],
                   candidates: [(String, String?)] = []) -> String? {
    guard let item = styleCompletionItems(marked, file: file, package: package, candidates: candidates)
        .first(where: { label.isEmpty || $0.label.contains(label) }) else { return nil }
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    let out = text.replacingCharacters(in: item.replaceRange, with: item.text) as NSString
    let c = item.replaceRange.location + item.caretOffset
    return out.substring(to: c) + "‸" + out.substring(from: c)
}

func styleTriggers(_ marked: String) -> Bool {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return GoStyleCompletions.shouldTrigger(in: text, caret: caret)
}

/// Markdown completion context with the caret at `|`.
func mdContext(_ marked: String, explicit: Bool = false) -> MarkdownCompletionContext? {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    let text = ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return MarkdownCompletions.context(in: text, caret: caret, explicit: explicit)
}
func nsRange(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
func applyEdits(_ text: String, _ edits: [(range: NSRange, text: String)]) -> String {
    let m = NSMutableString(string: text)
    for e in edits.sorted(by: { $0.range.location > $1.range.location }) { m.replaceCharacters(in: e.range, with: e.text) }
    return m as String
}

// MARK: - Offline Go Docs (DocsResearchTests)

/// Deterministic in-memory embedder for testing batch ingestion, cancel/resume, incremental diffs,
/// and cross-version vector reuse without any network or external model server.
final class CountingFakeEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor: EmbeddingModelDescriptor
    private let lock = NSLock()
    private var _callCount = 0
    private var _cancelManager: DocsPackManager?
    private var _cancelAfter: Int?
    private var _cancelVersion: String?
    private var _deleteInsteadOfCancel = false

    init(id: String = "fake-embed", version: String = "v1") {
        self.descriptor = EmbeddingModelDescriptor(id: id, version: version)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func resetCount() {
        lock.lock()
        _callCount = 0
        lock.unlock()
    }

    func configureCancel(manager: DocsPackManager, goVersion: String, afterCalls: Int) {
        lock.lock()
        _cancelManager = manager
        _cancelVersion = goVersion
        _cancelAfter = afterCalls
        _deleteInsteadOfCancel = false
        lock.unlock()
    }

    func configureDelete(manager: DocsPackManager, goVersion: String, afterCalls: Int) {
        lock.lock()
        _cancelManager = manager
        _cancelVersion = goVersion
        _cancelAfter = afterCalls
        _deleteInsteadOfCancel = true
        lock.unlock()
    }

    func clearCancel() {
        lock.lock()
        _cancelManager = nil
        _cancelVersion = nil
        _cancelAfter = nil
        _deleteInsteadOfCancel = false
        lock.unlock()
    }

    private func recordCallAndTakeCancelTarget() -> (DocsPackManager, String, Bool)? {
        lock.lock()
        defer { lock.unlock() }
        _callCount += 1
        let count = _callCount
        if let mgr = _cancelManager, let ver = _cancelVersion, let limit = _cancelAfter, count >= limit {
            _cancelAfter = nil
            return (mgr, ver, _deleteInsteadOfCancel)
        }
        return nil
    }

    func embed(_ text: String) async throws -> [Float] {
        if let (mgr, ver, shouldDelete) = recordCallAndTakeCancelTarget() {
            if shouldDelete {
                _ = try? await mgr.deletePack(goVersion: ver)
            } else {
                await mgr.requestCancel(goVersion: ver)
            }
        }

        // Deterministic 8-dim bag-of-bytes vector (normalized).
        var v = Array(repeating: Float(0), count: 8)
        for (idx, b) in text.utf8.enumerated() {
            v[idx % 8] += Float(b) / 255.0
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }
}

/// Embedder that throws on demand to test error propagation and `.failed` progress emission (M-16).
final class FailingFakeEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor = EmbeddingModelDescriptor(id: "fail-embed", version: "v1")
    func embed(_ text: String) async throws -> [Float] {
        throw DocsStorageError.embeddingFailed("injected embedder failure")
    }
}

/// Embedder that pauses briefly so concurrent re-entry and GC safety tests can overlap (H-8, H-9).
final class SlowFakeEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor: EmbeddingModelDescriptor
    let delayNs: UInt64
    init(id: String = "slow-embed", version: String = "v1", delayNs: UInt64 = 30_000_000) {
        self.descriptor = EmbeddingModelDescriptor(id: id, version: version)
        self.delayNs = delayNs
    }
    func embed(_ text: String) async throws -> [Float] {
        try await Task.sleep(nanoseconds: delayNs)
        var v = Array(repeating: Float(0), count: 8)
        for (idx, b) in text.utf8.enumerated() { v[idx % 8] += Float(b) / 255.0 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }
}

/// Deterministic keyword-aware embedder for verifying real semantic retrieval and M-1 anti-hallucination gating.
final class SemanticTopicEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor: EmbeddingModelDescriptor
    init(id: String = "topic-embed", version: String = "v1") {
        self.descriptor = EmbeddingModelDescriptor(id: id, version: version)
    }
    func embed(_ text: String) async throws -> [Float] {
        let lower = text.lowercased()
        // 4 orthogonal topic dimensions: [bufio/line, json, timeout, regexp] + [noise]
        var v: [Float] = [0.0, 0.0, 0.0, 0.0, 0.01]
        if lower.contains("scanner") || lower.contains("bufio") || lower.contains("line") || lower.contains("行") { v[0] = 1.0 }
        if lower.contains("json") || lower.contains("marshal") || lower.contains("encoder") || lower.contains("indent") { v[1] = 1.0 }
        if lower.contains("timeout") || lower.contains("context") || lower.contains("deadline") || lower.contains("タイムアウト") { v[2] = 1.0 }
        if lower.contains("regexp") || lower.contains("regex") || lower.contains("正規表現") { v[3] = 1.0 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

func makeDocsPackManager(in dir: TempDir) throws -> DocsPackManager {
    try DocsPackManager(rootDirectory: dir.subdir("docs-packs"))
}

func reopenDocsPackManager(at rootURL: URL) throws -> DocsPackManager {
    try DocsPackManager(rootDirectory: rootURL)
}

func stringContains(_ haystack: String, _ needle: String) -> Bool {
    haystack.contains(needle)
}

func pathExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func writeConceptRulesJSON(_ rules: [DocsConceptRule], to url: URL) throws {
    let data = try JSONEncoder().encode(rules)
    try data.write(to: url, options: .atomic)
}

func writeRawText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Creates a genuine legacy schema v1 pack (no `document_id`, no `provenance`, `schemaVersion == 1`) for T-1 testing.
func createLegacyV1Pack(in rootURL: URL, goVersion: String) throws {
    let packDir = rootURL.appendingPathComponent("packs/go\(goVersion)", isDirectory: true)
    try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
    let dbURL = packDir.appendingPathComponent("index.sqlite")

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
        throw DocsStorageError.sqlite("unable to create legacy v1 db")
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE chunks (
        stable_id TEXT PRIMARY KEY,
        go_version TEXT NOT NULL,
        source TEXT NOT NULL,
        package_name TEXT NOT NULL,
        symbol TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        anchor TEXT NOT NULL,
        since TEXT,
        summary TEXT NOT NULL,
        signature TEXT,
        example TEXT,
        body TEXT NOT NULL,
        search_aliases TEXT NOT NULL,
        content_hash TEXT NOT NULL
    );
    """
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, ddl, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "v1 ddl failed"
        sqlite3_free(err)
        throw DocsStorageError.sqlite(msg)
    }

    let manifest = DocsPackManifest(
        goVersion: goVersion,
        createdAt: "2026-01-01T00:00:00Z",
        chunkCount: 0,
        status: .indexingFTSOnly,
        schemaVersion: 1
    )
    try JSONEncoder().encode(manifest).write(to: packDir.appendingPathComponent("manifest.json"), options: .atomic)
}

/// Creates a corrupt legacy v2 pack (`index.sqlite` contains non-SQLite garbage bytes) for T-2 error isolation testing.
func createCorruptLegacyV2Pack(in rootURL: URL, goVersion: String) throws {
    let packDir = rootURL.appendingPathComponent("packs/go\(goVersion)", isDirectory: true)
    try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
    try Data("not a valid sqlite database file".utf8).write(to: packDir.appendingPathComponent("index.sqlite"))
    let manifest = DocsPackManifest(
        goVersion: goVersion,
        createdAt: "2026-01-01T00:00:00Z",
        chunkCount: 1,
        status: .indexingFTSOnly,
        schemaVersion: 2
    )
    try JSONEncoder().encode(manifest).write(to: packDir.appendingPathComponent("manifest.json"), options: .atomic)
}

/// Creates a genuine legacy schema v2 pack on disk (without the `provenance` column) for S-1 migration testing.
func createLegacyV2Pack(in rootURL: URL, goVersion: String, chunks: [DocsChunk]) throws {
    let packDir = rootURL.appendingPathComponent("packs/go\(goVersion)", isDirectory: true)
    try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
    let dbURL = packDir.appendingPathComponent("index.sqlite")

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
        throw DocsStorageError.sqlite("unable to create legacy v2 db")
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE chunks (
        stable_id TEXT PRIMARY KEY,
        go_version TEXT NOT NULL,
        source TEXT NOT NULL,
        package_name TEXT NOT NULL,
        document_id TEXT NOT NULL DEFAULT '',
        symbol TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        anchor TEXT NOT NULL,
        since TEXT,
        summary TEXT NOT NULL,
        signature TEXT,
        example TEXT,
        body TEXT NOT NULL,
        search_aliases TEXT NOT NULL,
        content_hash TEXT NOT NULL
    );
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
        stable_id UNINDEXED, title, package_name, symbol, summary, body, search_aliases, tokenize = 'unicode61'
    );
    CREATE TABLE pack_vector_refs (
        stable_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL, model_id TEXT NOT NULL, model_version TEXT NOT NULL
    );
    """
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, ddl, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "ddl failed"
        sqlite3_free(err)
        throw DocsStorageError.sqlite(msg)
    }

    let insert = """
    INSERT INTO chunks (
        stable_id, go_version, source, package_name, document_id, symbol, kind,
        title, anchor, since, summary, signature, example, body, search_aliases, content_hash
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16);
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        throw DocsStorageError.sqlite("prepare failed")
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for c in chunks {
        sqlite3_reset(stmt)
        let aliasesJSON = (try? JSONEncoder().encode(c.searchAliases)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let values: [String?] = [
            c.stableID, c.goVersion, c.source.rawValue, c.packageName, c.documentID,
            c.symbol, c.kind.rawValue, c.title, c.anchor, c.since,
            c.summary, c.signature, c.example, c.body, aliasesJSON, c.contentHash
        ]
        for (i, val) in values.enumerated() {
            if let val {
                _ = val.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, transient) }
            } else {
                sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DocsStorageError.sqlite("insert failed")
        }
    }

    let manifest = DocsPackManifest(
        goVersion: goVersion,
        createdAt: "2026-01-01T00:00:00Z",
        chunkCount: chunks.count,
        status: .indexingFTSOnly,
        schemaVersion: 2
    )
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: packDir.appendingPathComponent("manifest.json"), options: .atomic)
}

func recordProgress(_ box: ProgressRecorder, _ progress: DocsBatchProgress) {
    box.append(progress)
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DocsBatchProgress] = []
    func append(_ p: DocsBatchProgress) {
        lock.lock()
        items.append(p)
        lock.unlock()
    }
    var phases: [DocsBatchPhase] {
        lock.lock()
        defer { lock.unlock() }
        return items.map(\.phase)
    }
}

/// Deterministic batch-capable embedder for testing `embedBatch` and `reembedExistingPack` (Issue #21).
final class BatchCountingFakeEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor: EmbeddingModelDescriptor
    let preferredBatchSize: Int
    private let lock = NSLock()
    private var _batchCalls = 0
    private var _singleCalls = 0

    init(id: String = "batch-embed", version: String = "v1", batchSize: Int = 4) {
        self.descriptor = EmbeddingModelDescriptor(id: id, version: version)
        self.preferredBatchSize = batchSize
    }

    var batchCalls: Int { lock.withLock { _batchCalls } }
    var singleCalls: Int { lock.withLock { _singleCalls } }

    func embed(_ text: String) async throws -> [Float] {
        lock.withLock { _singleCalls += 1 }
        return Self.vector(for: text)
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { _batchCalls += 1 }
        return texts.map { Self.vector(for: $0) }
    }

    private static func vector(for text: String) -> [Float] {
        var v = Array(repeating: Float(0), count: 8)
        for (idx, b) in text.utf8.enumerated() { v[idx % 8] += Float(b) / 255.0 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// Deterministic cross-encoder reranker double for unit-testing Issue #21 Stage 2 ranking and anti-hallucination.
final class StubDocsReranker: DocsReranker, @unchecked Sendable {
    let modelID: String
    private let scorer: @Sendable (String, String) -> Double

    init(modelID: String = "stub-reranker-v1", scorer: @escaping @Sendable (String, String) -> Double) {
        self.modelID = modelID
        self.scorer = scorer
    }

    func rerank(query: String, documents: [String], topN: Int) async throws -> [DocsRerankerResult] {
        var results = documents.enumerated().map { idx, doc in
            DocsRerankerResult(index: idx, score: scorer(query, doc))
        }
        results.sort {
            if abs($0.score - $1.score) > 1e-9 { return $0.score > $1.score }
            return $0.index < $1.index
        }
        return Array(results.prefix(max(1, min(topN, results.count))))
    }
}

/// Reranker that always fails so tests can verify transparent fallback to Phase 1 ranking (Issue #21, DOC-10).
final class FailingDocsReranker: DocsReranker, @unchecked Sendable {
    let modelID = "failing-reranker"
    func rerank(query: String, documents: [String], topN: Int) async throws -> [DocsRerankerResult] {
        throw DocsStorageError.rerankFailed("injected reranker failure")
    }
}

/// Returns the local installed `GOROOT/src` directory if `go` is available on the host (for real GOROOT smoke tests).
func realGorootSrcURL() -> URL? {
    guard let goroot = GoVersionResolver.detectGoroot() else { return nil }
    let src = goroot.appendingPathComponent("src", isDirectory: true)
    return FileManager.default.fileExists(atPath: src.path) ? src : nil
}

func makeFakeToolLocator(with toolName: String, in dir: TempDir) -> ToolLocator {
    let binDir = dir.subdir("bin")
    let exe = dir.file("bin/\(toolName)", "#!/bin/sh\nexit 0\n")
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return ToolLocator(searchPath: [binDir.path], environment: ["PATH": binDir.path])
}

func makeTestDate(offsetSeconds: Double) -> Date {
    Date(timeIntervalSinceReferenceDate: 1_000_000 + offsetSeconds)
}

/// Embedder whose `embedBatch` always fails so tests verify single-item fallback (W-5).
final class BatchFailingThenSingleEmbedder: DocsEmbedder, @unchecked Sendable {
    let descriptor: EmbeddingModelDescriptor
    let preferredBatchSize: Int
    private let lock = NSLock()
    private var _batchFailures = 0
    private var _singleCalls = 0

    init(id: String = "batch-fallback", version: String = "v1", batchSize: Int = 4) {
        self.descriptor = EmbeddingModelDescriptor(id: id, version: version)
        self.preferredBatchSize = batchSize
    }

    var batchFailures: Int { lock.withLock { _batchFailures } }
    var singleCalls: Int { lock.withLock { _singleCalls } }

    func embed(_ text: String) async throws -> [Float] {
        lock.withLock { _singleCalls += 1 }
        var v = Array(repeating: Float(0), count: 8)
        for (idx, b) in text.utf8.enumerated() { v[idx % 8] += Float(b) / 255.0 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { _batchFailures += 1 }
        throw DocsStorageError.embeddingFailed("injected batch endpoint failure")
    }
}

/// Drops `shared_vectors` table from an existing `SharedVectorStore` DB so `semanticSearch` throws SQLite errors (V-4).
func corruptSharedVectorStoreTable(at databaseURL: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
        throw DocsStorageError.sqlite("unable to open shared vector store for corruption test")
    }
    defer { sqlite3_close(db) }
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, "DROP TABLE IF EXISTS shared_vectors;", nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "drop table failed"
        sqlite3_free(err)
        throw DocsStorageError.sqlite(msg)
    }
}

/// Programmable HTTP response for `LocalMockHTTPServer`.
struct LocalMockHTTPResponse: Sendable {
    var statusCode: Int
    var statusText: String
    var headers: [String: String]
    var body: Data
    var delaySeconds: Double

    init(
        statusCode: Int = 200,
        statusText: String = "OK",
        headers: [String: String] = ["Content-Type": "application/json"],
        bodyString: String = "{}",
        delaySeconds: Double = 0
    ) {
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = Data(bodyString.utf8)
        self.delaySeconds = delaySeconds
    }
}

/// Lightweight loopback-only POSIX socket HTTP/1.1 mock server for testing real `URLSession` client behavior
/// (redirects, HTTP 500, malformed JSON, empty results, timeouts — V-3, V-7, W-9).
final class LocalMockHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: String) -> LocalMockHTTPResponse

    let port: Int
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "og.tests.mock-http", attributes: .concurrent)
    private let lock = NSLock()
    private var _handler: Handler
    private var _stopped = false

    init(handler: @escaping Handler) throws {
        self._handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DocsStorageError.io("socket() failed")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw DocsStorageError.io("bind() failed")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw DocsStorageError.io("listen() failed")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else {
            close(fd)
            throw DocsStorageError.io("getsockname() failed")
        }
        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: addr.sin_port))
        startAcceptLoop()
    }

    deinit {
        stop()
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { _handler = handler }
    }

    func stop() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !_stopped else { return false }
            _stopped = true
            return true
        }
        if shouldClose {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
    }

    private func currentHandler() -> Handler {
        lock.withLock { _handler }
    }

    private func isStopped() -> Bool {
        lock.withLock { _stopped }
    }

    private func startAcceptLoop() {
        let fd = listenFD
        queue.async { [weak self] in
            while let self, !self.isStopped() {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(fd, $0, &addrLen)
                    }
                }
                if clientFD < 0 {
                    if self.isStopped() { break }
                    continue
                }
                self.queue.async { [weak self] in
                    self?.handleConnection(clientFD)
                }
            }
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { close(clientFD) }
        var nosig: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data("\r\n\r\n".utf8)
        var headerEndRange: Range<Data.Index>?

        while headerEndRange == nil && buffer.count < 65536 {
            let n = recv(clientFD, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            headerEndRange = buffer.range(of: delimiter)
        }
        guard let hdrRange = headerEndRange else { return }

        let headerText = String(data: buffer[..<hdrRange.lowerBound], encoding: .utf8) ?? ""
        let headerLines = headerText.components(separatedBy: "\r\n")
        let requestParts = (headerLines.first ?? "").split(separator: " ").map(String.init)
        let method = requestParts.count > 0 ? requestParts[0] : "GET"
        let path = requestParts.count > 1 ? requestParts[1] : "/"

        var contentLength = 0
        for line in headerLines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "content-length" {
                    contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }

        var bodyData = Data(buffer[hdrRange.upperBound...])
        while bodyData.count < contentLength {
            let n = recv(clientFD, &chunk, min(chunk.count, contentLength - bodyData.count), 0)
            if n <= 0 { break }
            bodyData.append(chunk, count: n)
        }
        let bodyString = String(data: bodyData.prefix(contentLength), encoding: .utf8) ?? ""

        let response = currentHandler()(method, path, bodyString)
        if response.delaySeconds > 0 {
            usleep(useconds_t(response.delaySeconds * 1_000_000))
        }

        var headerOut = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        for (k, v) in response.headers {
            headerOut += "\(k): \(v)\r\n"
        }
        headerOut += "Content-Length: \(response.body.count)\r\n"
        headerOut += "Connection: close\r\n\r\n"

        var wire = Data(headerOut.utf8)
        wire.append(response.body)
        wire.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = send(clientFD, base.advanced(by: sent), raw.count - sent, 0)
                if written <= 0 { break }
                sent += written
            }
        }
    }
}




