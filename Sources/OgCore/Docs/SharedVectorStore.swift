import Foundation
import SQLite3

/// Identifies an embedding model and version so vectors from different models are never mixed (FR-27, FR-30).
public struct EmbeddingModelDescriptor: Sendable, Hashable, Codable {
    public var id: String
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// Lookup key in `SharedVectorStore` (FR-25, FR-30).
public struct SharedVectorKey: Sendable, Hashable, Codable {
    public var contentHash: String
    public var modelID: String
    public var modelVersion: String

    public init(contentHash: String, modelID: String, modelVersion: String) {
        self.contentHash = contentHash
        self.modelID = modelID
        self.modelVersion = modelVersion
    }

    public init(contentHash: String, model: EmbeddingModelDescriptor) {
        self.contentHash = contentHash
        self.modelID = model.id
        self.modelVersion = model.version
    }
}

/// Protocol for computing text embeddings (implemented by local loopback servers in Phase 2 or test doubles).
public protocol DocsEmbedder: Sendable {
    var descriptor: EmbeddingModelDescriptor { get }
    /// Preferred number of chunks per batch during pack ingestion (1 for simple/test doubles; 32 for HTTP MLX server).
    var preferredBatchSize: Int { get }
    func embed(_ text: String) async throws -> [Float]
    /// Embeds a user search query (allows asymmetric models such as E5 to apply a `query:` prefix).
    func embedQuery(_ text: String) async throws -> [Float]
    /// Batch-embeds multiple document chunks in order.
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

public extension DocsEmbedder {
    var preferredBatchSize: Int { 1 }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            out.append(try await embed(text))
        }
        return out
    }
}

/// Loopback-only HTTP embedding client for the og-owned MLX / OpenAI-compatible `/v1/embeddings` endpoint
/// (FR-16, DES-1, D-9). Refuses non-loopback URLs at initialization (`NeverLeavesMachine`) and reuses a single URLSession (L-8).
public final class LoopbackEmbeddingClient: DocsEmbedder, Sendable {
    public let endpoint: URL
    public let descriptor: EmbeddingModelDescriptor
    public let preferredBatchSize: Int = 32
    private let session: URLSession

    public init?(endpoint: URL, descriptor: EmbeddingModelDescriptor) {
        guard LocalCompletionClient.isLoopback(endpoint) else { return nil }
        self.endpoint = endpoint
        self.descriptor = descriptor
        self.session = URLSession(configuration: LocalCompletionClient.sessionConfiguration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func embed(_ text: String) async throws -> [Float] {
        let vecs = try await requestEmbeddings(input: [text], inputType: "passage")
        guard let first = vecs.first else {
            throw DocsStorageError.embeddingFailed("empty embedding response")
        }
        return first
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        let vecs = try await requestEmbeddings(input: [text], inputType: "query")
        guard let first = vecs.first else {
            throw DocsStorageError.embeddingFailed("empty query embedding response")
        }
        return first
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await requestEmbeddings(input: texts, inputType: "passage")
    }

    private func requestEmbeddings(input: [String], inputType: String) async throws -> [[Float]] {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/embeddings"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": descriptor.id,
            "input": input.count == 1 ? input[0] : input,
            "input_type": inputType
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocsStorageError.embeddingFailed("HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else {
            throw DocsStorageError.embeddingFailed("invalid embedding response")
        }
        let sortedItems = items.sorted {
            (($0["index"] as? NSNumber)?.intValue ?? 0) < (($1["index"] as? NSNumber)?.intValue ?? 0)
        }
        var out: [[Float]] = []
        out.reserveCapacity(sortedItems.count)
        for item in sortedItems {
            guard let raw = item["embedding"] as? [NSNumber] else {
                throw DocsStorageError.embeddingFailed("missing embedding array")
            }
            out.append(raw.map(\.floatValue))
        }
        guard out.count == input.count else {
            throw DocsStorageError.embeddingFailed("embedding count mismatch (\(out.count) vs \(input.count))")
        }
        return out
    }
}

/// Errors thrown by SQLite-backed docs storage and ingestion.
public enum DocsStorageError: Error, LocalizedError, Sendable {
    case sqlite(String)
    case io(String)
    case embeddingFailed(String)
    case rerankFailed(String)
    case nonLoopbackEndpoint(String)
    case batchAlreadyRunning(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let msg): return "SQLite error: \(msg)"
        case .io(let msg): return "Storage I/O error: \(msg)"
        case .embeddingFailed(let msg): return "Embedding error: \(msg)"
        case .rerankFailed(let msg): return "Reranking error: \(msg)"
        case .nonLoopbackEndpoint(let url): return "Refused non-loopback endpoint: \(url)"
        case .batchAlreadyRunning(let ver): return "An ingestion batch for go\(ver) is already running."
        }
    }
}

