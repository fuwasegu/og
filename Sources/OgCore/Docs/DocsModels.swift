import CryptoKit
import Foundation

/// Authoritative source family for Go documentation chunks (FR-4, FR-8, Issue #27).
public enum DocsSourceKind: String, Sendable, Hashable, Codable, CaseIterable {
    case spec
    case guide
    case stdlib
    case release
    case dependency

    public var displayName: String {
        switch self {
        case .spec: return "Go Language Specification"
        case .guide: return "Effective Go / Official Guide"
        case .stdlib: return "Go Standard Library"
        case .release: return "Go Release Notes"
        case .dependency: return "Dependency Package"
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
    case example
    case guide
    case releaseNote = "release_note"
}

/// Provenance distinguishing official extracted GoDoc, official GOROOT Example tests,
/// official `golang/website` snapshots, and og's bundled curated summaries (R-9, Issue #25, #26).
public enum DocsProvenance: String, Sendable, Hashable, Codable {
    case officialExtracted = "official_extracted"
    case officialExample = "official_example"
    case officialWebsiteSnapshot = "official_website_snapshot"
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
    /// For `.dependency` chunks: Go module path (e.g. `"github.com/go-chi/chi/v5"`). `nil` for stdlib/spec/guide/release (Issue #27).
    public var modulePath: String?
    /// For `.dependency` chunks: exact module version from `go.mod` / `go.work` (e.g. `"v5.1.0"`). `nil` for stdlib (Issue #27).
    public var moduleVersion: String?
    /// For `.dependency` chunks: optional concise SPDX-style license identifier (e.g. `"MIT"`, `"Apache-2.0"`), detected from module root (DES-DEP-4).
    public var license: String?
    /// For `.officialWebsiteSnapshot` chunks: canonical official URL (e.g. `"https://go.dev/doc/effective_go#defer"`) (Issue #26, DOC-14a).
    public var sourceURL: String?
    /// For `.officialWebsiteSnapshot` chunks: ISO-8601 snapshot date (`YYYY-MM-DD`) of the ingested `golang/website` checkout (Issue #26, DOC-14a).
    public var snapshotDate: String?

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
        searchAliases: [String] = [],
        modulePath: String? = nil,
        moduleVersion: String? = nil,
        license: String? = nil,
        sourceURL: String? = nil,
        snapshotDate: String? = nil
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
        self.modulePath = modulePath
        self.moduleVersion = moduleVersion
        self.license = license
        self.sourceURL = sourceURL
        self.snapshotDate = snapshotDate
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
        storedContentHash: String,
        modulePath: String? = nil,
        moduleVersion: String? = nil,
        license: String? = nil,
        sourceURL: String? = nil,
        snapshotDate: String? = nil
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
        self.modulePath = modulePath
        self.moduleVersion = moduleVersion
        self.license = license
        self.sourceURL = sourceURL
        self.snapshotDate = snapshotDate
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

    /// Human-readable citation label (FR-13 / G-4, R-9, Issue #25, #26: clearly marks official examples,
    /// `golang/website` snapshot provenance with URL & snapshot date, and bundled curated summaries).
    public var citationLabel: String {
        if provenance == .officialWebsiteSnapshot {
            let urlPart = (sourceURL.map { !$0.isEmpty } == true) ? " (\((sourceURL ?? "")))" : ""
            let snapPart = (snapshotDate.map { !$0.isEmpty } == true)
                ? " [golang/website snapshot \(snapshotDate!)]"
                : " [golang/website snapshot]"
            return "\(title)\(urlPart)\(snapPart)"
        }
        let sourceLabel: String
        switch provenance {
        case .bundledCurated:
            sourceLabel = "\(source.displayName) [og bundled summary]"
        case .officialExample:
            sourceLabel = "\(source.displayName) [公式サンプル]"
        case .officialExtracted, .officialWebsiteSnapshot:
            sourceLabel = source.displayName
        }
        switch source {
        case .stdlib:
            if provenance == .officialExample {
                let target = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
                let exampleFn = anchor.split(separator: ".").last.map(String.init) ?? ""
                if !exampleFn.isEmpty && exampleFn != symbol {
                    return "\(sourceLabel): \(target) (\(exampleFn))"
                }
                return "\(sourceLabel): \(target)"
            }
            let sym = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
            return "\(sourceLabel): \(sym)"
        case .spec, .guide, .release:
            let suffix = anchor.isEmpty ? title : "\(title) (\(anchor))"
            return "\(sourceLabel): \(suffix)"
        case .dependency:
            let modHeader: String
            if let mp = modulePath, let mv = moduleVersion, !mp.isEmpty, !mv.isEmpty {
                modHeader = "\(mp)@\(mv)"
            } else {
                modHeader = source.displayName
            }
            let licTag = (license.map { !$0.isEmpty } == true) ? " [\(license!)]" : ""
            if provenance == .officialExample {
                let target = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
                let exampleFn = anchor.split(separator: ".").last.map(String.init) ?? ""
                if !exampleFn.isEmpty && exampleFn != symbol {
                    return "\(modHeader) [Example]\(licTag): \(target) (\(exampleFn))"
                }
                return "\(modHeader) [Example]\(licTag): \(target)"
            }
            let sym = symbol.isEmpty ? packageName : "\(packageName).\(symbol)"
            return "\(modHeader)\(licTag): \(sym)"
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

/// Metadata stored alongside a module-unit dependency documentation pack (Issue #27, DES-DEP-1, DES-DEP-4).
public struct DocsDependencyPackManifest: Sendable, Hashable, Codable {
    public var modulePath: String
    public var moduleVersion: String
    /// Resolved local directory path for local `replace` directives, or `nil` for GOMODCACHE packs.
    public var localSourcePath: String?
    public var storageKey: String
    public var createdAt: String
    /// Concise SPDX-style license identifier (e.g. `"MIT"`, `"Apache-2.0"`), or `nil` when undetected.
    public var license: String?
    public var chunkCount: Int
    public var status: DocsPackStatus
    public var embeddingModelID: String?
    public var embeddingModelVersion: String?
    public var sizeBytes: Int64
    /// True if extraction hit a safety budget (file/byte/chunk/time limit) and produced a partial index (N-1).
    public var truncated: Bool
    /// Human-readable reason when `truncated == true` (e.g. `"chunk limit (4000)"`).
    public var truncationReason: String?

    public var key: GoModuleKey {
        GoModuleKey(modulePath: modulePath, version: moduleVersion, localSourcePath: localSourcePath)
    }

    public init(
        modulePath: String,
        moduleVersion: String,
        localSourcePath: String? = nil,
        storageKey: String? = nil,
        createdAt: String,
        license: String? = nil,
        chunkCount: Int,
        status: DocsPackStatus,
        embeddingModelID: String? = nil,
        embeddingModelVersion: String? = nil,
        sizeBytes: Int64 = 0,
        truncated: Bool = false,
        truncationReason: String? = nil
    ) {
        self.modulePath = modulePath
        self.moduleVersion = moduleVersion
        self.localSourcePath = localSourcePath
        self.storageKey = storageKey ?? GoModuleKey(
            modulePath: modulePath,
            version: moduleVersion,
            localSourcePath: localSourcePath
        ).storageKey
        self.createdAt = createdAt
        self.license = license
        self.chunkCount = chunkCount
        self.status = status
        self.embeddingModelID = embeddingModelID
        self.embeddingModelVersion = embeddingModelVersion
        self.sizeBytes = sizeBytes
        self.truncated = truncated
        self.truncationReason = truncationReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modulePath = try c.decode(String.self, forKey: .modulePath)
        moduleVersion = try c.decode(String.self, forKey: .moduleVersion)
        localSourcePath = try c.decodeIfPresent(String.self, forKey: .localSourcePath)
        storageKey = try c.decodeIfPresent(String.self, forKey: .storageKey)
            ?? GoModuleKey(modulePath: modulePath, version: moduleVersion, localSourcePath: localSourcePath).storageKey
        createdAt = try c.decode(String.self, forKey: .createdAt)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        status = try c.decode(DocsPackStatus.self, forKey: .status)
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
        embeddingModelVersion = try c.decodeIfPresent(String.self, forKey: .embeddingModelVersion)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        truncationReason = try c.decodeIfPresent(String.self, forKey: .truncationReason)
    }
}

/// Metadata stored alongside the version-independent `golang/website` snapshot pack (Issue #26, DOC-14a, DES-WEB-1).
public struct DocsWebsitePackManifest: Sendable, Hashable, Codable {
    public static let defaultSourceRepository = "https://github.com/golang/website"

    public var sourceRepository: String
    /// ISO-8601 snapshot date (`YYYY-MM-DD`) of the ingested `golang/website` checkout.
    public var snapshotDate: String
    /// Optional git commit SHA / tag of the ingested `golang/website` checkout.
    public var snapshotCommit: String?
    public var createdAt: String
    public var license: String
    public var chunkCount: Int
    public var status: DocsPackStatus
    public var embeddingModelID: String?
    public var embeddingModelVersion: String?
    public var sizeBytes: Int64
    public var includedCategories: [String]

    public init(
        sourceRepository: String = DocsWebsitePackManifest.defaultSourceRepository,
        snapshotDate: String,
        snapshotCommit: String? = nil,
        createdAt: String,
        license: String = DocsLicense.goBSD3Clause,
        chunkCount: Int,
        status: DocsPackStatus,
        embeddingModelID: String? = nil,
        embeddingModelVersion: String? = nil,
        sizeBytes: Int64 = 0,
        includedCategories: [String] = []
    ) {
        self.sourceRepository = sourceRepository
        self.snapshotDate = snapshotDate
        self.snapshotCommit = snapshotCommit
        self.createdAt = createdAt
        self.license = license
        self.chunkCount = chunkCount
        self.status = status
        self.embeddingModelID = embeddingModelID
        self.embeddingModelVersion = embeddingModelVersion
        self.sizeBytes = sizeBytes
        self.includedCategories = includedCategories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceRepository = try c.decodeIfPresent(String.self, forKey: .sourceRepository) ?? Self.defaultSourceRepository
        snapshotDate = try c.decode(String.self, forKey: .snapshotDate)
        snapshotCommit = try c.decodeIfPresent(String.self, forKey: .snapshotCommit)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? DocsLicense.goBSD3Clause
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        status = try c.decode(DocsPackStatus.self, forKey: .status)
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
        embeddingModelVersion = try c.decodeIfPresent(String.self, forKey: .embeddingModelVersion)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        includedCategories = try c.decodeIfPresent([String].self, forKey: .includedCategories) ?? []
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

/// BSD-3-Clause license text for redistributed Go documentation excerpts (GOROOT & golang/website, Q-4, Issue #26).
public enum DocsLicense {
    public static let goBSD3Clause = """
    Go Documentation & Website Excerpts (golang/go, golang/website) — BSD-3-Clause License
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
