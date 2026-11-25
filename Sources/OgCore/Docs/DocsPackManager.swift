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
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("staging", isDirectory: true), withIntermediateDirectories: true)
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
                    } else {
                        let vector = try await embedder.embed(chunk.embeddingText)
                        try await sharedVectorStore.store(key: key, vector: vector)
                        try stageIndex.recordVectorReference(stableID: chunk.stableID, key: key)
                        computedCount += 1
                    }

                    processed += 1
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

    /// Reclaims any vector in `SharedVectorStore` not referenced by any active pack, staging checkpoint,
    /// or currently running batch (FR-30, H-9).
    @discardableResult
    public func garbageCollectSharedVectors() async throws -> Int {
        var referenced = Set<SharedVectorKey>()

        // 1. Active installed packs
        for pack in installedPacks() {
            if let index = try openIndex(for: pack.goVersion) {
                defer { index.close() }
                let refs = try index.vectorReferences()
                for key in refs.values { referenced.insert(key) }
            }
        }

        // 2. Staging checkpoints for resumable / paused batches (H-9)
        let stagingRoot = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in entries where dir.lastPathComponent.hasPrefix("go") {
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

        // 3. In-flight batch pinned keys (H-9: covers the window between store() and recordVectorReference())
        for keys in pinnedVectorKeys.values {
            referenced.formUnion(keys)
        }

        return try await sharedVectorStore.garbageCollect(referencedKeys: referenced)
    }

    // MARK: - Helpers

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
