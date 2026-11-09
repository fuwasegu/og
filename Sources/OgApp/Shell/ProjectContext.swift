import AppKit
import OgCore

/// Everything one project window needs. Panels receive this in their initializer.
///
/// CONTRACT for panel authors (Terminal / Run / Debug / Git / Search):
/// - `root`, `gopls`, `git`, `index`, `documents`, `breakpoints` are ready after init.
/// - Call `open(_:line:column:)` to show a file; `saveAll()` before running tools.
/// - Call `showPanel(_:)` to bring a bottom tab forward; `setStatus(_:)` for a status message.
/// - Set `debugStop` while the debugger is paused; the editor highlights it.
/// - Observe the Notification names in Shared/Notifications.swift.
@MainActor
final class ProjectContext {
    let root: URL
    let gopls: GoplsSession
    let git: GitService
    let index: ProjectIndex
    private(set) var documents: DocumentStore!
    private(set) var breakpoints: BreakpointStore!
    weak var window: ProjectWindowController?

    /// uri -> diagnostics (latest per document).
    private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]
    private(set) var goplsStatus: GoplsStatus = .stopped
    private(set) var gitStatus = GitStatus()
    /// Current debugger stop (file + 0-based line), or nil.
    var debugStop: (url: URL, line: Int)? {
        didSet { NotificationCenter.default.post(name: .ogDebugStopChanged, object: self) }
    }
    private var watcher: FileWatcher?
    private var gitRefreshTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.git = GitService(root: root)
        self.index = ProjectIndex(root: root)
        let box = WeakBox<ProjectContext>()
        self.gopls = GoplsSession(root: root, events: GoplsEvents(
            diagnostics: { uri, _, items in
                Task { @MainActor in box.value?.setDiagnostics(uri: uri, items) }
            },
            status: { status in
                Task { @MainActor in box.value?.setGoplsStatus(status) }
            },
            applyEdit: { edit in
                await MainActor.run { box.value?.applyWorkspaceEdit(edit) ?? false }
            },
            showMessage: { message in
                Task { @MainActor in box.value?.setStatus(message) }
            }
        ))
        box.value = self
        self.documents = DocumentStore(context: self)
        self.breakpoints = BreakpointStore(context: self)
    }

    func start() {
        Task { await gopls.start() }
        Task { await index.refresh() }
        refreshGit()
        watcher = FileWatcher(root: root) { paths in
            Task { @MainActor [weak self] in self?.filesChanged(paths) }
        }
    }

    func shutdown() {
        documents.autosaveAll()
        window?.bottomPanel.debugPanel.stop()
        watcher?.stop()
        let gopls = self.gopls
        Task { await gopls.stop() }
    }

    // MARK: - Navigation

    @discardableResult
    func open(_ url: URL, line: Int? = nil, column: Int? = nil, length: Int = 0) -> EditorController? {
        window?.editorArea.open(url, line: line, column: column, length: length)
    }

    func open(_ location: LSPLocation) {
        guard let url = location.url else { return }
        open(url, line: location.range.start.line, column: location.range.start.character)
    }

    var currentEditor: EditorController? { window?.editorArea.current }

    func editorController(for doc: Document) -> EditorController? {
        window?.editorArea.controller(for: doc)
    }

    func showPanel(_ tab: BottomTab) { window?.bottomPanel.show(tab) }

    func setStatus(_ message: String) { window?.statusBar.setMessage(message) }

    /// Saves every open document; returns false if any could not be saved.
    @discardableResult
    func saveAll() -> Bool { documents.saveAll() }

    func run(_ request: RunRequest) {
        saveAll()
        window?.bottomPanel.runPanel.run(request)
        showPanel(.run)
    }

    func debug(_ request: RunRequest) {
        saveAll()
        window?.bottomPanel.debugPanel.startDebugging(request)
        showPanel(.debug)
    }

    func relativePath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        let r = root.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    // MARK: - Events

    private func setDiagnostics(uri: String, _ items: [LSPDiagnostic]) {
        diagnostics[uri] = items.isEmpty ? nil : items
        NotificationCenter.default.post(name: .ogDiagnosticsChanged, object: self, userInfo: ["uri": uri])
    }

    private func setGoplsStatus(_ status: GoplsStatus) {
        goplsStatus = status
        NotificationCenter.default.post(name: .ogGoplsStatusChanged, object: self)
    }

    private func filesChanged(_ paths: [String]) {
        let gitTouched = paths.contains { $0.contains("/.git/") }
        let worktree = paths.filter { !$0.contains("/.git/") }
        if !worktree.isEmpty {
            documents.filesChanged(worktree)
            let index = self.index
            Task { await index.refresh() }
            NotificationCenter.default.post(name: .ogFilesChanged, object: self, userInfo: ["paths": worktree])
        }
        if gitTouched || !worktree.isEmpty { refreshGit() }
    }

    /// Debounced git status refresh (DES-3).
    func refreshGit() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            let status = await self.git.status()
            guard !Task.isCancelled else { return }
            self.gitStatus = status
            NotificationCenter.default.post(name: .ogGitStatusChanged, object: self)
        }
    }

    /// Applies a server-initiated workspace edit to open buffers (undoable) or files on disk.
    func applyWorkspaceEdit(_ edit: LSPWorkspaceEdit) -> Bool {
        for (uri, edits) in edit.changes {
            guard let url = URL(string: uri) else { continue }
            if let doc = documents.document(for: url) {
                if let editor = editorController(for: doc) {
                    editor.applyTextEdits(edits, undoName: "Code Action")
                } else {
                    doc.replaceAll(with: RenameTransaction.applyEdits(edits, to: doc.text))
                }
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let new = RenameTransaction.applyEdits(edits, to: text)
                try? Data(new.utf8).write(to: url, options: .atomic)
            }
        }
        return true
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}
