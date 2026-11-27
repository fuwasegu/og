import AppKit
import OgCore

/// Per-window coordinator for error-driven Docs hints (Issue #28, DOC-13, DES-ERR-1..4).
///
/// Guarantees:
/// - Never opens panels or steals focus (`HintsNeverInterrupt`).
/// - Never modifies documents automatically; snippet insertion is strictly explicit (`HintsNeverModifyDocument`).
/// - Clears stale gopls hints immediately when `Document.version` advances (`StaleHintsNeverSurvive`).
/// - Clears all build-source diagnostics and hints on a new build/vet run (`new_build_run`).
/// - Clears all shown hints immediately when Docs or error hints are disabled (`DisabledHasNoHints`).
/// - Buffers streaming build output across arbitrary chunk boundaries (E-2) and drains queued evaluations
///   beyond the concurrency cap so diagnostics past #12 are never silently dropped (E-3).
@MainActor
final class ErrorHintCoordinator {
    private static let maxConcurrentEvaluations = 12

    private weak var context: ProjectContext?
    private let store: DocsErrorHintStore
    private var evalTasks: [DocsErrorDiagnosticKey: Task<Void, Never>] = [:]
    private var pendingQueue: [DocsErrorDiagnostic] = []
    private var buildLineBuffers: [String: (buffer: DocsBuildErrorLineBuffer, directory: URL)] = [:]
    private var insertTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Main-thread snapshot of currently shown hints.
    private(set) var hints: [DocsErrorDiagnosticKey: DocsErrorHint] = [:]
    /// Main-thread snapshot of live build/vet diagnostics grouped by file URI.
    private(set) var buildDiagnostics: [String: [DocsErrorDiagnostic]] = [:]

