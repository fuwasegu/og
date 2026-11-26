import AppKit
import OgCore

/// Bottom "Docs" tool window for offline Go documentation lookup (Issue #18, Q-5).
///
/// 100% AppKit (no WebView, NFR-3). Displays short grounded cards with signature,
/// minimal compilable example, citation, Go version, and a version-gated "Insert" action.
@MainActor
final class DocsPanel: NSViewController, NSSearchFieldDelegate {
    let context: ProjectContext

    private let queryField = NSSearchField()
    private let versionPopup = NSPopUpButton()
    private let modeLabel = NSTextField(labelWithString: "")
    private let licenseButton = NSButton(title: "BSD License", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    private var explicitVersion: GoVersion?
    private var lastAnswer: DocsAnswer?
    private var searchTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    // MARK: - Public entry point

    func focusSearch(prefill: String? = nil) {
        _ = view
        if let prefill, !prefill.isEmpty {
            queryField.stringValue = prefill
            runSearch()
        }
        view.window?.makeFirstResponder(queryField)
        queryField.currentEditor()?.selectAll(nil)
    }

    // MARK: - View lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        Theme.paint(root, background: Theme.panelBackground)

        queryField.placeholderString = "Go の調べ物（例: ファイルを1行ずつ読みたい / for ループの書き方 / json.Encoder）"
        queryField.font = Theme.uiFont
        queryField.delegate = self
        queryField.sendsSearchStringImmediately = false
        queryField.sendsWholeSearchString = true
        queryField.target = self
        queryField.action = #selector(querySubmitted)

        versionPopup.controlSize = .small
        versionPopup.font = Theme.smallFont
        versionPopup.target = self
        versionPopup.action = #selector(versionChanged)

        modeLabel.font = Theme.smallFont
        modeLabel.textColor = Theme.secondaryText
        modeLabel.lineBreakMode = .byTruncatingTail

        licenseButton.bezelStyle = .recessed
        licenseButton.isBordered = false
        licenseButton.font = Theme.smallFont
        licenseButton.contentTintColor = Theme.secondaryText
        licenseButton.target = self
        licenseButton.action = #selector(showLicense)

        let topBar = NSStackView(views: [queryField, versionPopup, modeLabel, licenseButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        versionPopup.setContentHuggingPriority(.required, for: .horizontal)
        modeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        licenseButton.setContentHuggingPriority(.required, for: .horizontal)

        let sep = NSBox()
        sep.boxType = .separator

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)

        let clipDoc = DocsFlippedView()
        clipDoc.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        clipDoc.addSubview(contentStack)

        scrollView.documentView = clipDoc
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.borderType = .noBorder

        for v in [topBar, sep, scrollView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sep.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            clipDoc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            clipDoc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            clipDoc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            clipDoc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: clipDoc.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: clipDoc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clipDoc.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: clipDoc.bottomAnchor)
        ])

        view = root

