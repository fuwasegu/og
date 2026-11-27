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

/// SQLite FTS5 + metadata + shared-vector-reference index for a single Go version documentation pack
/// (FR-8, FR-9, FR-30, H-7, M-7, M-9, L-1..L-3).
public final class DocsIndex: @unchecked Sendable {
    public let databaseURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let hasDocumentIDColumn: Bool
    private let hasProvenanceColumn: Bool
    private let hasDependencyColumns: Bool

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
        sqlite3_busy_timeout(handle, 5000) // L-2
        self.db = handle
        if !readOnly {
            try Self.initializeSchema(db: handle)
            self.hasDocumentIDColumn = true
            self.hasProvenanceColumn = true
            self.hasDependencyColumns = true
        } else {
            self.hasDocumentIDColumn = Self.tableHasColumn(db: handle, table: "chunks", column: "document_id")
            self.hasProvenanceColumn = Self.tableHasColumn(db: handle, table: "chunks", column: "provenance")
            self.hasDependencyColumns = Self.tableHasColumn(db: handle, table: "chunks", column: "module_path")
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

    /// Flushes WAL pages and switches to single-file `DELETE` journal mode so copying or opening
    /// the database with `SQLITE_OPEN_READONLY` never fails due to missing `-shm`/`-wal` sidecars (M-7).
    public func checkpointWAL() throws {
        try withDB { db in
            try SQLiteHelpers.exec(db: db, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
            try SQLiteHelpers.exec(db: db, sql: "PRAGMA journal_mode=DELETE;")
        }
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
            provenance TEXT NOT NULL DEFAULT 'official_extracted',
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
            content_hash TEXT NOT NULL,
            module_path TEXT,
            module_version TEXT,
            license TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_pkg_sym ON chunks (package_name, symbol);
        CREATE INDEX IF NOT EXISTS idx_chunks_pkg_lower ON chunks (lower(package_name));
        CREATE INDEX IF NOT EXISTS idx_chunks_sym_lower ON chunks (lower(symbol));
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
        // Migrate v1/v2 databases created before `document_id` / `provenance` were added.
        if !Self.tableHasColumn(db: db, table: "chunks", column: "document_id") {
            try SQLiteHelpers.exec(db: db, sql: "ALTER TABLE chunks ADD COLUMN document_id TEXT NOT NULL DEFAULT '';")
        }
        if !Self.tableHasColumn(db: db, table: "chunks", column: "provenance") {
            try SQLiteHelpers.exec(db: db, sql: "ALTER TABLE chunks ADD COLUMN provenance TEXT NOT NULL DEFAULT 'official_extracted';")
        }
        if !Self.tableHasColumn(db: db, table: "chunks", column: "module_path") {
            try SQLiteHelpers.exec(db: db, sql: "ALTER TABLE chunks ADD COLUMN module_path TEXT;")
        }
        if !Self.tableHasColumn(db: db, table: "chunks", column: "module_version") {
            try SQLiteHelpers.exec(db: db, sql: "ALTER TABLE chunks ADD COLUMN module_version TEXT;")
        }
        if !Self.tableHasColumn(db: db, table: "chunks", column: "license") {
            try SQLiteHelpers.exec(db: db, sql: "ALTER TABLE chunks ADD COLUMN license TEXT;")
        }
    }

    private static func tableHasColumn(db: OpaquePointer, table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if SQLiteHelpers.columnText(stmt, index: 1) == column { return true }
        }
        return false
    }

    // MARK: - Writing chunks & vector references

    /// Replaces the entire chunk & FTS5 table atomically inside a transaction.
    public func replaceAllChunks(_ chunks: [DocsChunk]) throws {
        let jsonEncoder = JSONEncoder()
        try withDB { db in
            try SQLiteHelpers.exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try SQLiteHelpers.exec(db: db, sql: "DELETE FROM chunks; DELETE FROM chunks_fts;")
                let insertChunk = """
                INSERT INTO chunks (
                    stable_id, go_version, source, provenance, package_name, document_id, symbol, kind,
                    title, anchor, since, summary, signature, example, body,
                    search_aliases, content_hash, module_path, module_version, license
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20);
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
                    // L-1: persist aliases losslessly as JSON array; join with spaces for FTS5 indexing.
                    let aliasesJSON = (try? jsonEncoder.encode(c.searchAliases)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    let aliasesFTS = c.searchAliases.joined(separator: " ")

                    sqlite3_reset(chunkStmt)
                    SQLiteHelpers.bindText(chunkStmt, index: 1, value: c.stableID)
                    SQLiteHelpers.bindText(chunkStmt, index: 2, value: c.goVersion)
                    SQLiteHelpers.bindText(chunkStmt, index: 3, value: c.source.rawValue)
                    SQLiteHelpers.bindText(chunkStmt, index: 4, value: c.provenance.rawValue)
                    SQLiteHelpers.bindText(chunkStmt, index: 5, value: c.packageName)
                    SQLiteHelpers.bindText(chunkStmt, index: 6, value: c.documentID)
                    SQLiteHelpers.bindText(chunkStmt, index: 7, value: c.symbol)
                    SQLiteHelpers.bindText(chunkStmt, index: 8, value: c.kind.rawValue)
                    SQLiteHelpers.bindText(chunkStmt, index: 9, value: c.title)
                    SQLiteHelpers.bindText(chunkStmt, index: 10, value: c.anchor)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 11, value: c.since)
                    SQLiteHelpers.bindText(chunkStmt, index: 12, value: c.summary)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 13, value: c.signature)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 14, value: c.example)
                    SQLiteHelpers.bindText(chunkStmt, index: 15, value: c.body)
                    SQLiteHelpers.bindText(chunkStmt, index: 16, value: aliasesJSON)
                    SQLiteHelpers.bindText(chunkStmt, index: 17, value: c.contentHash)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 18, value: c.modulePath)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 19, value: c.moduleVersion)
                    SQLiteHelpers.bindOptionalText(chunkStmt, index: 20, value: c.license)
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
                    SQLiteHelpers.bindText(ftsStmt, index: 7, value: aliasesFTS)
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

    /// Removes vector references for deleted or changed chunks (FR-26, M-9).
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

    /// Updates chunk provenance in place for schema v2 -> v3 migration (S-1).
    /// Marks chunks whose `content_hash` or non-stdlib `stable_id` matches bundled curated excerpts.
    @discardableResult
    public func migrateBundledProvenance(
        bundledContentHashes: Set<String>,
        bundledNonStdlibStableIDs: Set<String>
    ) throws -> Int {
        guard !bundledContentHashes.isEmpty || !bundledNonStdlibStableIDs.isEmpty else { return 0 }
        return try withDB { db in
            try SQLiteHelpers.exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                var updated = 0
                if !bundledContentHashes.isEmpty {
                    let sql = "UPDATE chunks SET provenance = ?1 WHERE content_hash = ?2 AND provenance != ?1;"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                    }
                    defer { sqlite3_finalize(stmt) }
                    for hash in bundledContentHashes {
                        sqlite3_reset(stmt)
                        SQLiteHelpers.bindText(stmt, index: 1, value: DocsProvenance.bundledCurated.rawValue)
                        SQLiteHelpers.bindText(stmt, index: 2, value: hash)
                        guard sqlite3_step(stmt) == SQLITE_DONE else {
                            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                        }
                        updated += Int(sqlite3_changes(db))
                    }
                }
                if !bundledNonStdlibStableIDs.isEmpty {
                    let sql = "UPDATE chunks SET provenance = ?1 WHERE stable_id = ?2 AND source != 'stdlib' AND provenance != ?1;"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                        throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                    }
                    defer { sqlite3_finalize(stmt) }
                    for id in bundledNonStdlibStableIDs {
                        sqlite3_reset(stmt)
                        SQLiteHelpers.bindText(stmt, index: 1, value: DocsProvenance.bundledCurated.rawValue)
                        SQLiteHelpers.bindText(stmt, index: 2, value: id)
                        guard sqlite3_step(stmt) == SQLITE_DONE else {
                            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                        }
                        updated += Int(sqlite3_changes(db))
                    }
                }
                try SQLiteHelpers.exec(db: db, sql: "COMMIT;")
                return updated
            } catch {
                try? SQLiteHelpers.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
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
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let id = SQLiteHelpers.columnText(stmt, index: 0)
                    map[id] = SharedVectorKey(
                        contentHash: SQLiteHelpers.columnText(stmt, index: 1),
                        modelID: SQLiteHelpers.columnText(stmt, index: 2),
                        modelVersion: SQLiteHelpers.columnText(stmt, index: 3)
                    )
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
                }
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
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    out[SQLiteHelpers.columnText(stmt, index: 0)] = SQLiteHelpers.columnText(stmt, index: 1)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
                }
            }
            return out
        }
    }

    public func allChunks() throws -> [DocsChunk] {
        try withDB { db in
            let sql = selectColumns + " FROM chunks ORDER BY stable_id ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            return try Self.collectChunks(stmt: stmt, db: db)
        }
    }

    public func chunk(forStableID stableID: String) throws -> DocsChunk? {
        try withDB { db in
            let sql = selectColumns + " FROM chunks WHERE stable_id = ?1 LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            SQLiteHelpers.bindText(stmt, index: 1, value: stableID)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return Self.decodeChunk(stmt: stmt, offset: 0) }
            if rc == SQLITE_DONE { return nil }
            throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
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
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Search (FR-9a deterministic, FR-9b FTS5, FR-9c semantic; zero SHA-256 recomputation H-7)

    /// Deterministic lookup via indexed SQL `WHERE` queries (H-7: does not scan/decode all chunks).
    public func deterministicSearch(symbolOrPackage raw: String, limit: Int = 10) throws -> [DocsIndexHit] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let lower = needle.lowercased()

        var pkgPart: String?
        var symPart: String?
        // Package/symbol split: for import paths with `/`, the boundary is the first `.` AFTER the last `/`
        // (so `github.com/pkg/errors.New` splits into `github.com/pkg/errors` + `New`, and
        // `github.com/go-chi/chi/v5.Mux.Get` splits into `github.com/go-chi/chi/v5` + `Mux.Get`).
        // For short package names without `/`, the boundary is the first `.` (`bufio.Scanner.Scan`).
        let searchStart = needle.lastIndex(of: "/").map { needle.index(after: $0) } ?? needle.startIndex
        if let dot = needle[searchStart...].firstIndex(of: ".") {
            let p = String(needle[..<dot]).lowercased()
            let s = String(needle[needle.index(after: dot)...]).lowercased()
            if !p.isEmpty && !s.isEmpty {
                pkgPart = p
                symPart = s
            }
        }

        let candidates: [DocsChunk] = try withDB { db in
            let sql: String
            var stmt: OpaquePointer?
            if let pkgPart, let symPart {
                sql = selectColumns + """
                 FROM chunks
                WHERE (lower(package_name) = ?1 OR lower(package_name) LIKE ?2 OR lower(package_name) LIKE ?5)
                  AND (lower(symbol) = ?3 OR lower(symbol) LIKE ?4)
                ORDER BY CASE WHEN kind = 'example' THEN 1 ELSE 0 END, stable_id ASC
                LIMIT 64;
                """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                SQLiteHelpers.bindText(stmt, index: 1, value: pkgPart)
                SQLiteHelpers.bindText(stmt, index: 2, value: "%/" + pkgPart)
                SQLiteHelpers.bindText(stmt, index: 3, value: symPart)
                SQLiteHelpers.bindText(stmt, index: 4, value: symPart + ".%")
                SQLiteHelpers.bindText(stmt, index: 5, value: "%/" + pkgPart + "/v%")
                return try Self.collectChunks(stmt: stmt, db: db)
            } else {
                sql = selectColumns + """
                 FROM chunks
                WHERE lower(package_name) = ?1
                   OR lower(package_name) LIKE ?2
                   OR lower(package_name) LIKE ?3
                   OR lower(symbol) = ?1
                ORDER BY CASE WHEN kind = 'example' THEN 1 ELSE 0 END, stable_id ASC
                LIMIT 64;
                """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                SQLiteHelpers.bindText(stmt, index: 1, value: lower)
                SQLiteHelpers.bindText(stmt, index: 2, value: "%/" + lower)
                SQLiteHelpers.bindText(stmt, index: 3, value: "%/" + lower + "/v%")
                return try Self.collectChunks(stmt: stmt, db: db)
            }
        }

        var hits: [DocsIndexHit] = []
        for chunk in candidates {
            let cPkg = chunk.packageName.lowercased()
            let cShortPkg = Self.shortPackageName(for: cPkg)
            let cSym = chunk.symbol.lowercased()
            let full = cPkg.isEmpty ? cSym : "\(cPkg).\(cSym)"
            let shortFull = cShortPkg.isEmpty ? cSym : "\(cShortPkg).\(cSym)"

            var score: Double = 0
            let isExample = chunk.kind == .example
            // U-1: When a short package name collides with stdlib (e.g. `errors.New` vs `github.com/pkg/errors`),
            // stdlib retains deterministic priority unless the caller explicitly typed the full module path.
            let depPenalty: Double = (chunk.source == .dependency && full != lower) ? 3.0 : 0.0
            if full == lower || shortFull == lower {
                score = (isExample ? 92.0 : 100.0) - depPenalty
            } else if let pkgPart, let symPart, (cPkg == pkgPart || cShortPkg == pkgPart) {
                if cSym == symPart {
                    score = (isExample ? 90.0 : 98.0) - depPenalty
                } else if cSym.hasPrefix(symPart + ".") {
                    score = (isExample ? 82.0 : 88.0) - depPenalty
                }
            } else if cPkg == lower || cShortPkg == lower {
                score = (cSym.isEmpty ? (isExample ? 84.0 : 95.0) : (isExample ? 74.0 : 80.0)) - depPenalty
            } else if !cSym.isEmpty && cSym == lower {
                score = (isExample ? 78.0 : 85.0) - depPenalty
            }

            if score > 0 {
                hits.append(DocsIndexHit(chunk: chunk, score: score, matchedBy: .deterministicExact))
            }
        }
        hits.sort {
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            let p0 = $0.chunk.source == .dependency ? 1 : 0
            let p1 = $1.chunk.source == .dependency ? 1 : 0
            if p0 != p1 { return p0 < p1 }
            return $0.chunk.stableID < $1.chunk.stableID
        }
        return Array(hits.prefix(limit))
    }

    /// Full-text search via SQLite FTS5 BM25 + bounded SQL LIKE CJK fallback (FR-9b, H-7).
    public func ftsSearch(terms: [String], limit: Int = 12) throws -> [DocsIndexHit] {
        let sanitized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return [] }

        let matchExpr = sanitized
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " OR ")

        var hits: [DocsIndexHit] = try withDB { db in
            let provCol = hasProvenanceColumn ? "c.provenance" : "'official_extracted' AS provenance"
            let docCol = hasDocumentIDColumn ? "c.document_id" : "'' AS document_id"
            let depCols = hasDependencyColumns
                ? "c.module_path, c.module_version, c.license"
                : "NULL AS module_path, NULL AS module_version, NULL AS license"
            let sql = """
            SELECT c.stable_id, c.go_version, c.source, \(provCol), c.package_name, \(docCol), c.symbol, c.kind,
                   c.title, c.anchor, c.since, c.summary, c.signature, c.example, c.body,
                   c.search_aliases, c.content_hash, \(depCols),
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
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let chunk = Self.decodeChunk(stmt: stmt, offset: 0)
                    let bm25 = sqlite3_column_double(stmt, 20)
                    let normalized = max(0.1, -bm25)
                    out.append(DocsIndexHit(chunk: chunk, score: normalized, matchedBy: .fts5))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
                }
            }
            return out
        }

