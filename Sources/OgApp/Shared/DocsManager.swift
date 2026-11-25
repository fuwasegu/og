import AppKit
import OgCore

extension Notification.Name {
    /// Offline Go Docs settings, installed packs, or ingestion batch progress changed.
    static let ogDocsChanged = Notification.Name("og.docsChanged")
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
    private var batchTasks: [String: Task<Void, Never>] = [:]

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
        Task { [weak self] in
            await self?.refreshPacks()
        }
    }

    // MARK: - Opt-in Settings (FR-19, FR-24)

    private static var storedEnabled: Bool {
        (UserDefaults.standard.object(forKey: "og.docs.enabled") as? Bool) ?? false
    }

    var enabled: Bool {
        get { Self.storedEnabled }
        set {
            UserDefaults.standard.set(newValue, forKey: "og.docs.enabled")
            let svc = service
            Task { [weak self] in
                await svc?.setEnabled(newValue)
                if newValue {
                    await self?.ensureDefaultPackIfNeeded()
                }
                self?.notify()
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
            notify()
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

    // MARK: - Pack inventory & ingestion batches (FR-20, FR-22..29)

    func refreshPacks() async {
        guard let pm = packManager else { return }
        installedPacks = await pm.installedPacks()
        notify()
    }

    func ensureDefaultPackIfNeeded() async {
        guard let pm = packManager else { return }
        let packs = await pm.installedPacks()
        installedPacks = packs
        if packs.isEmpty {
            startBundledPackIngestion(goVersion: BundledGoCorpus.defaultVersion)
        } else {
            notify()
        }
    }

    /// Starts low-priority background ingestion of the bundled Go core pack for `goVersion` (FR-23, FR-24).
    func startBundledPackIngestion(goVersion: String) {
        let chunks = BundledGoCorpus.chunks(forGoVersion: goVersion)
        startIngestion(goVersion: goVersion, chunks: chunks)
    }

    /// Extracts standard library chunks from a local GOROOT `src/` directory and runs the staged batch (FR-4-1).
    func startGorootIngestion(goroot: URL, goVersion: String) {
        let srcURL = goroot.appendingPathComponent("src", isDirectory: true)
        guard let pm = packManager else { return }
        batchTasks[goVersion]?.cancel()
        lastError = nil
        activeProgress = DocsBatchProgress(goVersion: goVersion, phase: .extracting)
        notify()

        batchTasks[goVersion] = Task.detached(priority: .utility) {
            var chunks = BundledGoCorpus.chunks(forGoVersion: goVersion)
            let stdlib = DocsCorpusExtractor.extractStdlib(fromGorootSrc: srcURL, goVersion: goVersion)
            let existingIDs = Set(chunks.map(\.stableID))
            chunks.append(contentsOf: stdlib.filter { !existingIDs.contains($0.stableID) })
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
        notify()

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
        notify()
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
        notify()
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

    private func notify() {
        NotificationCenter.default.post(name: .ogDocsChanged, object: self)
    }
}
