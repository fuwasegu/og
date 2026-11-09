import AppKit
import OgCore

/// One editor tab: text view, gutter, highlighting, diagnostics, and LSP features.
@MainActor
final class EditorController: NSViewController, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let context: ProjectContext
    let document: Document
    let textView: CodeTextView
    let scrollView = NSScrollView()
    private(set) var gutter: GutterView!
    private let banner = EditorBanner()
    private var bannerHeight: NSLayoutConstraint!
    private var highlightTimer: Timer?
    private(set) var tokens: [GoToken] = []
    private var observers: [NSObjectProtocol] = []
    var completion: CompletionPopup?
    var info: InfoPopup?
    var ghostTask: Task<Void, Never>?
    var ghostTimer: Timer?
    var completionTask: Task<Void, Never>?
    var completionTimer: Timer?
    /// Lines (0-based) of the latest git changes for the gutter.
    var gitChanges: [GitLineChange] = []
    var pendingActions: (version: Int, actions: [LSPCodeAction])?
    var estimateRemovedNewlines = 0
    private var gitTask: Task<Void, Never>?

    init(context: ProjectContext, document: Document) {
        self.context = context
        self.document = document
        // TextKit 1 chain for line-fragment queries and temporary attributes.
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        document.storage.addLayoutManager(layout)
        textView = CodeTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    override func loadView() {
        let root = NSView()
        configureTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.borderType = .noBorder
        gutter = GutterView(scrollView: scrollView, editor: self)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        banner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(banner)
        root.addSubview(scrollView)
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bannerHeight,
            scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        banner.onAction = { [weak self] action in self?.bannerAction(action) }

        document.storage.delegate = self
        document.onStateChange.append { [weak self] _ in self?.updateBanner() }
        observe()
        rehighlight()
        applyDiagnostics()
        updateBanner()
        refreshGitChanges()
    }

    private func configureTextView() {
        let tv = textView
        tv.controller = self
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = Theme.editorFont
        tv.textColor = Theme.text
        tv.backgroundColor = Theme.background
        tv.insertionPointColor = NSColor.white
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.typingAttributes = [.font: Theme.editorFont, .foregroundColor: Theme.text, .paragraphStyle: paragraphStyle()]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.layoutManager?.usesFontLeading = false
        // Base attributes for existing content.
        let all = NSRange(location: 0, length: document.storage.length)
        document.storage.beginEditing()
        document.storage.setAttributes([.font: Theme.editorFont, .foregroundColor: Theme.text, .paragraphStyle: paragraphStyle()], range: all)
        document.storage.endEditing()
    }

    private func paragraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let tabWidth = (" " as NSString).size(withAttributes: [.font: Theme.editorFont]).width * 4
        p.defaultTabInterval = tabWidth
        p.tabStops = []
        p.lineHeightMultiple = 1.15
        return p
    }

    func applyFontChange() {
        textView.font = Theme.editorFont
        textView.typingAttributes = [.font: Theme.editorFont, .foregroundColor: Theme.text, .paragraphStyle: paragraphStyle()]
        document.storage.beginEditing()
        document.storage.addAttributes([.font: Theme.editorFont, .paragraphStyle: paragraphStyle()], range: NSRange(location: 0, length: document.storage.length))
        document.storage.endEditing()
        gutter.needsDisplay = true
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .ogDiagnosticsChanged, object: context, queue: .main) { [weak self] n in
            let info = n.userInfo as? [String: any Sendable] ?? [:]
            MainActor.assumeIsolated {
                guard let self, (info["uri"] as? String) == self.document.uri else { return }
                self.applyDiagnostics()
            }
        })
        observers.append(nc.addObserver(forName: .ogBreakpointsChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
        })
        observers.append(nc.addObserver(forName: .ogDebugStopChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDebugLine() }
        })
        observers.append(nc.addObserver(forName: .ogGitStatusChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGitChanges() }
        })
        observers.append(nc.addObserver(forName: .ogDocumentSaved, object: context, queue: .main) { [weak self] n in
            let info = n.userInfo as? [String: any Sendable] ?? [:]
            MainActor.assumeIsolated {
                guard let self, (info["url"] as? URL) == self.document.url else { return }
                self.refreshGitChanges()
            }
        })
    }

    // MARK: - Text changes

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Keep base attributes on inserted text.
        textStorage.addAttributes([.font: Theme.editorFont, .foregroundColor: Theme.text], range: editedRange)
        // Keep breakpoints attached to their lines.
        let ns = textStorage.string as NSString
        let inserted = ns.substring(with: editedRange).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineDelta = inserted - estimateRemovedNewlines
        estimateRemovedNewlines = 0
        if lineDelta != 0 {
            let line = TextLines(nsString: ns).line(forOffset: editedRange.location)
            context.breakpoints.shift(document.url, from: line + 1, by: lineDelta)
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.document.markEdited()
                self.scheduleHighlight()
                self.gutter.needsDisplay = true
            }
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ns = textView.string as NSString
        if affectedCharRange.length > 0, NSMaxRange(affectedCharRange) <= ns.length {
            estimateRemovedNewlines = ns.substring(with: affectedCharRange).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        } else {
            estimateRemovedNewlines = 0
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        textView.ghostText = nil
    }

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func scheduleHighlight() {
        highlightTimer?.invalidate()
        highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehighlight() }
        }
    }

    /// Re-tokenizes and recolors using temporary attributes (no undo / storage edits).
    func rehighlight() {
        guard let lm = textView.layoutManager else { return }
        let ns = document.storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard document.isGo, ns.length < 3_000_000 else { return }
        tokens = GoLexer.tokenize(ns)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for t in tokens {
            let color: NSColor
            switch t.kind {
            case .keyword: color = Theme.keyword
            case .type: color = Theme.type
            case .builtin: color = Theme.builtin
            case .string: color = Theme.string
            case .number: color = Theme.number
            case .comment: color = Theme.comment
            case .function: color = Theme.text
            case .funcDecl: color = Theme.function
            case .typeDecl: color = Theme.type
            case .constant: color = Theme.keyword
            }
            if t.kind == .function { continue }
            lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: t.range)
        }
    }

    func isInsideStringOrComment(_ offset: Int) -> Bool {
        tokens.contains { ($0.kind == .string || $0.kind == .comment) && offset > $0.location && offset < $0.location + $0.length }
    }

    // MARK: - Diagnostics

    var diagnostics: [LSPDiagnostic] { context.diagnostics[document.uri] ?? [] }

    func applyDiagnostics() {
        guard let lm = textView.layoutManager else { return }
        let ns = document.storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        let lines = TextLines(nsString: ns)
        for d in diagnostics {
            var r = lines.nsRange(for: d.range)
            if r.length == 0 {
                // Underline the word at the position.
                let lr = lines.lineRange(d.range.start.line)
                r = NSRange(location: r.location, length: min(1, NSMaxRange(lr) - r.location))
                if r.length == 0, r.location > lr.location { r = NSRange(location: r.location - 1, length: 1) }
            }
            guard NSMaxRange(r) <= ns.length, r.length > 0 else { continue }
            let color: NSColor = d.severity == .error ? Theme.error : (d.severity == .warning ? Theme.warning : Theme.info)
            lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, forCharacterRange: r)
            lm.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: r)
        }
        gutter?.needsDisplay = true
    }

    func diagnostics(atLine line: Int) -> [LSPDiagnostic] {
        diagnostics.filter { $0.range.start.line <= line && $0.range.end.line >= line }
    }

    // MARK: - Git gutter

    func refreshGitChanges() {
        let rel = context.relativePath(document.url)
        let text = document.text
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            guard let self else { return }
            let changes = await self.context.git.lineChanges(relativePath: rel, currentText: text)
            guard !Task.isCancelled else { return }
            self.gitChanges = changes
            self.gutter?.needsDisplay = true
        }
    }

    // MARK: - Debug

    func updateDebugLine() {
        if let stop = context.debugStop, stop.url.standardizedFileURL == document.url {
            textView.debugLine = stop.line
            reveal(line: stop.line, column: 0, length: 0, select: false)
        } else {
            textView.debugLine = nil
        }
        gutter.needsDisplay = true
    }

    // MARK: - Navigation

    func reveal(line: Int, column: Int, length: Int, select: Bool = true) {
        _ = view
        let lines = TextLines(nsString: document.storage.string as NSString)
        let offset = lines.offset(for: LSPPosition(line: line, character: column))
        let r = NSRange(location: offset, length: max(0, min(length, document.storage.length - offset)))
        if select { textView.setSelectedRange(r) }
        textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(document.storage.length, NSMaxRange(r) + 2000)))
        if let rect = textView.lineRect(forLine: line) {
            let visible = scrollView.contentView.bounds
            if !visible.contains(rect) {
                let y = max(0, rect.midY - visible.height / 3)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        textView.scrollRangeToVisible(r)
    }

    var caretOffset: Int { textView.selectedRange().location }

    var caretPosition: LSPPosition {
        TextLines(nsString: document.storage.string as NSString).position(forOffset: caretOffset)
    }

    func selectionDidChange() {
        let lines = TextLines(nsString: document.storage.string as NSString)
        let p = lines.position(forOffset: caretOffset)
        context.window?.statusBar.setPosition(line: p.line + 1, column: p.character + 1, selection: textView.selectedRange().length)
        if textView.ghostText != nil && caretOffset != textView.ghostLocation { dismissGhost() }
        completion?.caretMoved(to: caretOffset)
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Edits

    /// Applies LSP edits to the buffer as one undo step, preserving the caret.
    func applyTextEdits(_ edits: [LSPTextEdit], undoName: String) {
        guard !edits.isEmpty else { return }
        let ns = document.storage.string as NSString
        let lines = TextLines(nsString: ns)
        let resolved = edits.map { (lines.nsRange(for: $0.range), $0.newText) }
            .sorted { $0.0.location > $1.0.location }
        let caret = caretOffset
        var shift = 0
        document.undoManager.beginUndoGrouping()
        for (r, text) in resolved {
            guard NSMaxRange(r) <= document.storage.length else { continue }
            if textView.shouldChangeText(in: r, replacementString: text) {
                document.storage.replaceCharacters(in: r, with: text)
                textView.didChangeText()
                if r.location < caret { shift += (text as NSString).length - r.length }
            }
        }
        document.undoManager.endUndoGrouping()
        document.undoManager.setActionName(undoName)
        let newCaret = max(0, min(document.storage.length, caret + shift))
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    /// Replaces the whole buffer with new text as one undoable edit (minimal common prefix/suffix).
    func replaceText(with newText: String, undoName: String) {
        let old = document.storage.string as NSString
        let new = newText as NSString
        var prefix = 0
        let minLen = min(old.length, new.length)
        while prefix < minLen && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < minLen - prefix && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let r = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let caret = caretOffset
        if textView.shouldChangeText(in: r, replacementString: replacement) {
            document.storage.replaceCharacters(in: r, with: replacement)
            textView.didChangeText()
            document.undoManager.setActionName(undoName)
        }
        textView.setSelectedRange(NSRange(location: min(caret, document.storage.length), length: 0))
    }

    /// Reload after an external change; keeps caret line/column.
    func reloadPreservingSelection(_ text: String) {
        let pos = caretPosition
        let visible = scrollView.contentView.bounds.origin
        document.replaceAll(with: text)
        document.storage.setAttributes([.font: Theme.editorFont, .foregroundColor: Theme.text, .paragraphStyle: paragraphStyle()],
                                       range: NSRange(location: 0, length: document.storage.length))
        let lines = TextLines(nsString: document.storage.string as NSString)
        textView.setSelectedRange(NSRange(location: lines.offset(for: pos), length: 0))
        scrollView.contentView.scroll(to: visible)
        rehighlight()
        applyDiagnostics()
    }

    // MARK: - Banner (conflict / save error)

    private func updateBanner() {
        if document.conflict {
            banner.show(message: "\(document.url.lastPathComponent) changed on disk while you were editing.",
                        actions: [("Keep My Changes", "keep"), ("Load Disk Version", "disk")], style: .warning)
        } else if let err = document.saveError {
            banner.show(message: "Could not save: \(err)", actions: [("Retry", "retry"), ("Discard Changes", "discard")], style: .error)
        } else {
            banner.hide()
        }
        bannerHeight.constant = banner.isHidden ? 0 : 30
        context.window?.editorArea.refreshTabs()
    }

    private func bannerAction(_ action: String) {
        switch action {
        case "keep": context.documents.keepMine(document)
        case "disk": context.documents.takeDisk(document)
        case "retry": context.documents.save(document)
        case "discard": context.documents.discard(document)
        default: break
        }
        updateBanner()
    }
}

/// Thin bar above the editor for conflicts / save errors.
@MainActor
final class EditorBanner: NSView {
    enum Style { case warning, error }
    var onAction: ((String) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        label.font = Theme.uiFont
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(message: String, actions: [(String, String)], style: Style) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        label.stringValue = message
        stack.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        for (title, id) in actions {
            let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.bezelStyle = .recessed
            b.controlSize = .small
            stack.addArrangedSubview(b)
        }
        layer?.backgroundColor = (style == .warning ? NSColor(srgbRed: 0.45, green: 0.35, blue: 0.10, alpha: 1) : NSColor(srgbRed: 0.50, green: 0.15, blue: 0.15, alpha: 1)).cgColor
        isHidden = false
    }

    func hide() { isHidden = true }

    @objc private func clicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onAction?(id) }
    }
}
