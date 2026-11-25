import AppKit
import OgCore

extension Notification.Name {
    /// Offline Go Docs opt-in toggle or installed pack inventory changed (triggers DocsPanel refresh/requery).
    static let ogDocsChanged = Notification.Name("og.docsChanged")
    /// Ingestion batch progress or batch scheduling policy changed (status UI only; never retriggers search, M-4).
    static let ogDocsBatchProgressChanged = Notification.Name("og.docsBatchProgressChanged")
}

/// App-level coordinator for offline Go documentation lookup and pack management (FR-19..29, DOC-1..9).
@MainActor
final class DocsManager {
    static let shared = DocsManager()

    let packManager: DocsPackManager?
    let service: ResearchService?

    private(set) var installedPacks: [DocsPackManifest] = []
    private(set) var activeProgress: DocsBatchProgress?
    private(set) var lastError: String?
    private(set) var detectedToolchainVersion: GoVersion?
    private var batchTasks: [String: Task<Void, Never>] = [:]
    /// In-memory override for headless tests so `DebugDriver` never mutates UserDefaults opt-in (M-6).
    var debugEnabledOverride: Bool?

    private init() {
        do {
            let pm = try DocsPackManager()
            self.packManager = pm
            let svc = ResearchService(packManager: pm, enabled: Self.storedEnabled)
            self.service = svc
        } catch {
            self.packManager = nil
            self.service = nil
            self.lastError = error.localizedDescription
        }
        Task.detached(priority: .utility) {
            let ver = GoVersionResolver.detectInstalledToolchainVersion()
            await MainActor.run {
                DocsManager.shared.setDetectedToolchainVersion(ver)
            }
        }
        Task { [weak self] in
            await self?.refreshPacks()
        }
    }

    private func setDetectedToolchainVersion(_ ver: GoVersion?) {
        detectedToolchainVersion = ver
        notifyProgressChanged()
    }

    // MARK: - Opt-in Settings (FR-19, FR-24)

    private static var storedEnabled: Bool {
        (UserDefaults.standard.object(forKey: "og.docs.enabled") as? Bool) ?? false
    }

    var enabled: Bool {
        get { debugEnabledOverride ?? Self.storedEnabled }
        set {
            debugEnabledOverride = nil
            UserDefaults.standard.set(newValue, forKey: "og.docs.enabled")
            let svc = service
            Task { [weak self] in
                await svc?.setEnabled(newValue)
                if newValue {
                    await self?.ensureDefaultPackIfNeeded()
                }
                self?.notifyPacksChanged()
            }
        }
    }