    init(context: ProjectContext) {
        self.context = context
        self.store = DocsErrorHintStore(
            docsEnabled: DocsManager.shared.enabled,
            hintsEnabled: DocsManager.shared.errorHintsEnabled
        )
        observers.append(NotificationCenter.default.addObserver(forName: .ogDocsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSettings() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .ogDocsErrorHintsSettingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSettings() }
        })
    }

    func shutdown() {
        cancelAllEvaluations()
        buildLineBuffers.removeAll()
        insertTask?.cancel()
        insertTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: - Settings Sync (DOC-1, DOC-13c)

    private func syncSettings() {
        let docsOn = DocsManager.shared.enabled
        let hintsOn = DocsManager.shared.errorHintsEnabled
        if !docsOn || !hintsOn {
            cancelAllEvaluations()
            if !hints.isEmpty {
                hints.removeAll()
                notifyChanged()
            }
        }
        let store = self.store
        Task { [weak self] in
            await store.setDocsEnabled(docsOn)
            await store.setHintsEnabled(hintsOn)
            guard docsOn && hintsOn else { return }
            let pending = await store.unevaluatedDiagnostics()
            await MainActor.run {
                self?.enqueueEvaluations(for: pending)
            }
        }
    }

    // MARK: - Signal Ingestion (DES-ERR-2)

    func handleGoplsDiagnostics(fileURI: String, docVersion: Int, items: [LSPDiagnostic]) {
        let normalized = items.map { DocsErrorDiagnostic(fileURI: fileURI, docVersion: docVersion, lspDiagnostic: $0) }
        let incomingKeys = Set(normalized.map(\.key))

        // Immediately clear resolved or older-version gopls hints and queued items from the UI snapshot.
        var snapshotChanged = false
        for (key, hint) in hints where key.fileURI == fileURI && key.source == .gopls {
            if !incomingKeys.contains(key) || hint.docVersion != docVersion {
                hints.removeValue(forKey: key)
                evalTasks[key]?.cancel()
                evalTasks.removeValue(forKey: key)
                snapshotChanged = true
            }
        }
        pendingQueue.removeAll { diag in
            diag.fileURI == fileURI && diag.source == .gopls && (!incomingKeys.contains(diag.key) || diag.docVersion != docVersion)
        }
        if snapshotChanged { notifyChanged() }

        let store = self.store
        Task { [weak self] in
            let toEval = await store.publishGoplsDiagnostics(
                fileURI: fileURI,
                docVersion: docVersion,
                items: normalized
            )
            await MainActor.run {
                self?.enqueueEvaluations(for: toEval)
            }
        }
    }

    func handleDocumentEdited(fileURI: String, newVersion: Int) {
        var changed = false
        for (key, hint) in hints where key.fileURI == fileURI && key.source == .gopls && hint.docVersion != newVersion {
            hints.removeValue(forKey: key)
            changed = true
        }
        for key in evalTasks.keys where key.fileURI == fileURI && key.source == .gopls {
            evalTasks[key]?.cancel()
            evalTasks.removeValue(forKey: key)
        }
        pendingQueue.removeAll { $0.fileURI == fileURI && $0.source == .gopls && $0.docVersion != newVersion }
        if changed { notifyChanged() }
        drainEvaluationQueue()

        let store = self.store
        Task {
            await store.editDocument(fileURI: fileURI, newVersion: newVersion)
        }
    }

    func beginBuildRun() {
        var changed = !buildDiagnostics.isEmpty
        buildDiagnostics.removeAll()
        buildLineBuffers.removeAll()
        for key in hints.keys where key.source == .build {
            hints.removeValue(forKey: key)
            changed = true
        }
        for key in evalTasks.keys where key.source == .build {
            evalTasks[key]?.cancel()
            evalTasks.removeValue(forKey: key)
        }
        pendingQueue.removeAll { $0.source == .build }
        if changed { notifyChanged() }
        drainEvaluationQueue()

        let store = self.store
        Task {
            await store.beginBuildRun()
        }
    }

    /// Consumes a streaming build/vet/test output chunk, buffering partial trailing lines across chunk boundaries (E-2).
    func consumeBuildOutput(_ text: String, workingDirectory: URL, streamKey: String = "stderr") {
        guard let context else { return }
        var entry = buildLineBuffers[streamKey] ?? (DocsBuildErrorLineBuffer(), workingDirectory)
        entry.directory = workingDirectory
        let completeLines = entry.buffer.append(text)
        buildLineBuffers[streamKey] = entry
        guard !completeLines.isEmpty else { return }
        ingestParsedBuildLines(completeLines, workingDirectory: workingDirectory, projectRoot: context.root)
    }

    /// Flushes any trailing non-newline-terminated lines at the end of a build/test run (E-2).
    func finishBuildOutput() {
        guard let context else { return }
        let entries = buildLineBuffers
        buildLineBuffers.removeAll()
        for (_, var entry) in entries {
            let tail = entry.buffer.flush()
            if !tail.isEmpty {
                ingestParsedBuildLines(tail, workingDirectory: entry.directory, projectRoot: context.root)
            }
        }
    }

    private func ingestParsedBuildLines(_ lines: [String], workingDirectory: URL, projectRoot: URL) {
        let parsed = DocsBuildErrorParser.parse(
            lines: lines,
            workingDirectory: workingDirectory,
            projectRoot: projectRoot
        )
        guard !parsed.isEmpty else { return }

        var added = false
        for diag in parsed {
            var list = buildDiagnostics[diag.fileURI] ?? []
            if !list.contains(where: { $0.key == diag.key }) {
                list.append(diag)
                buildDiagnostics[diag.fileURI] = list
                added = true
            }
        }
        if added { notifyChanged() }

        let store = self.store
        Task { [weak self] in
            let toEval = await store.addBuildDiagnostics(parsed)
            await MainActor.run {
                self?.enqueueEvaluations(for: toEval)
            }
        }
    }

    // MARK: - User Actions (DOC-13c)

    func dismissHint(for key: DocsErrorDiagnosticKey) {
        evalTasks[key]?.cancel()
        evalTasks.removeValue(forKey: key)
        pendingQueue.removeAll { $0.key == key }
        hints.removeValue(forKey: key)
        notifyChanged()
        drainEvaluationQueue()

        let store = self.store
        Task {
            await store.dismissHint(for: key)
        }
    }

    func hint(for key: DocsErrorDiagnosticKey) -> DocsErrorHint? {
        guard DocsManager.shared.enabled && DocsManager.shared.errorHintsEnabled else { return nil }
        return hints[key]
    }

    /// Explicit user action to insert a grounded snippet from a shown Cards hint (`insert_from_hint`).
    func insertSnippet(for key: DocsErrorDiagnosticKey, cardIndex: Int) {
        insertTask?.cancel()
        let store = self.store
        insertTask = Task { [weak self] in
            guard let self, let context = self.context else { return }
            guard let item = await store.insertableCard(for: key, cardIndex: cardIndex) else {
                context.setStatus("This hint snippet cannot be inserted.")
                return
            }
            guard let editor = context.currentEditor else {
                context.setStatus("Open a Go file to insert the snippet.")
                return
            }
            guard editor.document.isGo else {
                context.setStatus("Switch to a Go (.go) file before inserting a Go Docs snippet.")
                return
            }
            let docVersionBefore = editor.document.version
            guard let prepared = await DocsCodeInserter.prepareSnippetAsync(
                from: item.card,
                targetVersion: item.targetVersion
            ) else {
                context.setStatus("Snippet cannot be inserted for go\(item.card.goVersion).")
                return
            }
            guard !Task.isCancelled else { return }
            guard context.currentEditor === editor, editor.document.version == docVersionBefore else {
                context.setStatus("Editor changed while formatting snippet; please try inserting again.")
                return
            }
            let range = editor.textView.selectedRange()
            let indent = Self.indentationForInsertion(in: editor.document.storage.string, atUTF16Offset: range.location)
            let indented = prepared.code
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? "" : indent + $0 }
                .joined(separator: "\n")
            let insertion = indented + "\n"
            let utf16Len = (insertion as NSString).length
            editor.document.undoManager.beginUndoGrouping()
            editor.textView.insertReplacing(range, with: insertion, caret: range.location + utf16Len)
            editor.document.undoManager.endUndoGrouping()
            editor.document.undoManager.setActionName("Insert Go Docs Snippet")
            editor.focus()
            let fmtNote = prepared.formattedByGofmt ? "" : " (unformatted: gofmt not found)"
            context.setStatus("Inserted snippet (\(item.card.citation), go\(item.card.goVersion))\(fmtNote)")
        }
    }

    // MARK: - Queued Background Evaluation (DES-ERR-3, E-3)

    private func enqueueEvaluations(for items: [DocsErrorDiagnostic]) {
        guard DocsManager.shared.enabled && DocsManager.shared.errorHintsEnabled else { return }
        for diag in items {
            let key = diag.key
            if hints[key] != nil || evalTasks[key] != nil { continue }
            if pendingQueue.contains(where: { $0.key == key }) { continue }
            pendingQueue.append(diag)
        }
        drainEvaluationQueue()
    }

    private func drainEvaluationQueue() {
        guard DocsManager.shared.enabled && DocsManager.shared.errorHintsEnabled else {
            pendingQueue.removeAll()
            return
        }
        guard let context, let service = DocsManager.shared.service else { return }
        let projectRoot = context.root
        let modCache = DocsManager.shared.detectedModuleCacheRoot
        let cachedToolchain = DocsManager.shared.detectedToolchainVersion
        let toolchainProvider: (@Sendable () -> GoVersion?)? = cachedToolchain.map { v in { @Sendable in v } }

        while evalTasks.count < Self.maxConcurrentEvaluations, !pendingQueue.isEmpty {
            let diag = pendingQueue.removeFirst()
            let key = diag.key
            if hints[key] != nil || evalTasks[key] != nil { continue }

            let editorCtx: DocsEditorContext? = {
                if let url = URL(string: diag.fileURI),
                   let doc = context.documents.document(for: url),
                   doc.isGo {
                    return DocsEditorContext.parse(goSource: doc.text)
                }
                return nil
            }()
            let store = self.store
            evalTasks[key] = Task(priority: .utility) { [weak self] in
                // Small debounce for gopls typing bursts.
                if diag.source == .gopls {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard !Task.isCancelled else { return }
                await service.setEnabled(true)
                let result = await store.evaluateHint(
                    for: key,
                    researchService: service,
                    projectRoot: projectRoot,
                    explicitVersionOverride: nil,
                    editorContext: editorCtx,
                    moduleCacheRoot: modCache,
                    toolchainVersionProvider: toolchainProvider
                )
                guard !Task.isCancelled, let self else { return }
                self.evalTasks.removeValue(forKey: key)
                if let result {
                    // Re-check UI opt-in switches before publishing.
                    if DocsManager.shared.enabled && DocsManager.shared.errorHintsEnabled {
                        self.hints[key] = result
                        self.notifyChanged()
                    }
                }
                // Continue draining remaining queued diagnostics past the concurrency cap (E-3).
                self.drainEvaluationQueue()
            }
        }
    }

    private func cancelAllEvaluations() {
        pendingQueue.removeAll()
        for (_, task) in evalTasks { task.cancel() }
        evalTasks.removeAll()
    }

    private func notifyChanged() {
        guard let context else { return }
        NotificationCenter.default.post(name: .ogErrorHintsChanged, object: context)
    }

    private static func indentationForInsertion(in text: String, atUTF16Offset offset: Int) -> String {
        let ns = text as NSString
        let clamped = max(0, min(offset, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let currentLine = ns.substring(with: lineRange)
        let leading = String(currentLine.prefix(while: { $0 == "\t" || $0 == " " }))
        if !leading.isEmpty { return leading }
        var pos = lineRange.location
        while pos > 0 {
            let prevRange = ns.lineRange(for: NSRange(location: pos - 1, length: 0))
            let prev = ns.substring(with: prevRange)
            let trimmed = prev.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let prevIndent = String(prev.prefix(while: { $0 == "\t" || $0 == " " }))
                return trimmed.hasSuffix("{") ? prevIndent + "\t" : prevIndent
            }
            pos = prevRange.location
        }
        return ""
    }
}
