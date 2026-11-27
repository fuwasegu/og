import AppKit
import OgCore

/// All diagnostics in the project (gopls + build/vet), grouped by file, with unobtrusive
/// error-driven Docs hints (Issue #28, DOC-13, DES-ERR-4).
///
/// Hints attach passively as a compact button on matching diagnostic rows; cards are shown
/// only in a popover when the user explicitly clicks the hint button (never auto-opens panels,
/// steals focus, or modifies documents).
@MainActor
final class ProblemsPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let context: ProjectContext
    private let outline = NSOutlineView()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activePopover: NSPopover?
    private var activePopoverKey: DocsErrorDiagnosticKey?

    final class Row: NSObject {
        let uri: String
        let diag: LSPDiagnostic?
        let errorKey: DocsErrorDiagnosticKey?
        let sourceTag: String?
        init(uri: String, diag: LSPDiagnostic?, errorKey: DocsErrorDiagnosticKey? = nil, sourceTag: String? = nil) {
            self.uri = uri
            self.diag = diag
            self.errorKey = errorKey
            self.sourceTag = sourceTag
        }
    }
    private var fileRows: [Row] = []
    private var childRows: [String: [Row]] = [:]

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("p"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 22
        outline.backgroundColor = Theme.panelBackground
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(open)
        outline.action = #selector(open)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        observers.append(NotificationCenter.default.addObserver(forName: .ogDiagnosticsChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .ogErrorHintsChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleHintsChanged() }
        })
        reload()
    }

    private func handleHintsChanged() {
        // Close an open popover immediately if its hint was cleared (diagnostic resolved, doc edited, dismissed, or disabled).
        if let key = activePopoverKey, context.errorHints.hint(for: key) == nil {
            activePopover?.close()
            activePopover = nil
            activePopoverKey = nil
        }
        scheduleReload()
    }

    private func scheduleReload() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        var grouped: [String: [Row]] = [:]

        // 1. Gopls & local style diagnostics.
        for (uri, items) in context.allDiagnostics {
            let rows = items.map { d -> Row in
                let key = DocsErrorDiagnosticKey(
                    fileURI: uri,
                    source: .gopls,
                    line: d.range.start.line,
                    column: d.range.start.character,
                    message: d.message
                )
                return Row(uri: uri, diag: d, errorKey: key, sourceTag: nil)
            }
            grouped[uri, default: []].append(contentsOf: rows)
        }

        // 2. Build / vet diagnostics from the latest run (deduplicated against identical gopls entries).
        for (uri, buildItems) in context.errorHints.buildDiagnostics {
            let existingSignatures = Set((grouped[uri] ?? []).compactMap { row -> String? in
                guard let d = row.diag else { return nil }
                return "\(d.range.start.line):\(d.message)"
            })
            for item in buildItems {
                let sig = "\(item.range.start.line):\(item.message)"
                if existingSignatures.contains(sig) { continue }
                let lsp = LSPDiagnostic(
                    range: item.range,
                    severity: item.severity,
                    message: item.message,
                    source: item.diagnosticSource ?? "go build"
                )
                grouped[uri, default: []].append(Row(uri: uri, diag: lsp, errorKey: item.key, sourceTag: "build"))
            }
        }

        let sortedURIs = grouped.keys.sorted()
        fileRows = sortedURIs.map { Row(uri: $0, diag: nil) }
        childRows = Dictionary(uniqueKeysWithValues: sortedURIs.map { uri in
            let sortedRows = (grouped[uri] ?? []).sorted { a, b in
                let la = (a.diag?.severity?.rawValue ?? 4, a.diag?.range.start.line ?? 0)
                let lb = (b.diag?.severity?.rawValue ?? 4, b.diag?.range.start.line ?? 0)
                return la < lb
            }
            return (uri, sortedRows)
        })
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? Row else { return fileRows.count }
        return row.diag == nil ? childRows[row.uri]?.count ?? 0 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? Row else { return fileRows[index] }
        return childRows[row.uri]?[index] ?? row
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Row)?.diag == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        if let d = row.diag {
            let sev = NSTextField(labelWithString: d.severity == .error ? "●" : (d.severity == .warning ? "▲" : "ⓘ"))
            sev.textColor = d.severity == .error ? Theme.error : (d.severity == .warning ? Theme.warning : Theme.info)
            sev.setContentHuggingPriority(.required, for: .horizontal)

            let msg = NSTextField(labelWithString: d.message.replacingOccurrences(of: "\n", with: " "))
            msg.font = Theme.uiFont
            msg.textColor = Theme.text
            msg.lineBreakMode = .byTruncatingTail
            msg.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let loc = NSTextField(labelWithString: ":\(d.range.start.line + 1)")
            loc.font = Theme.smallFont
            loc.textColor = Theme.secondaryText
            loc.setContentHuggingPriority(.required, for: .horizontal)

            var views: [NSView] = [sev, msg, loc]

            if let srcTag = row.sourceTag {
                let badge = NSTextField(labelWithString: "[\(srcTag)]")
                badge.font = Theme.smallFont
                badge.textColor = Theme.secondaryText
                badge.setContentHuggingPriority(.required, for: .horizontal)
                views.append(badge)
            }

            if let key = row.errorKey, let hint = context.errorHints.hint(for: key) {
                let hintBtn = ErrorHintBadgeButton(key: key, isDepReport: hint.isDepReport, cardCount: hint.cards.count)
                hintBtn.target = self
                hintBtn.action = #selector(hintBadgeClicked(_:))
                views.append(hintBtn)
            }

            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            return stack
        }
        let url = URL(string: row.uri)
        let name = NSTextField(labelWithString: url.map { context.relativePath($0) } ?? row.uri)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = Theme.text
        let count = NSTextField(labelWithString: "\(childRows[row.uri]?.count ?? 0)")
        count.font = Theme.smallFont
        count.textColor = Theme.secondaryText
        return NSStackView(views: [name, count])
    }

    @objc private func open() {
        guard let row = outline.item(atRow: outline.clickedRow) as? Row, let url = URL(string: row.uri) else { return }
        if let d = row.diag {
            context.open(url, line: d.range.start.line, column: d.range.start.character)
        } else {
            context.open(url)
        }
    }

    @objc private func hintBadgeClicked(_ sender: ErrorHintBadgeButton) {
        let key = sender.diagnosticKey
        guard let hint = context.errorHints.hint(for: key) else { return }
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        let vc = ErrorHintPopoverController(
            hint: hint,
            context: context,
            onDismiss: { [weak self, weak popover] in
                popover?.close()
                self?.activePopover = nil
                self?.activePopoverKey = nil
                self?.context.errorHints.dismissHint(for: key)
            },
            onOpenInDocs: { [weak self, weak popover] query in
                popover?.close()
                self?.activePopover = nil
                self?.activePopoverKey = nil
                self?.context.showPanel(.docs)
                self?.context.window?.bottomPanel.docsPanel.focusSearch(prefill: query)
            },
            onClosePopover: { [weak self, weak popover] in
                popover?.close()
                self?.activePopover = nil
                self?.activePopoverKey = nil
            }
        )
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        activePopover = popover
        activePopoverKey = key
    }
}

