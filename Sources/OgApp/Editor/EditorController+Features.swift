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
        let flushDoc = document
        let uri = document.uri
        let pos = caretPosition
        let version = document.version
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            guard var items = await self.context.gopls.completion(uri: uri, position: pos), !Task.isCancelled else { return }
            // Spec LSP-2: a response for an older version only refilters; it never applies stale ranges.
            let stale = self.document.version != version
            if let err = GoErrCheck.suggestion(in: self.document.storage.string as NSString, caret: self.caretOffset) {
                items.insert(Self.errCheckItem(err), at: 0)
            }
            if items.isEmpty { self.completion?.close(); return }
            if self.completion == nil { self.completion = CompletionPopup(editor: self) }
            self.completion?.show(items: items, text: self.document.storage.string as NSString, caret: self.caretOffset, staleRanges: stale, explicit: explicit)
        }
    }

    /// `if err != nil { … }` as the first completion right after an error assignment.
    static func errCheckItem(_ s: GoErrCheckSuggestion) -> LSPCompletionItem {
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "}", with: "\\}")
        }
        let ns = s.text as NSString
        let snippet = esc(ns.substring(to: s.caretOffset)) + "$0" + esc(ns.substring(from: s.caretOffset))
        let ret = s.text.components(separatedBy: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
        return LSPCompletionItem(label: "if \(s.variable) != nil { \(ret) }", detail: "error check", snippet: snippet,
                                 filterText: "if", sortText: "!")
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
            if exp.templateName == "switch", expandSwitchWithCases(exp) { return true }
            textView.insertReplacing(exp.replaceRange, with: exp.text, caret: exp.replaceRange.location + exp.caretOffset)
            document.undoManager.setActionName("Postfix .\(exp.templateName)")
            if exp.text.contains("fmt.") { organizeImports(quiet: true) }
            return true
        }
        if let ghost = textView.ghostText, textView.ghostLocation == caret {
            textView.ghostText = nil
            textView.insertReplacing(NSRange(location: caret, length: 0), with: ghost, caret: caret + (ghost as NSString).length)
            return true
        }
        return false
    }

    /// `.switch` on an enum-like value (named type + consts): insert an empty switch and let
    /// gopls fill every case (type-checked, so only real enums qualify). Otherwise the
    /// plain `case :` template is put back.
    private func expandSwitchWithCases(_ exp: PostfixExpansion) -> Bool {
        let ns = exp.text as NSString
        let brace = ns.range(of: "{")
        let lastNL = ns.range(of: "\n", options: .backwards)
        guard brace.location != NSNotFound, lastNL.location != NSNotFound else { return false }
        let indent = ns.substring(with: NSRange(location: lastNL.location + 1, length: ns.length - lastNL.location - 2))
        let empty = ns.substring(to: NSMaxRange(brace)) + "\n" + indent + "}"
        let start = exp.replaceRange.location
        let bodyAt = start + NSMaxRange(brace)
        textView.insertReplacing(exp.replaceRange, with: empty, caret: bodyAt)
        document.undoManager.setActionName("Postfix .switch")
        let doc = document, uri = document.uri
        let lines = TextLines(nsString: doc.storage.string as NSString)
        let at = lines.position(forOffset: start)
        let range = LSPRange(start: at, end: at)
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(doc)
            let version = doc.version
            var fill = await self.context.gopls.codeActions(uri: uri, range: range, diagnostics: [], only: ["refactor.rewrite.fillSwitch"])
                .first { $0.kind == "refactor.rewrite.fillSwitch" }
            if var a = fill, a.edit == nil { a = await self.context.gopls.resolve(codeAction: a); fill = a }
            guard doc.version == version, self.caretOffset == bodyAt else { return }  // the user moved on
            if let edit = fill?.edit {
                _ = self.context.applyWorkspaceEdit(edit)
                // Caret at the end of the first case line.
                let text = doc.storage.string as NSString
                let c = text.range(of: "case ", range: NSRange(location: start, length: text.length - start))
                if c.location != NSNotFound {
                    let colon = text.range(of: ":", range: NSRange(location: c.location, length: text.length - c.location))
                    if colon.location != NSNotFound { self.textView.setSelectedRange(NSRange(location: colon.location + 1, length: 0)) }
                }
            } else {
                let filler = "\n" + indent + "case :"
                self.textView.insertReplacing(NSRange(location: bodyAt, length: 0), with: filler, caret: bodyAt + (filler as NSString).length - 1)
            }
        }
        return true
    }

    // MARK: - Ghost text (local AI)

    static var aiEnabled: Bool { ModelServerManager.shared.enabled }

    func scheduleGhost() {
        ghostTimer?.invalidate()
        ghostTask?.cancel()
        guard Self.aiEnabled, document.isGo else { return }
        ghostTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestGhost() }
        }
    }

    func requestGhost() {
        // ASSUME-3: only while the app-owned server is ready.
        guard completion?.isVisible != true, textView.selectedRange().length == 0,
              let client = ModelServerManager.shared.client else { return }
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

    /// Mouse moved over a glyph. Timing is per identifier, not per character, so moving
    /// inside one word does not restart the delay. The gopls request starts early (prefetch)
    /// and the card appears after a short delay, or at once when a card is already open.
    func hoverMoved(to offset: Int, rect: NSRect) {
        guard document.isGo, completion?.isVisible != true else { return }
        let word = identifierRange(at: offset) ?? NSRange(location: offset, length: 1)
        if word == hoverWord { return }
        hoverWord = word
        hoverTimer?.invalidate()
        let switching = info?.isVisible == true && info?.kind == .hover
        let started = Date()
        let minDelay: TimeInterval = switching ? 0 : 0.3
        // Short debounce so sweeping across many words does not flood gopls.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: switching ? 0.15 : 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoverWord == word else { return }
                self.showHover(at: word.location, rect: rect, notBefore: started.addingTimeInterval(minDelay), word: word)
            }
        }
    }

    func hoverLeft() {
        hoverTimer?.invalidate()
        hoverWord = nil
    }

    /// Module paths that live in this workspace: the file's own module plus go.work `use` entries.
    /// Their packages are usually not published, so pkg.go.dev links to them are hidden.
    func localModulePaths() -> [String] {
        var out: [String] = []
        if let m = GoTestLocator.findModule(from: document.url.deletingLastPathComponent()) { out.append(m.path) }
        if let work = try? String(contentsOf: context.root.appendingPathComponent("go.work"), encoding: .utf8) {
            var inUse = false
            for raw in work.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
                var dir: String?
                if inUse {
                    if line.hasPrefix(")") { inUse = false } else if !line.isEmpty { dir = line }
                } else if line.hasPrefix("use") {
                    let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("(") { inUse = true } else if !rest.isEmpty { dir = rest }
                }
                if let dir, let m = GoTestLocator.findModule(from: context.root.appendingPathComponent(dir.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")))) {
                    out.append(m.path)
                }
            }
        }
        return out
    }

    private func identifierRange(at offset: Int) -> NSRange? {
        let ns = document.storage.string as NSString
        func isIdent(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        guard offset < ns.length, isIdent(ns.character(at: offset)) else { return nil }
        var lo = offset, hi = offset + 1
        while lo > 0, isIdent(ns.character(at: lo - 1)) { lo -= 1 }
        while hi < ns.length, isIdent(ns.character(at: hi)) { hi += 1 }
        return NSRange(location: lo, length: hi - lo)
    }

    /// gopls hover text, shared by prefetch and display; reset whenever the buffer changes.
    private func hoverAnswer(at offset: Int) -> Task<HoverInfo, Never> {
        if hoverCacheVersion != document.version {
            hoverCache.removeAll()
            hoverCacheVersion = document.version
        }
        if let t = hoverCache[offset] { return t }
        let lines = TextLines(nsString: document.storage.string as NSString)
        let pos = lines.position(forOffset: offset)
        let uri = document.uri, doc = document, ctx = context
        let t = Task { @MainActor () -> HoverInfo in
            await ctx.documents.flush(doc)
            let md = await ctx.gopls.hover(uri: uri, position: pos)
            var info = HoverInfo(markdown: md)
            // Enum-like type: list its constants from the declaring package.
            if let md, let name = HoverInfo.declaredTypeName(md),
               let def = await ctx.gopls.definition(uri: uri, position: pos).first, let file = def.url {
                info.constants = await Task.detached { HoverInfo.constants(ofType: name, nextTo: file) }.value
            }
            return info
        }
        hoverCache[offset] = t
        return t
    }

    func showHover(at offset: Int, rect: NSRect, notBefore: Date? = nil, word: NSRange? = nil) {
        guard document.isGo, completion?.isVisible != true else { return }
        let lines = TextLines(nsString: document.storage.string as NSString)
        let line = lines.position(forOffset: offset).line
        let span = word ?? NSRange(location: offset, length: 0)
        let diags = diagnostics.filter { d in
            let r = lines.nsRange(for: d.range)
            return (r.location <= NSMaxRange(span) && offset <= NSMaxRange(r)) || (r.length == 0 && d.range.start.line == line)
        }
        let answer = hoverAnswer(at: offset)
        Task { [weak self] in
            let hover = await answer.value
            if let notBefore, notBefore.timeIntervalSinceNow > 0 {
                try? await Task.sleep(nanoseconds: UInt64(notBefore.timeIntervalSinceNow * 1_000_000_000))
            }
            guard let self else { return }
            if let word, self.hoverWord != word { return }  // the mouse moved on
            let card = Markdown.hoverCard(diagnostics: diags.map(\.message), markdown: hover.markdown ?? "",
                                          constants: hover.constants, localModules: self.localModulePaths())
            guard card.length > 0 else { return }
            if self.info == nil { self.info = InfoPopup(editor: self) }
            self.info?.show(attributed: card, at: rect, in: self.textView, kind: .hover)
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
        let flushDoc = document
        let uri = document.uri
        let pos = caretPosition
        let offset = caretOffset
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            guard let sig = await self.context.gopls.signatureHelp(uri: uri, position: pos) else { return }
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
        let flushDoc = document
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
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
        let flushDoc = document
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            guard let first = await self.context.gopls.typeDefinition(uri: uri, position: pos).first else { return }
            self.context.window?.editorArea.pushHistory()
            self.context.open(first)
        }
    }

    func gotoImplementation() {
        let flushDoc = document
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
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
        let flushDoc = document
        let uri = document.uri, pos = caretPosition
        let word = wordAtCaret() ?? "symbol"
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
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

    /// Identifier at (or just before) the caret.
    func wordAtCaret() -> String? {
        let ns = document.storage.string as NSString
        func isIdent(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "_"
        }
        var start = caretOffset
        if !isIdent(start) && isIdent(start - 1) { start -= 1 }
        guard isIdent(start) else { return nil }
        var end = start
        while isIdent(start - 1) { start -= 1 }
        while isIdent(end) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
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
        let flushDoc = document
        let uri = document.uri
        let lines = TextLines(nsString: document.storage.string as NSString)
        let sel = textView.selectedRange()
        let range = lines.lspRange(for: sel)
        let diags = diagnostics(atLine: range.start.line)
        let version = document.version
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            var actions = await self.context.gopls.codeActions(uri: uri, range: range, diagnostics: diags)
            actions.sort { Self.actionRank($0) < Self.actionRank($1) }
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

    /// Quick fixes, then fill switch/struct, then other refactors, then source/doc browsing.
    static func actionRank(_ a: LSPCodeAction) -> Int {
        let k = a.kind ?? ""
        if a.isPreferred { return 0 }
        if k.hasPrefix("quickfix") { return 1 }
        if k == "refactor.rewrite.fillSwitch" || k == "refactor.rewrite.fillStruct" { return 2 }
        if k.hasPrefix("refactor") { return 3 }
        if k.hasPrefix("gopls.doc") { return 6 }
        if k.hasPrefix("source") { return 5 }
        return 4
    }

    /// Headless driver: print the actions at the caret, optionally apply one by title.
    func debugCodeActions(apply match: String?) {
        let lines = TextLines(nsString: document.storage.string as NSString)
        let range = lines.lspRange(for: textView.selectedRange())
        let uri = document.uri, doc = document, version = document.version
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(doc)
            let actions = await self.context.gopls.codeActions(uri: uri, range: range, diagnostics: self.diagnostics(atLine: range.start.line))
            print("actions: " + actions.map { "\($0.title) [\($0.kind ?? "")]" }.joined(separator: " | "))
            guard let match, let i = actions.firstIndex(where: { $0.title.contains(match) }) else { return }
            self.pendingActions = (version, actions)
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.tag = i
            self.runCodeAction(item)
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
        let flushDoc = document
        let uri = document.uri
        let v = document.version
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            guard let edits = await self.context.gopls.formatting(uri: uri), self.document.version == v else { return }
            if edits.isEmpty { self.context.setStatus("Already formatted"); return }
            self.applyTextEdits(edits, undoName: "Reformat Code")
        }
    }

    func organizeImports(quiet: Bool = false) {
        let flushDoc = document
        let uri = document.uri
        let v = document.version
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
            let edits = await self.context.gopls.organizeImports(uri: uri)
            guard self.document.version == v else { return }
            if edits.isEmpty { if !quiet { self.context.setStatus("Imports are already optimized") }; return }
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
            editor.organizeImports(quiet: true)
            return
        }
        if FileManager.default.fileExists(atPath: testURL.path) {
            guard let editor = context.open(testURL) else { return }
            let end = editor.document.storage.length
            editor.textView.insertReplacing(NSRange(location: end, length: 0), with: gen.appendContent, caret: end)
            revealFunction(gen.functionName, in: editor)
            editor.organizeImports(quiet: true)
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
        let flushDoc = document
        let uri = document.uri, pos = caretPosition
        Task { [weak self] in
            guard let self else { return }
            await self.context.documents.flush(flushDoc)
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

/// Renders gopls hover markdown: Go code blocks are syntax highlighted, prose uses the UI font.
@MainActor
enum Markdown {
    /// True for a pkg.go.dev URL that points into one of `modules`.
    static func isLocalDocLink(_ url: URL, modules: [String]) -> Bool {
        guard url.host == "pkg.go.dev" else { return false }
        let path = String(url.path.drop { $0 == "/" })
        return modules.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func hoverCard(diagnostics: [String], markdown: String, constants: [GoEnumConstant] = [], localModules: [String] = []) -> NSAttributedString {
        let isLocal: (URL) -> Bool = { isLocalDocLink($0, modules: localModules) }
        let out = NSMutableAttributedString()
        let size = max(11, Theme.fontSize - 1)
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let prose = NSFont.systemFont(ofSize: size)
        func gap() { if out.length > 0 { out.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 4)])) } }
        for d in diagnostics {
            gap()
            out.append(NSAttributedString(string: "⚠ " + d, attributes: [.font: prose, .foregroundColor: Theme.warning]))
        }
        var code: [String] = []
        var text: [String] = []
        var shownConstants = false
        var inCode = false
        func flushText() {
            let body = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeAll()
            guard !body.isEmpty else { return }
            gap()
            out.append(inline(body, prose: prose, mono: mono, isLocal: isLocal))
        }
        var indented: [String] = []
        func flushIndented() {
            let src = indented.joined(separator: "\n").trimmingCharacters(in: .newlines)
            indented.removeAll()
            guard !src.isEmpty else { return }
            gap()
            out.append(highlighted(src, font: mono))
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    let src = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !src.isEmpty { gap(); out.append(highlighted(src, font: mono)) }
                    code.removeAll()
                    if !constants.isEmpty, !shownConstants {
                        shownConstants = true
                        let shown = constants.prefix(40)
                        let width = shown.map { ($0.name as NSString).length }.max() ?? 0
                        var body = shown.map { c in
                            c.value.map { c.name.padding(toLength: width, withPad: " ", startingAt: 0) + " = " + $0 } ?? c.name
                        }.joined(separator: "\n")
                        if constants.count > shown.count { body += "\n// … \(constants.count - shown.count) more" }
                        gap()
                        out.append(NSAttributedString(string: "\(constants.count) values\n", attributes: [.font: NSFont.systemFont(ofSize: size - 1), .foregroundColor: Theme.secondaryText]))
                        out.append(highlighted(body, font: mono))
                    }
                } else {
                    flushText()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            // Indented block (Go doc example code) -> highlighted code.
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                flushText()
                indented.append(line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(4)))
                continue
            }
            if !indented.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty { indented.append(""); continue }
            flushIndented()
            if line.hasPrefix("#") {
                flushText()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                gap()
                out.append(NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: size + 1), .foregroundColor: Theme.text]))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "---" { flushText(); continue }
            // "[`pkg.Name` on pkg.go.dev](…)" for a workspace package: there is no such page.
            if line.contains(" on pkg.go.dev]("), let open = line.range(of: "]("), let close = line.range(of: ")", options: .backwards),
               open.upperBound <= close.lowerBound, let url = URL(string: String(line[open.upperBound..<close.lowerBound])), isLocal(url) {
                continue
            }
            text.append(line)
        }
        flushIndented()
        flushText()
        return out
    }

    /// Go source colored with the editor's lexer and theme.
    static func highlighted(_ src: String, font: NSFont) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: src, attributes: [.font: font, .foregroundColor: Theme.text])
        let ns = src as NSString
        var qualifiedDecl = false
        for t in GoLexer.tokenize(ns) where NSMaxRange(t.range) <= attr.length {
            var kind = t.kind
            // Hover signatures read `func pkg.Name(`: color Name, not pkg.
            if kind == .funcDecl, NSMaxRange(t.range) < ns.length, ns.character(at: NSMaxRange(t.range)) == 46 {
                qualifiedDecl = true
                continue
            }
            if qualifiedDecl, kind == .function { kind = .funcDecl }
            qualifiedDecl = false
            if let c = Theme.color(for: kind) { attr.addAttribute(.foregroundColor, value: c, range: t.range) }
        }
        return attr
    }

    /// Prose with `code`, **bold**, [links](…) and backslash escapes.
    static func inline(_ md: String, prose: NSFont, mono: NSFont, isLocal: (URL) -> Bool = { _ in false }) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: prose, .foregroundColor: Theme.text]
        var buf = ""
        var bold = false
        func emit(_ s: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            var a = base
            if bold { a[.font] = NSFont.boldSystemFont(ofSize: prose.pointSize) }
            for (k, v) in extra { a[k] = v }
            out.append(NSAttributedString(string: s, attributes: a))
        }
        func flush() { if !buf.isEmpty { emit(buf); buf = "" } }
        let chars = Array(md)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                buf.append(chars[i + 1]); i += 2; continue
            }
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                flush()
                emit(String(chars[(i + 1)..<end]), [.font: mono, .foregroundColor: Theme.type])
                i = end + 1; continue
            }
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                flush(); bold.toggle(); i += 2; continue
            }
            if c == "[", let mid = chars[(i + 1)...].firstIndex(of: "]"), mid + 1 < chars.count, chars[mid + 1] == "(",
               let close = chars[(mid + 2)...].firstIndex(of: ")") {
                flush()
                let label = String(chars[(i + 1)..<mid]).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\\", with: "")
                var extra: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.function]
                if let url = URL(string: String(chars[(mid + 2)..<close])), url.scheme == "https" || url.scheme == "http" {
                    if isLocal(url) { extra[.foregroundColor] = Theme.type } else { extra[.link] = url }
                }
                emit(label, extra)
                i = close + 1; continue
            }
            buf.append(c); i += 1
        }
        flush()
        return out
    }
}

/// gopls hover plus og's own additions (constants of an enum-like type).
struct HoverInfo: Sendable {
    var markdown: String?
    var constants: [GoEnumConstant] = []

    /// `T` when the hover's code block declares a defined (non-struct, non-interface, non-alias) type.
    static func declaredTypeName(_ md: String) -> String? {
        guard let line = md.components(separatedBy: "\n").first(where: { $0.hasPrefix("type ") }) else { return nil }
        let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].contains("[") else { return nil }
        let rest = parts[1]
        if rest.hasPrefix("struct") || rest.hasPrefix("interface") || rest.hasPrefix("=") || rest.hasPrefix("func") { return nil }
        return parts[0]
    }

    /// Constants of `type` declared in the package (non-test files) of `file`, in source order.
    static func constants(ofType type: String, nextTo file: URL) -> [GoEnumConstant] {
        let dir = file.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        // The declaring file first, then the rest alphabetically.
        let ordered = [file.lastPathComponent] + names.filter { $0 != file.lastPathComponent }.sorted()
        var out: [GoEnumConstant] = []
        for name in ordered where names.contains(name) {
            guard let src = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            out += GoEnumScanner.constants(ofType: type, in: src)
        }
        return out
    }
}
