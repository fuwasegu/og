import AppKit
import OgCore

/// Completion in Markdown buffers: link and image paths, heading anchors, reference labels and
/// code fence languages (all local; there is no language server for Markdown).
extension EditorController {
    func markdownTyped(_ s: String) {
        let ns = document.storage.string as NSString
        if MarkdownCompletions.context(in: ns, caret: caretOffset) != nil {
            // Everything is computed locally, so each keystroke simply asks again.
            scheduleCompletion(delay: 0.03)
        } else {
            completionTimer?.invalidate()
            completion?.close()
        }
    }

    func requestMarkdownCompletion(explicit: Bool) {
        let ns = document.storage.string as NSString
        let caret = caretOffset
        guard let ctx = MarkdownCompletions.context(in: ns, caret: caret, explicit: explicit) else {
            completion?.close()
            return
        }
        let text = document.storage.string
        let version = document.version
        let docDir = document.url.deletingLastPathComponent()
        let root = context.root
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            var entries: [MarkdownPathEntry] = []
            var headings: [String]?
            switch ctx {
            case .path(let dir, _, _):
                let url = Self.resolveMarkdownPath(dir, docDir: docDir, root: root)
                entries = await Task.detached(priority: .userInitiated) { Self.markdownEntries(in: url) }.value
            case .anchor(let file, _) where !file.isEmpty:
                let url = Self.resolveMarkdownPath(file, docDir: docDir, root: root).standardizedFileURL
                if let open = self?.context.documents.document(for: url) {
                    headings = MarkdownCompletions.headings(in: open.text)
                } else {
                    headings = await Task.detached(priority: .userInitiated) {
                        (try? String(contentsOf: url, encoding: .utf8)).map { MarkdownCompletions.headings(in: $0) } ?? []
                    }.value
                }
            default:
                break
            }
            guard let self, !Task.isCancelled, self.document.version == version, self.caretOffset == caret else { return }
            let found = MarkdownCompletions.items(for: ctx, in: text, entries: entries, headings: headings, caret: caret)
            let replace = ctx.replaceRange
            let typed = ns.substring(with: replace)
            // Nothing to offer once the typed text is already complete (Return must stay a newline).
            if found.isEmpty || (!explicit && found.contains { $0.text == typed }) {
                self.completion?.close()
                return
            }
            let lines = self.document.lines
            let items = found.map { Self.markdownItem($0, lines: lines) }
            if self.completion == nil { self.completion = CompletionPopup(editor: self) }
            self.completion?.show(items: items, text: ns, caret: caret, staleRanges: false, explicit: explicit, anchor: replace.location)
        }
    }

    /// ⌘S on a Markdown file: tables, headings and whitespace (MarkdownFormatter), as one undo step.
    func formatMarkdown() {
        let old = document.storage.string
        let new = MarkdownFormatter.format(old)
        guard new != old else { return }
        let lines = document.lines
        let edits = MarkdownFormatter.edits(from: old, to: new).map { LSPTextEdit(range: lines.lspRange(for: $0.range), newText: $0.text) }
        let caret = MarkdownFormatter.mapCaret(caretOffset, from: old, to: new)
        applyTextEdits(edits, undoName: "Format")
        textView.setSelectedRange(NSRange(location: min(caret, document.storage.length), length: 0))
    }

    /// After a directory was accepted in a link, offer its contents.
    func markdownCompletionAccepted(_ inserted: String) {
        guard document.isMarkdown, inserted.hasSuffix("/") else { return }
        // After the edit's own (async) version bump, or the request is dropped as stale.
        scheduleCompletion(delay: 0.03)
    }

    nonisolated static func markdownItem(_ c: MarkdownCompletion, lines: TextLines) -> LSPCompletionItem {
        let snippet = c.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "}", with: "\\}") + "$0"
        let filter = c.label.hasPrefix("#") ? String(c.label.dropFirst()) : c.label
        var item = LSPCompletionItem(label: c.label, detail: c.detail, snippet: snippet, filterText: filter, sortText: c.sortText)
        item.textEdit = LSPTextEdit(range: lines.lspRange(for: c.replace), newText: snippet)
        return item
    }

    /// A link path as typed: relative to the document, or to the project root when it starts with `/`.
    nonisolated static func resolveMarkdownPath(_ path: String, docDir: URL, root: URL) -> URL {
        if path.isEmpty { return docDir }
        if path.hasPrefix("/") { return root.appendingPathComponent(String(path.dropFirst())) }
        return docDir.appendingPathComponent(path)
    }

    nonisolated static func markdownEntries(in dir: URL) -> [MarkdownPathEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.prefix(500).map { u in
            MarkdownPathEntry(name: u.lastPathComponent, isDirectory: (try? u.resourceValues(forKeys: Set(keys)).isDirectory) == true)
        }
    }
}
