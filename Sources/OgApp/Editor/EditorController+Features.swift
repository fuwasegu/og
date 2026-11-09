import AppKit
import OgCore

extension EditorController {
    // MARK: - Typing hooks

    func textTyped(_ s: String) {
        guard document.isGo else { return }
        if completion?.isVisible == true {
            if s.count == 1, let c = s.unicodeScalars.first, CharacterSet.alphanumerics.contains(c) || s == "_" {
                completion?.refilter(text: document.storage.string as NSString, caret: caretOffset)
                scheduleCompletion(delay: 0.12)
            } else if s == "." {
                scheduleCompletion(delay: 0.02)
            } else {
                completion?.close()
            }
        } else if s == "." {
            scheduleCompletion(delay: 0.05)
        } else if s.count == 1, let c = s.unicodeScalars.first, CharacterSet.letters.contains(c) || s == "_" {
            if !isInsideStringOrComment(caretOffset) { scheduleCompletion(delay: 0.25) }
        }
        if s == "(" || s == "," { showSignatureHelp() }
        if s == ")" { info?.closeIf(kind: .signature) }
        scheduleGhost()
    }

    // MARK: - Completion

    func scheduleCompletion(delay: TimeInterval) {
        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestCompletion(explicit: false) }
        }
    }

    func requestCompletion(explicit: Bool) {
        guard document.isGo else { return }
        context.documents.syncToGopls(document)
        let uri = document.uri
        let pos = caretPosition
        let version = document.version
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            guard let items = await self.context.gopls.completion(uri: uri, position: pos), !Task.isCancelled else { return }
            // Spec LSP-2: a response for an older version only refilters; it never applies stale ranges.
            let stale = self.document.version != version
            if items.isEmpty { self.completion?.close(); return }
            if self.completion == nil { self.completion = CompletionPopup(editor: self) }
            self.completion?.show(items: items, text: self.document.storage.string as NSString, caret: self.caretOffset, staleRanges: stale, explicit: explicit)
        }
    }

    func acceptCompletion(_ item: LSPCompletionItem, staleRanges: Bool) {
        let ns = document.storage.string as NSString
        let caret = caretOffset
        var start = caret
        while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.contains(u) || u == "_" { start -= 1 }
        var range = NSRange(location: start, length: caret - start)
        if !staleRanges, let te = item.textEdit {
            let lines = TextLines(nsString: ns)
            let r = lines.nsRange(for: te.range)
            if r.location <= caret { range = NSRange(location: r.location, length: max(r.length, caret - r.location)) }
        }
        let (text, caretIn) = item.plainInsertion
        document.undoManager.beginUndoGrouping()
        textView.insertReplacing(range, with: text, caret: range.location + caretIn)
        if !item.additionalTextEdits.isEmpty && !staleRanges {
            applyTextEdits(item.additionalTextEdits, undoName: "Completion")
            // applyTextEdits keeps the caret relative; nothing else to do.
        }
        document.undoManager.endUndoGrouping()
        document.undoManager.setActionName("Completion")
        if text.hasSuffix("()") == false && text.contains("(") { showSignatureHelp() }
    }

    /// Keys while the completion popup is open. Returns true if consumed.
    func handlePopupKey(_ event: NSEvent) -> Bool {
        guard let popup = completion, popup.isVisible else { return false }
        switch event.keyCode {
        case 125: popup.move(1); return true          // down
        case 126: popup.move(-1); return true         // up
        case 121: popup.move(8); return true          // page down
        case 116: popup.move(-8); return true         // page up
        case 36, 76, 48:                              // return / enter / tab
            popup.acceptSelected(); return true
        case 53: popup.close(); return true           // esc
        default: return false
        }
    }

    func dismissTransientUI() -> Bool {
        var any = false
        if completion?.isVisible == true { completion?.close(); any = true }
        if info?.isVisible == true { info?.close(); any = true }
        return any
    }

    // MARK: - Tab: postfix > ghost text > indent (completion.fsl, ASSUME-2)

    func handleTab() -> Bool {
        let text = document.storage.string
        let caret = caretOffset
        if textView.selectedRange().length == 0, document.isGo, let exp = GoPostfix.expansion(in: text, caret: caret) {
            dismissGhost()
            textView.insertReplacing(exp.replaceRange, with: exp.text, caret: exp.replaceRange.location + exp.caretOffset)
            document.undoManager.setActionName("Postfix .\(exp.templateName)")
            return true
        }
        if let ghost = textView.ghostText, textView.ghostLocation == caret {
            textView.ghostText = nil
            textView.insertReplacing(NSRange(location: caret, length: 0), with: ghost, caret: caret + (ghost as NSString).length)
            return true
        }
        return false
    }

    // MARK: - Ghost text (local AI)

    static var aiEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "og.ai.enabled") as? Bool) ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "og.ai.enabled") }
    }

    static var aiEndpoint: String {
        get { UserDefaults.standard.string(forKey: "og.ai.endpoint") ?? "http://127.0.0.1:8080" }
        set { UserDefaults.standard.set(newValue, forKey: "og.ai.endpoint") }
    }

    func scheduleGhost() {
        ghostTimer?.invalidate()
        ghostTask?.cancel()
        guard Self.aiEnabled, document.isGo else { return }
        ghostTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestGhost() }
        }
    }

    func requestGhost() {
        guard completion?.isVisible != true, textView.selectedRange().length == 0,
              let url = URL(string: Self.aiEndpoint), let client = LocalCompletionClient(endpoint: url) else { return }
        let ns = document.storage.string as NSString
        let caret = caretOffset
        // Only at end of line (ignoring trailing whitespace / closers).
        let lines = TextLines(nsString: ns)
        let lr = lines.lineRange(lines.line(forOffset: caret))
        let rest = ns.substring(with: NSRange(location: caret, length: NSMaxRange(lr) - caret)).trimmingCharacters(in: CharacterSet(charactersIn: " \t)]}\"'`"))
        guard rest.isEmpty else { return }
        let prefix = ns.substring(to: caret)
        let suffix = ns.substring(from: caret)
        let version = document.version
        ghostTask?.cancel()
        ghostTask = Task { [weak self] in
            var acc = ""
            do {
                for try await chunk in client.complete(prefix: String(prefix.suffix(6000)), suffix: String(suffix.prefix(2000))) {
                    guard let self, !Task.isCancelled, self.document.version == version, self.caretOffset == caret else { return }
                    acc += chunk
                    self.textView.ghostLocation = caret
                    self.textView.ghostText = acc.trimmingCharacters(in: .newlines).isEmpty ? nil : acc
                }
            } catch {
                return
            }
        }
    }

    func dismissGhost() {
        ghostTask?.cancel()
        textView.ghostText = nil
    }

    // MARK: - Hover / signature / docs

    func showHover(at offset: Int, rect: NSRect) {
        guard document.isGo, completion?.isVisible != true else { return }
        let lines = TextLines(nsString: document.storage.string as NSString)
        let pos = lines.position(forOffset: offset)
        let line = pos.line
        let diags = diagnostics.filter { d in
            let r = lines.nsRange(for: d.range)
            return (r.location <= offset && offset <= NSMaxRange(r)) || (r.length == 0 && d.range.start.line == line)
        }
        let uri = document.uri
        context.documents.syncToGopls(document)
        Task { [weak self] in
            guard let self else { return }
            let hover = await self.context.gopls.hover(uri: uri, position: pos)
            var parts: [String] = diags.map { "⚠ " + $0.message }
            if let h = hover, !h.isEmpty { parts.append(Markdown.plain(h)) }
            guard !parts.isEmpty else { return }
            if self.info == nil { self.info = InfoPopup(editor: self) }
            self.info?.show(text: parts.joined(separator: "\n\n"), at: rect, in: self.textView, kind: .hover)
        }
    }

    func showDocumentationAtCaret() {
        let offset = caretOffset
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let glyph = lm.glyphIndexForCharacter(at: min(offset, max(0, document.storage.length - 1)))
        var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        showHover(at: offset, rect: rect)
    }

    func showSignatureHelp() {
        guard document.isGo else { return }
        context.documents.syncToGopls(document)
        let uri = document.uri
        let pos = caretPosition
        let offset = caretOffset
        Task { [weak self] in
            guard let self, let sig = await self.context.gopls.signatureHelp(uri: uri, position: pos) else { return }
            guard let lm = self.textView.layoutManager, let tc = self.textView.textContainer, self.document.storage.length > 0 else { return }
            let glyph = lm.glyphIndexForCharacter(at: min(offset, self.document.storage.length - 1))
            var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
            rect.origin.x += self.textView.textContainerOrigin.x
            rect.origin.y += self.textView.textContainerOrigin.y
            if self.info == nil { self.info = InfoPopup(editor: self) }
            self.info?.showSignature(sig, at: rect, in: self.textView)
        }
    }

    // MARK: - Navigation

    func gotoDeclaration() {
        guard document.isGo else { return }
        context.documents.syncToGopls(document)
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            let locs = await self.context.gopls.definition(uri: uri, position: pos)
            if let first = locs.first {
                // On the declaration itself → show usages (GoLand behavior).
                if first.uri == uri, first.range.start.line == pos.line,
                   first.range.start.character <= pos.character, pos.character <= first.range.end.character {
                    self.findUsages()
                } else {
                    self.context.window?.editorArea.pushHistory()
                    self.context.open(first)
                }
            } else {
                self.context.setStatus("No declaration found")
            }
        }
    }

    func gotoTypeDeclaration() {
        context.documents.syncToGopls(document)
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self, let first = await self.context.gopls.typeDefinition(uri: uri, position: pos).first else { return }
            self.context.window?.editorArea.pushHistory()
            self.context.open(first)
        }
    }

    func gotoImplementation() {
        context.documents.syncToGopls(document)
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            let locs = await self.context.gopls.implementation(uri: uri, position: pos)
            if locs.count == 1 {
                self.context.window?.editorArea.pushHistory()
                self.context.open(locs[0])
            } else if locs.isEmpty {
                self.context.setStatus("No implementations found")
            } else {
                self.chooseLocation(locs, title: "Implementations")
            }
        }
    }

    func findUsages() {
        context.documents.syncToGopls(document)
        let uri = document.uri, pos = caretPosition
        let word = wordAtCaret() ?? "symbol"
        Task { [weak self] in
            guard let self else { return }
            let locs = await self.context.gopls.references(uri: uri, position: pos)
            if locs.isEmpty { self.context.setStatus("No usages of \(word)"); return }
            self.context.window?.bottomPanel.findPanel.showResults(title: "Usages of \(word)", locations: locs)
            self.context.showPanel(.find)
        }
    }

    private func chooseLocation(_ locs: [LSPLocation], title: String) {
        let menu = NSMenu(title: title)
        for loc in locs.prefix(40) {
            guard let url = loc.url else { continue }
            let item = NSMenuItem(title: "\(context.relativePath(url)):\(loc.range.start.line + 1)", action: #selector(openLocationItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = loc.uri + "#" + "\(loc.range.start.line)#\(loc.range.start.character)"
            menu.addItem(item)
        }
        let caretRect = caretScreenRect()
        menu.popUp(positioning: nil, at: NSPoint(x: caretRect.minX, y: caretRect.maxY), in: textView)
    }

    @objc private func openLocationItem(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let parts = s.components(separatedBy: "#")
        guard parts.count == 3, let url = URL(string: parts[0]), let line = Int(parts[1]), let col = Int(parts[2]) else { return }
        context.window?.editorArea.pushHistory()
        context.open(url, line: line, column: col)
    }

    func caretScreenRect() -> NSRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, document.storage.length > 0 else { return .zero }
        let glyph = lm.glyphIndexForCharacter(at: min(caretOffset, document.storage.length - 1))
        var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    func wordAtCaret() -> String? {
        let r = textView.selectionRange(forProposedRange: NSRange(location: caretOffset, length: 0), granularity: .selectByWord)
        guard r.length > 0 else { return nil }
        let w = (document.storage.string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? nil : w
    }

    func gotoNextError(forward: Bool) {
        let lines = TextLines(nsString: document.storage.string as NSString)
        let offsets = diagnostics.map { lines.offset(for: $0.range.start) }.sorted()
        guard !offsets.isEmpty else { context.setStatus("No problems in this file"); return }
        let caret = caretOffset
        let target = forward ? (offsets.first { $0 > caret } ?? offsets[0]) : (offsets.last { $0 < caret } ?? offsets[offsets.count - 1])
        let p = lines.position(forOffset: target)
        reveal(line: p.line, column: p.character, length: 0)
        let rect = caretScreenRect()
        showHover(at: target, rect: rect)
    }

    // MARK: - Code actions (Alt-Enter)

    func showCodeActions() {
        guard document.isGo else { return }
        context.documents.syncToGopls(document)
        let uri = document.uri
        let lines = TextLines(nsString: document.storage.string as NSString)
        let sel = textView.selectedRange()
        let range = lines.lspRange(for: sel)
        let diags = diagnostics(atLine: range.start.line)
        let version = document.version
        Task { [weak self] in
            guard let self else { return }
            var actions = await self.context.gopls.codeActions(uri: uri, range: range, diagnostics: diags)
            actions.sort { ($0.isPreferred ? 0 : 1, $0.kind == "quickfix" ? 0 : 1) < ($1.isPreferred ? 0 : 1, $1.kind == "quickfix" ? 0 : 1) }
            let menu = NSMenu(title: "Actions")
            let header = NSMenuItem(title: "Context Actions", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, a) in actions.enumerated() {
                let item = NSMenuItem(title: a.title, action: #selector(self.runCodeAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
            // og's own Go intentions.
            menu.addItem(.separator())
            let tags = NSMenuItem(title: "Add json struct tags", action: #selector(self.menuStructTags), keyEquivalent: "")
            tags.target = self
            menu.addItem(tags)
            let tt = NSMenuItem(title: "Generate table-driven test", action: #selector(self.menuTableTest), keyEquivalent: "")
            tt.target = self
            menu.addItem(tt)
            self.pendingActions = (version, actions)
            let rect = self.caretScreenRect()
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self.textView)
        }
    }

    @objc private func runCodeAction(_ sender: NSMenuItem) {
        guard let pending = pendingActions, sender.tag < pending.actions.count else { return }
        let version = pending.version
        Task { [weak self] in
            guard let self else { return }
            var action = pending.actions[sender.tag]
            if action.edit == nil && action.command == nil {
                action = await self.context.gopls.resolve(codeAction: action)
            }
            if let edit = action.edit {
                // Spec LSP-2: never apply edits computed against an older version.
                guard self.document.version == version else { self.context.setStatus("The file changed; try again."); return }
                _ = self.context.applyWorkspaceEdit(edit)
            }
            if let cmd = action.command, cmd["command"]?.stringValue != nil {
                await self.context.gopls.execute(command: cmd)
            }
        }
    }

    @objc private func menuStructTags() { addStructTags() }
    @objc private func menuTableTest() { generateTableTest() }

    // MARK: - Format / imports

    func reformat() {
        context.documents.syncToGopls(document)
        let uri = document.uri
        let v = document.version
        Task { [weak self] in
            guard let self, let edits = await self.context.gopls.formatting(uri: uri), self.document.version == v else { return }
            if edits.isEmpty { self.context.setStatus("Already formatted"); return }
            self.applyTextEdits(edits, undoName: "Reformat Code")
        }
    }

    func organizeImports() {
        context.documents.syncToGopls(document)
        let uri = document.uri
        let v = document.version
        Task { [weak self] in
            guard let self else { return }
            let edits = await self.context.gopls.organizeImports(uri: uri)
            guard self.document.version == v else { return }
            if edits.isEmpty { self.context.setStatus("Imports are already optimized"); return }
            self.applyTextEdits(edits, undoName: "Optimize Imports")
        }
    }

    // MARK: - Go intentions

    func addStructTags() {
        let line = caretPosition.line
        guard let new = GoStructTags.apply(to: document.text, line: line, keys: ["json"], style: .snake) else {
            context.setStatus("Place the caret inside a struct to add tags")
            return
        }
        replaceText(with: new, undoName: "Add Struct Tags")
    }

    func generateTableTest() {
        let line = caretPosition.line
        guard let gen = GoTableTest.generate(source: document.text, fileName: document.url.lastPathComponent, line: line) else {
            context.setStatus("Place the caret on a function to generate a test")
            return
        }
        let testURL = document.url.deletingLastPathComponent().appendingPathComponent(gen.testFileName)
        if let doc = context.documents.document(for: testURL), let editor = context.open(testURL) {
            let end = doc.storage.length
            editor.textView.insertReplacing(NSRange(location: end, length: 0), with: gen.appendContent, caret: end)
            revealFunction(gen.functionName, in: editor)
            return
        }
        if FileManager.default.fileExists(atPath: testURL.path) {
            guard let editor = context.open(testURL) else { return }
            let end = editor.document.storage.length
            editor.textView.insertReplacing(NSRange(location: end, length: 0), with: gen.appendContent, caret: end)
            revealFunction(gen.functionName, in: editor)
        } else {
            do {
                try Data(gen.newFileContent.utf8).write(to: testURL, options: .atomic)
            } catch {
                context.setStatus("Could not create \(gen.testFileName): \(error.localizedDescription)")
                return
            }
            if let editor = context.open(testURL) { revealFunction(gen.functionName, in: editor) }
        }
        context.setStatus("Generated \(gen.functionName)")
    }

    private func revealFunction(_ name: String, in editor: EditorController) {
        let ns = editor.document.storage.string as NSString
        let r = ns.range(of: "func \(name)(")
        guard r.location != NSNotFound else { return }
        let p = TextLines(nsString: ns).position(forOffset: r.location)
        editor.reveal(line: p.line, column: 5, length: (name as NSString).length)
    }

    // MARK: - Rename (refactor.fsl)

    func startRename() {
        guard document.isGo else { return }
        guard context.saveAll() else { context.setStatus("Save all files before renaming"); return }
        context.documents.syncToGopls(document)
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            guard let prep = await self.context.gopls.prepareRename(uri: uri, position: pos) else {
                self.context.setStatus("This element can't be renamed")
                return
            }
            let ns = self.document.storage.string as NSString
            let oldName = prep.placeholder ?? ns.substring(with: TextLines(nsString: ns).nsRange(for: prep.range))
            guard let window = self.view.window else { return }
            RenameSheet.present(on: window, editor: self, oldName: oldName, uri: uri, position: pos)
        }
    }
}

/// Converts gopls markdown hover to readable plain text.
enum Markdown {
    static func plain(_ md: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            var l = line
            if !inCode {
                l = l.replacingOccurrences(of: "\\", with: "")
                // [text](link) -> text
                while let open = l.range(of: "["), let mid = l.range(of: "](", range: open.upperBound..<l.endIndex),
                      let close = l.range(of: ")", range: mid.upperBound..<l.endIndex) {
                    let text = l[open.upperBound..<mid.lowerBound]
                    l.replaceSubrange(open.lowerBound..<close.upperBound, with: text)
                }
                l = l.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            }
            out.append(l)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