/// Sendable owner for a SQLite handle so actor `deinit` cleanly closes it under Swift 6 strict concurrency.
final class SQLiteConnectionBox: @unchecked Sendable {
    var handle: OpaquePointer?
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit {
        if let handle { sqlite3_close(handle) }
    }
}

/// Shared vector store keyed by `(content_hash, model_id, model_version)` (FR-30).
///
/// Packs only store references to keys here, so unchanged chunks across Go versions or pack
/// updates reuse existing embeddings without recomputation. Unreferenced vectors can be
/// reclaimed via `garbageCollect(referencedKeys:)`.
public actor SharedVectorStore {
    public let databaseURL: URL
    private let box: SQLiteConnectionBox
    private var db: OpaquePointer? { box.handle }

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            throw DocsStorageError.sqlite(msg)
        }
        sqlite3_busy_timeout(handle, 5000) // L-2
        self.box = SQLiteConnectionBox(handle)
        try Self.initializeSchema(db: handle)
    }

    private static func initializeSchema(db: OpaquePointer) throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS shared_vectors (
            content_hash TEXT NOT NULL,
            model_id TEXT NOT NULL,
            model_version TEXT NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (content_hash, model_id, model_version)
        );
        """
        try SQLiteHelpers.exec(db: db, sql: sql)
    }

    public func contains(_ key: SharedVectorKey) throws -> Bool {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let sql = "SELECT 1 FROM shared_vectors WHERE content_hash = ?1 AND model_id = ?2 AND model_version = ?3 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        SQLiteHelpers.bindText(stmt, index: 1, value: key.contentHash)
        SQLiteHelpers.bindText(stmt, index: 2, value: key.modelID)
        SQLiteHelpers.bindText(stmt, index: 3, value: key.modelVersion)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
    }

    public func vector(for key: SharedVectorKey) throws -> [Float]? {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let sql = "SELECT dim, vector FROM shared_vectors WHERE content_hash = ?1 AND model_id = ?2 AND model_version = ?3 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        SQLiteHelpers.bindText(stmt, index: 1, value: key.contentHash)
        SQLiteHelpers.bindText(stmt, index: 2, value: key.modelID)
        SQLiteHelpers.bindText(stmt, index: 3, value: key.modelVersion)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
        }
        let dim = Int(sqlite3_column_int(stmt, 0))
        guard let raw = sqlite3_column_blob(stmt, 1) else { return nil }
        let bytes = Int(sqlite3_column_bytes(stmt, 1))
        guard bytes == dim * MemoryLayout<Float>.size else { return nil }
        return Self.decodeFloatArray(raw: raw, count: dim)
    }

    /// Batch-fetches vectors for a set of keys to avoid N+1 SQLite/actor round-trips during semantic search (R-5).
    public func vectors(for keys: [SharedVectorKey]) throws -> [SharedVectorKey: [Float]] {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        guard !keys.isEmpty else { return [:] }

        var hashesByModel: [EmbeddingModelDescriptor: [String]] = [:]
        var seenPerModel: [EmbeddingModelDescriptor: Set<String>] = [:]
        for key in keys {
            let model = EmbeddingModelDescriptor(id: key.modelID, version: key.modelVersion)
            if seenPerModel[model, default: []].insert(key.contentHash).inserted {
                hashesByModel[model, default: []].append(key.contentHash)
            }
        }

        var result: [SharedVectorKey: [Float]] = [:]
        let batchSize = 500
        for (model, hashes) in hashesByModel {
            var idx = 0
            while idx < hashes.count {
                let end = min(idx + batchSize, hashes.count)
                let slice = hashes[idx..<end]
                let placeholders = (0..<slice.count).map { "?\($0 + 3)" }.joined(separator: ", ")
                let sql = """
                SELECT content_hash, dim, vector
                FROM shared_vectors
                WHERE model_id = ?1 AND model_version = ?2 AND content_hash IN (\(placeholders));
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                SQLiteHelpers.bindText(stmt, index: 1, value: model.id)
                SQLiteHelpers.bindText(stmt, index: 2, value: model.version)
                for (offset, hash) in slice.enumerated() {
                    SQLiteHelpers.bindText(stmt, index: Int32(offset + 3), value: hash)
                }
                while true {
                    let rc = sqlite3_step(stmt)
                    if rc == SQLITE_ROW {
                        let hash = SQLiteHelpers.columnText(stmt, index: 0)
                        let dim = Int(sqlite3_column_int(stmt, 1))
                        guard let raw = sqlite3_column_blob(stmt, 2) else { continue }
                        let bytes = Int(sqlite3_column_bytes(stmt, 2))
                        guard bytes == dim * MemoryLayout<Float>.size else { continue }
                        let key = SharedVectorKey(contentHash: hash, model: model)
                        result[key] = Self.decodeFloatArray(raw: raw, count: dim)
                    } else if rc == SQLITE_DONE {
                        break
                    } else {
                        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
                    }
                }
                idx = end
            }
        }
        return result
    }

    public func store(key: SharedVectorKey, vector: [Float]) throws {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let sql = """
        INSERT OR REPLACE INTO shared_vectors (content_hash, model_id, model_version, dim, vector)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        SQLiteHelpers.bindText(stmt, index: 1, value: key.contentHash)
        SQLiteHelpers.bindText(stmt, index: 2, value: key.modelID)
        SQLiteHelpers.bindText(stmt, index: 3, value: key.modelVersion)
        sqlite3_bind_int(stmt, 4, Int32(vector.count))
        let data = Self.encodeFloatArray(vector)
        data.withUnsafeBytes { buf in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_blob(stmt, 5, buf.baseAddress, Int32(buf.count), transient)
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func count() throws -> Int {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let sql = "SELECT COUNT(*) FROM shared_vectors;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Removes vectors that are no longer referenced by any active pack, staging checkpoint, or in-flight batch (FR-30, H-9).
    @discardableResult
    public func garbageCollect(referencedKeys: Set<SharedVectorKey>) throws -> Int {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let existing = try allKeys()
        let orphans = existing.filter { !referencedKeys.contains($0) }
        guard !orphans.isEmpty else { return 0 }

        try SQLiteHelpers.exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let delSQL = "DELETE FROM shared_vectors WHERE content_hash = ?1 AND model_id = ?2 AND model_version = ?3;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, delSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for key in orphans {
                sqlite3_reset(stmt)
                SQLiteHelpers.bindText(stmt, index: 1, value: key.contentHash)
                SQLiteHelpers.bindText(stmt, index: 2, value: key.modelID)
                SQLiteHelpers.bindText(stmt, index: 3, value: key.modelVersion)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
            }
            try SQLiteHelpers.exec(db: db, sql: "COMMIT;")
            return orphans.count
        } catch {
            try? SQLiteHelpers.exec(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func allKeys() throws -> [SharedVectorKey] {
        guard let db else { throw DocsStorageError.sqlite("database closed") }
        let sql = "SELECT content_hash, model_id, model_version FROM shared_vectors;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var keys: [SharedVectorKey] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                keys.append(SharedVectorKey(
                    contentHash: SQLiteHelpers.columnText(stmt, index: 0),
                    modelID: SQLiteHelpers.columnText(stmt, index: 1),
                    modelVersion: SQLiteHelpers.columnText(stmt, index: 2)
                ))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
            }
        }
        return keys
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0..<a.count {
            let av = Double(a[i])
            let bv = Double(b[i])
            dot += av * bv
            normA += av * av
            normB += bv * bv
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private static func encodeFloatArray(_ values: [Float]) -> Data {
        var copy = values
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private static func decodeFloatArray(raw: UnsafeRawPointer, count: Int) -> [Float] {
        var out = Array(repeating: Float(0), count: count)
        _ = out.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress, raw, count * MemoryLayout<Float>.size)
        }
        return out
    }
}

/// Shared low-level SQLite binding helpers for `OgCore/Docs`.
enum SQLiteHelpers {
    static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        _ = value.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, transientDestructor)
        }
    }

    static func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func columnText(_ stmt: OpaquePointer, index: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cstr)
    }

    static func columnOptionalText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    static func exec(db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQL execution failed"
            sqlite3_free(errMsg)
            throw DocsStorageError.sqlite(msg)
        }
    }
}
