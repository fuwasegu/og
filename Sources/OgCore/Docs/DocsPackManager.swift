import Foundation

/// Background batch scheduling policy configurable in Settings (FR-24).
public enum DocsBatchRunPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    case anytime
    case idleOnly
    case powerConnectedOnly

    public var title: String {
        switch self {
        case .anytime: return "Run in background (low priority)"
        case .idleOnly: return "Only when idle"
        case .powerConnectedOnly: return "Only on AC power"
        }
    }
}

/// Phase of a staged pack ingestion batch (FR-22, FR-23, `spec/design/research.fsl`).
public enum DocsBatchPhase: String, Sendable, Hashable, Codable {
    case idle
    case extracting
    case buildingFTS
    case embedding
    case activating
    case completed
    case cancelled
    case failed
}

/// Live progress snapshot reported to Setup Assistant and Settings (FR-23, FR-29).
public struct DocsBatchProgress: Sendable, Hashable {
    public var goVersion: String
    public var phase: DocsBatchPhase
    public var processedChunks: Int
    public var totalChunks: Int
    public var reusedVectors: Int
    public var computedVectors: Int
    public var estimatedBytes: Int64
    public var errorMessage: String?

    public init(
        goVersion: String,
        phase: DocsBatchPhase,
        processedChunks: Int = 0,
        totalChunks: Int = 0,
        reusedVectors: Int = 0,
        computedVectors: Int = 0,
        estimatedBytes: Int64 = 0,
        errorMessage: String? = nil
    ) {
        self.goVersion = goVersion
        self.phase = phase
        self.processedChunks = processedChunks
        self.totalChunks = totalChunks
        self.reusedVectors = reusedVectors
        self.computedVectors = computedVectors
        self.estimatedBytes = estimatedBytes
        self.errorMessage = errorMessage
    }

    public var fractionCompleted: Double {
        guard totalChunks > 0 else { return phase == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(processedChunks) / Double(totalChunks)))
    }
}

/// Pre-flight batch estimate shown before ingestion starts (FR-29).
/// Does not fabricate time estimates unless measured throughput is supplied.
public struct DocsBatchEstimate: Sendable, Hashable {
    public var chunkCount: Int
    public var estimatedBytes: Int64
    public var measuredEstimatedSeconds: Double?

    public init(chunkCount: Int, estimatedBytes: Int64, measuredEstimatedSeconds: Double? = nil) {
        self.chunkCount = chunkCount
        self.estimatedBytes = estimatedBytes
        self.measuredEstimatedSeconds = measuredEstimatedSeconds
    }
}

/// Result summary of a pack ingestion run.
public struct DocsIngestionReport: Sendable, Hashable {
    public var goVersion: String
    public var status: DocsPackStatus
    public var totalChunks: Int
    public var addedChunks: Int
    public var changedChunks: Int
    public var removedChunks: Int
    public var unchangedChunks: Int
    public var reusedVectors: Int
    public var computedVectors: Int
    public var cancelled: Bool

    public init(
        goVersion: String,
        status: DocsPackStatus,
        totalChunks: Int,
        addedChunks: Int,
        changedChunks: Int,
        removedChunks: Int,
        unchangedChunks: Int,
        reusedVectors: Int,
        computedVectors: Int,
        cancelled: Bool
    ) {
        self.goVersion = goVersion
        self.status = status
        self.totalChunks = totalChunks
        self.addedChunks = addedChunks
        self.changedChunks = changedChunks
        self.removedChunks = removedChunks
        self.unchangedChunks = unchangedChunks
        self.reusedVectors = reusedVectors
        self.computedVectors = computedVectors
        self.cancelled = cancelled
    }
}

/// Result of migrating legacy installed documentation packs to the current schema (T-1, T-2).
public struct DocsMigrationReport: Sendable, Hashable {
    public var migratedVersions: [String]
    public var failedVersions: [String: String]
    public var legacyV1ReimportVersions: [String]

    public init(
        migratedVersions: [String] = [],
        failedVersions: [String: String] = [:],
        legacyV1ReimportVersions: [String] = []
    ) {
        self.migratedVersions = migratedVersions
        self.failedVersions = failedVersions
        self.legacyV1ReimportVersions = legacyV1ReimportVersions
    }
}

/// Result of synchronizing a project's `go.mod`/`go.work` dependencies from local `GOMODCACHE` (Issue #27, DOC-12).
public struct DocsDependencySyncReport: Sendable, Hashable {
    public var synced: [GoModuleKey]
    public var skippedUpToDate: [GoModuleKey]
    public var uncached: [GoModuleKey]
    /// Modules whose extraction hit safety budgets (`DocsModuleExtractionLimits`) and were partially indexed (N-1).
    public var truncatedModules: [String: String]
    public var failed: [String: String]
    public var cancelled: Bool

    public init(
        synced: [GoModuleKey] = [],
        skippedUpToDate: [GoModuleKey] = [],
        uncached: [GoModuleKey] = [],
        truncatedModules: [String: String] = [:],
        failed: [String: String] = [:],
        cancelled: Bool = false
    ) {
        self.synced = synced
        self.skippedUpToDate = skippedUpToDate
        self.uncached = uncached
        self.truncatedModules = truncatedModules
        self.failed = failed
        self.cancelled = cancelled
    }
}

/// Persisted manager-level settings (M-15: selected embedding model survives restarts).
private struct DocsManagerSettings: Codable {
    var selectedEmbeddingModel: EmbeddingModelDescriptor?
}

