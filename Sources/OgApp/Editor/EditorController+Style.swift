import AppKit
import OgCore

/// Per-editor state of og's Go style checks (Effective Go / Google Go Style).
@MainActor
final class StyleCheckState {
    var timer: Timer?
    var task: Task<Void, Never>?
    /// Findings for the buffer as of `version`, and the same as editor diagnostics (`source` = og).
    var findings: [GoStyleFinding] = []
    var diagnostics: [LSPDiagnostic] = []
    var version = -1
    /// Fixes listed in the open ⌥↩ menu.
    var pendingFixes: [StyleFixChoice] = []
}

struct StyleFixChoice {
    var finding: GoStyleFinding
    var fix: GoStyleFix
    var version: Int
}

extension EditorController {
    // MARK: - Checks (debounced, off the main thread)

    /// Re-runs the style checks once typing pauses. Cheap to call on every edit.
    func scheduleStyleCheck(delay: TimeInterval = 0.4) {
        guard document.isGo else { return }
        style.timer?.invalidate()
        style.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runStyleCheck() }
        }
    }

    private func runStyleCheck() {
        let text = document.text
        guard (text as NSString).length < 2_000_000 else { return }
        let version = document.version
        let name = document.url.lastPathComponent
        style.task?.cancel()
        style.task = Task { [weak self] in
            let findings = await Task.detached(priority: .utility) { GoStyle.check(text, fileName: name) }.value
            guard let self, !Task.isCancelled, self.document.version == version else { return }
            self.style.version = version
            guard findings != self.style.findings else { return }
            self.style.findings = findings
            self.style.diagnostics = findings.map(\.diagnostic)
            // Same path as gopls diagnostics: underlines, gutter, Problems panel.
            NotificationCenter.default.post(name: .ogDiagnosticsChanged, object: self.context, userInfo: ["uri": self.document.uri])
        }
    }

    /// Guide link for an og diagnostic (hover card).
    nonisolated static func styleGuideLink(_ d: LSPDiagnostic) -> (title: String, url: URL)? {
        guard d.source == GoStyle.source, let id = d.code?.stringValue, let rule = GoStyleRules.rule(id: id),
              let url = URL(string: rule.url) else { return nil }
        return (rule.guide, url)
    }

    // MARK: - Quick fixes (⌥↩)

    /// Fixes for findings on `line`, computed on the current buffer so their ranges are exact.
    func styleFixes(atLine line: Int) -> [StyleFixChoice] {
        guard document.isGo else { return [] }
        let version = document.version
        return GoStyle.check(document.text, fileName: document.url.lastPathComponent)
            .filter { $0.range.start.line <= line && $0.range.end.line >= line }
            .compactMap { f in f.fix.map { StyleFixChoice(finding: f, fix: $0, version: version) } }
    }

    func addStyleFixItems(_ fixes: [StyleFixChoice], to menu: NSMenu) {
        style.pendingFixes = fixes
        for (i, f) in fixes.enumerated() {
            let item = NSMenuItem(title: "\(f.fix.title)  (\(f.finding.rule.guide))", action: #selector(styleFixClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
    }

    @objc private func styleFixClicked(_ sender: NSMenuItem) {
        guard sender.tag < style.pendingFixes.count else { return }
        applyStyleFix(style.pendingFixes[sender.tag])
    }

    func applyStyleFix(_ choice: StyleFixChoice) {
        guard document.version == choice.version else { context.setStatus("The file changed; try again."); return }
        switch choice.fix.kind {
        case .edits(let edits, let caret):
            applyTextEdits(edits, undoName: choice.fix.title)
            if let caret {
                let lines = TextLines(nsString: document.storage.string as NSString)
                textView.setSelectedRange(NSRange(location: lines.offset(for: caret), length: 0))
            }
        case .rename(let position, let newName):
            let lines = TextLines(nsString: document.storage.string as NSString)
            textView.setSelectedRange(NSRange(location: lines.offset(for: position), length: 0))
            startRename(suggested: newName)
        }
    }

    // MARK: - Completion templates

    /// Typing `//` or `func (` opens completion for og's templates (gopls offers nothing there).
    func styleTyped(_ s: String) {
        guard s == "/" || s == " " || s == "(" else { return }
        if GoStyleCompletions.shouldTrigger(in: document.storage.string as NSString, caret: caretOffset) {
            scheduleCompletion(delay: 0.05)
        }
    }

    /// og's style templates for the caret, as completion items placed above gopls' list.
    func styleCompletionItems(gopls: [LSPCompletionItem]) async -> (items: [LSPCompletionItem], inComment: Bool) {
        guard document.isGo else { return ([], false) }
        let caret = caretOffset
        let version = document.version
        var sources: [String] = []
        if GoStyleCompletions.wantsPackageSources(in: document.storage.string as NSString, caret: caret) {
            let dir = document.url.deletingLastPathComponent()
            let me = document.url.lastPathComponent
            let onDisk = await Task.detached(priority: .userInitiated) { Self.packageFiles(in: dir, excluding: me) }.value
            guard document.version == version, caretOffset == caret else { return ([], false) }
            // Open buffers win over their files on disk.
            sources = onDisk.map { context.documents.document(for: $0.url)?.text ?? $0.text }
        }
        // Scanning is whole-file work: do it off the main thread on the cached snapshot.
        let lines = document.lines
        let candidates = gopls.prefix(60).map { GoCompletionCandidate(label: $0.label, detail: $0.detail) }
        let fileName = document.url.lastPathComponent
        let pkg = sources
        let (found, inComment) = await Task.detached(priority: .userInitiated) {
            (GoStyleCompletions.items(in: lines.text, caret: caret, fileName: fileName, packageSources: pkg, candidates: candidates),
             GoStyleCompletions.isInCommentOrString(lines.text, caret: caret))
        }.value
        guard document.version == version, caretOffset == caret else { return ([], false) }
        return (found.map { Self.completionItem($0, lines: lines) }, inComment)
    }

    nonisolated static func packageFiles(in dir: URL, excluding name: String) -> [(url: URL, text: String)] {
        let includeTests = name.hasSuffix("_test.go")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".go") && $0 != name && (includeTests || !$0.hasSuffix("_test.go")) }
            .sorted()
            .prefix(200)
        var out: [(URL, String)] = []
        var total = 0
        for n in names {
            let url = dir.appendingPathComponent(n).standardizedFileURL
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            total += text.utf8.count
            if total > 8_000_000 { break }
            out.append((url, text))
        }
        return out
    }

    nonisolated static func completionItem(_ c: GoStyleCompletion, lines: TextLines) -> LSPCompletionItem {
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "}", with: "\\}")
        }
        let ns = c.text as NSString
        let snippet = esc(ns.substring(to: c.caretOffset)) + "$0" + esc(ns.substring(from: c.caretOffset))
        var item = LSPCompletionItem(label: c.label, detail: c.detail, snippet: snippet, filterText: c.filterText, sortText: c.sortText)
        // The range is computed on the buffer as it is now, so it stays valid while the user types on.
        item.textEdit = LSPTextEdit(range: lines.lspRange(for: c.replaceRange), newText: snippet)
        return item
    }

    /// After an og template: add the imports it uses (fmt, errors, cmp).
    func styleCompletionAccepted(_ item: LSPCompletionItem) {
        guard item.isLocal else { return }
        let text = item.plainInsertion.text
        guard text.contains("fmt.") || text.contains("errors.") || text.contains("cmp.") else { return }
        // After the edit's own (async) version bump, or organizeImports drops its answer as stale.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.organizeImports(quiet: true) }
        }
    }

    // MARK: - Headless driver

    func debugCompletionLabels() -> [String] {
        completion?.debugShown.map(\.label) ?? []
    }

    func debugAcceptCompletion(matching s: String) {
        guard let popup = completion else { print("accept: no popup"); return }
        let items = popup.debugShown
        guard let i = s.isEmpty ? (items.isEmpty ? nil : 0) : items.firstIndex(where: { $0.label.contains(s) }) else {
            print("accept: no item matching \(s)")
            return
        }
        print("accept: \(items[i].label)")
        popup.debugAccept(index: i)
    }
}

extension ProjectContext {
    /// gopls diagnostics plus og's style findings of the open editors (Problems panel).
    var allDiagnostics: [String: [LSPDiagnostic]] {
        var out = diagnostics
        var seen: Set<String> = []
        for ed in window?.editorArea.editors ?? [] where !ed.style.diagnostics.isEmpty {
            let uri = ed.document.uri
            guard seen.insert(uri).inserted else { continue }
            out[uri, default: []] += ed.style.diagnostics
        }
        return out
    }
}