// MARK: - Compact Hint Badge Button

@MainActor
private final class ErrorHintBadgeButton: NSButton {
    let diagnosticKey: DocsErrorDiagnosticKey

    init(key: DocsErrorDiagnosticKey, isDepReport: Bool, cardCount: Int) {
        self.diagnosticKey = key
        super.init(frame: .zero)
        bezelStyle = .recessed
        controlSize = .small
        font = Theme.smallFont
        title = isDepReport ? "Dep" : "Docs (\(cardCount))"
        image = NSImage(systemSymbolName: isDepReport ? "shippingbox" : "book", accessibilityDescription: "Docs Hint")
        imagePosition = .imageLeading
        toolTip = isDepReport
            ? "未取得または未インデックスの依存パッケージ情報を見る"
            : "関連する Go ドキュメントカード（出典付き）を表示"
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - On-Demand Hint Popover (100% AppKit, DOC-13a..d)

@MainActor
private final class ErrorHintPopoverController: NSViewController {
    private let hint: DocsErrorHint
    private let context: ProjectContext
    private let onDismiss: () -> Void
    private let onOpenInDocs: (String) -> Void
    private let onClosePopover: () -> Void

    init(
        hint: DocsErrorHint,
        context: ProjectContext,
        onDismiss: @escaping () -> Void,
        onOpenInDocs: @escaping (String) -> Void,
        onClosePopover: @escaping () -> Void
    ) {
        self.hint = hint
        self.context = context
        self.onDismiss = onDismiss
        self.onOpenInDocs = onOpenInDocs
        self.onClosePopover = onClosePopover
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        container.wantsLayer = true
        Theme.paint(container, background: Theme.panelBackground)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header row: title + Dismiss button
        let headerTitle: String
        switch hint.content {
        case .cards(_, let targetVer, let mode, let query):
            headerTitle = "Docs ヒント: `\(query)` (go\(targetVer.minorKey) • \(mode.shortLabel))"
        case .depReport(let report):
            headerTitle = "依存ドキュメント状況: \(report.importPath)"
        }
        let titleLabel = makeLabel(headerTitle, color: Theme.text, size: 12, bold: true)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dismissBtn = NSButton(title: "この診断では非表示", target: self, action: #selector(dismissClicked))
        dismissBtn.bezelStyle = .rounded
        dismissBtn.controlSize = .small
        dismissBtn.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [titleLabel, NSView(), dismissBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        switch hint.content {
        case .cards(let cards, _, _, let query):
            for (idx, card) in cards.enumerated() {
                let cardView = makeCardView(card: card, index: idx)
                stack.addArrangedSubview(cardView)
                cardView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            let openDocsBtn = NSButton(title: "Docs パネルで詳しく調べる…", target: self, action: #selector(openInDocsClicked))
            openDocsBtn.bezelStyle = .rounded
            openDocsBtn.controlSize = .small
            openDocsBtn.identifier = NSUserInterfaceItemIdentifier(query)
            stack.addArrangedSubview(openDocsBtn)

        case .depReport(let report):
            let body = makeLabel(report.message, color: Theme.text, size: 12)
            stack.addArrangedSubview(body)
            let actionTitle = report.isCachedButUnindexed ? "依存ドキュメントを抽出" : "go mod download を実行"
            let actionSel = report.isCachedButUnindexed ? #selector(syncDepsClicked) : #selector(downloadDepsClicked)
            let btn = NSButton(title: actionTitle, target: self, action: actionSel)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            stack.addArrangedSubview(btn)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let docView = ErrorHintFlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(stack)
        scroll.documentView = docView
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: docView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor)
        ])

        view = container
        preferredContentSize = NSSize(width: 460, height: hint.isDepReport ? 150 : min(420, 120 + hint.cards.count * 130))
    }

    private func makeCardView(card: DocsAnswerCard, index: Int) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        Theme.paint(box, background: Theme.background, border: Theme.border)
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 5
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])

        inner.addArrangedSubview(makeLabel(card.title, color: Theme.text, size: 12, bold: true))
        if !card.reason.isEmpty {
            inner.addArrangedSubview(makeLabel(card.reason, color: Theme.text, size: 11))
        }
        if let sig = card.signature, !sig.isEmpty {
            let sigField = NSTextField(wrappingLabelWithString: sig)
            sigField.font = Theme.editorFont.withSize(11)
            sigField.textColor = Theme.function
            sigField.isSelectable = true
            inner.addArrangedSubview(sigField)
        }
        if let example = card.example, !example.isEmpty {
            let codeField = NSTextField(wrappingLabelWithString: example)
            codeField.font = Theme.editorFont.withSize(10.5)
            codeField.textColor = Theme.text
            codeField.isSelectable = true
            inner.addArrangedSubview(codeField)
        }

        let citeText = card.sourceKind == .dependency
            ? "出典: \(card.citation)"
            : "出典: \(card.citation) • go\(card.goVersion)" + (card.since.map { " (since go\($0))" } ?? "")
        let citeLabel = makeLabel(citeText, color: Theme.secondaryText, size: 10.5)
        citeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var footerViews: [NSView] = [citeLabel, NSView()]
        if card.example != nil {
            let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyClicked(_:)))
            copyBtn.bezelStyle = .rounded
            copyBtn.controlSize = .small
            copyBtn.tag = index
            footerViews.append(copyBtn)
        }
        if card.canInsert {
            let insertBtn = NSButton(title: "Insert", target: self, action: #selector(insertClicked(_:)))
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

    private func makeLabel(_ text: String, color: NSColor, size: CGFloat, bold: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        f.textColor = color
        f.isSelectable = true
        return f
    }

    @objc private func dismissClicked() {
        onDismiss()
    }

    @objc private func openInDocsClicked(_ sender: NSButton) {
        let q = sender.identifier?.rawValue ?? hint.derivedQuery ?? ""
        onOpenInDocs(q)
    }

    @objc private func copyClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard hint.cards.indices.contains(idx), let code = hint.cards[idx].example else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        context.setStatus("Copied snippet from \(hint.cards[idx].citation)")
    }

    @objc private func insertClicked(_ sender: NSButton) {
        let idx = sender.tag
        onClosePopover()
        context.errorHints.insertSnippet(for: hint.diagnosticKey, cardIndex: idx)
    }

    @objc private func syncDepsClicked() {
        onClosePopover()
        DocsManager.shared.syncProjectDependencies(projectRoot: context.root)
    }

    @objc private func downloadDepsClicked() {
        onClosePopover()
        DocsManager.shared.downloadAndSyncProjectDependencies(projectRoot: context.root)
    }
}

private final class ErrorHintFlippedView: NSView {
    override var isFlipped: Bool { true }
}
