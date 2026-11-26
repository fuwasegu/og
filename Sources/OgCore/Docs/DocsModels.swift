import CryptoKit
import Foundation

/// Authoritative source family for Go documentation chunks (FR-4, FR-8).
public enum DocsSourceKind: String, Sendable, Hashable, Codable, CaseIterable {
    case spec
    case guide
    case stdlib
    case release

    public var displayName: String {
        switch self {
        case .spec: return "Go Language Specification"
        case .guide: return "Effective Go / Official Guide"
        case .stdlib: return "Go Standard Library"
        case .release: return "Go Release Notes"
        }
    }
}

/// Structural unit of a chunk (FR-7, FR-8).
public enum DocsChunkKind: String, Sendable, Hashable, Codable, CaseIterable {
    case syntax
    case section
    case package
    case type
    case function = "func"
    case method
    case constant = "const"
    case variable = "var"
    case guide
    case releaseNote = "release_note"
}

/// Provenance distinguishing official extracted GoDoc/docs from og's bundled curated summaries (R-9).
public enum DocsProvenance: String, Sendable, Hashable, Codable {
    case officialExtracted = "official_extracted"
    case bundledCurated = "bundled_curated"
}

/// One indexed documentation chunk with version-independent stable ID and content hash (FR-7, FR-8, FR-31).
public struct DocsChunk: Sendable, Hashable, Codable {
    /// Version-independent deterministic ID (FR-31, H-6): derived from
    /// `source + docScope(package or documentID) + symbol + kind + anchor`.
    public var stableID: String
    /// Pack Go version (minor key, e.g. `"1.23"` or `"1.21"`).
    public var goVersion: String
    public var source: DocsSourceKind
    /// Provenance of the chunk's text (official extracted vs og bundled curated summary, R-9).
    public var provenance: DocsProvenance
    /// For stdlib: Go import path (e.g. `"encoding/json"`). For guides/spec: empty.
    public var packageName: String
    /// Document identity for non-stdlib sources (e.g. `"go_spec"`, `"effective_go"`, `"tutorial"`) to prevent
    /// cross-document heading collisions (H-6). Defaults to `packageName` for stdlib.
    public var documentID: String
    public var symbol: String
    public var kind: DocsChunkKind
    public var title: String
    /// Citation/jump anchor (e.g. `"#For_statements"`, `"bufio.Scanner"`).
    public var anchor: String
    /// Version in which the feature/symbol was introduced; `nil` when unknown (FR-8: never guessed).
    public var since: String?
    /// Concise summary (used for card excerpt when no LLM is running, FR-15).
    public var summary: String
    /// Optional Go syntax/type/function/const/var signature.
    public var signature: String?
    /// Optional minimal runnable/compilable Go snippet (Example-based, UX-1 / UX-2).
    public var example: String?
    /// Full body text used for FTS5 indexing and embedding.
    public var body: String
    /// General multilingual search concepts (no test-query hardcoding; H-2).
    public var searchAliases: [String]
    /// Deterministic SHA-256 hash of all semantic & embedding inputs (FR-25, FR-30, FR-31, M-8).
    public var contentHash: String

    public init(
        goVersion: String,
        source: DocsSourceKind,
        provenance: DocsProvenance = .officialExtracted,
        packageName: String,
        documentID: String? = nil,
        symbol: String,
        kind: DocsChunkKind,
        title: String,
        anchor: String,
        since: String? = nil,
        summary: String,
        signature: String? = nil,
        example: String? = nil,
        body: String,
        searchAliases: [String] = []
    ) {
        let resolvedDocID = documentID ?? (packageName.isEmpty ? source.rawValue : packageName)
        self.stableID = Self.makeStableID(
            source: source,
            documentID: resolvedDocID,
            packageName: packageName,
            symbol: symbol,
            kind: kind,
            anchor: anchor
        )
        self.goVersion = goVersion
        self.source = source
        self.provenance = provenance
        self.packageName = packageName
        self.documentID = resolvedDocID
        self.symbol = symbol
        self.kind = kind
        self.title = title
        self.anchor = anchor
        self.since = since
        self.summary = summary
        self.signature = signature
        self.example = example
        self.body = body
        self.searchAliases = searchAliases
        self.contentHash = Self.computeContentHash(
            stableID: self.stableID,
            title: title,
            signature: signature,
            summary: summary,
            example: example,
            body: body,
            searchAliases: searchAliases,
            since: since
        )
    }

