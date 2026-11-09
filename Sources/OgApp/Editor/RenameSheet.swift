import AppKit
import OgCore

/// Rename flow (spec/design/refactor.fsl): name → preview (diff per file) → two-phase apply.
@MainActor
final class RenameSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: RenameSheet?
    static var lastRecord: RenameRecord?

    private weak var editor: EditorController?
    private let window: NSWindow
    private let sheet: NSWindow
    private let field = NSTextField()
    private let table = NSTableView()
    private let diff = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Refactor", target: nil, action: nil)
    private var previews: [FileDiffPreview] = []
    private var versions: [URL: Int] = [:]
    private let uri: String
    private let position: LSPPosition
    private let oldName: String
    private var observer: NSObjectProtocol?

    static func present(on window: NSWindow, editor: EditorController, oldName: String, uri: String, position: LSPPosition) {
        let s = RenameSheet(window: window, editor: editor, oldName: oldName, uri: uri, position: position)
        current = s
        window.beginSheet(s.sheet) { _ in current = nil }
        s.sheet.makeFirstResponder(s.field)
    }

    private init(window: NSWindow, editor: EditorController, oldName: String, uri: String, position: LSPPosition) {
        self.window = window
        self.editor = editor
        self.uri = uri
        self.position = position
        self.oldName = oldName
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let content = NSView()
        let title = NSTextField(labelWithString: "Rename '\(oldName)' and its usages to:")
        field.stringValue = oldName
        field.font = Theme.editorFont
        field.target = self
        field.action = #selector(previewClicked)
        let previewButton = NSButton(title: "Preview", target: self, action: #selector(previewClicked))
        let col = NSTableColumn(identifier: .init("f"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        diff.isEditable = false
        diff.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diff.backgroundColor = Theme.background
        diff.isVerticallyResizable = true
        diff.autoresizingMask = [.width]
        let diffScroll = NSScrollView()
        diffScroll.documentView = diff
        diffScroll.hasVerticalScroller = true
        status.textColor = Theme.secondaryText
        status.font = Theme.smallFont
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false

        let top = NSStackView(views: [field, previewButton])
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(diffScroll)
        let bottom = NSStackView(views: [status, NSView(), cancel, applyButton])
        for v in [title, top, split, bottom] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            tableScroll.widthAnchor.constraint(equalToConstant: 240),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        sheet.contentView = content
        // RF-1 / ASSUME-2: edits while previewing make the preview stale.
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStale() }
        }
    }

    @objc private func previewClicked() {
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let editor, !newName.isEmpty, newName != oldName else { return }
        status.stringValue = "Computing…"
        applyButton.isEnabled = false
        let ctx = editor.context
        Task { [weak self] in
            guard let self else { return }
            switch await ctx.gopls.rename(uri: self.uri, position: self.position, newName: newName) {
            case .failure(let err):
                self.status.stringValue = err.localizedDescription
            case .success(let edit):
                var texts: [URL: String] = [:]
                var versions: [URL: Int] = [:]
                for (uri, _) in edit.changes {
                    if let url = URL(string: uri), let doc = ctx.documents.document(for: url) {
                        texts[url.standardizedFileURL] = doc.text
                        versions[url.standardizedFileURL] = doc.version
                    }
                }
                let snapshot = texts
                self.previews = RenameTransaction.preview(edit) { snapshot[$0.standardizedFileURL] }
                self.versions = versions
                self.table.reloadData()
                if !self.previews.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.showDiff(0)
                }
                self.status.stringValue = "\(self.previews.count) file(s) will change"
                self.applyButton.isEnabled = !self.previews.isEmpty
            }
        }
    }

    private func checkStale() {
        guard let editor, !previews.isEmpty else { return }
        for (url, v) in versions where editor.context.documents.document(for: url)?.version != v {
            applyButton.isEnabled = false
            status.stringValue = "A file changed — press Preview again."
            return
        }
    }

    @objc private func applyClicked() {
        guard let editor else { return }
        checkStale()
        guard applyButton.isEnabled else { return }
        let ctx = editor.context
        guard ctx.saveAll() else { status.stringValue = "Could not save all files"; return }
        do {
            let record = try RenameTransaction.apply(previews)
            RenameSheet.lastRecord = record
            // Reload open buffers from disk (they were clean).
            for p in previews {
                if let doc = ctx.documents.document(for: p.url) {
                    if let ed = ctx.editorController(for: doc) { ed.reloadPreservingSelection(p.newText) } else { doc.replaceAll(with: p.newText) }
                    doc.markSaved(p.newText)
                    ctx.documents.syncToGopls(doc)
                }
            }
            ctx.setStatus("Renamed in \(previews.count) file(s). Refactor ▸ Undo Last Rename reverts it.")
            close()
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func cancelClicked() { close() }

    private func close() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        window.endSheet(sheet)
    }

    static func undoLast(context: ProjectContext) {
        guard let record = lastRecord else { context.setStatus("Nothing to undo"); return }
        // RF-1 / ASSUME-3: only while no renamed file has been edited since.
        for (url, _) in record.originals {
            if let doc = context.documents.document(for: url), doc.dirty {
                context.setStatus("A renamed file was edited; use Edit ▸ Undo in that file instead.")
                return
            }
        }
        do {
            try RenameTransaction.undo(record)
            for (url, text) in record.originals {
                if let doc = context.documents.document(for: url) {
                    if let ed = context.editorController(for: doc) { ed.reloadPreservingSelection(text) } else { doc.replaceAll(with: text) }
                    doc.markSaved(text)
                    context.documents.syncToGopls(doc)
                }
            }
            lastRecord = nil
            context.setStatus("Rename undone")
        } catch {
            context.setStatus(error.localizedDescription)
        }
    }

    private func showDiff(_ row: Int) {
        guard row >= 0, row < previews.count else { return }
        let text = previews[row].unifiedDiff
        let attr = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            var color = Theme.text
            if line.hasPrefix("+") { color = Theme.gitAdded } else if line.hasPrefix("-") { color = Theme.error } else if line.hasPrefix("@@") { color = Theme.info }
            attr.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]))
        }
        diff.textStorage?.setAttributedString(attr)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { previews.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = editor?.context.relativePath(previews[row].url) ?? previews[row].url.lastPathComponent
        let f = NSTextField(labelWithString: name)
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showDiff(table.selectedRow) }
}