    var batchPolicy: DocsBatchRunPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "og.docs.batchPolicy"),
                  let p = DocsBatchRunPolicy(rawValue: raw) else { return .anytime }
            return p
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "og.docs.batchPolicy")
            notifyProgressChanged()
        }
    }

    func startIfEnabled() {
        guard enabled else { return }
        Task { [weak self] in
            await self?.service?.setEnabled(true)
            await self?.ensureDefaultPackIfNeeded()
        }
    }

    func shutdownForQuit() {
        for (_, task) in batchTasks { task.cancel() }
        batchTasks.removeAll()
    }

    // MARK: - Pack inventory & ingestion batches (FR-20, FR-22..29, M-5)

    func refreshPacks() async {
        guard let pm = packManager else { return }
        installedPacks = await pm.installedPacks()
        notifyPacksChanged()
    }

    func ensureDefaultPackIfNeeded() async {
        guard let pm = packManager else { return }
        let packs = await pm.installedPacks()
        installedPacks = packs
        if packs.isEmpty {
            startBundledPackIngestion(goVersion: BundledGoCorpus.defaultVersion)
        } else {
            notifyPacksChanged()
        }
    }

    /// Starts low-priority background ingestion of the bundled Go core pack for `goVersion` (FR-23, FR-24).
    func startBundledPackIngestion(goVersion: String) {
        let chunks = BundledGoCorpus.chunks(forGoVersion: goVersion)
        startIngestion(goVersion: goVersion, chunks: chunks)
    }

    /// Extracts standard library chunks from a local GOROOT `src/` directory and runs the staged batch (FR-4-1).
    /// M-5: Real GOROOT GoDoc takes precedence over bundled stdlib excerpts so citations match actual official GoDoc;
    /// bundled spec/guide/release chunks complement the extracted stdlib.
    func startGorootIngestion(goroot: URL, goVersion: String) {
        let srcURL = goroot.appendingPathComponent("src", isDirectory: true)
        guard let pm = packManager else { return }
        batchTasks[goVersion]?.cancel()
        lastError = nil
        activeProgress = DocsBatchProgress(goVersion: goVersion, phase: .extracting)
        notifyProgressChanged()

        batchTasks[goVersion] = Task.detached(priority: .utility) {
            let stdlib = DocsCorpusExtractor.extractStdlib(fromGorootSrc: srcURL, goVersion: goVersion)
            let extractedIDs = Set(stdlib.map(\.stableID))
            let bundled = BundledGoCorpus.chunks(forGoVersion: goVersion)
            // Keep real stdlib first; add non-stdlib (spec/guide/release) and any stdlib not covered by GOROOT.
            let combined = stdlib + bundled.filter { $0.source != .stdlib || !extractedIDs.contains($0.stableID) }
            do {
                _ = try await pm.ingest(goVersion: goVersion, chunks: combined, embedder: nil) { progress in
                    Task { @MainActor in
                        DocsManager.shared.handleBatchProgress(progress)
                    }
                }
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: nil)
            } catch {
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: error.localizedDescription)
            }
        }
    }

    func startIngestion(goVersion: String, chunks: [DocsChunk]) {
        guard let pm = packManager else { return }
        batchTasks[goVersion]?.cancel()
        lastError = nil
        let est = DocsPackManager.estimateBatch(chunks: chunks, includesEmbeddings: false)
        activeProgress = DocsBatchProgress(
            goVersion: goVersion,
            phase: .extracting,
            processedChunks: 0,
            totalChunks: est.chunkCount,
            estimatedBytes: est.estimatedBytes
        )
        notifyProgressChanged()

        // FR-24: run at background `.utility` priority so typing & completion are never blocked.
        batchTasks[goVersion] = Task.detached(priority: .utility) {
            do {
                _ = try await pm.ingest(goVersion: goVersion, chunks: chunks, embedder: nil) { progress in
                    Task { @MainActor in
                        DocsManager.shared.handleBatchProgress(progress)
                    }
                }
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: nil)
            } catch {
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: error.localizedDescription)
            }
        }
    }

    private func handleBatchProgress(_ progress: DocsBatchProgress) {
        activeProgress = progress
        notifyProgressChanged()
    }

    func cancelActiveBatch() {
        guard let progress = activeProgress else { return }
        let ver = progress.goVersion
        batchTasks[ver]?.cancel()
        batchTasks.removeValue(forKey: ver)
        if let pm = packManager {
            Task { [weak self] in
                await pm.requestCancel(goVersion: ver)
                await self?.refreshPacks()
            }
        }
        activeProgress = DocsBatchProgress(
            goVersion: ver,
            phase: .cancelled,
            processedChunks: progress.processedChunks,
            totalChunks: progress.totalChunks,
            estimatedBytes: progress.estimatedBytes
        )
        notifyProgressChanged()
    }

    func deletePack(goVersion: String) {
        guard let pm = packManager else { return }
        batchTasks[goVersion]?.cancel()
        batchTasks.removeValue(forKey: goVersion)
        Task { [weak self] in
            do {
                _ = try await pm.deletePack(goVersion: goVersion)
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
            await self?.refreshPacks()
        }
    }

    /// Synchronous helper for headless tests / immediate first-run setup.
    func ensureBundledPackSync(goVersion: String = BundledGoCorpus.defaultVersion) async {
        guard let pm = packManager else { return }
        _ = try? await pm.ensureBundledPackInstalled(goVersion: goVersion)
        await refreshPacks()
    }

    // MARK: - Search (UX-5: asynchronous, never blocks editor)

    func search(
        query: String,
        projectRoot: URL?,
        explicitVersion: GoVersion?,
        editorContext: DocsEditorContext?
    ) async -> DocsAnswer {
        guard let service else {
            return DocsAnswer(
                query: query,
                status: .disabled,
                language: DocsLanguage.detect(in: query),
                intent: .needsReverseLookup,
                conclusion: lastError ?? "Go Docs storage is unavailable."
            )
        }
        await service.setEnabled(enabled)
        do {
            return try await service.search(
                query: query,
                projectRoot: projectRoot,
                explicitVersionOverride: explicitVersion,
                editorContext: editorContext
            )
        } catch is CancellationError {
            return DocsAnswer(
                query: query,
                status: .notFound,
                language: DocsLanguage.detect(in: query),
                intent: .needsReverseLookup,
                conclusion: ""
            )
        } catch {
            return DocsAnswer(
                query: query,
                status: .notFound,
                language: DocsLanguage.detect(in: query),
                intent: .needsReverseLookup,
                conclusion: error.localizedDescription
            )
        }
    }

    private func finishBatch(goVersion: String, error: String?) async {
        batchTasks.removeValue(forKey: goVersion)
        lastError = error
        await refreshPacks()
    }

    private func notifyPacksChanged() {
        NotificationCenter.default.post(name: .ogDocsChanged, object: self)
    }

    private func notifyProgressChanged() {
        NotificationCenter.default.post(name: .ogDocsBatchProgressChanged, object: self)
    }
}