        // M-4: separate pack/toggle changes from batch progress updates so progress never spams searches.
        observers.append(NotificationCenter.default.addObserver(forName: .ogDocsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVersionPopup()
                if let q = self?.queryField.stringValue, !q.trimmingCharacters(in: .whitespaces).isEmpty {
                    self?.runSearch()
                } else {
                    self?.renderIdleOrStatus()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .ogDocsBatchProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVersionPopup()
                self?.updateModeLabelForProgress()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .ogDocsServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateModeLabelForProgress()
            }
        })
        refreshVersionPopup()
        renderIdleOrStatus()
    }

    private func updateModeLabelForProgress() {
        if let prog = DocsManager.shared.activeProgress,
           prog.phase == .extracting || prog.phase == .buildingFTS || prog.phase == .embedding || prog.phase == .activating {
            modeLabel.stringValue = "Indexing go\(prog.goVersion) (\(prog.processedChunks)/\(prog.totalChunks))"
        } else if let a = lastAnswer {
            modeLabel.stringValue = a.searchMode.shortLabel
        } else {
            modeLabel.stringValue = idleModeText()
        }
    }

    private func idleModeText() -> String {
        guard DocsManager.shared.enabled else { return "Off" }
        switch DocsServerManager.shared.phase {
        case .ready:
            return DocsServerManager.shared.rerankReady ? "MLX Ready (Embed + Rerank)" : "MLX Ready (Embed)"
        case .starting(let detail):
            return "MLX: \(detail)"
        case .failed:
            return "FTS5 のみ（MLX 停止）"
        case .off:
            return "FTS5 のみ（ローカル完結）"
        }
    }

    // MARK: - Actions

    @objc private func querySubmitted() {
        runSearch()
    }

    @objc private func versionChanged() {
        let title = versionPopup.titleOfSelectedItem ?? ""
        if title.hasPrefix("Auto") {
            explicitVersion = nil
        } else {
            explicitVersion = GoVersion(parsing: title)
        }
        if !queryField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            runSearch()
        }
    }

    @objc private func enableDocsClicked() {
        DocsManager.shared.enabled = true
        renderIdleOrStatus()
    }

    @objc private func installRequestedPackClicked(_ sender: NSButton) {
        guard let ver = sender.identifier?.rawValue, !ver.isEmpty else { return }
        DocsManager.shared.startBundledPackIngestion(goVersion: ver)
    }

    @objc private func switchToInstalledVersionClicked(_ sender: NSButton) {
        guard let verStr = sender.identifier?.rawValue, let v = GoVersion(parsing: verStr) else { return }
        explicitVersion = v
        refreshVersionPopup()
        runSearch()
    }

    @objc private func insertCardClicked(_ sender: NSButton) {
        let index = sender.tag
        guard let answer = lastAnswer, answer.cards.indices.contains(index) else { return }
        let card = answer.cards[index]
        let targetVer = answer.targetVersion
        insertTask?.cancel()
        insertTask = Task { [weak self] in
            _ = await self?.insertCardAsync(card, targetVersion: targetVer)
        }
    }

    @objc private func copyCardClicked(_ sender: NSButton) {
        let index = sender.tag
        guard let answer = lastAnswer, answer.cards.indices.contains(index),
              let code = answer.cards[index].example else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        context.setStatus("Copied snippet from \(answer.cards[index].citation)")
    }

    @objc private func showLicense() {
        let alert = NSAlert()
        alert.messageText = "Go Documentation License (BSD-3-Clause)"
        alert.informativeText = DocsLicense.goBSD3Clause
        alert.addButton(withTitle: "OK")
        if let w = view.window {
            alert.beginSheetModal(for: w, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Search & Insertion

    private func runSearch() {
        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            lastAnswer = nil
            renderIdleOrStatus()
            return
        }
        searchTask?.cancel()
        let root = context.root
        let overrideVer = explicitVersion
        let editorCtx = currentEditorContext()

        searchTask = Task { [weak self] in
            let answer = await DocsManager.shared.search(
                query: query,
                projectRoot: root,
                explicitVersion: overrideVer,
                editorContext: editorCtx
            )
            guard !Task.isCancelled, let self else { return }
            self.lastAnswer = answer
            self.render(answer: answer)
        }
    }

    private func currentEditorContext() -> DocsEditorContext? {
        guard let ed = context.currentEditor, ed.document.isGo else { return nil }
        return DocsEditorContext.parse(goSource: ed.document.text)
    }

    /// M-3 & L-10: checks `.isGo`, runs `gofmt` off the main thread, then inserts safely via UTF-16 ranges.
    @discardableResult
    private func insertCardAsync(_ card: DocsAnswerCard, targetVersion: GoVersion?) async -> Bool {
        guard let editor = context.currentEditor else {
            context.setStatus("Open a Go file to insert the snippet.")
            return false
        }
        guard editor.document.isGo else {
            context.setStatus("Switch to a Go (.go) file before inserting a Go Docs snippet.")
            return false
        }
        guard let ver = targetVersion ?? GoVersion(parsing: card.goVersion) else {
            context.setStatus("Snippet cannot be inserted for unknown Go version.")
            return false
        }
        let docVersionBefore = editor.document.version
        guard let prepared = await DocsCodeInserter.prepareSnippetAsync(from: card, targetVersion: ver) else {
            context.setStatus("Snippet cannot be inserted for \(ver.description).")
            return false
        }
        guard !Task.isCancelled else { return false }
        guard context.currentEditor === editor, editor.document.version == docVersionBefore else {
            context.setStatus("Editor changed while formatting snippet; please try inserting again.")
            return false
        }
        // UTF-16 safe insertion via existing editor path (AGENTS.md §4-2), matching surrounding indentation.
        let range = editor.textView.selectedRange()
        let indent = indentationForInsertion(in: editor.document.storage.string, atUTF16Offset: range.location)
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
        context.setStatus("Inserted snippet (\(card.citation), go\(card.goVersion))\(fmtNote)")
        return true
    }

    private func indentationForInsertion(in text: String, atUTF16Offset offset: Int) -> String {
        let ns = text as NSString
        let clamped = max(0, min(offset, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let currentLine = ns.substring(with: lineRange)
        let leading = String(currentLine.prefix(while: { $0 == "\t" || $0 == " " }))
        if !leading.isEmpty { return leading }
        // If the current line is blank, inherit indentation from the nearest preceding non-empty line.
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

    // MARK: - Rendering

    private func refreshVersionPopup() {
        // S-2: use cached async toolchain detection so the main thread never blocks on `go version`.
        let cachedToolchain = DocsManager.shared.detectedToolchainVersion
        let detected = GoVersionResolver.resolve(projectRoot: context.root, toolchainVersionProvider: { cachedToolchain })
        let autoLabel = detected.map { "Auto (\($0.version.description))" } ?? "Auto (go\(BundledGoCorpus.defaultVersion))"
        versionPopup.removeAllItems()
        versionPopup.addItem(withTitle: autoLabel)
        for pack in DocsManager.shared.installedPacks {
            versionPopup.addItem(withTitle: "go\(pack.goVersion)")
        }
        if let exp = explicitVersion, versionPopup.itemTitles.contains("go\(exp.minorKey)") {
            versionPopup.selectItem(withTitle: "go\(exp.minorKey)")
        } else {
            versionPopup.selectItem(at: 0)
        }
    }

    private func clearContent() {
        for v in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func renderIdleOrStatus() {
        clearContent()
        let mgr = DocsManager.shared
        if !mgr.enabled {
            modeLabel.stringValue = "Off"
            let msg = label("オフライン Go 調べ物機能はオフです（ローカル完結・通信なし）。", color: Theme.secondaryText, size: 12)
            let btn = NSButton(title: "Go Docs を有効にする", target: self, action: #selector(enableDocsClicked))
            btn.bezelStyle = .rounded
            contentStack.addArrangedSubview(msg)
            contentStack.addArrangedSubview(btn)
            return
        }
        if let prog = mgr.activeProgress, prog.phase != .completed && prog.phase != .idle && prog.phase != .cancelled {
            modeLabel.stringValue = "Indexing (\(prog.processedChunks)/\(prog.totalChunks))"
            contentStack.addArrangedSubview(label(
                "Go \(prog.goVersion) パック構築中: \(prog.phase.rawValue) (\(prog.processedChunks)/\(prog.totalChunks)) — FTS 検索は利用可能です。",
                color: Theme.warning,
                size: 12
            ))
        } else {
            modeLabel.stringValue = idleModeText()
        }
        let hint = label(
            "ニーズから Go の書き方・標準ライブラリを逆引きできます（例: 「json のデコード」「ファイルを1行ずつ読みたい」「for ループの書き方」「json.Encoder」）。",
            color: Theme.secondaryText,
            size: 12
        )
        contentStack.addArrangedSubview(hint)
    }

    private func render(answer: DocsAnswer) {
        clearContent()
        modeLabel.stringValue = answer.searchMode.shortLabel

        // Conclusion banner (UX-1)
        let conclusionField = label(answer.conclusion, color: Theme.text, size: 13, bold: true)
        contentStack.addArrangedSubview(conclusionField)

        switch answer.status {
        case .disabled:
            let btn = NSButton(title: "Go Docs を有効にする", target: self, action: #selector(enableDocsClicked))
            btn.bezelStyle = .rounded
            contentStack.addArrangedSubview(btn)

        case .missingPack(let requested, let installed):
            let installBtn = NSButton(title: "Go \(requested.minorKey) コアパックを作成", target: self, action: #selector(installRequestedPackClicked(_:)))
            installBtn.bezelStyle = .rounded
            installBtn.identifier = NSUserInterfaceItemIdentifier(requested.minorKey)
            var rowViews: [NSView] = [installBtn]
            for ver in installed {
                let switchBtn = NSButton(title: "go\(ver) で明示的に検索", target: self, action: #selector(switchToInstalledVersionClicked(_:)))
                switchBtn.bezelStyle = .rounded
                switchBtn.identifier = NSUserInterfaceItemIdentifier(ver)
                rowViews.append(switchBtn)
            }
            let row = NSStackView(views: rowViews)
            row.orientation = .horizontal
            row.spacing = 8
            contentStack.addArrangedSubview(row)

        case .notFound:
            if !answer.searchedScope.isEmpty {
                contentStack.addArrangedSubview(label("検索範囲: \(answer.searchedScope)", color: Theme.secondaryText, size: 11))
            }

        case .found:
            for (idx, card) in answer.cards.enumerated() {
                let cardView = makeCardView(card: card, index: idx)
                contentStack.addArrangedSubview(cardView)
                cardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24).isActive = true
            }
        }

        // Separated newer-version notices (UC-1 / FR-10: never insertable)
        if !answer.newerVersionNotes.isEmpty {
            let header = label("現在の Go バージョンより新しい機能（参考・挿入不可）:", color: Theme.warning, size: 11, bold: true)
            contentStack.addArrangedSubview(header)
            for note in answer.newerVersionNotes {
                let line = label(
                    "• [Go \(note.since.minorKey)+] \(note.title) — \(note.citation)",
                    color: Theme.secondaryText,
                    size: 11
                )
                contentStack.addArrangedSubview(line)
            }
        }

        if !answer.searchedScope.isEmpty && answer.status == .found {
            contentStack.addArrangedSubview(label(
                "検索対象: \(answer.searchedScope) | モード: \(answer.searchMode.label)",
                color: Theme.secondaryText,
                size: 10
            ))
        }
    }

    private func makeCardView(card: DocsAnswerCard, index: Int) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        Theme.paint(box, background: Theme.panelBackground, border: Theme.border)
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])

        let titleField = label(card.title, color: Theme.text, size: 12, bold: true)
        inner.addArrangedSubview(titleField)

        let reasonField = label(card.reason, color: Theme.text, size: 12)
        inner.addArrangedSubview(reasonField)

        if let sig = card.signature, !sig.isEmpty {
            let sigField = NSTextField(wrappingLabelWithString: sig)
            sigField.font = Theme.editorFont.withSize(11)
            sigField.textColor = Theme.function
            sigField.isSelectable = true
            inner.addArrangedSubview(sigField)
        }

        if let example = card.example, !example.isEmpty {
            let codeContainer = NSView()
            codeContainer.wantsLayer = true
            Theme.paint(codeContainer, background: Theme.background, border: Theme.border)
            codeContainer.layer?.cornerRadius = 4
            codeContainer.layer?.borderWidth = 0.5
            let codeField = NSTextField(wrappingLabelWithString: example)
            codeField.font = Theme.editorFont.withSize(11)
            codeField.textColor = Theme.text
            codeField.isSelectable = true
            codeField.translatesAutoresizingMaskIntoConstraints = false
            codeContainer.addSubview(codeField)
            NSLayoutConstraint.activate([
                codeField.topAnchor.constraint(equalTo: codeContainer.topAnchor, constant: 6),
                codeField.leadingAnchor.constraint(equalTo: codeContainer.leadingAnchor, constant: 8),
                codeField.trailingAnchor.constraint(equalTo: codeContainer.trailingAnchor, constant: -8),
                codeField.bottomAnchor.constraint(equalTo: codeContainer.bottomAnchor, constant: -6)
            ])
            inner.addArrangedSubview(codeContainer)
        }

        // Footer: citation + Go version + Insert / Copy actions (UX-1, UX-2, G-4)
        let sincePart = card.since.map { " (since go\($0))" } ?? ""
        let citeField = label("出典: \(card.citation) • go\(card.goVersion)\(sincePart)", color: Theme.secondaryText, size: 11)
        citeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var footerViews: [NSView] = [citeField, NSView()]
        if card.example != nil {
            let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyCardClicked(_:)))
            copyBtn.bezelStyle = .rounded
            copyBtn.controlSize = .small
            copyBtn.tag = index
            footerViews.append(copyBtn)
        }
        if card.canInsert {
            let insertBtn = NSButton(title: "Insert", target: self, action: #selector(insertCardClicked(_:)))
            insertBtn.bezelStyle = .rounded
            insertBtn.controlSize = .small
            insertBtn.tag = index
            footerViews.append(insertBtn)
        }
        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.spacing = 6
        inner.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -20).isActive = true

        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func label(_ text: String, color: NSColor, size: CGFloat, bold: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        f.textColor = color
        f.isSelectable = true
        return f
    }

    // MARK: - Headless DebugDriver helpers (§8.4)

    func debugSetVersion(_ raw: String?) {
        explicitVersion = raw.flatMap { GoVersion(parsing: $0) }
        refreshVersionPopup()
    }

    @discardableResult
    func debugSearch(_ query: String) async -> DocsAnswer {
        _ = view
        searchTask?.cancel()
        queryField.stringValue = query
        // M-6: use in-memory debug override so headless tests never persist opt-in to UserDefaults.
        DocsManager.shared.debugEnabledOverride = true
        let cachedToolchain = DocsManager.shared.detectedToolchainVersion
        await DocsManager.shared.ensureBundledPackSync(
            goVersion: explicitVersion?.minorKey
                ?? GoVersionResolver.resolve(projectRoot: context.root, toolchainVersionProvider: { cachedToolchain })?.version.minorKey
                ?? BundledGoCorpus.defaultVersion
        )
        searchTask?.cancel()
        queryField.stringValue = query
        let answer = await DocsManager.shared.search(
            query: query,
            projectRoot: context.root,
            explicitVersion: explicitVersion,
            editorContext: currentEditorContext()
        )
        lastAnswer = answer
        render(answer: answer)
        view.layoutSubtreeIfNeeded()
        return answer
    }

    @discardableResult
    func debugInsertFirstCard() async -> Bool {
        guard let answer = lastAnswer, let first = answer.cards.first else { return false }
        return await insertCardAsync(first, targetVersion: answer.targetVersion)
    }

    func debugSummary() -> String {
        guard let a = lastAnswer else { return "none" }
        let titles = a.cards.map { "\($0.citation)[go\($0.goVersion)]" }.joined(separator: " | ")
        return "status=\(a.status) mode=\(a.searchMode.rawValue) rerank=\(a.usedReranker) cards=\(a.cards.count) newer=\(a.newerVersionNotes.count) [\(titles)]"
    }
}

private final class DocsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
