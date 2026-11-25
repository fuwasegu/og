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

/// Manages versioned Go documentation packs, staged atomic activation, resumable & incremental
/// ingestion batches, and the shared vector store (FR-5, FR-6, FR-20, FR-22..31).
public actor DocsPackManager {
    public let rootDirectory: URL
    public let sharedVectorStore: SharedVectorStore

    private var activeBatches: [String: Bool] = [:] // goVersion -> cancelRequested
    private var latestProgress: [String: DocsBatchProgress] = [:]
    private var selectedEmbeddingModel: EmbeddingModelDescriptor?

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

    private func manifestURL(in dir: URL) -> URL {
        dir.appendingPathComponent("manifest.json")
    }

    // MARK: - Pack inventory & lifecycle (FR-20, FR-27)

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

    /// Ensures the bundled default Go documentation pack is installed offline if no pack exists yet (Q-1).
    @discardableResult
    public func ensureBundledPackInstalled(
        goVersion: String = BundledGoCorpus.defaultVersion
    ) async throws -> DocsPackManifest {
        if let existing = manifest(for: goVersion) {
            return existing
        }
        let chunks = BundledGoCorpus.chunks(forGoVersion: goVersion)
        _ = try await ingest(goVersion: goVersion, chunks: chunks, embedder: nil)
        guard let installed = manifest(for: goVersion) else {
            throw DocsStorageError.io("bundled pack manifest missing after ingestion")
        }
        return installed
    }

    /// Deletes an installed pack and reclaims any newly unreferenced vectors from `SharedVectorStore` (FR-20, FR-30).
    @discardableResult
    public func deletePack(goVersion: String) async throws -> Int {
        activeBatches[goVersion] = true
        let fm = FileManager.default
        let packDir = packDirectory(for: goVersion)
        if fm.fileExists(atPath: packDir.path) {
            try fm.removeItem(at: packDir)
        }
        let stageDir = stagingDirectory(for: goVersion)
        if fm.fileExists(atPath: stageDir.path) {
            try? fm.removeItem(at: stageDir)
        }
        latestProgress.removeValue(forKey: goVersion)
        return try await garbageCollectSharedVectors()
    }

    /// Switches the active embedding model (FR-27 / DOC-4).
    /// Returns true if any installed pack requires rebuilding its vectors so models are never mixed.
    @discardableResult
    public func selectEmbeddingModel(_ model: EmbeddingModelDescriptor?) throws -> Bool {
        let changed = selectedEmbeddingModel != model
        selectedEmbeddingModel = model
        guard changed else { return false }

        var needsRebuild = false
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for var pack in installedPacks() {
            let matches = (pack.embeddingModelID == model?.id && pack.embeddingModelVersion == model?.version)
            if pack.status == .ready && !matches {
                needsRebuild = true
                pack.status = .indexingFTSOnly
                let dir = packDirectory(for: pack.goVersion)
                let data = try encoder.encode(pack)
                try data.write(to: manifestURL(in: dir), options: .atomic)
                // Discard incompatible staging checkpoints so resume never mixes models.
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
        // FTS5 index overhead ~2.2x text size; 384-dim float32 vector ~1.6KB per chunk.
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
        activeBatches[goVersion] = true
    }

    public func progress(for goVersion: String) -> DocsBatchProgress? {
        latestProgress[goVersion]
    }

    // MARK: - Staged, Resumable, Incremental Ingestion Batch (FR-6, FR-22..31)

    /// Executes the full ingestion pipeline in a staging area:
    /// `extract -> chunk diff -> FTS5 build -> shared vector reuse / embedding -> atomic activation`.
    ///
    /// - FR-6 / FR-22: Builds in staging and swaps atomically; failures/cancellations keep old packs intact.
    /// - FR-23 / FR-25: Emits progress, respects cancellation, and resumes only incomplete chunks.
    /// - FR-26 / FR-31: Computes `DocsChunkDiff` by `stableID` + `contentHash` to re-embed only diffs.
    /// - FR-28: On first install (when no active pack exists), publishes an FTS-only pack once FTS is built
    ///          so search works immediately while embeddings compute.
    /// - FR-30: Looks up `(content_hash, model_id, model_version)` in `SharedVectorStore` before calling `embedder`.
    public func ingest(
        goVersion: String,
        chunks: [DocsChunk],
        embedder: (any DocsEmbedder)? = nil,
        simulateSwapFailure: Bool = false,
        onProgress: (@Sendable (DocsBatchProgress) -> Void)? = nil
    ) async throws -> DocsIngestionReport {
        activeBatches[goVersion] = false
        let estimate = Self.estimateBatch(chunks: chunks, includesEmbeddings: embedder != nil)
        let fm = FileManager.default
        let activeDir = packDirectory(for: goVersion)
        let stageDir = stagingDirectory(for: goVersion)
        let activeExists = fm.fileExists(atPath: indexURL(for: goVersion).path)

        func emit(_ p: DocsBatchProgress) {
            latestProgress[goVersion] = p
            onProgress?(p)
        }

        emit(DocsBatchProgress(
            goVersion: goVersion,
            phase: .extracting,
            processedChunks: 0,
            totalChunks: chunks.count,
            estimatedBytes: estimate.estimatedBytes
        ))

        // Compute diff against the currently active pack if one exists (FR-26, FR-31).
        var previousHashes: [String: String] = [:]
        var previousRefs: [String: SharedVectorKey] = [:]
        if activeExists, let activeIndex = try? DocsIndex(databaseURL: indexURL(for: goVersion), readOnly: true) {
            previousHashes = (try? activeIndex.contentHashesByStableID()) ?? [:]
            previousRefs = (try? activeIndex.vectorReferences()) ?? [:]
            activeIndex.close()
        }
        let diff = DocsChunkDiff.compute(previous: previousHashes, next: chunks)

        // Prepare staging directory (preserve existing staging DB for resume when present, FR-25).
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let stageDBURL = stageDir.appendingPathComponent("index.sqlite")
        let stageIndex = try DocsIndex(databaseURL: stageDBURL, readOnly: false)

        // Load previously checkpointed vector references in staging for resume (FR-25).
        let stageRefs = (try? stageIndex.vectorReferences()) ?? [:]

        emit(DocsBatchProgress(
            goVersion: goVersion,
            phase: .buildingFTS,
            processedChunks: 0,
            totalChunks: chunks.count,
            estimatedBytes: estimate.estimatedBytes
        ))

        try stageIndex.replaceAllChunks(chunks)

        // Remove references for deleted chunks (FR-26).
        if !diff.removed.isEmpty {
            try stageIndex.removeVectorReferences(forStableIDs: diff.removed)
        }

        // Preserve compatible references from active pack + staging checkpoint (FR-25, FR-26).
        if let embedder {
            let model = embedder.descriptor
            selectedEmbeddingModel = model
            for (stableID, ref) in previousRefs {
                if ref.modelID == model.id && ref.modelVersion == model.version &&
                    !diff.removed.contains(stableID) &&
                    stageRefs[stableID] == nil {
                    try? stageIndex.recordVectorReference(stableID: stableID, key: ref)
                }
            }
        }

        // FR-28: If no active pack exists yet and embeddings will run, expose FTS-only pack right away.
        if !activeExists && embedder != nil {
            try publishInitialFTSOnlySnapshot(fromStageDB: stageDBURL, goVersion: goVersion, chunkCount: chunks.count)
        }

        // Embedding phase (FR-22..30).
        var reusedCount = 0
        var computedCount = 0
        var processed = 0
        var finalStatus: DocsPackStatus = .indexingFTSOnly

        if let embedder {
            let model = embedder.descriptor
            let completedRefs = (try? stageIndex.vectorReferences()) ?? [:]

            for chunk in chunks {
                if Task.isCancelled || activeBatches[goVersion] == true {
                    stageIndex.close()
                    emit(DocsBatchProgress(
                        goVersion: goVersion,
                        phase: .cancelled,
                        processedChunks: processed,
                        totalChunks: chunks.count,
                        reusedVectors: reusedCount,
                        computedVectors: computedCount,
                        estimatedBytes: estimate.estimatedBytes
                    ))
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

                // FR-25: Skip already checkpointed chunks with matching hash and model.
                if let existingRef = completedRefs[chunk.stableID], existingRef == key,
                   (try await sharedVectorStore.contains(key)) {
                    reusedCount += 1
                    processed += 1
                    emit(DocsBatchProgress(
                        goVersion: goVersion,
                        phase: .embedding,
                        processedChunks: processed,
                        totalChunks: chunks.count,
                        reusedVectors: reusedCount,
                        computedVectors: computedCount,
                        estimatedBytes: estimate.estimatedBytes
                    ))
                    continue
                }

                // FR-30: Reuse vector from SharedVectorStore if another Go version or prior pack computed it.
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
                emit(DocsBatchProgress(
                    goVersion: goVersion,
                    phase: .embedding,
                    processedChunks: processed,
                    totalChunks: chunks.count,
                    reusedVectors: reusedCount,
                    computedVectors: computedCount,
                    estimatedBytes: estimate.estimatedBytes
                ))
            }
            finalStatus = .ready
        } else {
            // Phase 1 FTS-only pack (FR-15: works offline without an embedding/LLM model).
            processed = chunks.count
            finalStatus = .indexingFTSOnly
        }

        stageIndex.close()

        emit(DocsBatchProgress(
            goVersion: goVersion,
            phase: .activating,
            processedChunks: processed,
            totalChunks: chunks.count,
            reusedVectors: reusedCount,
            computedVectors: computedCount,
            estimatedBytes: estimate.estimatedBytes
        ))

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

        // FR-6 / FR-22: Atomic swap from staging to active. Failure leaves old pack intact.
        do {
            if simulateSwapFailure {
                throw DocsStorageError.io("simulated atomic swap failure")
            }
            try Self.atomicReplaceDirectory(source: stageDir, destination: activeDir)
        } catch {
            emit(DocsBatchProgress(
                goVersion: goVersion,
                phase: .failed,
                processedChunks: processed,
                totalChunks: chunks.count,
                reusedVectors: reusedCount,
                computedVectors: computedCount,
                estimatedBytes: estimate.estimatedBytes,
                errorMessage: error.localizedDescription
            ))
            throw error
        }

        emit(DocsBatchProgress(
            goVersion: goVersion,
            phase: .completed,
            processedChunks: chunks.count,
            totalChunks: chunks.count,
            reusedVectors: reusedCount,
            computedVectors: computedCount,
            estimatedBytes: estimate.estimatedBytes
        ))

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
    }

    /// Reclaims any vector in `SharedVectorStore` not referenced by any installed pack (FR-30).
    @discardableResult
    public func garbageCollectSharedVectors() async throws -> Int {
        var referenced = Set<SharedVectorKey>()
        for pack in installedPacks() {
            if let index = try openIndex(for: pack.goVersion) {
                defer { index.close() }
                let refs = try index.vectorReferences()
                for key in refs.values {
                    referenced.insert(key)
                }
            }
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
