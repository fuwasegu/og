import AppKit
import OgCore

extension Notification.Name {
    /// Offline Go Docs opt-in toggle or installed pack inventory changed (triggers DocsPanel refresh/requery).
    static let ogDocsChanged = Notification.Name("og.docsChanged")
    /// Ingestion batch progress or batch scheduling policy changed (status UI only; never retriggers search, M-4).
    static let ogDocsBatchProgressChanged = Notification.Name("og.docsBatchProgressChanged")
    /// Error-driven Docs hints toggle changed (independent of Docs opt-in, DOC-13c).
    static let ogDocsErrorHintsSettingChanged = Notification.Name("og.docsErrorHintsSettingChanged")
}

/// App-level coordinator for offline Go documentation lookup and pack management (FR-19..29, DOC-1..9).
@MainActor
final class DocsManager {
    static let shared = DocsManager()

    let packManager: DocsPackManager?
    let service: ResearchService?

    private(set) var installedPacks: [DocsPackManifest] = []
    private(set) var installedDependencyPacks: [DocsDependencyPackManifest] = []
    private(set) var installedWebsitePack: DocsWebsitePackManifest?
    private(set) var activeProgress: DocsBatchProgress?
    private(set) var lastError: String?
    private(set) var detectedToolchainVersion: GoVersion?
    private(set) var detectedModuleCacheRoot: URL?
    private var toolchainDetectionCompleted = false
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
            async let ver = GoVersionResolver.detectInstalledToolchainVersionAsync()
            async let modCache = GoModuleResolver.detectModuleCacheRootAsync()
            let (resolvedVer, resolvedCache) = await (ver, modCache)
            await MainActor.run {
                DocsManager.shared.setDetectedEnvironment(version: resolvedVer, moduleCacheRoot: resolvedCache)
            }
        }
        Task { [weak self] in
            await self?.refreshPacks()
        }
    }

    private func setDetectedEnvironment(version ver: GoVersion?, moduleCacheRoot: URL?) {
        detectedToolchainVersion = ver
        detectedModuleCacheRoot = moduleCacheRoot
        toolchainDetectionCompleted = true
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
            DocsServerManager.shared.syncWithDocsOptIn(docsEnabled: newValue)
            DocsAnswerServerManager.shared.syncWithDocsOptIn(docsEnabled: newValue)
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

    /// Independent switch for error-driven Docs hints in Problems (DOC-13c; defaults to true when Docs is enabled).
    var errorHintsEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "og.docs.errorHintsEnabled") as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "og.docs.errorHintsEnabled")
            NotificationCenter.default.post(name: .ogDocsErrorHintsSettingChanged, object: self)
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
        DocsServerManager.shared.startIfEnabled()
        DocsAnswerServerManager.shared.startIfEnabled()
        Task { [weak self] in
            await self?.service?.setEnabled(true)
            await self?.ensureDefaultPackIfNeeded()
        }
    }

    func shutdownForQuit() {
        for (_, task) in batchTasks { task.cancel() }
        batchTasks.removeAll()
        DocsServerManager.shared.shutdownForQuit()
        DocsAnswerServerManager.shared.shutdownForQuit()
    }

    /// Synchronizes the active loopback embedder, reranker, and answer generator clients into `ResearchService` (Phase 2/3, D-9, DOC-10, DOC-11).
    func syncInferenceClients() {
        guard let svc = service else { return }
        let embedder = DocsServerManager.shared.embedderClient
        let reranker = DocsServerManager.shared.rerankerClient
        let endpoint = DocsServerManager.shared.endpointURL
        let generator = DocsAnswerServerManager.shared.answerGeneratorClient
        let includeCtx = DocsAnswerServerManager.shared.config.includeEditorContext
        Task { [weak self] in
            try? await svc.setLocalEndpoint(endpoint)
            await svc.setEmbedder(embedder)
            await svc.setReranker(reranker)
            await svc.setAnswerGenerator(generator)
            await svc.setIncludeEditorContextInGeneration(includeCtx)
            self?.notifyPacksChanged()
        }
    }

    /// Handles an embedding model change in Settings: demotes incompatible packs to FTS-only (FR-27, DOC-4).
    func handleEmbeddingModelChanged(to descriptor: EmbeddingModelDescriptor) {
        guard let pm = packManager else { return }
        Task { [weak self] in
            do {
                _ = try await pm.selectEmbeddingModel(descriptor)
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
            await self?.refreshPacks()
        }
    }

    // MARK: - Pack inventory & ingestion batches (FR-20, FR-22..29, M-5)

    func refreshPacks() async {
        guard let pm = packManager else { return }
        // S-1, T-1, T-2: migrate v2 packs in place with per-pack error isolation; surface failures rather than swallowing.
        let migration = await pm.migrateLegacyPacksIfNeeded()
        if let firstFail = migration.failedVersions.sorted(by: { $0.key < $1.key }).first {
            lastError = "Pack go\(firstFail.key) migration failed: \(firstFail.value)"
        }
        // S-3, T-3: validate concept_rules.json (surfacing JSON errors) while keeping live disk reload enabled.
        await reloadConceptRules()
        installedPacks = await pm.installedPacks()
        installedDependencyPacks = await pm.installedDependencyPacks()
        installedWebsitePack = await pm.websiteManifest()
        notifyPacksChanged()
    }

    /// Validates `concept_rules.json` (surfacing any parse error in `lastError`) and keeps `ResearchService`
    /// reading live global & per-pack rules on every search (S-3, T-3).
    func reloadConceptRules() async {
        guard let pm = packManager, let service else { return }
        _ = await pm.loadConceptRules()
        await service.setConceptRules(nil)
        if let err = await pm.conceptRulesLoadError() {
            lastError = err
        } else if lastError?.contains("concept_rules.json") == true {
            lastError = nil
        }
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

        let activeEmbedder = DocsServerManager.shared.embedderClient
        batchTasks[goVersion] = Task.detached(priority: .utility) {
            let stdlib = DocsCorpusExtractor.extractStdlib(fromGorootSrc: srcURL, goVersion: goVersion)
            let extractedIDs = Set(stdlib.map(\.stableID))
            let bundled = BundledGoCorpus.chunks(forGoVersion: goVersion)
            // Keep real stdlib first; add non-stdlib (spec/guide/release) and any stdlib not covered by GOROOT.
            let combined = stdlib + bundled.filter { $0.source != .stdlib || !extractedIDs.contains($0.stableID) }
            do {
                _ = try await pm.ingest(goVersion: goVersion, chunks: combined, embedder: activeEmbedder) { progress in
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
        let activeEmbedder = DocsServerManager.shared.embedderClient
        batchTasks[goVersion]?.cancel()
        lastError = nil
        let est = DocsPackManager.estimateBatch(chunks: chunks, includesEmbeddings: activeEmbedder != nil)
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
                _ = try await pm.ingest(goVersion: goVersion, chunks: chunks, embedder: activeEmbedder) { progress in
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

    /// Re-embeds an already-installed pack in place with the active local MLX embedder (FR-27, FR-30).
    func startReembedPack(goVersion: String) {
        guard let pm = packManager else { return }
        guard let activeEmbedder = DocsServerManager.shared.embedderClient else {
            lastError = "Docs semantic server is not ready yet. Enable and start it first."
            notifyProgressChanged()
            return
        }
        batchTasks[goVersion]?.cancel()
        lastError = nil
        activeProgress = DocsBatchProgress(goVersion: goVersion, phase: .embedding)
        notifyProgressChanged()

        batchTasks[goVersion] = Task.detached(priority: .utility) {
            do {
                let report = try await pm.reembedExistingPack(goVersion: goVersion, embedder: activeEmbedder) { progress in
                    Task { @MainActor in
                        DocsManager.shared.handleBatchProgress(progress)
                    }
                }
                if report == nil {
                    await DocsManager.shared.finishBatch(goVersion: goVersion, error: "No installed pack for go\(goVersion).")
                    return
                }
                // Also re-embed installed golang/website snapshot pack if present and not yet Ready with the active model.
                if let webManifest = await pm.websiteManifest(),
                   webManifest.status != .ready || webManifest.embeddingModelID != activeEmbedder.descriptor.id {
                    _ = try await pm.reembedWebsitePack(embedder: activeEmbedder) { progress in
                        Task { @MainActor in
                            DocsManager.shared.handleBatchProgress(progress)
                        }
                    }
                }
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: nil)
            } catch {
                await DocsManager.shared.finishBatch(goVersion: goVersion, error: error.localizedDescription)
            }
        }
    }

    /// Extracts curated guides, Tour of Go, Effective Go, FAQ, and technical Go Blog posts from a local
    /// `golang/website` checkout into the version-independent website snapshot pack (Issue #26, DOC-14).
    func startWebsiteIngestion(websiteRoot: URL) {
        guard let pm = packManager else { return }
        let taskKey = "website"
        batchTasks[taskKey]?.cancel()
        lastError = nil
        activeProgress = DocsBatchProgress(goVersion: "golang/website", phase: .extracting)
        notifyProgressChanged()

        let activeEmbedder = DocsServerManager.shared.embedderClient
        batchTasks[taskKey] = Task.detached(priority: .utility) {
            let extracted = DocsWebsiteCorpusExtractor.extractWebsite(fromWebsiteRoot: websiteRoot)
            guard !extracted.chunks.isEmpty else {
                await DocsManager.shared.finishBatch(
                    goVersion: taskKey,
                    error: "No supported golang/website content found under \(websiteRoot.lastPathComponent) (expected _content/doc, _content/tour, _content/blog)."
                )
                return
            }
            do {
                _ = try await pm.ingestWebsite(
                    chunks: extracted.chunks,
                    snapshotDate: extracted.snapshotDate,
                    snapshotCommit: extracted.snapshotCommit,
                    includedCategories: Array(extracted.categoryCounts.keys).sorted(),
                    embedder: activeEmbedder
                ) { progress in
                    Task { @MainActor in
                        DocsManager.shared.handleBatchProgress(progress)
                    }
                }
                await DocsManager.shared.finishBatch(goVersion: taskKey, error: nil)
            } catch {
                await DocsManager.shared.finishBatch(goVersion: taskKey, error: error.localizedDescription)
            }
        }
    }

    func deleteWebsitePack() {
        guard let pm = packManager else { return }
        batchTasks["website"]?.cancel()
        batchTasks.removeValue(forKey: "website")
        Task { [weak self] in
            do {
                _ = try await pm.deleteWebsitePack()
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
            await self?.refreshPacks()
        }
    }

    private func handleBatchProgress(_ progress: DocsBatchProgress) {
        activeProgress = progress
        notifyProgressChanged()
    }

    /// Incrementally extracts and indexes `go.mod`/`go.work` dependencies present in local `GOMODCACHE` (Issue #27, DOC-12).
    /// Never runs `go mod download` automatically.
    func syncProjectDependencies(projectRoot: URL, forceRebuild: Bool = false) {
        guard enabled, let pm = packManager else { return }
        let taskKey = "deps:\(projectRoot.standardizedFileURL.path)"
        batchTasks[taskKey]?.cancel()
        lastError = nil

        let activeEmbedder = DocsServerManager.shared.embedderClient
        let cachedModCache = detectedModuleCacheRoot
        let goVer = GoVersionResolver.resolve(
            projectRoot: projectRoot,
            toolchainVersionProvider: { [cached = detectedToolchainVersion] in cached }
        )?.version.minorKey ?? BundledGoCorpus.defaultVersion

        batchTasks[taskKey] = Task.detached(priority: .utility) {
            let modCache: URL?
            if let cachedModCache {
                modCache = cachedModCache
            } else {
                modCache = await GoModuleResolver.detectModuleCacheRootAsync()
            }
            let report = await pm.syncProjectDependencies(
                projectRoot: projectRoot,
                moduleCacheRoot: modCache,
                goVersion: goVer,
                embedder: activeEmbedder,
                forceRebuild: forceRebuild
            ) { progress in
                Task { @MainActor in
                    DocsManager.shared.handleBatchProgress(progress)
                }
            }
            let errText: String? = report.failed.isEmpty ? nil : report.failed.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            await DocsManager.shared.finishBatch(goVersion: taskKey, error: errText)
        }
    }

    /// Explicit user-triggered `go mod download` for uncached dependencies, followed by local extraction (DOC-12a).
    /// Never called automatically.
    func downloadAndSyncProjectDependencies(projectRoot: URL) {
        guard enabled else { return }
        let taskKey = "deps-dl:\(projectRoot.standardizedFileURL.path)"
        batchTasks[taskKey]?.cancel()
        lastError = nil
        activeProgress = DocsBatchProgress(goVersion: "go mod download", phase: .extracting)
        notifyProgressChanged()

        batchTasks[taskKey] = Task.detached(priority: .utility) {
            let locator = ToolLocator.shared
            guard let goExe = locator.find("go") else {
                await DocsManager.shared.finishBatch(goVersion: taskKey, error: "`go` executable not found on PATH.")
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: goExe)
            proc.arguments = ["mod", "download"]
            proc.currentDirectoryURL = projectRoot
            proc.environment = locator.environment
            let errPipe = Pipe()
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice
            do {
                try proc.run()
                // Drain stderr BEFORE waitUntilExit so a verbose `go mod download` never deadlocks on a full pipe buffer.
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    await DocsManager.shared.finishBatch(
                        goVersion: taskKey,
                        error: "go mod download failed: \(errMsg?.isEmpty == false ? errMsg! : "exit \(proc.terminationStatus)")"
                    )
                    return
                }
            } catch {
                await DocsManager.shared.finishBatch(goVersion: taskKey, error: "go mod download failed: \(error.localizedDescription)")
                return
            }
            await MainActor.run {
                DocsManager.shared.batchTasks.removeValue(forKey: taskKey)
                DocsManager.shared.syncProjectDependencies(projectRoot: projectRoot)
            }
        }
    }

    /// Removes dependency packs not required by any of the given open project roots and runs shared-vector GC (N-2).
    func pruneUnusedDependencyPacks(keepingProjectRoots roots: [URL]) {
        guard let pm = packManager else { return }
        let modCache = detectedModuleCacheRoot
        Task { [weak self] in
            do {
                _ = try await pm.pruneUnusedDependencyPacks(forProjectRoots: roots, moduleCacheRoot: modCache)
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
            await self?.refreshPacks()
        }
    }

    func cancelActiveBatch() {
        guard let progress = activeProgress else { return }
        let ver = progress.goVersion
        batchTasks[ver]?.cancel()
        batchTasks.removeValue(forKey: ver)
        for (k, task) in batchTasks where k.hasPrefix("deps:") || k.hasPrefix("deps-dl:") || k == "website" {
            task.cancel()
            batchTasks.removeValue(forKey: k)
        }
        if let pm = packManager {
            Task { [weak self] in
                await pm.requestCancel(goVersion: ver)
                await pm.requestCancelWebsite()
                if let atIdx = ver.firstIndex(of: "@") {
                    let mp = String(ver[..<atIdx])
                    let mv = String(ver[ver.index(after: atIdx)...])
                    await pm.requestCancelDependency(key: GoModuleKey(modulePath: mp, version: mv))
                }
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
        editorContext: DocsEditorContext?,
        includeSynthesis: Bool = true
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
        let cachedToolchain = detectedToolchainVersion
        let hasCompletedDetection = toolchainDetectionCompleted
        let provider: (@Sendable () -> GoVersion?)? = hasCompletedDetection ? { @Sendable in cachedToolchain } : nil
        do {
            let answer = try await service.search(
                query: query,
                projectRoot: projectRoot,
                explicitVersionOverride: explicitVersion,
                editorContext: editorContext,
                includeSynthesis: includeSynthesis,
                moduleCacheRoot: detectedModuleCacheRoot,
                toolchainVersionProvider: provider
            )
            // T-3: surface any concept_rules.json decode error encountered during live reload.
            if let pm = packManager {
                if let err = await pm.conceptRulesLoadError() {
                    if lastError != err {
                        lastError = err
                        notifyProgressChanged()
                    }
                } else if lastError?.contains("concept_rules.json") == true {
                    lastError = nil
                    notifyProgressChanged()
                }
            }
            return answer
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

    func hasAnswerGenerator() async -> Bool {
        guard let service else { return false }
        return await service.hasAnswerGenerator()
    }

    func synthesizeAnswer(
        for answer: DocsAnswer,
        editorContext: DocsEditorContext?
    ) async -> DocsGeneratedAnswer? {
        guard let service else { return nil }
        return await service.synthesizeAnswer(for: answer, editorContext: editorContext)
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