        // Bounded SQL LIKE fallback for Japanese substrings when unicode61 token boundaries miss CJK compounds (H-7).
        let cjkTerms = sanitized.filter { term in
            term.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            }
        }
        if !cjkTerms.isEmpty {
            let existingIDs = Set(hits.map(\.chunk.stableID))
            let sqlMatches: [DocsChunk] = try withDB { db in
                let clauses = cjkTerms.enumerated().map { idx, _ in
                    let p = idx + 1
                    return "(title LIKE ?\(p) OR summary LIKE ?\(p) OR search_aliases LIKE ?\(p))"
                }.joined(separator: " OR ")
                let sql = selectColumns + " FROM chunks WHERE \(clauses) LIMIT 32;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                for (idx, term) in cjkTerms.enumerated() {
                    SQLiteHelpers.bindText(stmt, index: Int32(idx + 1), value: "%\(term)%")
                }
                return try Self.collectChunks(stmt: stmt, db: db)
            }

            for chunk in sqlMatches where !existingIDs.contains(chunk.stableID) {
                let haystack = (chunk.title + " " + chunk.summary + " " + chunk.searchAliases.joined(separator: " ")).lowercased()
                var matchScore: Double = 0
                for term in cjkTerms where haystack.contains(term.lowercased()) {
                    matchScore += Double(max(2, term.count))
                }
                if matchScore > 0 {
                    hits.append(DocsIndexHit(chunk: chunk, score: matchScore, matchedBy: .fts5))
                }
            }
        }

        hits.sort { ($0.score, $1.chunk.stableID) > ($1.score, $0.chunk.stableID) }
        return Array(hits.prefix(limit))
    }

    /// Semantic similarity search reading referenced vectors from `SharedVectorStore` in batch (FR-9c, FR-27, FR-30, H-7, M-1, M-9, R-5).
    /// Strictly validates BOTH embedding model match (FR-27) AND chunk `contentHash` match (M-9),
    /// fetches vectors in a single batch call (no N+1), and decodes only top-K matching chunks (H-7).
    public func semanticSearch(
        queryVector: [Float],
        model: EmbeddingModelDescriptor,
        sharedStore: SharedVectorStore,
        minimumSimilarity: Double = 0.25,
        limit: Int = 10
    ) async throws -> [DocsIndexHit] {
        let refs = try vectorReferences()
        guard !refs.isEmpty else { return [] }
        let currentHashes = try contentHashesByStableID()

        var eligible: [(stableID: String, key: SharedVectorKey)] = []
        eligible.reserveCapacity(refs.count)
        for (stableID, refKey) in refs {
            // FR-27: strict model match guard
            guard refKey.modelID == model.id && refKey.modelVersion == model.version else { continue }
            // M-9: strict content hash match guard (never use a stale vector for a changed chunk)
            guard currentHashes[stableID] == refKey.contentHash else { continue }
            eligible.append((stableID, refKey))
        }
        guard !eligible.isEmpty else { return [] }

        // R-5: batch fetch all eligible vectors in one actor/SQLite sweep instead of N+1 awaits.
        let vectorMap = try await sharedStore.vectors(for: eligible.map(\.key))

        var scoredIDs: [(stableID: String, score: Double)] = []
        for item in eligible {
            guard let vec = vectorMap[item.key] else { continue }
            let sim = SharedVectorStore.cosineSimilarity(queryVector, vec)
            if sim >= minimumSimilarity {
                scoredIDs.append((item.stableID, sim * 100.0))
            }
        }
        scoredIDs.sort { ($0.score, $1.stableID) > ($1.score, $0.stableID) }

        var hits: [DocsIndexHit] = []
        for item in scoredIDs.prefix(limit) {
            if let chunk = try chunk(forStableID: item.stableID) {
                hits.append(DocsIndexHit(chunk: chunk, score: item.score, matchedBy: .semantic))
            }
        }
        return hits
    }

    // MARK: - Decoding (H-7: zero SHA-256 recomputation; L-1: JSON aliases; L-3: error propagation)

    /// Returns the idiomatic Go short package name for an import path, stripping trailing major-version segments
    /// like `/v2`, `/v5` (e.g. `github.com/go-chi/chi/v5` -> `chi`).
    public static func shortPackageName(for importPath: String) -> String {
        let parts = importPath.split(separator: "/").map(String.init)
        guard let last = parts.last else { return importPath }
        if parts.count >= 2, last.hasPrefix("v"), last.count >= 2, last.dropFirst().allSatisfy(\.isNumber) {
            return parts[parts.count - 2]
        }
        return last
    }

    private var selectColumns: String {
        let provCol = hasProvenanceColumn ? "provenance" : "'official_extracted' AS provenance"
        let docCol = hasDocumentIDColumn ? "document_id" : "'' AS document_id"
        let depCols = hasDependencyColumns
            ? "module_path, module_version, license"
            : "NULL AS module_path, NULL AS module_version, NULL AS license"
        return """
        SELECT stable_id, go_version, source, \(provCol), package_name, \(docCol), symbol, kind,
               title, anchor, since, summary, signature, example, body,
               search_aliases, content_hash, \(depCols)
        """
    }

    private static func collectChunks(stmt: OpaquePointer, db: OpaquePointer) throws -> [DocsChunk] {
        var out: [DocsChunk] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(decodeChunk(stmt: stmt, offset: 0))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DocsStorageError.sqlite(String(cString: sqlite3_errmsg(db))) // L-3
            }
        }
        return out
    }

    private static func decodeChunk(stmt: OpaquePointer, offset: Int32) -> DocsChunk {
        let stableID = SQLiteHelpers.columnText(stmt, index: offset + 0)
        let goVersion = SQLiteHelpers.columnText(stmt, index: offset + 1)
        let source = DocsSourceKind(rawValue: SQLiteHelpers.columnText(stmt, index: offset + 2)) ?? .stdlib
        let provenance = DocsProvenance(rawValue: SQLiteHelpers.columnText(stmt, index: offset + 3)) ?? .officialExtracted
        let pkg = SQLiteHelpers.columnText(stmt, index: offset + 4)
        let docID = SQLiteHelpers.columnText(stmt, index: offset + 5)
        let sym = SQLiteHelpers.columnText(stmt, index: offset + 6)
        let kind = DocsChunkKind(rawValue: SQLiteHelpers.columnText(stmt, index: offset + 7)) ?? .section
        let title = SQLiteHelpers.columnText(stmt, index: offset + 8)
        let anchor = SQLiteHelpers.columnText(stmt, index: offset + 9)
        let since = SQLiteHelpers.columnOptionalText(stmt, index: offset + 10)
        let summary = SQLiteHelpers.columnText(stmt, index: offset + 11)
        let signature = SQLiteHelpers.columnOptionalText(stmt, index: offset + 12)
        let example = SQLiteHelpers.columnOptionalText(stmt, index: offset + 13)
        let body = SQLiteHelpers.columnText(stmt, index: offset + 14)
        let aliasesRaw = SQLiteHelpers.columnText(stmt, index: offset + 15)
        let storedHash = SQLiteHelpers.columnText(stmt, index: offset + 16)
        let modulePath = SQLiteHelpers.columnOptionalText(stmt, index: offset + 17)
        let moduleVersion = SQLiteHelpers.columnOptionalText(stmt, index: offset + 18)
        let license = SQLiteHelpers.columnOptionalText(stmt, index: offset + 19)

        let aliases: [String]
        if aliasesRaw.hasPrefix("["),
           let data = aliasesRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            aliases = decoded
        } else if aliasesRaw.isEmpty {
            aliases = []
        } else {
            aliases = aliasesRaw.split(separator: " ").map(String.init)
        }

        return DocsChunk(
            restoredStableID: stableID,
            goVersion: goVersion,
            source: source,
            provenance: provenance,
            packageName: pkg,
            documentID: docID,
            symbol: sym,
            kind: kind,
            title: title,
            anchor: anchor,
            since: since,
            summary: summary,
            signature: signature,
            example: example,
            body: body,
            searchAliases: aliases,
            storedContentHash: storedHash,
            modulePath: modulePath,
            moduleVersion: moduleVersion,
            license: license
        )
    }
}
