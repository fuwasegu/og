import Foundation
import SQLite3

/// A scored chunk candidate returned from `DocsIndex` (FTS5, deterministic match, or semantic vector match).
public struct DocsIndexHit: Sendable, Hashable {
    public var chunk: DocsChunk
    public var score: Double
    public var matchedBy: DocsMatchOrigin

    public init(chunk: DocsChunk, score: Double, matchedBy: DocsMatchOrigin) {
        self.chunk = chunk
        self.score = score
        self.matchedBy = matchedBy
    }
}

public enum DocsMatchOrigin: String, Sendable, Hashable, Codable {
    case deterministicExact
    case fts5
    case semantic
}

/// SQLite FTS5 + metadata + shared-vector-reference index for a single Go version documentation pack (FR-8, FR-9, FR-30).
public final class DocsIndex: @unchecked Sendable {
    public let databaseURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(databaseURL: URL, readOnly: Bool = false) throws {
        self.databaseURL = databaseURL
        if !readOnly {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags: Int32 = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open index database"
            if let handle { sqlite3_close(handle) }
            throw DocsStorageError.sqlite(msg)
        }
        self.db = handle
        if !readOnly {
            try Self.initializeSchema(db: handle)
        }
    }

    deinit {
        lock.lock()
        if let db { sqlite3_close(db) }
        db = nil
        lock.unlock()
    }

