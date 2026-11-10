import AppKit
import OgCore

/// One open file (spec/design/workspace.fsl: buf / known / dirty / conflict / save_error).
@MainActor
final class Document {
    let url: URL
    let storage: NSTextStorage
    /// LSP document version; bumps on every edit.
    private(set) var version = 1
    /// DES-2: disk content as last read, written, or reported by FSEvents.
    var known: String { didSet { knownNS = NSString(string: known) } }
    /// `known` as a real NSString, so the dirty check is a memcmp instead of a Unicode-aware Swift compare.
    private var knownNS: NSString
    /// Line index of the current buffer, rebuilt at most once per edit.
    private var linesCache: TextLines?
    private(set) var dirty = false
    /// Disk changed externally while the buffer had unsaved edits.
    var conflict = false
    var saveError: String?
    let undoManager = UndoManager()
    var isGo: Bool { url.pathExtension == "go" }
    var uri: String { url.lspURI }
    var text: String { storage.string }
    /// Called after every content change (by edits, reloads, or programmatic replace).
    var onChange: [(Document) -> Void] = []
    var onStateChange: [(Document) -> Void] = []

    init(url: URL, text: String) {
        self.url = url
        self.known = text
        self.knownNS = NSString(string: text)
        self.storage = NSTextStorage(string: text)
    }

    /// The buffer's line index (UTF-16). Cached; invalidated synchronously on every storage edit.
    var lines: TextLines {
        if let c = linesCache { return c }
        let l = TextLines(nsString: storage.string as NSString)
        linesCache = l
        return l
    }

    /// Called from the storage delegate as soon as characters change.
    func storageDidChange() { linesCache = nil; editGeneration &+= 1 }
    /// Bumps synchronously on every storage edit (unlike `version`, which follows markEdited).
    private(set) var editGeneration = 0

    private var differsFromDisk: Bool {
        storage.length != knownNS.length || !(storage.string as NSString).isEqual(knownNS)
    }

    /// `editGeneration` as of the last version bump.
    private var versionedGeneration = 0

    /// Bumps the version if the storage changed since the last bump. The storage delegate defers this
    /// to the next runloop turn; `DocumentStore.flush` calls it first so gopls never gets new text
    /// under an old version (which it would drop, then answer requests on the old text).
    func markEditedIfNeeded() {
        guard editGeneration != versionedGeneration else { return }
        markEdited()
    }

    func markEdited() {
        linesCache = nil
        editGeneration &+= 1
        versionedGeneration = editGeneration
        version += 1
        let wasDirty = dirty
        dirty = differsFromDisk
        if !dirty { saveError = nil }
        for cb in onChange { cb(self) }
        if wasDirty != dirty { notifyState() }
    }

    func markSaved(_ text: String) {
        known = text
        dirty = differsFromDisk
        saveError = nil
        conflict = false
        notifyState()
    }

    func notifyState() { for cb in onStateChange { cb(self) } }

    /// Replaces the whole buffer (reload / take-disk). Not undoable.
    func replaceAll(with text: String) {
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        undoManager.removeAllActions()
        markEdited()
    }
}

/// Open documents, autosave, compare-before-replace writes, and FSEvents handling
/// (spec/design/workspace.fsl).
@MainActor
final class DocumentStore {
    private(set) var documents: [URL: Document] = [:]
    private weak var context: ProjectContext?
    private var idleTimers: [URL: Timer] = [:]
    private var syncTimers: [URL: Timer] = [:]
    static let autosaveIdle: TimeInterval = 2.0