    /// Restores a persisted chunk directly from SQLite without recomputing SHA-256 (H-7).
    public init(
        restoredStableID: String,
        goVersion: String,
        source: DocsSourceKind,
        provenance: DocsProvenance = .officialExtracted,
        packageName: String,
        documentID: String,
        symbol: String,
        kind: DocsChunkKind,
        title: String,
        anchor: String,
        since: String?,
        summary: String,
        signature: String?,
        example: String?,
        body: String,
        searchAliases: [String],
        storedContentHash: String
    ) {
        self.stableID = restoredStableID
        self.goVersion = goVersion
        self.source = source
        self.provenance = provenance
        self.packageName = packageName
        self.documentID = documentID
        self.symbol = symbol
        self.kind = kind
        self.title = title
        self.anchor = anchor
        self.since = since
        self.summary = summary
        self.signature = signature
        self.example = example
        self.body = body
        self.searchAliases = searchAliases
        self.contentHash = storedContentHash
    }

    /// FR-31 & H-6: deterministic, version-independent ID including document identity.
    public static func makeStableID(
        source: DocsSourceKind,
        documentID: String = "",
        packageName: String,
        symbol: String,
        kind: DocsChunkKind,
        anchor: String
    ) -> String {
        let scope = !documentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? documentID
            : packageName
        let components = [source.rawValue, scope, packageName, symbol, kind.rawValue, anchor]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return components.joined(separator: "::")
    }

