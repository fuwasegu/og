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

/// One indexed documentation chunk with version-independent stable ID and content hash (FR-7, FR-8, FR-31).
public struct DocsChunk: Sendable, Hashable, Codable {
    /// Version-independent deterministic ID (FR-31): derived from source + package + symbol + kind + anchor.
    public var stableID: String
    /// Pack Go version (minor key, e.g. `"1.23"` or `"1.21"`).
    public var goVersion: String
    public var source: DocsSourceKind
    public var packageName: String
    public var symbol: String
    public var kind: DocsChunkKind
    public var title: String
    /// Citation/jump anchor (e.g. `"#For_statements"`, `"bufio.Scanner"`).
    public var anchor: String
    /// Version in which the feature/symbol was introduced; `nil` when unknown (FR-8: never guessed).
    public var since: String?
    /// Concise summary (used for card excerpt when no LLM is running, FR-15).
    public var summary: String
    /// Optional Go syntax/type/function signature.
    public var signature: String?
    /// Optional minimal runnable/compilable Go snippet (Example-based, UX-1 / UX-2).
    public var example: String?
    /// Full body text used for FTS5 indexing and embedding.
    public var body: String
    /// Optional multilingual search cues (e.g. Japanese intent phrases) for offline FTS5 cross-lingual recall.
    public var searchAliases: [String]
    /// Deterministic SHA-256 hash of semantic content (FR-25, FR-30, FR-31).
    public var contentHash: String

    public init(
        goVersion: String,
        source: DocsSourceKind,
        packageName: String,
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
        self.stableID = Self.makeStableID(
            source: source,
            packageName: packageName,
            symbol: symbol,
            kind: kind,
            anchor: anchor
        )
        self.goVersion = goVersion
        self.source = source
        self.packageName = packageName
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
            example: example,
            body: body,
            since: since
        )
    }

    /// FR-31: deterministic, version-independent ID.
    public static func makeStableID(
        source: DocsSourceKind,
        packageName: String,
        symbol: String,
        kind: DocsChunkKind,
        anchor: String
    ) -> String {
        let components = [source.rawValue, packageName, symbol, kind.rawValue, anchor]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return components.joined(separator: "::")
    }

    /// SHA-256 hex digest of chunk content, independent of `goVersion` so identical chunks
    /// across Go versions share one vector in `SharedVectorStore` (FR-30).
    public static func computeContentHash(
        stableID: String,
        title: String,
        signature: String?,
        example: String?,
        body: String,
        since: String?
    ) -> String {
        let payload = [
            stableID,
            title,
            signature ?? "",
            example ?? "",
            body,
            since ?? ""
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable citation label (FR-13 / G-4).
    public var citationLabel: String {
        switch source {
        case .stdlib:
            let sym = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
            return "\(source.displayName): \(sym)"
        case .spec, .guide, .release:
            let suffix = anchor.isEmpty ? title : "\(title) (\(anchor))"
            return "\(source.displayName): \(suffix)"
        }
    }

    /// Full text concatenated for embedding computation.
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
}

/// Lifecycle state of an installed documentation pack (matches `spec/req/research.fsl`).
public enum DocsPackStatus: String, Sendable, Hashable, Codable {
    case indexingFTSOnly = "indexing_fts_only"
    case ready = "ready"
}

/// Metadata stored alongside a documentation pack (FR-5, FR-20, Q-4).
public struct DocsPackManifest: Sendable, Hashable, Codable {
    public var goVersion: String
    public var createdAt: String
    public var license: String
    public var chunkCount: Int
    public var status: DocsPackStatus
    public var embeddingModelID: String?
    public var embeddingModelVersion: String?
    public var sizeBytes: Int64

    public init(
        goVersion: String,
        createdAt: String,
        license: String = DocsLicense.goBSD3Clause,
        chunkCount: Int,
        status: DocsPackStatus,
        embeddingModelID: String? = nil,
        embeddingModelVersion: String? = nil,
        sizeBytes: Int64 = 0
    ) {
        self.goVersion = goVersion
        self.createdAt = createdAt
        self.license = license
        self.chunkCount = chunkCount
        self.status = status
        self.embeddingModelID = embeddingModelID
        self.embeddingModelVersion = embeddingModelVersion
        self.sizeBytes = sizeBytes
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