    init(context: ProjectContext) {
        self.context = context
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveAll() }
        }
    }

    func document(for url: URL) -> Document? { documents[url.standardizedFileURL] }

    /// Opens (or returns) a document. Returns nil for binary/unreadable files.
    func open(_ url: URL) -> Document? {
        let key = url.standardizedFileURL
        if let d = documents[key] { return d }
        guard let data = try? Data(contentsOf: key) else { return nil }
        guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        let doc = Document(url: key, text: text)
        documents[key] = doc
        doc.onChange.append { [weak self] d in self?.didEdit(d) }
        if doc.isGo, let ctx = context {
            let uri = doc.uri, version = doc.version
            Task { await ctx.gopls.open(uri: uri, text: text, version: version) }
        }
        return doc
    }

    /// Closes a document. Autosaves first; refuses if it cannot be saved (D-6) or is in conflict.
    @discardableResult
    func close(_ doc: Document) -> Bool {
        if doc.conflict { return false }
        if doc.dirty && !save(doc) { return false }
        documents[doc.url] = nil
        idleTimers[doc.url]?.invalidate(); idleTimers[doc.url] = nil
        syncTimers[doc.url]?.invalidate(); syncTimers[doc.url] = nil
        if doc.isGo, let ctx = context {
            let uri = doc.uri
            Task { await ctx.gopls.close(uri: uri) }
        }
        return true
    }

    // MARK: - Editing

    private func didEdit(_ doc: Document) {
        // Coalesced didChange to gopls (DES-1: ordered stream, last version wins).
        if doc.isGo {
            syncTimers[doc.url]?.invalidate()
            syncTimers[doc.url] = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self, weak doc] _ in
                MainActor.assumeIsolated {
                    guard let doc else { return }
                    self?.syncToGopls(doc)
                }
            }
        }
        idleTimers[doc.url]?.invalidate()
        if doc.dirty {
            idleTimers[doc.url] = Timer.scheduledTimer(withTimeInterval: Self.autosaveIdle, repeats: false) { [weak self, weak doc] _ in
                MainActor.assumeIsolated {
                    guard let doc, doc.dirty, !doc.conflict else { return }
                    self?.save(doc)
                }
            }
        }
    }

    /// Sends the current version and waits until gopls has it queued (call before a request).
    func flush(_ doc: Document) async {
        doc.markEditedIfNeeded()
        syncTimers[doc.url]?.invalidate()
        syncTimers[doc.url] = nil
        guard doc.isGo, let ctx = context else { return }
        await ctx.gopls.change(uri: doc.uri, text: doc.text, version: doc.version)
    }

    /// Fire-and-forget didChange (timers, after programmatic edits).
    func syncToGopls(_ doc: Document) {
        syncTimers[doc.url]?.invalidate()
        syncTimers[doc.url] = nil
        guard doc.isGo, let ctx = context else { return }
        let uri = doc.uri, text = doc.text, version = doc.version
        Task { await ctx.gopls.change(uri: uri, text: text, version: version) }
    }

    // MARK: - Saving (DES-2 compare-before-replace)

    /// Writes one document. Returns true on success. Synchronous: no keystroke can interleave (DES-1).
    @discardableResult
    func save(_ doc: Document) -> Bool {
        guard !doc.conflict else { return false }
        guard doc.dirty || doc.saveError != nil else { return true }
        let snapshot = doc.text
        // Byte compare first (memcmp); decode only when the disk really differs.
        let diskData = try? Data(contentsOf: doc.url)
        if let diskData, diskData != Data(doc.known.utf8), let diskNow = String(data: diskData, encoding: .utf8) {
            // The disk changed behind our back: abort and let the change surface (DES-2).
            externalChange(doc, disk: diskNow)
            return false
        }
        do {
            try Data(snapshot.utf8).write(to: doc.url, options: .atomic)
        } catch {
            doc.saveError = error.localizedDescription
            doc.notifyState()
            context?.setStatus("Could not save \(doc.url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        doc.markSaved(snapshot)
        idleTimers[doc.url]?.invalidate()
        if doc.isGo, let ctx = context {
            let uri = doc.uri
            syncToGopls(doc)
            Task { await ctx.gopls.save(uri: uri) }
        }
        NotificationCenter.default.post(name: .ogDocumentSaved, object: context, userInfo: ["url": doc.url])
        return true
    }

    /// Autosave every dirty document without a conflict (D-7: one file at a time).
    func autosaveAll() {
        for doc in documents.values where doc.dirty && !doc.conflict { save(doc) }
    }

    /// Saves everything before run / commit / rename. Returns false if any file could not be saved.
    @discardableResult
    func saveAll() -> Bool {
        autosaveAll()
        return !documents.values.contains { $0.dirty }
    }

    /// Cmd-S: organize imports + gofmt via gopls, then save.
    func saveWithFormatting(_ doc: Document, editor: EditorController?) {
        guard doc.isGo, let ctx = context else { save(doc); return }
        let uri = doc.uri
        Task { @MainActor in
            await self.flush(doc)
            let versionBefore = doc.version
            let imports = await ctx.gopls.organizeImports(uri: uri)
            if doc.version == versionBefore, !imports.isEmpty {
                editor?.applyTextEdits(imports, undoName: "Organize Imports")
            }
            await self.flush(doc)
            let v2 = doc.version
            switch await ctx.gopls.formatting(uri: uri) {
            case .some(let fmt) where doc.version == v2 && !fmt.isEmpty:
                editor?.applyTextEdits(fmt, undoName: "Format")
            case .none:
                // gofmt refuses files that do not parse; say so instead of saving silently unformatted.
                ctx.setStatus("Saved without formatting: gopls could not format \(doc.url.lastPathComponent) (syntax error?)")
            default:
                break
            }
            // The edits above bump the version on the next runloop turn; save the formatted text now.
            doc.markEditedIfNeeded()
            self.save(doc)
        }
    }

    // MARK: - External changes (FSEvents)

    /// Files gopls must hear about when they change on disk.
    nonisolated static func isGoplsWatched(_ url: URL) -> Bool {
        url.pathExtension == "go" || ["go.mod", "go.sum", "go.work", "go.work.sum"].contains(url.lastPathComponent)
    }

    func filesChanged(_ paths: [String]) {
        var changes: [GoplsSession.WatchedFileChange] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if Self.isGoplsWatched(url) {
                let exists = FileManager.default.fileExists(atPath: url.path)
                // A .go file gopls may not know yet counts as created: that makes it re-read the package.
                let kind: GoplsSession.WatchedFileChange.Kind = !exists ? .deleted : (url.pathExtension == "go" && documents[url] == nil ? .created : .changed)
                changes.append(.init(uri: url.lspURI, kind: kind))
            }
            guard let doc = documents[url] else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data == Data(doc.known.utf8) { continue } // DES-3 echo of our own write
            guard let disk = String(data: data, encoding: .utf8) else { continue }
            externalChange(doc, disk: disk)
        }
        if let ctx = context, !changes.isEmpty {
            Task { await ctx.gopls.didChangeWatchedFiles(changes) }
        }
    }

    private func externalChange(_ doc: Document, disk: String) {
        doc.known = disk
        if doc.dirty {
            doc.conflict = true
            doc.notifyState()
        } else {
            context?.editorController(for: doc)?.reloadPreservingSelection(disk)
            if context?.editorController(for: doc) == nil { doc.replaceAll(with: disk) }
            doc.markSaved(disk)
        }
    }

    /// Conflict resolution: keep the buffer and overwrite disk.
    func keepMine(_ doc: Document) {
        guard doc.conflict else { return }
        do {
            try Data(doc.text.utf8).write(to: doc.url, options: .atomic)
            doc.markSaved(doc.text)
        } catch {
            doc.saveError = error.localizedDescription
            doc.notifyState()
        }
    }

    /// Conflict resolution: discard the buffer and reload disk.
    func takeDisk(_ doc: Document) {
        guard doc.conflict else { return }
        context?.editorController(for: doc)?.reloadPreservingSelection(doc.known)
        if context?.editorController(for: doc) == nil { doc.replaceAll(with: doc.known) }
        doc.markSaved(doc.known)
    }

    /// After a failed save: drop edits and show disk content (D-6).
    func discard(_ doc: Document) {
        context?.editorController(for: doc)?.reloadPreservingSelection(doc.known)
        if context?.editorController(for: doc) == nil { doc.replaceAll(with: doc.known) }
        doc.markSaved(doc.known)
    }
}