/// Manages versioned Go documentation packs, staged atomic activation, resumable & incremental
/// ingestion batches, and the shared vector store (FR-5, FR-6, FR-20, FR-22..31, H-8, H-9, M-7, M-9, M-15, M-16).
public actor DocsPackManager {
    public let rootDirectory: URL
    public let sharedVectorStore: SharedVectorStore

    /// H-8: per-version in-flight guard preventing concurrent re-entrant ingests on the same staging DB.
    private var inFlightVersions: Set<String> = []
    private var cancelRequested: [String: Bool] = [:]
    /// R-8: marks versions deleted while an ingest was in-flight so staging & orphan vectors are reclaimed on exit.
    private var deletedWhileInFlight: Set<String> = []
    /// H-9: vector keys pinned by currently running batches so concurrent GC never deletes them.
    private var pinnedVectorKeys: [String: Set<SharedVectorKey>] = [:]
    private var latestProgress: [String: DocsBatchProgress] = [:]
    private var selectedEmbeddingModel: EmbeddingModelDescriptor?
    /// T-3: surfaces JSON parse/read errors from `concept_rules.json` instead of silently ignoring typos.
    private var lastConceptRulesError: String?

    public static var defaultRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("og/docs-packs", isDirectory: true)
    }

    public init(rootDirectory: URL = DocsPackManager.defaultRootDirectory) throws {
        self.rootDirectory = rootDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("packs", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("packs/deps", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("staging", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("staging/deps", isDirectory: true), withIntermediateDirectories: true)
        let storeURL = rootDirectory.appendingPathComponent("shared_vectors.sqlite")
        self.sharedVectorStore = try SharedVectorStore(databaseURL: storeURL)
        // M-15: load persisted selected embedding model
        let settingsURL = rootDirectory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(DocsManagerSettings.self, from: data) {
            self.selectedEmbeddingModel = decoded.selectedEmbeddingModel
        }
    }

    // MARK: - Paths

    public func packDirectory(for goVersion: String) -> URL {
        rootDirectory.appendingPathComponent("packs/go\(goVersion)", isDirectory: true)
    }

    public func stagingDirectory(for goVersion: String) -> URL {
        rootDirectory.appendingPathComponent("staging/go\(goVersion)", isDirectory: true)
    }

    public func indexURL(for goVersion: String) -> URL {
        packDirectory(for: goVersion).appendingPathComponent("index.sqlite")
    }

    public func dependencyPackDirectory(for key: GoModuleKey) -> URL {
        rootDirectory.appendingPathComponent("packs/deps/\(key.storageKey)", isDirectory: true)
    }

    public func dependencyStagingDirectory(for key: GoModuleKey) -> URL {
        rootDirectory.appendingPathComponent("staging/deps/\(key.storageKey)", isDirectory: true)
    }

    public func dependencyIndexURL(for key: GoModuleKey) -> URL {
        dependencyPackDirectory(for: key).appendingPathComponent("index.sqlite")
    }

    public func websitePackDirectory() -> URL {
        rootDirectory.appendingPathComponent("packs/website", isDirectory: true)
    }

    public func websiteStagingDirectory() -> URL {
        rootDirectory.appendingPathComponent("staging/website", isDirectory: true)
    }

    public func websiteIndexURL() -> URL {
        websitePackDirectory().appendingPathComponent("index.sqlite")
    }

    private static let websiteBatchKey = "website"

    /// Global user/app-extensible concept rules JSON path (S-3).
    public func conceptRulesURL() -> URL {
        rootDirectory.appendingPathComponent("concept_rules.json")
    }

    /// Per-pack optional concept rules JSON path (S-3).
    public func packConceptRulesURL(for goVersion: String) -> URL {
        packDirectory(for: goVersion).appendingPathComponent("concept_rules.json")
    }

    /// Loads data-driven Phase 1 concept rules: bundled defaults + global `concept_rules.json` + optional per-pack `concept_rules.json` (R-1, S-3, T-3).
    /// Records any JSON decode/read error in `conceptRulesLoadError()` instead of silently ignoring typos.
    public func loadConceptRules(forGoVersion goVersion: String? = nil) -> [DocsConceptRule] {
        var rules = BundledGoCorpus.defaultConceptRules
        var errors: [String] = []

        let globalResult = Self.decodeConceptRules(at: conceptRulesURL())
        rules.append(contentsOf: globalResult.rules)
        if let err = globalResult.error { errors.append(err) }

        if let goVersion {
            let packResult = Self.decodeConceptRules(at: packConceptRulesURL(for: goVersion))
            rules.append(contentsOf: packResult.rules)
            if let err = packResult.error { errors.append(err) }
        }

        lastConceptRulesError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        return rules
    }

    /// Loads only the per-pack custom concept rules, if any (S-3, T-3).
    public func loadPackConceptRules(forGoVersion goVersion: String) -> [DocsConceptRule] {
        let result = Self.decodeConceptRules(at: packConceptRulesURL(for: goVersion))
        if let err = result.error {
            lastConceptRulesError = err
        }
        return result.rules
    }

    /// Most recent read/JSON decode error from `concept_rules.json`, or `nil` when valid/absent (T-3).
    public func conceptRulesLoadError() -> String? {
        lastConceptRulesError
    }

    /// Persists custom global concept rules to `concept_rules.json` so rules can be extended without code changes (S-3).
    public func saveCustomConceptRules(_ rules: [DocsConceptRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: conceptRulesURL(), options: .atomic)
        lastConceptRulesError = nil
    }

    private static func decodeConceptRules(at url: URL) -> (rules: [DocsConceptRule], error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DocsConceptRule].self, from: data)
            return (decoded, nil)
        } catch {
            return ([], "Failed to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func manifestURL(in dir: URL) -> URL {
        dir.appendingPathComponent("manifest.json")
    }

    private func settingsURL() -> URL {
        rootDirectory.appendingPathComponent("settings.json")
    }

    private func persistSettings() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(DocsManagerSettings(selectedEmbeddingModel: selectedEmbeddingModel))
        try data.write(to: settingsURL(), options: .atomic)
    }

    // MARK: - Pack inventory & lifecycle (FR-20, FR-27, M-15)

    public func installedPacks() -> [DocsPackManifest] {
        let packsDir = rootDirectory.appendingPathComponent("packs", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: packsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var manifests: [DocsPackManifest] = []
        let decoder = JSONDecoder()
        for dir in entries where dir.lastPathComponent.hasPrefix("go") {
            let mURL = manifestURL(in: dir)
            guard let data = try? Data(contentsOf: mURL),
                  var manifest = try? decoder.decode(DocsPackManifest.self, from: data) else { continue }
            manifest.sizeBytes = Self.directorySizeBytes(dir)
            manifests.append(manifest)
        }
        manifests.sort { $0.goVersion > $1.goVersion }
        return manifests
    }

    public func manifest(for goVersion: String) -> DocsPackManifest? {
        let dir = packDirectory(for: goVersion)
        guard let data = try? Data(contentsOf: manifestURL(in: dir)),
              var m = try? JSONDecoder().decode(DocsPackManifest.self, from: data) else { return nil }
        m.sizeBytes = Self.directorySizeBytes(dir)
        return m
    }

    public func openIndex(for goVersion: String) throws -> DocsIndex? {
        let url = indexURL(for: goVersion)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try DocsIndex(databaseURL: url, readOnly: true)
    }

    // MARK: - Dependency Pack Inventory (Issue #27, DES-DEP-1)

    public func installedDependencyPacks() -> [DocsDependencyPackManifest] {
        let depsDir = rootDirectory.appendingPathComponent("packs/deps", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: depsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var manifests: [DocsDependencyPackManifest] = []
        let decoder = JSONDecoder()
        for dir in entries {
            let mURL = manifestURL(in: dir)
            guard let data = try? Data(contentsOf: mURL),
                  var manifest = try? decoder.decode(DocsDependencyPackManifest.self, from: data) else { continue }
            manifest.sizeBytes = Self.directorySizeBytes(dir)
            manifests.append(manifest)
        }
        manifests.sort { $0.key < $1.key }
        return manifests
    }

    public func dependencyManifest(for key: GoModuleKey) -> DocsDependencyPackManifest? {
        let dir = dependencyPackDirectory(for: key)
        guard let data = try? Data(contentsOf: manifestURL(in: dir)),
              var m = try? JSONDecoder().decode(DocsDependencyPackManifest.self, from: data) else { return nil }
        // Strict verification: manifest modulePath, moduleVersion, and localSourcePath must match requested key exactly.
        guard m.modulePath == key.modulePath
            && m.moduleVersion == key.version
            && m.localSourcePath == key.localSourcePath else { return nil }
        m.sizeBytes = Self.directorySizeBytes(dir)
        return m
    }

    public func openDependencyIndex(for key: GoModuleKey) throws -> DocsIndex? {
        guard dependencyManifest(for: key) != nil else { return nil }
        let url = dependencyIndexURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try DocsIndex(databaseURL: url, readOnly: true)
    }

    public func requestCancelDependency(key: GoModuleKey) {
        cancelRequested[Self.depBatchKey(for: key)] = true
    }

    @discardableResult
    public func deleteDependencyPack(key: GoModuleKey) async throws -> Int {
        let batchKey = Self.depBatchKey(for: key)
        cancelRequested[batchKey] = true
        let fm = FileManager.default
        let packDir = dependencyPackDirectory(for: key)
        if fm.fileExists(atPath: packDir.path) {
            try fm.removeItem(at: packDir)
        }
        let stageDir = dependencyStagingDirectory(for: key)
        if inFlightVersions.contains(batchKey) {
            deletedWhileInFlight.insert(batchKey)
        } else if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        latestProgress.removeValue(forKey: batchKey)
        return try await garbageCollectSharedVectors()
    }

    private static func depBatchKey(for key: GoModuleKey) -> String {
        "dep:\(key.storageKey)"
    }

    // MARK: - Website Snapshot Pack Inventory (Issue #26, DOC-14a, DES-WEB-1)

    public func websiteManifest() -> DocsWebsitePackManifest? {
        let dir = websitePackDirectory()
        guard let data = try? Data(contentsOf: manifestURL(in: dir)),
              var m = try? JSONDecoder().decode(DocsWebsitePackManifest.self, from: data) else { return nil }
        m.sizeBytes = Self.directorySizeBytes(dir)
        return m
    }

    public func openWebsiteIndex() throws -> DocsIndex? {
        guard websiteManifest() != nil else { return nil }
        let url = websiteIndexURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try DocsIndex(databaseURL: url, readOnly: true)
    }

    public func requestCancelWebsite() {
        cancelRequested[Self.websiteBatchKey] = true
    }

    @discardableResult
    public func deleteWebsitePack() async throws -> Int {
        let batchKey = Self.websiteBatchKey
        cancelRequested[batchKey] = true
        let fm = FileManager.default
        let packDir = websitePackDirectory()
        if fm.fileExists(atPath: packDir.path) {
            try fm.removeItem(at: packDir)
        }
        let stageDir = websiteStagingDirectory()
        if inFlightVersions.contains(batchKey) {
            deletedWhileInFlight.insert(batchKey)
        } else if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        latestProgress.removeValue(forKey: batchKey)
        return try await garbageCollectSharedVectors()
    }

    /// Migrates existing v2 installed packs (including GOROOT-imported packs) in place to schema v3 (S-1, T-1, T-2):
    /// - v2 packs (`schemaVersion == 2`): adds missing `provenance` column, accurately tags bundled complement chunks
    ///   with `.bundledCurated` while preserving `.officialExtracted` on real GOROOT chunks, checkpoints WAL, closes DB
    ///   immediately per pack, and bumps `manifest.schemaVersion` to v3.
    /// - v1 packs (`schemaVersion < 2`): left unbumped and reported in `legacyV1ReimportVersions` because v1 predates
    ///   `document_id` and current `contentHash` inputs and requires rebuild/re-import rather than in-place hash matching (T-1).
    /// - Per-pack errors are isolated in `failedVersions` so one corrupt pack never blocks migration of other packs (T-2).
    @discardableResult
    public func migrateLegacyPacksIfNeeded() -> DocsMigrationReport {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var report = DocsMigrationReport()

        for var pack in installedPacks() {
            guard pack.schemaVersion < DocsPackManifest.currentSchemaVersion else { continue }
            guard !inFlightVersions.contains(pack.goVersion) else { continue }

            // T-1: v1 packs cannot be reliably reclassified by v2/v3 hashes; leave schemaVersion < 2 so they trigger rebuild/re-import.
            if pack.needsReimport {
                report.legacyV1ReimportVersions.append(pack.goVersion)
                continue
            }

            let dir = packDirectory(for: pack.goVersion)
            let dbURL = dir.appendingPathComponent("index.sqlite")
            guard fm.fileExists(atPath: dbURL.path) else { continue }

            // T-2: isolate per-pack errors and close each SQLite handle immediately before moving to the next pack.
            do {
                let bundled = BundledGoCorpus.chunks(forGoVersion: pack.goVersion)
                let bundledHashes = Set(bundled.map(\.contentHash))
                let bundledNonStdlibIDs = Set(bundled.filter { $0.source != .stdlib }.map(\.stableID))

                try {
                    let idx = try DocsIndex(databaseURL: dbURL, readOnly: false)
                    defer { idx.close() }
                    _ = try idx.migrateBundledProvenance(
                        bundledContentHashes: bundledHashes,
                        bundledNonStdlibStableIDs: bundledNonStdlibIDs
                    )
                    try idx.checkpointWAL()
                }()

                pack.schemaVersion = DocsPackManifest.currentSchemaVersion
                pack.sizeBytes = Self.directorySizeBytes(dir)
                try encoder.encode(pack).write(to: manifestURL(in: dir), options: .atomic)
                report.migratedVersions.append(pack.goVersion)
            } catch {
                report.failedVersions[pack.goVersion] = error.localizedDescription
            }
        }
        return report
    }

    /// Ensures the bundled default Go documentation pack is installed (and migrated if schema changed) offline (Q-1).
    @discardableResult
    public func ensureBundledPackInstalled(
        goVersion: String = BundledGoCorpus.defaultVersion
    ) async throws -> DocsPackManifest {
        _ = migrateLegacyPacksIfNeeded()
        if let existing = manifest(for: goVersion),
           existing.schemaVersion >= DocsPackManifest.currentSchemaVersion {
            return existing
        }
        let chunks = BundledGoCorpus.chunks(forGoVersion: goVersion)
        _ = try await ingest(goVersion: goVersion, chunks: chunks, embedder: nil)
        guard let installed = manifest(for: goVersion) else {
            throw DocsStorageError.io("bundled pack manifest missing after ingestion")
        }
        return installed
    }

    /// Deletes an installed pack and reclaims unreferenced vectors while preserving other staging/in-flight vectors (FR-20, FR-30, H-8, H-9, R-8).
    @discardableResult
    public func deletePack(goVersion: String) async throws -> Int {
        cancelRequested[goVersion] = true
        let fm = FileManager.default
        let packDir = packDirectory(for: goVersion)
        if fm.fileExists(atPath: packDir.path) {
            try fm.removeItem(at: packDir)
        }
        let stageDir = stagingDirectory(for: goVersion)
        if inFlightVersions.contains(goVersion) {
            // R-8: defer staging removal & GC to the in-flight ingest's cancellation exit so no orphan staging leaks.
            deletedWhileInFlight.insert(goVersion)
        } else if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        latestProgress.removeValue(forKey: goVersion)
        return try await garbageCollectSharedVectors()
    }

    /// Switches the active embedding model and persists it (FR-27 / DOC-4, M-15).
    /// Invalidates all incompatible packs (demotes to FTS-only, clears manifest model metadata and pack vector refs,
    /// and discards incompatible staging checkpoints) so vectors from distinct models are never mixed even after restart.
    @discardableResult
    public func selectEmbeddingModel(_ model: EmbeddingModelDescriptor?) throws -> Bool {
        let changed = selectedEmbeddingModel != model
        selectedEmbeddingModel = model
        try persistSettings()
        guard changed else { return false }

        var needsRebuild = false
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for var pack in installedPacks() {
            let matches = (pack.embeddingModelID == model?.id && pack.embeddingModelVersion == model?.version)
            if !matches && (pack.status == .ready || pack.embeddingModelID != nil) {
                needsRebuild = true
                pack.status = .indexingFTSOnly
                pack.embeddingModelID = nil
                pack.embeddingModelVersion = nil
                let dir = packDirectory(for: pack.goVersion)
                let dbURL = dir.appendingPathComponent("index.sqlite")
                if fm.fileExists(atPath: dbURL.path) {
                    let idx = try DocsIndex(databaseURL: dbURL, readOnly: false)
                    defer { idx.close() }
                    try idx.clearVectorReferences()
                    try idx.checkpointWAL()
                }
                let data = try encoder.encode(pack)
                try data.write(to: manifestURL(in: dir), options: .atomic)
            }
            // Discard incompatible staging checkpoints so resume never mixes models.
            if !inFlightVersions.contains(pack.goVersion) {
                let stage = stagingDirectory(for: pack.goVersion)
                if fm.fileExists(atPath: stage.path) {
                    try? fm.removeItem(at: stage)
                }
            }
        }

        // DOC-4 / ReadyDepPackMatchesModel: also demote incompatible dependency packs to FTS-only.
        for var depPack in installedDependencyPacks() {
            let matches = (depPack.embeddingModelID == model?.id && depPack.embeddingModelVersion == model?.version)
            if !matches && (depPack.status == .ready || depPack.embeddingModelID != nil) {
                needsRebuild = true
                depPack.status = .indexingFTSOnly
                depPack.embeddingModelID = nil
                depPack.embeddingModelVersion = nil
                let dir = dependencyPackDirectory(for: depPack.key)
                let dbURL = dir.appendingPathComponent("index.sqlite")
                if fm.fileExists(atPath: dbURL.path) {
                    let idx = try DocsIndex(databaseURL: dbURL, readOnly: false)
                    defer { idx.close() }
                    try idx.clearVectorReferences()
                    try idx.checkpointWAL()
                }
                let data = try encoder.encode(depPack)
                try data.write(to: manifestURL(in: dir), options: .atomic)
            }
            let batchKey = Self.depBatchKey(for: depPack.key)
            if !inFlightVersions.contains(batchKey) {
                let stage = dependencyStagingDirectory(for: depPack.key)
                if fm.fileExists(atPath: stage.path) {
                    try? fm.removeItem(at: stage)
                }
            }
        }

        // DOC-14c / ReadyWebsitePackMatchesModel: also demote incompatible website snapshot pack to FTS-only.
        if var webPack = websiteManifest() {
            let matches = (webPack.embeddingModelID == model?.id && webPack.embeddingModelVersion == model?.version)
            if !matches && (webPack.status == .ready || webPack.embeddingModelID != nil) {
                needsRebuild = true
                webPack.status = .indexingFTSOnly
                webPack.embeddingModelID = nil
                webPack.embeddingModelVersion = nil
                let dir = websitePackDirectory()
                let dbURL = dir.appendingPathComponent("index.sqlite")
                if fm.fileExists(atPath: dbURL.path) {
                    let idx = try DocsIndex(databaseURL: dbURL, readOnly: false)
                    defer { idx.close() }
                    try idx.clearVectorReferences()
                    try idx.checkpointWAL()
                }
                let data = try encoder.encode(webPack)
                try data.write(to: manifestURL(in: dir), options: .atomic)
            }
            if !inFlightVersions.contains(Self.websiteBatchKey) {
                let stage = websiteStagingDirectory()
                if fm.fileExists(atPath: stage.path) {
                    try? fm.removeItem(at: stage)
                }
            }
        }
        return needsRebuild
    }

    public func currentEmbeddingModel() -> EmbeddingModelDescriptor? {
        selectedEmbeddingModel
    }

    // MARK: - Batch Estimation & Control (FR-23, FR-29)

    /// Computes chunk count and disk estimate before starting a batch (FR-29).
    public static func estimateBatch(
        chunks: [DocsChunk],
        includesEmbeddings: Bool,
        measuredChunksPerSecond: Double? = nil
    ) -> DocsBatchEstimate {
        let textBytes = chunks.reduce(Int64(0)) { acc, c in
            acc + Int64(c.title.utf8.count + c.summary.utf8.count + c.body.utf8.count + (c.example?.utf8.count ?? 0))
        }
        let ftsBytes = Int64(Double(textBytes) * 2.2) + 32_768
        let vectorBytes = includesEmbeddings ? Int64(chunks.count) * 1600 : 0
        let secs: Double? = measuredChunksPerSecond.flatMap { rate in
            rate > 0 ? Double(chunks.count) / rate : nil
        }
        return DocsBatchEstimate(
            chunkCount: chunks.count,
            estimatedBytes: ftsBytes + vectorBytes,
            measuredEstimatedSeconds: secs
        )
    }

    public func requestCancel(goVersion: String) {
        cancelRequested[goVersion] = true
    }

    public func progress(for goVersion: String) -> DocsBatchProgress? {
        latestProgress[goVersion]
    }

    // MARK: - Staged, Resumable, Incremental Ingestion Batch (FR-6, FR-22..31, H-8, H-9, M-7, M-9, M-16)

    public func ingest(
        goVersion: String,
        chunks: [DocsChunk],
        embedder: (any DocsEmbedder)? = nil,
        simulateSwapFailure: Bool = false,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport {
        // H-8: reject concurrent re-entrant ingestion for the same Go version.
        guard !inFlightVersions.contains(goVersion) else {
            throw DocsStorageError.batchAlreadyRunning(goVersion)
        }
        inFlightVersions.insert(goVersion)
        cancelRequested[goVersion] = false
        deletedWhileInFlight.remove(goVersion)
        pinnedVectorKeys[goVersion] = []
        defer {
            inFlightVersions.remove(goVersion)
            pinnedVectorKeys.removeValue(forKey: goVersion)
            deletedWhileInFlight.remove(goVersion)
        }

        let estimate = Self.estimateBatch(chunks: chunks, includesEmbeddings: embedder != nil)
        let fm = FileManager.default
        let activeDir = packDirectory(for: goVersion)
        let stageDir = stagingDirectory(for: goVersion)
        let activeDBURL = indexURL(for: goVersion)
        let activeExists = fm.fileExists(atPath: activeDBURL.path)

        var processed = 0
        var reusedCount = 0
        var computedCount = 0

        func emit(_ phase: DocsBatchPhase, error: String? = nil) {
            let p = DocsBatchProgress(
                goVersion: goVersion,
                phase: phase,
                processedChunks: processed,
                totalChunks: chunks.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                estimatedBytes: estimate.estimatedBytes,
                errorMessage: error
            )
            latestProgress[goVersion] = p
            onProgress?(p)
        }

        var stageIndexHandle: DocsIndex?
        var stageClosed = false
        func closeStageIndex() {
            if !stageClosed {
                stageIndexHandle?.close()
                stageClosed = true
            }
        }

        do {
            emit(.extracting)

            // M-16: propagate errors when reading an existing active pack instead of silently assuming empty.
            var previousHashes: [String: String] = [:]
            var previousRefs: [String: SharedVectorKey] = [:]
            if activeExists {
                let activeIndex = try DocsIndex(databaseURL: activeDBURL, readOnly: true)
                defer { activeIndex.close() }
                previousHashes = try activeIndex.contentHashesByStableID()
                previousRefs = try activeIndex.vectorReferences()
            }
            let diff = DocsChunkDiff.compute(previous: previousHashes, next: chunks)
            let unchangedIDs = Set(diff.unchanged.map(\.stableID))
            let changedIDs = diff.changed.map(\.stableID)

            // Prepare staging directory (preserve existing staging DB for resume when present, FR-25).
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let stageDBURL = stageDir.appendingPathComponent("index.sqlite")
            let stageIndex = try DocsIndex(databaseURL: stageDBURL, readOnly: false)
            stageIndexHandle = stageIndex
            defer { closeStageIndex() }

            let stageRefs = try stageIndex.vectorReferences()

            emit(.buildingFTS)
            try stageIndex.replaceAllChunks(chunks)

            // M-9: drop vector references for both deleted AND changed chunks so stale vectors are never reused.
            try stageIndex.removeVectorReferences(forStableIDs: diff.removed + changedIDs)

            // Preserve compatible references ONLY for unchanged chunks (FR-25, FR-26, M-9).
            // R-8: never silently overwrite `selectedEmbeddingModel` here; `selectEmbeddingModel(_:)` owns that state.
            if let embedder {
                let model = embedder.descriptor
                for (stableID, ref) in previousRefs where unchangedIDs.contains(stableID) {
                    if ref.modelID == model.id && ref.modelVersion == model.version && stageRefs[stableID] == nil {
                        try stageIndex.recordVectorReference(stableID: stableID, key: ref)
                    }
                }
            } else {
                // FTS-only pack has no active embedding model; clear any stale refs (M-9).
                try stageIndex.clearVectorReferences()
            }

            // M-7: checkpoint WAL before copying the initial FTS-only snapshot!
            try stageIndex.checkpointWAL()

            if !activeExists && embedder != nil && !(Task.isCancelled || cancelRequested[goVersion] == true) {
                try publishInitialFTSOnlySnapshot(fromStageDB: stageDBURL, goVersion: goVersion, chunkCount: chunks.count)
            }

            var finalStatus: DocsPackStatus = .indexingFTSOnly

            if let embedder {
                let model = embedder.descriptor
                let completedRefs = try stageIndex.vectorReferences()
                let batchSize = max(1, embedder.preferredBatchSize)
                var pendingBatch: [(chunk: DocsChunk, key: SharedVectorKey)] = []
                pendingBatch.reserveCapacity(batchSize)

                for chunk in chunks {
                    if Task.isCancelled || cancelRequested[goVersion] == true {
                        try? stageIndex.checkpointWAL()
                        closeStageIndex()
                        await cleanupDeletedInFlightIfNeeded(goVersion: goVersion)
                        emit(.cancelled)
                        return DocsIngestionReport(
                            goVersion: goVersion,
                            status: manifest(for: goVersion)?.status ?? .indexingFTSOnly,
                            totalChunks: chunks.count,
                            addedChunks: diff.added.count,
                            changedChunks: diff.changed.count,
                            removedChunks: diff.removed.count,
                            unchangedChunks: diff.unchanged.count,
                            reusedVectors: reusedCount,
                            computedVectors: computedCount,
                            cancelled: true
                        )
                    }

                    let key = SharedVectorKey(contentHash: chunk.contentHash, model: model)
                    // H-9: pin key before any await so concurrent GC cannot delete it.
                    pinnedVectorKeys[goVersion, default: []].insert(key)

                    // FR-25: skip already checkpointed chunks with matching hash & model.
                    if let existingRef = completedRefs[chunk.stableID], existingRef == key,
                       (try await sharedVectorStore.contains(key)) {
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                        continue
                    }

                    // FR-30: reuse vector from SharedVectorStore if computed by another version or prior pack.
                    if try await sharedVectorStore.contains(key) {
                        try stageIndex.recordVectorReference(stableID: chunk.stableID, key: key)
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                    } else {
                        pendingBatch.append((chunk, key))
                        if pendingBatch.count >= batchSize {
                            let batch = pendingBatch
                            pendingBatch.removeAll(keepingCapacity: true)
                            let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                            for (item, vector) in zip(batch, vectors) {
                                try await sharedVectorStore.store(key: item.key, vector: vector)
                                try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                                computedCount += 1
                                processed += 1
                            }
                            emit(.embedding)
                        }
                    }
                }
                if !pendingBatch.isEmpty && !(Task.isCancelled || cancelRequested[goVersion] == true) {
                    let batch = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                    for (item, vector) in zip(batch, vectors) {
                        try await sharedVectorStore.store(key: item.key, vector: vector)
                        try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                        computedCount += 1
                        processed += 1
                    }
                    emit(.embedding)
                }
                finalStatus = .ready
            } else {
                processed = chunks.count
                finalStatus = .indexingFTSOnly
            }

            // H-8 & R-8: honor cancellation/deletePack before atomic activation (covers FTS-only path too).
            if Task.isCancelled || cancelRequested[goVersion] == true {
                try? stageIndex.checkpointWAL()
                closeStageIndex()
                await cleanupDeletedInFlightIfNeeded(goVersion: goVersion)
                emit(.cancelled)
                return DocsIngestionReport(
                    goVersion: goVersion,
                    status: manifest(for: goVersion)?.status ?? .indexingFTSOnly,
                    totalChunks: chunks.count,
                    addedChunks: diff.added.count,
                    changedChunks: diff.changed.count,
                    removedChunks: diff.removed.count,
                    unchangedChunks: diff.unchanged.count,
                    reusedVectors: reusedCount,
                    computedVectors: computedCount,
                    cancelled: true
                )
            }

            // M-7: flush WAL completely before closing & swapping.
            try stageIndex.checkpointWAL()
            closeStageIndex()

            emit(.activating)

            let manifest = DocsPackManifest(
                goVersion: goVersion,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                license: DocsLicense.goBSD3Clause,
                chunkCount: chunks.count,
                status: finalStatus,
                embeddingModelID: embedder?.descriptor.id,
                embeddingModelVersion: embedder?.descriptor.version,
                sizeBytes: Self.directorySizeBytes(stageDir)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL(in: stageDir), options: .atomic)

            if simulateSwapFailure {
                throw DocsStorageError.io("simulated atomic swap failure")
            }
            try Self.atomicReplaceDirectory(source: stageDir, destination: activeDir)

            emit(.completed)
            return DocsIngestionReport(
                goVersion: goVersion,
                status: finalStatus,
                totalChunks: chunks.count,
                addedChunks: diff.added.count,
                changedChunks: diff.changed.count,
                removedChunks: diff.removed.count,
                unchangedChunks: diff.unchanged.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                cancelled: false
            )
        } catch {
            // R-8: clean up staging & orphan vectors if deletePack raced with this error/cancellation.
            closeStageIndex()
            await cleanupDeletedInFlightIfNeeded(goVersion: goVersion)
            // M-16: always emit `.failed` on any ingestion error (embedder, SQLite, or swap).
            emit(.failed, error: error.localizedDescription)
            throw error
        }
    }

    /// Re-embeds an already-installed pack in place (preserving its extracted chunks) using `embedder` (FR-27, FR-30).
    /// Returns `nil` if no pack is installed for `goVersion`.
    public func reembedExistingPack(
        goVersion: String,
        embedder: any DocsEmbedder,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport? {
        guard let index = try openIndex(for: goVersion) else { return nil }
        let chunks: [DocsChunk]
        do {
            chunks = try index.allChunks()
        } catch {
            index.close()
            throw error
        }
        index.close()
        return try await ingest(goVersion: goVersion, chunks: chunks, embedder: embedder, onProgress: onProgress)
    }

    // MARK: - Staged, Resumable Website Snapshot Pack Ingestion (Issue #26, DOC-14c, DES-WEB-3)

    /// Ingests a version-independent `golang/website` snapshot pack into `packs/website/` with staged
    /// atomic activation, chunk-level pause/resume checkpoints, and shared vector store reuse.
    public func ingestWebsite(
        chunks: [DocsChunk],
        snapshotDate: String,
        snapshotCommit: String? = nil,
        sourceRepository: String = DocsWebsitePackManifest.defaultSourceRepository,
        includedCategories: [String] = [],
        embedder: (any DocsEmbedder)? = nil,
        simulateSwapFailure: Bool = false,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport {
        let batchKey = Self.websiteBatchKey
        guard !inFlightVersions.contains(batchKey) else {
            throw DocsStorageError.batchAlreadyRunning("golang/website")
        }
        inFlightVersions.insert(batchKey)
        cancelRequested[batchKey] = false
        deletedWhileInFlight.remove(batchKey)
        pinnedVectorKeys[batchKey] = []
        defer {
            inFlightVersions.remove(batchKey)
            pinnedVectorKeys.removeValue(forKey: batchKey)
            deletedWhileInFlight.remove(batchKey)
        }

        let estimate = Self.estimateBatch(chunks: chunks, includesEmbeddings: embedder != nil)
        let fm = FileManager.default
        let activeDir = websitePackDirectory()
        let stageDir = websiteStagingDirectory()
        let activeDBURL = websiteIndexURL()
        let activeExists = fm.fileExists(atPath: activeDBURL.path)

        var processed = 0
        var reusedCount = 0
        var computedCount = 0

        func emit(_ phase: DocsBatchPhase, error: String? = nil) {
            let p = DocsBatchProgress(
                goVersion: "golang/website (\(snapshotDate))",
                phase: phase,
                processedChunks: processed,
                totalChunks: chunks.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                estimatedBytes: estimate.estimatedBytes,
                errorMessage: error
            )
            latestProgress[batchKey] = p
            onProgress?(p)
        }

        var stageIndexHandle: DocsIndex?
        var stageClosed = false
        func closeStageIndex() {
            if !stageClosed {
                stageIndexHandle?.close()
                stageClosed = true
            }
        }

        do {
            emit(.extracting)

            var previousHashes: [String: String] = [:]
            var previousRefs: [String: SharedVectorKey] = [:]
            if activeExists {
                let activeIndex = try DocsIndex(databaseURL: activeDBURL, readOnly: true)
                defer { activeIndex.close() }
                previousHashes = try activeIndex.contentHashesByStableID()
                previousRefs = try activeIndex.vectorReferences()
            }
            let diff = DocsChunkDiff.compute(previous: previousHashes, next: chunks)
            let unchangedIDs = Set(diff.unchanged.map(\.stableID))
            let changedIDs = diff.changed.map(\.stableID)

            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let stageDBURL = stageDir.appendingPathComponent("index.sqlite")
            let stageIndex = try DocsIndex(databaseURL: stageDBURL, readOnly: false)
            stageIndexHandle = stageIndex
            defer { closeStageIndex() }

            let stageRefs = try stageIndex.vectorReferences()

            emit(.buildingFTS)
            try stageIndex.replaceAllChunks(chunks)
            try stageIndex.removeVectorReferences(forStableIDs: diff.removed + changedIDs)

            if let embedder {
                let model = embedder.descriptor
                for (stableID, ref) in previousRefs where unchangedIDs.contains(stableID) {
                    if ref.modelID == model.id && ref.modelVersion == model.version && stageRefs[stableID] == nil {
                        try stageIndex.recordVectorReference(stableID: stableID, key: ref)
                    }
                }
            } else {
                try stageIndex.clearVectorReferences()
            }

            try stageIndex.checkpointWAL()

            if !activeExists && embedder != nil && !(Task.isCancelled || cancelRequested[batchKey] == true) {
                try publishInitialWebsiteFTSOnlySnapshot(
                    fromStageDB: stageDBURL,
                    snapshotDate: snapshotDate,
                    snapshotCommit: snapshotCommit,
                    sourceRepository: sourceRepository,
                    includedCategories: includedCategories,
                    chunkCount: chunks.count
                )
            }

            var finalStatus: DocsPackStatus = .indexingFTSOnly

            if let embedder {
                let model = embedder.descriptor
                let completedRefs = try stageIndex.vectorReferences()
                let batchSize = max(1, embedder.preferredBatchSize)
                var pendingBatch: [(chunk: DocsChunk, key: SharedVectorKey)] = []
                pendingBatch.reserveCapacity(batchSize)

                for chunk in chunks {
                    if Task.isCancelled || cancelRequested[batchKey] == true {
                        try? stageIndex.checkpointWAL()
                        closeStageIndex()
                        await cleanupDeletedWebsiteInFlightIfNeeded()
                        emit(.cancelled)
                        return DocsIngestionReport(
                            goVersion: batchKey,
                            status: websiteManifest()?.status ?? .indexingFTSOnly,
                            totalChunks: chunks.count,
                            addedChunks: diff.added.count,
                            changedChunks: diff.changed.count,
                            removedChunks: diff.removed.count,
                            unchangedChunks: diff.unchanged.count,
                            reusedVectors: reusedCount,
                            computedVectors: computedCount,
                            cancelled: true
                        )
                    }

                    let vKey = SharedVectorKey(contentHash: chunk.contentHash, model: model)
                    pinnedVectorKeys[batchKey, default: []].insert(vKey)

                    if let existingRef = completedRefs[chunk.stableID], existingRef == vKey,
                       (try await sharedVectorStore.contains(vKey)) {
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                        continue
                    }

                    if try await sharedVectorStore.contains(vKey) {
                        try stageIndex.recordVectorReference(stableID: chunk.stableID, key: vKey)
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                    } else {
                        pendingBatch.append((chunk, vKey))
                        if pendingBatch.count >= batchSize {
                            let batch = pendingBatch
                            pendingBatch.removeAll(keepingCapacity: true)
                            let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                            for (item, vector) in zip(batch, vectors) {
                                try await sharedVectorStore.store(key: item.key, vector: vector)
                                try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                                computedCount += 1
                                processed += 1
                            }
                            emit(.embedding)
                        }
                    }
                }
                if !pendingBatch.isEmpty && !(Task.isCancelled || cancelRequested[batchKey] == true) {
                    let batch = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                    for (item, vector) in zip(batch, vectors) {
                        try await sharedVectorStore.store(key: item.key, vector: vector)
                        try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                        computedCount += 1
                        processed += 1
                    }
                    emit(.embedding)
                }
                finalStatus = .ready
            } else {
                processed = chunks.count
                finalStatus = .indexingFTSOnly
            }

            if Task.isCancelled || cancelRequested[batchKey] == true {
                try? stageIndex.checkpointWAL()
                closeStageIndex()
                await cleanupDeletedWebsiteInFlightIfNeeded()
                emit(.cancelled)
                return DocsIngestionReport(
                    goVersion: batchKey,
                    status: websiteManifest()?.status ?? .indexingFTSOnly,
                    totalChunks: chunks.count,
                    addedChunks: diff.added.count,
                    changedChunks: diff.changed.count,
                    removedChunks: diff.removed.count,
                    unchangedChunks: diff.unchanged.count,
                    reusedVectors: reusedCount,
                    computedVectors: computedCount,
                    cancelled: true
                )
            }

            try stageIndex.checkpointWAL()
            closeStageIndex()

            emit(.activating)

            let manifest = DocsWebsitePackManifest(
                sourceRepository: sourceRepository,
                snapshotDate: snapshotDate,
                snapshotCommit: snapshotCommit,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                license: DocsLicense.goBSD3Clause,
                chunkCount: chunks.count,
                status: finalStatus,
                embeddingModelID: embedder?.descriptor.id,
                embeddingModelVersion: embedder?.descriptor.version,
                sizeBytes: Self.directorySizeBytes(stageDir),
                includedCategories: includedCategories
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL(in: stageDir), options: .atomic)

            if simulateSwapFailure {
                throw DocsStorageError.io("simulated atomic swap failure")
            }
            try Self.atomicReplaceDirectory(source: stageDir, destination: activeDir)

            emit(.completed)
            return DocsIngestionReport(
                goVersion: batchKey,
                status: finalStatus,
                totalChunks: chunks.count,
                addedChunks: diff.added.count,
                changedChunks: diff.changed.count,
                removedChunks: diff.removed.count,
                unchangedChunks: diff.unchanged.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                cancelled: false
            )
        } catch {
            closeStageIndex()
            await cleanupDeletedWebsiteInFlightIfNeeded()
            emit(.failed, error: error.localizedDescription)
            throw error
        }
    }

    /// Re-embeds an already-installed website snapshot pack in place using `embedder` (DOC-14c).
    public func reembedWebsitePack(
        embedder: any DocsEmbedder,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport? {
        guard let existing = websiteManifest(),
              let index = try openWebsiteIndex() else { return nil }
        let chunks: [DocsChunk]
        do {
            chunks = try index.allChunks()
        } catch {
            index.close()
            throw error
        }
        index.close()
        return try await ingestWebsite(
            chunks: chunks,
            snapshotDate: existing.snapshotDate,
            snapshotCommit: existing.snapshotCommit,
            sourceRepository: existing.sourceRepository,
            includedCategories: existing.includedCategories,
            embedder: embedder,
            onProgress: onProgress
        )
    }

    // MARK: - Staged, Resumable Dependency Module Pack Ingestion (Issue #27, DES-DEP-1..4)

    /// Ingests a single `(modulePath, moduleVersion)` dependency pack with staged atomic activation,
    /// chunk-level pause/resume checkpoints, and shared vector reuse across versions.
    public func ingestDependency(
        modulePath: String,
        moduleVersion: String,
        localSourcePath: String? = nil,
        chunks: [DocsChunk],
        license: String? = nil,
        truncated: Bool = false,
        truncationReason: String? = nil,
        embedder: (any DocsEmbedder)? = nil,
        simulateSwapFailure: Bool = false,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport {
        let key = GoModuleKey(modulePath: modulePath, version: moduleVersion, localSourcePath: localSourcePath)
        let batchKey = Self.depBatchKey(for: key)
        guard !inFlightVersions.contains(batchKey) else {
            throw DocsStorageError.batchAlreadyRunning(key.displayID)
        }
        inFlightVersions.insert(batchKey)
        cancelRequested[batchKey] = false
        deletedWhileInFlight.remove(batchKey)
        pinnedVectorKeys[batchKey] = []
        defer {
            inFlightVersions.remove(batchKey)
            pinnedVectorKeys.removeValue(forKey: batchKey)
            deletedWhileInFlight.remove(batchKey)
        }

        let estimate = Self.estimateBatch(chunks: chunks, includesEmbeddings: embedder != nil)
        let fm = FileManager.default
        let activeDir = dependencyPackDirectory(for: key)
        let stageDir = dependencyStagingDirectory(for: key)
        let activeDBURL = dependencyIndexURL(for: key)
        let activeExists = fm.fileExists(atPath: activeDBURL.path)

        var processed = 0
        var reusedCount = 0
        var computedCount = 0

        func emit(_ phase: DocsBatchPhase, error: String? = nil) {
            let p = DocsBatchProgress(
                goVersion: key.displayID,
                phase: phase,
                processedChunks: processed,
                totalChunks: chunks.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                estimatedBytes: estimate.estimatedBytes,
                errorMessage: error
            )
            latestProgress[batchKey] = p
            onProgress?(p)
        }

        var stageIndexHandle: DocsIndex?
        var stageClosed = false
        func closeStageIndex() {
            if !stageClosed {
                stageIndexHandle?.close()
                stageClosed = true
            }
        }

        do {
            emit(.extracting)

            var previousHashes: [String: String] = [:]
            var previousRefs: [String: SharedVectorKey] = [:]
            if activeExists {
                let activeIndex = try DocsIndex(databaseURL: activeDBURL, readOnly: true)
                defer { activeIndex.close() }
                previousHashes = try activeIndex.contentHashesByStableID()
                previousRefs = try activeIndex.vectorReferences()
            }
            let diff = DocsChunkDiff.compute(previous: previousHashes, next: chunks)
            let unchangedIDs = Set(diff.unchanged.map(\.stableID))
            let changedIDs = diff.changed.map(\.stableID)

            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let stageDBURL = stageDir.appendingPathComponent("index.sqlite")
            let stageIndex = try DocsIndex(databaseURL: stageDBURL, readOnly: false)
            stageIndexHandle = stageIndex
            defer { closeStageIndex() }

            let stageRefs = try stageIndex.vectorReferences()

            emit(.buildingFTS)
            try stageIndex.replaceAllChunks(chunks)
            try stageIndex.removeVectorReferences(forStableIDs: diff.removed + changedIDs)

            if let embedder {
                let model = embedder.descriptor
                for (stableID, ref) in previousRefs where unchangedIDs.contains(stableID) {
                    if ref.modelID == model.id && ref.modelVersion == model.version && stageRefs[stableID] == nil {
                        try stageIndex.recordVectorReference(stableID: stableID, key: ref)
                    }
                }
            } else {
                try stageIndex.clearVectorReferences()
            }

            try stageIndex.checkpointWAL()

            if !activeExists && embedder != nil && !(Task.isCancelled || cancelRequested[batchKey] == true) {
                try publishInitialDependencyFTSOnlySnapshot(
                    fromStageDB: stageDBURL,
                    key: key,
                    license: license,
                    chunkCount: chunks.count
                )
            }

            var finalStatus: DocsPackStatus = .indexingFTSOnly

            if let embedder {
                let model = embedder.descriptor
                let completedRefs = try stageIndex.vectorReferences()
                let batchSize = max(1, embedder.preferredBatchSize)
                var pendingBatch: [(chunk: DocsChunk, key: SharedVectorKey)] = []
                pendingBatch.reserveCapacity(batchSize)

                for chunk in chunks {
                    if Task.isCancelled || cancelRequested[batchKey] == true {
                        try? stageIndex.checkpointWAL()
                        closeStageIndex()
                        await cleanupDeletedDependencyInFlightIfNeeded(key: key)
                        emit(.cancelled)
                        return DocsIngestionReport(
                            goVersion: key.displayID,
                            status: dependencyManifest(for: key)?.status ?? .indexingFTSOnly,
                            totalChunks: chunks.count,
                            addedChunks: diff.added.count,
                            changedChunks: diff.changed.count,
                            removedChunks: diff.removed.count,
                            unchangedChunks: diff.unchanged.count,
                            reusedVectors: reusedCount,
                            computedVectors: computedCount,
                            cancelled: true
                        )
                    }

                    let vKey = SharedVectorKey(contentHash: chunk.contentHash, model: model)
                    pinnedVectorKeys[batchKey, default: []].insert(vKey)

                    if let existingRef = completedRefs[chunk.stableID], existingRef == vKey,
                       (try await sharedVectorStore.contains(vKey)) {
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                        continue
                    }

                    if try await sharedVectorStore.contains(vKey) {
                        try stageIndex.recordVectorReference(stableID: chunk.stableID, key: vKey)
                        reusedCount += 1
                        processed += 1
                        emit(.embedding)
                    } else {
                        pendingBatch.append((chunk, vKey))
                        if pendingBatch.count >= batchSize {
                            let batch = pendingBatch
                            pendingBatch.removeAll(keepingCapacity: true)
                            let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                            for (item, vector) in zip(batch, vectors) {
                                try await sharedVectorStore.store(key: item.key, vector: vector)
                                try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                                computedCount += 1
                                processed += 1
                            }
                            emit(.embedding)
                        }
                    }
                }
                if !pendingBatch.isEmpty && !(Task.isCancelled || cancelRequested[batchKey] == true) {
                    let batch = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    let vectors = try await computeBatchVectors(batch.map(\.chunk.embeddingText), with: embedder)
                    for (item, vector) in zip(batch, vectors) {
                        try await sharedVectorStore.store(key: item.key, vector: vector)
                        try stageIndex.recordVectorReference(stableID: item.chunk.stableID, key: item.key)
                        computedCount += 1
                        processed += 1
                    }
                    emit(.embedding)
                }
                finalStatus = .ready
            } else {
                processed = chunks.count
                finalStatus = .indexingFTSOnly
            }

            if Task.isCancelled || cancelRequested[batchKey] == true {
                try? stageIndex.checkpointWAL()
                closeStageIndex()
                await cleanupDeletedDependencyInFlightIfNeeded(key: key)
                emit(.cancelled)
                return DocsIngestionReport(
                    goVersion: key.displayID,
                    status: dependencyManifest(for: key)?.status ?? .indexingFTSOnly,
                    totalChunks: chunks.count,
                    addedChunks: diff.added.count,
                    changedChunks: diff.changed.count,
                    removedChunks: diff.removed.count,
                    unchangedChunks: diff.unchanged.count,
                    reusedVectors: reusedCount,
                    computedVectors: computedCount,
                    cancelled: true
                )
            }

            try stageIndex.checkpointWAL()
            closeStageIndex()

            emit(.activating)

            let manifest = DocsDependencyPackManifest(
                modulePath: modulePath,
                moduleVersion: moduleVersion,
                localSourcePath: localSourcePath,
                storageKey: key.storageKey,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                license: license,
                chunkCount: chunks.count,
                status: finalStatus,
                embeddingModelID: embedder?.descriptor.id,
                embeddingModelVersion: embedder?.descriptor.version,
                sizeBytes: Self.directorySizeBytes(stageDir),
                truncated: truncated,
                truncationReason: truncationReason
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL(in: stageDir), options: .atomic)

            if simulateSwapFailure {
                throw DocsStorageError.io("simulated atomic swap failure")
            }
            try Self.atomicReplaceDirectory(source: stageDir, destination: activeDir)

            emit(.completed)
            return DocsIngestionReport(
                goVersion: key.displayID,
                status: finalStatus,
                totalChunks: chunks.count,
                addedChunks: diff.added.count,
                changedChunks: diff.changed.count,
                removedChunks: diff.removed.count,
                unchangedChunks: diff.unchanged.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                cancelled: false
            )
        } catch {
            closeStageIndex()
            await cleanupDeletedDependencyInFlightIfNeeded(key: key)
            emit(.failed, error: error.localizedDescription)
            throw error
        }
    }

    /// Default total disk budget for cached dependency packs (256 MB, N-2).
    public static let defaultDependencyStorageBudgetBytes: Int64 = 256 * 1024 * 1024

    /// Incrementally extracts and indexes only the dependencies of `projectRoot` that are present in local
    /// `GOMODCACHE` and missing or outdated as dependency packs (Issue #27, DOC-12a, DOC-12b, N-1, N-2).
    /// Uncached dependencies are reported in `report.uncached` and never auto-downloaded or substituted.
    public func syncProjectDependencies(
        projectRoot: URL,
        moduleCacheRoot: URL? = nil,
        goVersion: String = BundledGoCorpus.defaultVersion,
        embedder: (any DocsEmbedder)? = nil,
        forceRebuild: Bool = false,
        extractionLimits: DocsModuleExtractionLimits = .default,
        storageBudgetBytes: Int64 = DocsPackManager.defaultDependencyStorageBudgetBytes,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async -> DocsDependencySyncReport {
        let deps = GoModuleResolver.resolveDependencies(projectRoot: projectRoot, moduleCacheRoot: moduleCacheRoot)
        var report = DocsDependencySyncReport()

        for dep in deps {
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            guard let sourceDir = dep.cacheDirectory else {
                report.uncached.append(dep.packKey)
                continue
            }

            // Skip already up-to-date immutable module-cache packs unless rebuild, embedding upgrade,
            // or retry after a transient time-limit truncation is needed.
            if !forceRebuild, dep.localReplaceDirectory == nil, let existing = dependencyManifest(for: dep.packKey) {
                let wasTimeTruncated = existing.truncated && (existing.truncationReason?.hasPrefix("time limit") == true)
                let embeddingSatisfied: Bool
                if let embedder {
                    embeddingSatisfied = existing.status == .ready
                        && existing.embeddingModelID == embedder.descriptor.id
                        && existing.embeddingModelVersion == embedder.descriptor.version
                } else {
                    embeddingSatisfied = true
                }
                if embeddingSatisfied && !wasTimeTruncated {
                    report.skippedUpToDate.append(dep.packKey)
                    continue
                }
            }

            let license = GoModuleResolver.detectLicenseIdentifier(in: sourceDir)
            let extracted = DocsCorpusExtractor.extractModuleDetailed(
                fromModuleRoot: sourceDir,
                modulePath: dep.modulePath,
                moduleVersion: dep.version,
                goVersion: goVersion,
                license: license,
                limits: extractionLimits
            )
            if extracted.cancelled {
                report.cancelled = true
                break
            }
            if extracted.truncated {
                report.truncatedModules[dep.displayID] = extracted.truncationReason ?? "extraction budget reached"
            }
            do {
                let res = try await ingestDependency(
                    modulePath: dep.modulePath,
                    moduleVersion: dep.version,
                    localSourcePath: dep.localReplaceDirectory?.standardizedFileURL.path,
                    chunks: extracted.chunks,
                    license: license,
                    truncated: extracted.truncated,
                    truncationReason: extracted.truncationReason,
                    embedder: embedder,
                    onProgress: onProgress
                )
                if res.cancelled {
                    report.cancelled = true
                    break
                }
                report.synced.append(dep.packKey)
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.failed[dep.displayID] = error.localizedDescription
            }
        }

        // N-2: enforce total dependency pack storage budget, protecting the current project's dependencies.
        let activeKeys = Set(deps.map(\.packKey))
        _ = try? await enforceDependencyStorageBudget(maxTotalBytes: storageBudgetBytes, protecting: activeKeys)
        return report
    }

    /// Removes all installed dependency packs not present in `activeKeys` and garbage-collects unreferenced shared vectors (N-2).
    @discardableResult
    public func pruneUnusedDependencyPacks(keepingActiveKeys activeKeys: Set<GoModuleKey>) async throws -> [GoModuleKey] {
        var removed: [GoModuleKey] = []
        let fm = FileManager.default
        for pack in installedDependencyPacks() {
            let key = pack.key
            guard !activeKeys.contains(key) else { continue }
            let batchKey = Self.depBatchKey(for: key)
            guard !inFlightVersions.contains(batchKey) else { continue }
            let packDir = dependencyPackDirectory(for: key)
            if fm.fileExists(atPath: packDir.path) {
                try fm.removeItem(at: packDir)
            }
            let stageDir = dependencyStagingDirectory(for: key)
            if fm.fileExists(atPath: stageDir.path) {
                try? fm.removeItem(at: stageDir)
            }
            latestProgress.removeValue(forKey: batchKey)
            removed.append(key)
        }
        if !removed.isEmpty {
            _ = try await garbageCollectSharedVectors()
        }
        return removed
    }

    /// Removes dependency packs not required by any of the given project roots (N-2).
    @discardableResult
    public func pruneUnusedDependencyPacks(
        forProjectRoots roots: [URL],
        moduleCacheRoot: URL? = nil
    ) async throws -> [GoModuleKey] {
        var active = Set<GoModuleKey>()
        for root in roots {
            let deps = GoModuleResolver.resolveDependencies(projectRoot: root, moduleCacheRoot: moduleCacheRoot)
            for dep in deps {
                active.insert(dep.packKey)
            }
        }
        return try await pruneUnusedDependencyPacks(keepingActiveKeys: active)
    }

    /// Evicts oldest non-protected dependency packs when total disk usage exceeds `maxTotalBytes`, then runs shared-vector GC (N-2).
    @discardableResult
    public func enforceDependencyStorageBudget(
        maxTotalBytes: Int64 = DocsPackManager.defaultDependencyStorageBudgetBytes,
        protecting activeKeys: Set<GoModuleKey> = []
    ) async throws -> [GoModuleKey] {
        guard maxTotalBytes > 0 else { return [] }
        let packs = installedDependencyPacks()
        var totalBytes = packs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard totalBytes > maxTotalBytes else { return [] }

        let evictable = packs
            .filter { !activeKeys.contains($0.key) && !inFlightVersions.contains(Self.depBatchKey(for: $0.key)) }
            .sorted { $0.createdAt < $1.createdAt }

        var evicted: [GoModuleKey] = []
        let fm = FileManager.default
        for pack in evictable {
            guard totalBytes > maxTotalBytes else { break }
            let dir = dependencyPackDirectory(for: pack.key)
            if fm.fileExists(atPath: dir.path) {
                try? fm.removeItem(at: dir)
            }
            let stageDir = dependencyStagingDirectory(for: pack.key)
            if fm.fileExists(atPath: stageDir.path) {
                try? fm.removeItem(at: stageDir)
            }
            totalBytes -= pack.sizeBytes
            evicted.append(pack.key)
        }
        if !evicted.isEmpty {
            _ = try await garbageCollectSharedVectors()
        }
        return evicted
    }

    /// JSON payload exported for reproducible offline Phase 2 evaluation (`scripts/eval-docs-phase2.py`, V-7).
    public struct ExportedEvalChunk: Codable, Sendable, Hashable {
        public var stable_id: String
        public var title: String
        public var package_name: String
        public var symbol: String
        public var source: String
        public var provenance: String
        public var content_hash: String
        public var text: String
        public var rerank_text: String

        public init(from chunk: DocsChunk) {
            self.stable_id = chunk.stableID
            self.title = chunk.title
            self.package_name = chunk.packageName
            self.symbol = chunk.symbol
            self.source = chunk.source.rawValue
            self.provenance = chunk.provenance.rawValue
            self.content_hash = chunk.contentHash
            self.text = chunk.embeddingText
            self.rerank_text = chunk.rerankDocumentText
        }
    }

    /// Exports all chunks from an installed documentation pack to JSON for `scripts/eval-docs-phase2.py` (V-7).
    @discardableResult
    public func exportChunksJSON(forGoVersion goVersion: String, to destinationURL: URL) throws -> Int {
        guard let index = try openIndex(for: goVersion) else {
            throw DocsStorageError.io("No installed pack for go\(goVersion)")
        }
        defer { index.close() }
        let chunks = try index.allChunks()
        return try Self.writeExportedChunksJSON(chunks, to: destinationURL)
    }

    /// Extracts real stdlib chunks from a local `GOROOT/src` directory and writes them as JSON for evaluation (V-7).
    @discardableResult
    public static func exportGorootChunksJSON(
        fromGorootSrc srcURL: URL,
        goVersion: String,
        includeBundledComplement: Bool = true,
        to destinationURL: URL
    ) throws -> Int {
        let stdlib = DocsCorpusExtractor.extractStdlib(fromGorootSrc: srcURL, goVersion: goVersion)
        let chunks: [DocsChunk]
        if includeBundledComplement {
            let extractedIDs = Set(stdlib.map(\.stableID))
            let bundled = BundledGoCorpus.chunks(forGoVersion: goVersion)
            chunks = stdlib + bundled.filter { $0.source != .stdlib || !extractedIDs.contains($0.stableID) }
        } else {
            chunks = stdlib
        }
        return try writeExportedChunksJSON(chunks, to: destinationURL)
    }

    private static func writeExportedChunksJSON(_ chunks: [DocsChunk], to destinationURL: URL) throws -> Int {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let exported = chunks.map(ExportedEvalChunk.init(from:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(exported)
        try data.write(to: destinationURL, options: .atomic)
        return exported.count
    }

    private func computeBatchVectors(_ texts: [String], with embedder: any DocsEmbedder) async throws -> [[Float]] {
        if texts.count == 1 {
            return [try await embedder.embed(texts[0])]
        }
        do {
            let vectors = try await embedder.embedBatch(texts)
            if vectors.count == texts.count {
                return vectors
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // W-5: degrade failed batch call to single-item embedding before failing the batch.
        }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            out.append(try await embedder.embed(text))
        }
        return out
    }

    private func cleanupDeletedInFlightIfNeeded(goVersion: String) async {
        guard deletedWhileInFlight.remove(goVersion) != nil else { return }
        let fm = FileManager.default
        let stageDir = stagingDirectory(for: goVersion)
        let activeDir = packDirectory(for: goVersion)
        if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        if fm.fileExists(atPath: activeDir.path) {
            try? fm.removeItem(at: activeDir)
        }
        pinnedVectorKeys.removeValue(forKey: goVersion)
        latestProgress.removeValue(forKey: goVersion)
        _ = try? await garbageCollectSharedVectors()
    }

    private func cleanupDeletedDependencyInFlightIfNeeded(key: GoModuleKey) async {
        let batchKey = Self.depBatchKey(for: key)
        guard deletedWhileInFlight.remove(batchKey) != nil else { return }
        let fm = FileManager.default
        let stageDir = dependencyStagingDirectory(for: key)
        let activeDir = dependencyPackDirectory(for: key)
        if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        if fm.fileExists(atPath: activeDir.path) {
            try? fm.removeItem(at: activeDir)
        }
        pinnedVectorKeys.removeValue(forKey: batchKey)
        latestProgress.removeValue(forKey: batchKey)
        _ = try? await garbageCollectSharedVectors()
    }

    private func cleanupDeletedWebsiteInFlightIfNeeded() async {
        let batchKey = Self.websiteBatchKey
        guard deletedWhileInFlight.remove(batchKey) != nil else { return }
        let fm = FileManager.default
        let stageDir = websiteStagingDirectory()
        let activeDir = websitePackDirectory()
        if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        if fm.fileExists(atPath: activeDir.path) {
            try? fm.removeItem(at: activeDir)
        }
        pinnedVectorKeys.removeValue(forKey: batchKey)
        latestProgress.removeValue(forKey: batchKey)
        _ = try? await garbageCollectSharedVectors()
    }

    /// Reclaims any vector in `SharedVectorStore` not referenced by any active pack, staging checkpoint,
    /// or currently running batch (FR-30, H-9).
    @discardableResult
    public func garbageCollectSharedVectors() async throws -> Int {
        var referenced = Set<SharedVectorKey>()

        // 1. Active installed packs (stdlib + dependency packs)
        for pack in installedPacks() {
            if let index = try openIndex(for: pack.goVersion) {
                defer { index.close() }
                let refs = try index.vectorReferences()
                for key in refs.values { referenced.insert(key) }
            }
        }
        for depPack in installedDependencyPacks() {
            if let index = try openDependencyIndex(for: depPack.key) {
                defer { index.close() }
                let refs = try index.vectorReferences()
                for key in refs.values { referenced.insert(key) }
            }
        }
        if let webIndex = try openWebsiteIndex() {
            defer { webIndex.close() }
            let refs = try webIndex.vectorReferences()
            for key in refs.values { referenced.insert(key) }
        }

        // 2. Staging checkpoints for resumable / paused batches (H-9)
        let stagingRoots = [
            rootDirectory.appendingPathComponent("staging", isDirectory: true),
            rootDirectory.appendingPathComponent("staging/deps", isDirectory: true)
        ]
        for stagingRoot in stagingRoots {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for dir in entries where dir.lastPathComponent != "deps" {
                    let dbURL = dir.appendingPathComponent("index.sqlite")
                    guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
                    // R-10b: if an uncheckpointed WAL staging DB from a crash fails read-only open,
                    // fall back to read-write open so SQLite recovers the WAL and preserves checkpointed refs.
                    let stageIdx = (try? DocsIndex(databaseURL: dbURL, readOnly: true))
                        ?? (try? DocsIndex(databaseURL: dbURL, readOnly: false))
                    if let stageIdx {
                        defer { stageIdx.close() }
                        if let refs = try? stageIdx.vectorReferences() {
                            for key in refs.values { referenced.insert(key) }
                        }
                    }
                }
            }
        }

        // 3. In-flight batch pinned keys (H-9: covers the window between store() and recordVectorReference())
        for keys in pinnedVectorKeys.values {
            referenced.formUnion(keys)
        }

        return try await sharedVectorStore.garbageCollect(referencedKeys: referenced)
    }

    // MARK: - Helpers

    private func publishInitialDependencyFTSOnlySnapshot(
        fromStageDB stageDB: URL,
        key: GoModuleKey,
        license: String?,
        chunkCount: Int
    ) throws {
        let fm = FileManager.default
        let tempDir = rootDirectory.appendingPathComponent("staging/deps/.fts-pub-\(key.storageKey)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.copyItem(at: stageDB, to: tempDir.appendingPathComponent("index.sqlite"))
        let manifest = DocsDependencyPackManifest(
            modulePath: key.modulePath,
            moduleVersion: key.version,
            localSourcePath: key.localSourcePath,
            storageKey: key.storageKey,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            license: license,
            chunkCount: chunkCount,
            status: .indexingFTSOnly,
            sizeBytes: Self.directorySizeBytes(tempDir)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: tempDir), options: .atomic)
        try Self.atomicReplaceDirectory(source: tempDir, destination: dependencyPackDirectory(for: key))
    }

    private func publishInitialWebsiteFTSOnlySnapshot(
        fromStageDB stageDB: URL,
        snapshotDate: String,
        snapshotCommit: String?,
        sourceRepository: String,
        includedCategories: [String],
        chunkCount: Int
    ) throws {
        let fm = FileManager.default
        let tempDir = rootDirectory.appendingPathComponent("staging/.fts-pub-website-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.copyItem(at: stageDB, to: tempDir.appendingPathComponent("index.sqlite"))
        let manifest = DocsWebsitePackManifest(
            sourceRepository: sourceRepository,
            snapshotDate: snapshotDate,
            snapshotCommit: snapshotCommit,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            license: DocsLicense.goBSD3Clause,
            chunkCount: chunkCount,
            status: .indexingFTSOnly,
            sizeBytes: Self.directorySizeBytes(tempDir),
            includedCategories: includedCategories
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: tempDir), options: .atomic)
        try Self.atomicReplaceDirectory(source: tempDir, destination: websitePackDirectory())
    }

    private func publishInitialFTSOnlySnapshot(fromStageDB stageDB: URL, goVersion: String, chunkCount: Int) throws {
        let fm = FileManager.default
        let tempDir = rootDirectory.appendingPathComponent("staging/.fts-pub-\(goVersion)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.copyItem(at: stageDB, to: tempDir.appendingPathComponent("index.sqlite"))
        let manifest = DocsPackManifest(
            goVersion: goVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            license: DocsLicense.goBSD3Clause,
            chunkCount: chunkCount,
            status: .indexingFTSOnly,
            sizeBytes: Self.directorySizeBytes(tempDir)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: tempDir), options: .atomic)
        try Self.atomicReplaceDirectory(source: tempDir, destination: packDirectory(for: goVersion))
    }

    private static func atomicReplaceDirectory(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    private static func directorySizeBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