    /// SHA-256 hex digest covering every field included in `embeddingText` plus `since`/`example` (M-8),
    /// independent of `goVersion` so identical chunks across Go versions share one vector (FR-30).
    public static func computeContentHash(
        stableID: String,
        title: String,
        signature: String?,
        summary: String,
        example: String?,
        body: String,
        searchAliases: [String],
        since: String?
    ) -> String {
        let payload = [
            stableID,
            title,
            signature ?? "",
            summary,
            example ?? "",
            body,
            searchAliases.joined(separator: "\u{1E}"),
            since ?? ""
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable citation label (FR-13 / G-4, R-9: clearly marks bundled curated summaries).
    public var citationLabel: String {
        let sourceLabel = provenance == .bundledCurated
            ? "\(source.displayName) [og bundled summary]"
            : source.displayName
        switch source {
        case .stdlib:
            let sym = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
            return "\(sourceLabel): \(sym)"
        case .spec, .guide, .release:
            let suffix = anchor.isEmpty ? title : "\(title) (\(anchor))"
            return "\(sourceLabel): \(suffix)"
        }
    }

    /// Full text concatenated for embedding computation (inputs match `computeContentHash`, M-8).
    public var embeddingText: String {
        var parts = [title]
        if !packageName.isEmpty || !symbol.isEmpty {
            parts.append([packageName, symbol].filter { !$0.isEmpty }.joined(separator: "."))
        }
        if let signature, !signature.isEmpty { parts.append(signature) }
        parts.append(summary)
        parts.append(body)
        if !searchAliases.isEmpty { parts.append(searchAliases.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }

    /// Concise, deduplicated text passed to the local cross-encoder reranker (fits within 256 tokens, Issue #21).
    public var rerankDocumentText: String {
        var parts: [String] = []
        let qualified = [packageName, symbol].filter { !$0.isEmpty }.joined(separator: ".")
        if !title.isEmpty {
            parts.append(title)
        }
        if !qualified.isEmpty && !title.contains(qualified) {
            parts.append(qualified)
        }
        if let signature, !signature.isEmpty {
            parts.append(signature)
        }
        if !summary.isEmpty {
            parts.append(summary)
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty && trimmedBody != summary {
            // Avoid repeating the summary prefix when body begins with it.
            let bodySnippet = trimmedBody.count > 500 ? String(trimmedBody.prefix(500)) : trimmedBody
            parts.append(bodySnippet)
        }
        if !searchAliases.isEmpty {
            parts.append(searchAliases.joined(separator: " "))
        }
        let joined = parts.joined(separator: "\n")
        return joined.count > 700 ? String(joined.prefix(700)) : joined
    }
}

/// Lifecycle state of an installed documentation pack (matches `spec/req/research.fsl`).
public enum DocsPackStatus: String, Sendable, Hashable, Codable {
    case indexingFTSOnly = "indexing_fts_only"
    case ready = "ready"
}

/// Metadata stored alongside a documentation pack (FR-5, FR-20, Q-4).
public struct DocsPackManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 3

    public var goVersion: String
    public var createdAt: String
    public var license: String
    public var chunkCount: Int
    public var status: DocsPackStatus
    public var embeddingModelID: String?
    public var embeddingModelVersion: String?
    public var sizeBytes: Int64
    public var schemaVersion: Int

    /// True for legacy v1 packs created before `document_id` and updated content hashing;
    /// v1 packs cannot be reliably provenance-migrated in place and should be re-imported (T-1).
    public var needsReimport: Bool {
        schemaVersion < 2
    }

    public init(
        goVersion: String,
        createdAt: String,
        license: String = DocsLicense.goBSD3Clause,
        chunkCount: Int,
        status: DocsPackStatus,
        embeddingModelID: String? = nil,
        embeddingModelVersion: String? = nil,
        sizeBytes: Int64 = 0,
        schemaVersion: Int = DocsPackManifest.currentSchemaVersion
    ) {
        self.goVersion = goVersion
        self.createdAt = createdAt
        self.license = license
        self.chunkCount = chunkCount
        self.status = status
        self.embeddingModelID = embeddingModelID
        self.embeddingModelVersion = embeddingModelVersion
        self.sizeBytes = sizeBytes
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goVersion = try c.decode(String.self, forKey: .goVersion)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? DocsLicense.goBSD3Clause
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        status = try c.decode(DocsPackStatus.self, forKey: .status)
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
        embeddingModelVersion = try c.decodeIfPresent(String.self, forKey: .embeddingModelVersion)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

/// Diff between two chunk sets computed by stable ID and content hash (FR-26, FR-31).
public struct DocsChunkDiff: Sendable, Equatable {
    public var added: [DocsChunk]
    public var removed: [String]
    public var changed: [DocsChunk]
    public var unchanged: [DocsChunk]

    public init(added: [DocsChunk], removed: [String], changed: [DocsChunk], unchanged: [DocsChunk]) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.unchanged = unchanged
    }

    /// Computes added / removed / changed / unchanged using `stableID` and `contentHash` (FR-31).
    public static func compute(previous: [String: String], next: [DocsChunk]) -> DocsChunkDiff {
        var added: [DocsChunk] = []
        var changed: [DocsChunk] = []
        var unchanged: [DocsChunk] = []
        var nextIDs = Set<String>()

        for chunk in next {
            nextIDs.insert(chunk.stableID)
            if let oldHash = previous[chunk.stableID] {
                if oldHash == chunk.contentHash {
                    unchanged.append(chunk)
                } else {
                    changed.append(chunk)
                }
            } else {
                added.append(chunk)
            }
        }
        let removed = previous.keys.filter { !nextIDs.contains($0) }.sorted()
        return DocsChunkDiff(added: added, removed: removed, changed: changed, unchanged: unchanged)
    }
}

/// BSD-3-Clause license text for redistributed Go documentation excerpts (Q-4).
public enum DocsLicense {
    public static let goBSD3Clause = """
    Go Documentation Excerpts — BSD-3-Clause License
    Copyright (c) 2009 The Go Authors. All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

       * Redistributions of source code must retain the above copyright
         notice, this list of conditions and the following disclaimer.
       * Redistributions in binary form must reproduce the above
         copyright notice, this list of conditions and the following disclaimer
         in the documentation and/or other materials provided with the
         distribution.
       * Neither the name of Google LLC nor the names of its
         contributors may be used to endorse or promote products derived from
         this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED.
    """
}