    public func close() {
        lock.lock()
        if let db { sqlite3_close(db) }
        db = nil
        lock.unlock()
    }

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DocsStorageError.sqlite("index database closed") }
        return try body(db)
    }

    private static func initializeSchema(db: OpaquePointer) throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;

        CREATE TABLE IF NOT EXISTS chunks (
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

        CREATE INDEX IF NOT EXISTS idx_chunks_pkg_sym ON chunks (package_name, symbol);
        CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks (source);

        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            stable_id UNINDEXED,
            title,
            package_name,
            symbol,
            summary,
            body,
            search_aliases,
            tokenize = 'unicode61'
        );

        -- FR-30: pack holds only references into SharedVectorStore, not raw blobs.
        CREATE TABLE IF NOT EXISTS pack_vector_refs (
            stable_id TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            model_id TEXT NOT NULL,
            model_version TEXT NOT NULL
        );
        """
        try SQLiteHelpers.exec(db: db, sql: sql)
    }

    // MARK: - Writing chunks & vector references

    /// Replaces the entire chunk & FTS5 table atomically inside a transaction.
    public func replaceAllChunks(_ chunks: [DocsChunk]) throws {
        try withDB { db in
            try SQLiteHelpers.exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try SQLiteHelpers.exec(db: db, sql: "DELETE FROM chunks; DELETE FROM chunks_fts;")
                let insertChunk = """
                INSERT INTO chunks (
                    stable_id, go_version, source, package_name, symbol, kind,
                    title, anchor, since, summary, signature, example, body,
                    search_aliases, content_hash
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
                """
                let insertFTS = """
                INSERT INTO chunks_fts (
                    stable_id, title, package_name, symbol, summary, body, search_aliases
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
                """
                var chunkStmt: OpaquePointer?
                var ftsStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertChunk, -1, &chunkStmt, nil) == SQLITE_OK, let chunkStmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(chunkStmt) }
                guard sqlite3_prepare_v2(db, insertFTS, -1, &ftsStmt, nil) == SQLITE_OK, let ftsStmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(ftsStmt) }

                for c in chunks {
                    let aliasesJoined = c.searchAliases.joined(separator: " ")
                    sqlite3_reset(chunkStmt)
                    SQLiteHelpers.bindText(chunkStmt, index: 1, value: c.stableID)
                    SQLiteHelpers.bindText(chunkStmt, index: 2, value: c.goVersion)
                    SQLiteHelpers.bindText(chunkStmt, index: 3, value: c.source.rawValue)
                    SQLiteHelpers.bindText(chunkStmt, index: 4, value: c.packageName)
                    SQLiteHelpers.bindText(chunkStmt, index: 5, value: c.symbol)
                    SQLiteHelpers.bindText(chunkStmt, index: 6, value: c.kind.rawValue)
                    SQLiteHelpers.bindText(chunkStmt, index: 7, value: c.title)
                    SQLiteHelpers.bindText(chunkStmt, index: 8, value: c.anchor)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 9, value: c.since)
                    SQLiteHelpers.bindText(chunkStmt, index: 10, value: c.summary)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 11, value: c.signature)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 12, value: c.example)
                    SQLiteHelpers.bindText(chunkStmt, index: 13, value: c.body)
                    SQLiteHelpers.bindText(chunkStmt, index: 14, value: aliasesJoined)
                    SQLiteHelpers.bindText(chunkStmt, index: 15, value: c.contentHash)
                    guard sqlite3_step(chunkStmt) == SQLITE_DONE else {
                        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                    }

                    sqlite3_reset(ftsStmt)
                    SQLiteHelpers.bindText(ftsStmt, index: 1, value: c.stableID)
                    SQLiteHelpers.bindText(ftsStmt, index: 2, value: c.title)
                    SQLiteHelpers.bindText(ftsStmt, index: 3, value: c.packageName)
                    SQLiteHelpers.bindText(ftsStmt, index: 4, value: c.symbol)
                    SQLiteHelpers.bindText(ftsStmt, index: 5, value: c.summary)
                    SQLiteHelpers.bindText(ftsStmt, index: 6, value: c.body)
                    SQLiteHelpers.bindText(ftsStmt, index: 7, value: aliasesJoined)
                    guard sqlite3_step(ftsStmt) == SQLITE_DONE else {
                        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                    }
                }
                try SQLiteHelpers.exec(db: db, sql: "COMMIT;")
            } catch {
                try? SQLiteHelpers.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    /// Records a single chunk's shared vector reference (also acts as the resumable checkpoint, FR-25 & FR-30).
    public func recordVectorReference(stableID: String, key: SharedVectorKey) throws {
        try withDB { db in
            let sql = """
            INSERT OR REPLACE INTO pack_vector_refs (stable_id, content_hash, model_id, model_version)
            VALUES (?1, ?2, ?3, ?4);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            SQLiteHelpers.bindText(stmt, index: 1, value: stableID)
            SQLiteHelpers.bindText(stmt, index: 2, value: key.contentHash)
            SQLiteHelpers.bindText(stmt, index: 3, value: key.modelID)
            SQLiteHelpers.bindText(stmt, index: 4, value: key.modelVersion)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Removes vector references for deleted chunks (FR-26).
    public func removeVectorReferences(forStableIDs ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try withDB { db in
            let sql = "DELETE FROM pack_vector_refs WHERE stable_id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                SQLiteHelpers.bindText(stmt, index: 1, value: id)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    public func clearVectorReferences() throws {
        try withDB { db in
            try SQLiteHelpers.exec(db: db, sql: "DELETE FROM pack_vector_refs;")
        }
    }

    public func vectorReferences() throws -> [String: SharedVectorKey] {
        try withDB { db in
            let sql = "SELECT stable_id, content_hash, model_id, model_version FROM pack_vector_refs;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var map: [String: SharedVectorKey] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteHelpers.columnText(stmt, index: 0)
                map[id] = SharedVectorKey(
                    contentHash: SQLiteHelpers.columnText(stmt, index: 1),
                    modelID: SQLiteHelpers.columnText(stmt, index: 2),
                    modelVersion: SQLiteHelpers.columnText(stmt, index: 3)
                )
            }
            return map
        }
    }

    public func contentHashesByStableID() throws -> [String: String] {
        try withDB { db in
            let sql = "SELECT stable_id, content_hash FROM chunks;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var out: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[SQLiteHelpers.columnText(stmt, index: 0)] = SQLiteHelpers.columnText(stmt, index: 1)
            }
            return out
        }
    }

    public func allChunks() throws -> [DocsChunk] {
        try withDB { db in
            let sql = Self.selectColumns + " FROM chunks ORDER BY stable_id ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var out: [DocsChunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.decodeChunk(stmt: stmt, offset: 0))
            }
            return out
        }
    }

    public func chunkCount() throws -> Int {
        try withDB { db in
            let sql = "SELECT COUNT(*) FROM chunks;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // MARK: - Search (FR-9a deterministic, FR-9b FTS5, FR-9c semantic)

    /// Deterministic lookup by exact `package.Symbol`, `shortPkg.Symbol`, `package`, or `symbol` (FR-1, FR-9a).
    public func deterministicSearch(symbolOrPackage raw: String, limit: Int = 10) throws -> [DocsIndexHit] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let lower = needle.lowercased()

        // Split e.g. `json.Encoder` -> (pkg: "json", sym: "Encoder") or `encoding/json.Encoder`.
        var pkgPart: String?
        var symPart: String?
        if let dot = needle.firstIndex(of: ".") {
            let p = String(needle[..<dot]).lowercased()
            let s = String(needle[needle.index(after: dot)...]).lowercased()
            if !p.isEmpty && !s.isEmpty {
                pkgPart = p
                symPart = s
            }
        }

        let all = try allChunks()
        var hits: [DocsIndexHit] = []
        for chunk in all {
            let cPkg = chunk.packageName.lowercased()
            let cShortPkg = cPkg.split(separator: "/").last.map(String.init) ?? cPkg
            let cSym = chunk.symbol.lowercased()
            let full = cPkg.isEmpty ? cSym : "\(cPkg).\(cSym)"
            let shortFull = cShortPkg.isEmpty ? cSym : "\(cShortPkg).\(cSym)"

            var score: Double = 0
            if full == lower || shortFull == lower {
                score = 100.0
            } else if let pkgPart, let symPart, (cPkg == pkgPart || cShortPkg == pkgPart) {
                if cSym == symPart {
                    score = 98.0
                } else if cSym.hasPrefix(symPart + ".") || cSym.contains(symPart) {
                    score = 88.0
                }
            } else if cPkg == lower || cShortPkg == lower {
                score = cSym.isEmpty ? 95.0 : 80.0
            } else if !cSym.isEmpty && cSym == lower {
                score = 85.0
            }

            if score > 0 {
                hits.append(DocsIndexHit(chunk: chunk, score: score, matchedBy: .deterministicExact))
            }
        }
        hits.sort { ($0.score, $1.chunk.stableID) > ($1.score, $0.chunk.stableID) }
        return Array(hits.prefix(limit))
    }

    /// Full-text search via SQLite FTS5 BM25 (FR-9b).
    /// Accepts expanded keywords (English + Japanese tokens) and ranks with `bm25`.
    public func ftsSearch(terms: [String], limit: Int = 12) throws -> [DocsIndexHit] {
        let sanitized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return [] }

        let matchExpr = sanitized
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " OR ")

        var hits: [DocsIndexHit] = try withDB { db in
            let sql = """
            SELECT c.stable_id, c.go_version, c.source, c.package_name, c.symbol, c.kind,
                   c.title, c.anchor, c.since, c.summary, c.signature, c.example, c.body,
                   c.search_aliases, c.content_hash,
                   bm25(chunks_fts, 0.0, 4.0, 3.0, 5.0, 2.5, 1.0, 4.5) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.stable_id = chunks_fts.stable_id
            WHERE chunks_fts MATCH ?1
            ORDER BY rank ASC
            LIMIT ?2;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            SQLiteHelpers.bindText(stmt, index: 1, value: matchExpr)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var out: [DocsIndexHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let chunk = Self.decodeChunk(stmt: stmt, offset: 0)
                let bm25 = sqlite3_column_double(stmt, 15) // negative: closer to -inf is better
                let normalized = max(0.1, -bm25)
                out.append(DocsIndexHit(chunk: chunk, score: normalized, matchedBy: .fts5))
            }
            return out
        }

        // Japanese substring fallback when FTS5 unicode61 token boundaries miss CJK compounds.
        let cjkTerms = sanitized.filter { term in
            term.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            }
        }
        if !cjkTerms.isEmpty {
            let existingIDs = Set(hits.map(\.chunk.stableID))
            let all = try allChunks()
            for chunk in all where !existingIDs.contains(chunk.stableID) {
                let haystack = (chunk.title + " " + chunk.summary + " " + chunk.searchAliases.joined(separator: " ")).lowercased()
                var matchScore: Double = 0
                for term in cjkTerms {
                    if haystack.contains(term.lowercased()) {
                        matchScore += Double(max(2, term.count))
                    }
                }
                if matchScore > 0 {
                    hits.append(DocsIndexHit(chunk: chunk, score: matchScore, matchedBy: .fts5))
                }
            }
        }

        hits.sort { ($0.score, $1.chunk.stableID) > ($1.score, $0.chunk.stableID) }
        return Array(hits.prefix(limit))
    }

    /// Semantic similarity search reading referenced vectors from `SharedVectorStore` (FR-9c, FR-30).
    /// Only compares vectors matching `model` so distinct embedding models are never mixed (FR-27).
    public func semanticSearch(
        queryVector: [Float],
        model: EmbeddingModelDescriptor,
        sharedStore: SharedVectorStore,
        limit: Int = 10
    ) async throws -> [DocsIndexHit] {
        let refs = try vectorReferences()
        guard !refs.isEmpty else { return [] }
        let chunksByID = Dictionary(uniqueKeysWithValues: try allChunks().map { ($0.stableID, $0) })

        var hits: [DocsIndexHit] = []
        for (stableID, refKey) in refs {
            // FR-27: strict model match guard
            guard refKey.modelID == model.id && refKey.modelVersion == model.version else { continue }
            guard let chunk = chunksByID[stableID] else { continue }
            guard let vec = try await sharedStore.vector(for: refKey) else { continue }
            let sim = SharedVectorStore.cosineSimilarity(queryVector, vec)
            if sim > 0.05 {
                hits.append(DocsIndexHit(chunk: chunk, score: sim * 100.0, matchedBy: .semantic))
            }
        }
        hits.sort { ($0.score, $1.chunk.stableID) > ($1.score, $0.chunk.stableID) }
        return Array(hits.prefix(limit))
    }

    // MARK: - Decoding

    private static let selectColumns = """
    SELECT stable_id, go_version, source, package_name, symbol, kind,
           title, anchor, since, summary, signature, example, body,
           search_aliases, content_hash
    """

    private static func decodeChunk(stmt: OpaquePointer, offset: Int32) -> DocsChunk {
        let goVersion = SQLiteHelpers.columnText(stmt, index: offset + 1)
        let source = DocsSourceKind(rawValue: SQLiteHelpers.columnText(stmt, index: offset + 2)) ?? .stdlib
        let pkg = SQLiteHelpers.columnText(stmt, index: offset + 3)
        let sym = SQLiteHelpers.columnText(stmt, index: offset + 4)
        let kind = DocsChunkKind(rawValue: SQLiteHelpers.columnText(stmt, index: offset + 5)) ?? .section
        let title = SQLiteHelpers.columnText(stmt, index: offset + 6)
        let anchor = SQLiteHelpers.columnText(stmt, index: offset + 7)
        let since = SQLiteHelpers.columnOptionalText(stmt, index: offset + 8)
        let summary = SQLiteHelpers.columnText(stmt, index: offset + 9)
        let signature = SQLiteHelpers.columnOptionalText(stmt, index: offset + 10)
        let example = SQLiteHelpers.columnOptionalText(stmt, index: offset + 11)
        let body = SQLiteHelpers.columnText(stmt, index: offset + 12)
        let aliasesRaw = SQLiteHelpers.columnText(stmt, index: offset + 13)
        let aliases = aliasesRaw.isEmpty ? [] : aliasesRaw.split(separator: " ").map(String.init)
        return DocsChunk(
            goVersion: goVersion,
            source: source,
            packageName: pkg,
            symbol: sym,
            kind: kind,
            title: title,
            anchor: anchor,
            since: since,
            summary: summary,
            signature: signature,
            example: example,
            body: body,
            searchAliases: aliases
        )
    }
}
