import AppKit
import OgCore

/// Preferences: editor font, session, and the app-owned local AI server (spec/req/model_server.fsl).
@MainActor
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()
    private let fontSize = NSStepper()
    private let fontLabel = NSTextField(labelWithString: "")
    private let fontFamily = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let fontPreview = NSTextField(labelWithString: "")
    private let reopen = NSButton(checkboxWithTitle: "Reopen the last project on launch", target: nil, action: nil)

    private let aiEnabled = NSButton(checkboxWithTitle: "Enable inline AI completion (runs a local model server; code never leaves this Mac)", target: nil, action: nil)
    private let backend = NSPopUpButton()
    private let model = NSComboBox()
    private let custom = NSTextField()
    private let customRow = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Restart", target: nil, action: nil)
    private let logView = NSTextView()

    // Offline Go Docs (FR-19, FR-20, FR-23, FR-24, FR-27, FR-29, Q-4, L-9, Issue #21, #28)
    private let docsEnabled = NSButton(checkboxWithTitle: "Enable offline Go Docs lookup (local-only; independent of inline AI completion)", target: nil, action: nil)
    private let docsErrorHintsEnabled = NSButton(checkboxWithTitle: "Show error-driven Docs hints in Problems (never auto-opens panels or edits code)", target: nil, action: nil)
    private let docsSemanticEnabled = NSButton(checkboxWithTitle: "Enable semantic search & cross-encoder reranker (local MLX server via uvx on 127.0.0.1)", target: nil, action: nil)
    private let docsEmbedModel = NSComboBox()
    private let docsRerankEnabled = NSButton(checkboxWithTitle: "Use cross-encoder reranker (improves Japanese -> English ranking)", target: nil, action: nil)
    private let docsRerankModel = NSComboBox()
    private let docsServerStatus = NSTextField(labelWithString: "")
    private let docsServerActionButton = NSButton(title: "Restart", target: nil, action: nil)
    private let docsReembedButton = NSButton(title: "Build Embeddings", target: nil, action: nil)
    private let docsBatchPolicy = NSPopUpButton()
    private let docsVersionCombo = NSComboBox()
    private let docsInstallButton = NSButton(title: "Add / Update Pack", target: nil, action: nil)
    private let docsImportGorootButton = NSButton(title: "Import GOROOT…", target: nil, action: nil)
    private let docsImportWebsiteButton = NSButton(title: "Import Website…", target: nil, action: nil)
    private let docsDeleteWebsiteButton = NSButton(title: "Delete Website", target: nil, action: nil)
    private let docsDeleteButton = NSButton(title: "Delete Pack", target: nil, action: nil)
    private let docsPruneDepsButton = NSButton(title: "Prune Unused Deps", target: nil, action: nil)
    private let docsCancelButton = NSButton(title: "Cancel Batch", target: nil, action: nil)
    private let docsLicenseButton = NSButton(title: "BSD License…", target: nil, action: nil)
    private let docsPacksLabel = NSTextField(wrappingLabelWithString: "")
    private let docsProgressBar = NSProgressIndicator()
    private let docsProgressLabel = NSTextField(labelWithString: "")
    // Docs Phase 3 answer synthesis (Issue #24, D-9, D-10)
    private let docsAnswerMode = NSPopUpButton()
    private let docsAnswerBackend = NSPopUpButton()
    private let docsAnswerModel = NSComboBox()
    private let docsIncludeEditorContext = NSButton(checkboxWithTitle: "Include active Go file imports in Docs synthesis (imports only; enabled by default)", target: nil, action: nil)
    private let docsAnswerStatus = NSTextField(labelWithString: "")
    private let docsAnswerActionButton = NSButton(title: "Restart", target: nil, action: nil)

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Settings"
        super.init(window: w)
        build()
        load()
        w.center()
        NotificationCenter.default.addObserver(forName: .ogModelServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsErrorHintsSettingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsBatchProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
        NotificationCenter.default.addObserver(forName: .ogDocsAnswerServerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDocs() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        fontSize.minValue = 9
        fontSize.maxValue = 32
        fontSize.increment = 1
        fontSize.target = self
        fontSize.action = #selector(fontChanged)
        reopen.target = self
        reopen.action = #selector(reopenChanged)
        for m in ThemeMode.allCases { themePopup.addItem(withTitle: m.title) }
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        fontFamily.addItem(withTitle: Self.systemMono)
        fontFamily.menu?.addItem(.separator())
        for f in Theme.monospacedFamilies() { fontFamily.addItem(withTitle: f) }
        fontFamily.target = self
        fontFamily.action = #selector(familyChanged)
        fontPreview.stringValue = "func main() { fmt.Println(\"0O 1lI {}[]() := != <-\") }"

        aiEnabled.target = self
        aiEnabled.action = #selector(enabledChanged)
        for b in ModelBackend.allCases { backend.addItem(withTitle: b.title) }
        backend.target = self
        backend.action = #selector(backendChanged)
        model.isEditable = true
        model.completes = false
        model.delegate = self
        model.target = self
        model.action = #selector(modelChanged)
        model.placeholderString = "preset, Hugging Face repo, or path"
        custom.placeholderString = "e.g. /path/to/server --port {port}"
        custom.target = self
        custom.action = #selector(customChanged)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        status.font = Theme.uiFont
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.backgroundColor = Theme.background
        logView.textColor = Theme.secondaryText
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        func row(_ label: String, _ v: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return NSStackView(views: [l, v])
        }
        model.widthAnchor.constraint(equalToConstant: 420).isActive = true
        custom.widthAnchor.constraint(equalToConstant: 420).isActive = true
        customRow.setViews([NSTextField(labelWithString: "Command"), custom], in: .leading)
        let hint = NSTextField(wrappingLabelWithString: "llama.cpp: install with `brew install llama.cpp` (or mise). MLX: needs `uv` (`brew install uv`); the model is downloaded on first start. og binds the server to 127.0.0.1 on a free port and stops it when you quit.")
        hint.font = Theme.smallFont
        hint.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [status, NSView(), actionButton])

        // Offline Go Docs controls (FR-19, FR-20, FR-23, FR-24, FR-27, FR-29, L-9, Issue #21, #28)
        docsEnabled.target = self
        docsEnabled.action = #selector(docsEnabledChanged)
        docsErrorHintsEnabled.target = self
        docsErrorHintsEnabled.action = #selector(docsErrorHintsEnabledChanged)
        docsSemanticEnabled.target = self
        docsSemanticEnabled.action = #selector(docsSemanticEnabledChanged)
        docsEmbedModel.isEditable = true
        docsEmbedModel.completes = false
        docsEmbedModel.delegate = self
        docsEmbedModel.target = self
        docsEmbedModel.action = #selector(docsEmbedModelChanged)
        docsEmbedModel.addItems(withObjectValues: DocsEmbedModelPreset.all.map(\.title))
        docsEmbedModel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        docsRerankEnabled.target = self
        docsRerankEnabled.action = #selector(docsRerankEnabledChanged)
        docsRerankModel.isEditable = true
        docsRerankModel.completes = false
        docsRerankModel.delegate = self
        docsRerankModel.target = self
        docsRerankModel.action = #selector(docsRerankModelChanged)
        docsRerankModel.addItems(withObjectValues: DocsRerankModelPreset.all.map(\.title))
        docsRerankModel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        docsServerStatus.font = Theme.smallFont
        docsServerActionButton.target = self
        docsServerActionButton.action = #selector(docsServerActionClicked)
        docsReembedButton.target = self
        docsReembedButton.action = #selector(docsReembedClicked)
        let docsServerRow = NSStackView(views: [docsServerStatus, NSView(), docsReembedButton, docsServerActionButton])
        let docsSemanticHint = NSTextField(wrappingLabelWithString: "Requires `uv` (`brew install uv`). First start downloads ~1.15 GB of MLX models (BGE-M3 8-bit + BGE-Reranker-v2-M3 8-bit) and Python packages via `uvx`. Once cached, startup takes ~3s completely offline on 127.0.0.1; turn off anytime to stay in Phase 1 FTS5 mode.")
        docsSemanticHint.font = Theme.smallFont
        docsSemanticHint.textColor = .secondaryLabelColor

        for m in DocsAnswerLLMMode.allCases { docsAnswerMode.addItem(withTitle: m.title) }
        docsAnswerMode.target = self
        docsAnswerMode.action = #selector(docsAnswerModeChanged)
        for b in ModelBackend.allCases { docsAnswerBackend.addItem(withTitle: b.title) }
        docsAnswerBackend.target = self
        docsAnswerBackend.action = #selector(docsAnswerBackendChanged)
        docsAnswerModel.isEditable = true
        docsAnswerModel.completes = false
        docsAnswerModel.delegate = self
        docsAnswerModel.target = self
        docsAnswerModel.action = #selector(docsAnswerModelChanged)
        docsAnswerModel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        docsIncludeEditorContext.target = self
        docsIncludeEditorContext.action = #selector(docsIncludeEditorContextChanged)
        docsAnswerStatus.font = Theme.smallFont
        docsAnswerActionButton.target = self
        docsAnswerActionButton.action = #selector(docsAnswerActionClicked)
        let docsAnswerRow = NSStackView(views: [docsAnswerStatus, NSView(), docsAnswerActionButton])

        for p in DocsBatchRunPolicy.allCases { docsBatchPolicy.addItem(withTitle: p.title) }
        docsBatchPolicy.target = self
        docsBatchPolicy.action = #selector(docsPolicyChanged)
        docsVersionCombo.isEditable = true
        docsVersionCombo.completes = false
        docsVersionCombo.placeholderString = "go1.23"
        docsVersionCombo.widthAnchor.constraint(equalToConstant: 96).isActive = true
        docsInstallButton.target = self
        docsInstallButton.action = #selector(docsInstallClicked)
        docsImportGorootButton.target = self
        docsImportGorootButton.action = #selector(docsImportGorootClicked)
        docsImportWebsiteButton.target = self
        docsImportWebsiteButton.action = #selector(docsImportWebsiteClicked)
        docsDeleteWebsiteButton.target = self
        docsDeleteWebsiteButton.action = #selector(docsDeleteWebsiteClicked)
        docsDeleteButton.target = self
        docsDeleteButton.action = #selector(docsDeleteClicked)
        docsPruneDepsButton.target = self
        docsPruneDepsButton.action = #selector(docsPruneDepsClicked)
        docsCancelButton.target = self
        docsCancelButton.action = #selector(docsCancelClicked)
        docsLicenseButton.target = self
        docsLicenseButton.action = #selector(docsLicenseClicked)
        docsPacksLabel.font = Theme.smallFont
        docsPacksLabel.textColor = Theme.secondaryText
        docsProgressBar.isIndeterminate = false
        docsProgressBar.minValue = 0
        docsProgressBar.maxValue = 1
        docsProgressBar.controlSize = .small
        docsProgressLabel.font = Theme.smallFont
        docsProgressLabel.textColor = Theme.secondaryText
        let docsButtons = NSStackView(views: [docsVersionCombo, docsInstallButton, docsImportGorootButton, docsDeleteButton, docsCancelButton, docsLicenseButton])
        docsButtons.orientation = .horizontal
        docsButtons.spacing = 6
        let docsCorpusButtons = NSStackView(views: [docsImportWebsiteButton, docsDeleteWebsiteButton, docsPruneDepsButton])
        docsCorpusButtons.orientation = .horizontal
        docsCorpusButtons.spacing = 6

        let stack = NSStackView(views: [
            row("Theme", themePopup), row("Font", fontFamily), NSStackView(views: [fontLabel, fontSize]), fontPreview,
            reopen, NSBox(),
            aiEnabled, row("Backend", backend), row("Model", model), customRow, hint, statusRow, logScroll,
            NSBox(),
            docsEnabled, docsErrorHintsEnabled, docsSemanticEnabled, docsSemanticHint, row("Embedding", docsEmbedModel), docsRerankEnabled, row("Reranker", docsRerankModel),
            docsServerRow,
            row("Synthesis", docsAnswerMode), row("LLM Back", docsAnswerBackend), row("LLM Model", docsAnswerModel), docsIncludeEditorContext, docsAnswerRow,
            row("Indexing", docsBatchPolicy), docsButtons, docsCorpusButtons, docsPacksLabel, docsProgressBar, docsProgressLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsSemanticHint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsServerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsAnswerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsProgressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        docsPacksLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        window?.contentView = scroll
    }

    private func load() {
        fontSize.doubleValue = Double(Theme.fontSize)
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        themePopup.selectItem(at: ThemeMode.allCases.firstIndex(of: Theme.mode) ?? 0)
        if let fam = Theme.fontFamily, fontFamily.itemTitles.contains(fam) { fontFamily.selectItem(withTitle: fam) } else { fontFamily.selectItem(at: 0) }
        fontPreview.font = Theme.editorFont
        reopen.state = ((UserDefaults.standard.object(forKey: "og.reopenLast") as? Bool) ?? true) ? .on : .off
        let m = ModelServerManager.shared
        aiEnabled.state = m.enabled ? .on : .off
        let cfg = m.config
        backend.selectItem(at: ModelBackend.allCases.firstIndex(of: cfg.backend) ?? 0)
        fillModels(for: cfg.backend)
        model.stringValue = ModelPreset.all.first { $0.id == cfg.model }?.title ?? cfg.model
        custom.stringValue = cfg.customCommand
        updateRows()
        refreshStatus()
        refreshDocs()
    }

    private func fillModels(for b: ModelBackend) {
        model.removeAllItems()
        model.addItems(withObjectValues: ModelPreset.presets(for: b).map(\.title))
    }

    private func updateRows() {
        let b = ModelBackend.allCases[max(0, backend.indexOfSelectedItem)]
        customRow.isHidden = b != .custom
        model.isEnabled = b != .custom
    }

    private func refreshStatus() {
        let m = ModelServerManager.shared
        switch m.phase {
        case .off: status.stringValue = "Server: off"; status.textColor = .secondaryLabelColor; actionButton.title = "Start"
        case .starting(let d): status.stringValue = "Server: \(d)"; status.textColor = .systemOrange; actionButton.title = "Restart"
        case .ready: status.stringValue = "Server: ready on 127.0.0.1:\(m.port ?? 0)"; status.textColor = .systemGreen; actionButton.title = "Restart"
        case .failed(let why): status.stringValue = "Server failed: \(why)"; status.textColor = .systemRed; actionButton.title = "Retry"
        }
        actionButton.isEnabled = m.enabled
        logView.string = m.log.suffix(200).joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - Actions

    private func save(_ change: (inout ModelServerConfig) -> Void) {
        var cfg = ModelServerManager.shared.config
        change(&cfg)
        ModelServerManager.shared.config = cfg
    }

    @objc private func enabledChanged() {
        ModelServerManager.shared.enabled = aiEnabled.state == .on
        refreshStatus()
    }

    @objc private func backendChanged() {
        let b = ModelBackend.allCases[max(0, backend.indexOfSelectedItem)]
        fillModels(for: b)
        let first = ModelPreset.presets(for: b).first
        model.stringValue = first?.title ?? ""
        updateRows()
        save { $0.backend = b; $0.model = first?.id ?? "" }
    }

    @objc private func modelChanged() {
        let text = model.stringValue.trimmingCharacters(in: .whitespaces)
        let id = ModelPreset.all.first { $0.title == text }?.id ?? text
        guard !id.isEmpty else { return }
        save { $0.model = id }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let sender = notification.object as AnyObject?
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if sender === self.docsEmbedModel {
                    self.docsEmbedModelChanged()
                } else if sender === self.docsRerankModel {
                    self.docsRerankModelChanged()
                } else if sender === self.docsAnswerModel {
                    self.docsAnswerModelChanged()
                } else if sender === self.model {
                    self.modelChanged()
                }
            }
        }
    }

    @objc private func customChanged() {
        save { $0.customCommand = custom.stringValue }
    }

    @objc private func actionClicked() {
        let m = ModelServerManager.shared
        switch m.phase {
        case .failed: m.retry()
        case .off: m.enabled = true
        default: m.restart()
        }
    }

    static let systemMono = "System Monospaced (SF Mono)"

    @objc private func fontChanged() {
        Theme.setFont(family: Theme.fontFamily, size: CGFloat(fontSize.doubleValue))
        fontLabel.stringValue = "Editor font size: \(Int(Theme.fontSize))"
        fontPreview.font = Theme.editorFont
    }

    @objc private func familyChanged() {
        let title = fontFamily.titleOfSelectedItem
        Theme.setFont(family: title == Self.systemMono ? nil : title, size: Theme.fontSize)
        fontPreview.font = Theme.editorFont
    }

    @objc private func themeChanged() {
        Theme.mode = ThemeMode.allCases[max(0, themePopup.indexOfSelectedItem)]
    }

    @objc private func reopenChanged() {
        UserDefaults.standard.set(reopen.state == .on, forKey: "og.reopenLast")
    }

    // MARK: - Offline Go Docs Actions (FR-19, FR-20, FR-23, FR-24, FR-29)

    private func refreshDocs() {
        let d = DocsManager.shared
        let ds = DocsServerManager.shared
        let dsCfg = ds.config
        docsEnabled.state = d.enabled ? .on : .off
        docsErrorHintsEnabled.state = d.errorHintsEnabled ? .on : .off
        docsErrorHintsEnabled.isEnabled = d.enabled
        docsSemanticEnabled.state = ds.enabled ? .on : .off
        docsSemanticEnabled.isEnabled = d.enabled
        docsEmbedModel.stringValue = DocsEmbedModelPreset.matching(id: dsCfg.embedModel)?.title ?? dsCfg.embedModel
        docsEmbedModel.isEnabled = d.enabled && ds.enabled
        docsRerankEnabled.state = dsCfg.rerankEnabled ? .on : .off
        docsRerankEnabled.isEnabled = d.enabled && ds.enabled
        docsRerankModel.stringValue = DocsRerankModelPreset.matching(id: dsCfg.rerankModel)?.title ?? dsCfg.rerankModel
        docsRerankModel.isEnabled = d.enabled && ds.enabled && dsCfg.rerankEnabled

        switch ds.phase {
        case .off:
            docsServerStatus.stringValue = "Docs MLX Server: off (Phase 1 FTS5 mode)"
            docsServerStatus.textColor = .secondaryLabelColor
            docsServerActionButton.title = "Start"
        case .starting(let detail):
            docsServerStatus.stringValue = "Docs MLX Server: \(detail)"
            docsServerStatus.textColor = .systemOrange
            docsServerActionButton.title = "Restart"
        case .ready:
            let rr = ds.rerankReady ? " + reranker" : ""
            docsServerStatus.stringValue = "Docs MLX Server: ready on 127.0.0.1:\(ds.port ?? 0) (embedder\(rr))"
            docsServerStatus.textColor = .systemGreen
            docsServerActionButton.title = "Restart"
        case .failed(let why):
            docsServerStatus.stringValue = "Docs MLX Server failed: \(why)"
            docsServerStatus.textColor = .systemRed
            docsServerActionButton.title = "Retry"
        }
        docsServerActionButton.isEnabled = d.enabled && ds.enabled
        docsReembedButton.isEnabled = d.enabled && ds.phase == .ready && !d.installedPacks.isEmpty

        let ansMgr = DocsAnswerServerManager.shared
        let ansCfg = ansMgr.config
        docsAnswerMode.selectItem(at: DocsAnswerLLMMode.allCases.firstIndex(of: ansCfg.mode) ?? 0)
        docsAnswerMode.isEnabled = d.enabled
        docsAnswerBackend.selectItem(at: ModelBackend.allCases.firstIndex(of: ansCfg.backend) ?? 0)
        docsAnswerBackend.isEnabled = d.enabled && ansCfg.mode == .dedicated
        docsAnswerModel.removeAllItems()
        docsAnswerModel.addItems(withObjectValues: DocsAnswerModelPreset.presets(for: ansCfg.backend).map(\.title))
        docsAnswerModel.stringValue = DocsAnswerModelPreset.all.first { $0.id == ansCfg.model }?.title ?? ansCfg.model
        docsAnswerModel.isEnabled = d.enabled && ansCfg.mode == .dedicated
        docsIncludeEditorContext.state = ansCfg.includeEditorContext ? .on : .off
        docsIncludeEditorContext.isEnabled = d.enabled && ansCfg.mode != .off
        docsAnswerStatus.stringValue = ansMgr.statusText
        if ansCfg.mode == .sharedCompletion {
            let modelName = ModelServerManager.shared.loadedModelName ?? ModelServerManager.shared.config.model
            let isLikelyNonInstruct = modelName.contains("--fim-") || !modelName.lowercased().contains("instruct")
            if isLikelyNonInstruct {
                docsAnswerStatus.stringValue = "\(ansMgr.statusText) — 注意: FIM/非Instructモデルでは生成が不安定になる場合があります"
                docsAnswerStatus.textColor = .systemOrange
            } else {
                docsAnswerStatus.textColor = .systemGreen
            }
        } else {
            switch ansMgr.phase {
            case .failed: docsAnswerStatus.textColor = .systemRed; docsAnswerActionButton.title = "Retry"
            case .ready: docsAnswerStatus.textColor = .systemGreen; docsAnswerActionButton.title = "Restart"
            case .starting: docsAnswerStatus.textColor = .systemOrange; docsAnswerActionButton.title = "Restart"
            case .off: docsAnswerStatus.textColor = .secondaryLabelColor; docsAnswerActionButton.title = "Start"
            }
        }
        docsAnswerActionButton.isEnabled = d.enabled && ansCfg.mode == .dedicated

        docsBatchPolicy.selectItem(at: DocsBatchRunPolicy.allCases.firstIndex(of: d.batchPolicy) ?? 0)

        let packs = d.installedPacks
        // L-9: populate combo dynamically from installed packs, cached toolchain version, and bundled default.
        var versions: [String] = []
        for p in packs where !versions.contains(p.goVersion) { versions.append(p.goVersion) }
        if let detected = d.detectedToolchainVersion?.minorKey, !versions.contains(detected) {
            versions.append(detected)
        }
        if !versions.contains(BundledGoCorpus.defaultVersion) {
            versions.append(BundledGoCorpus.defaultVersion)
        }
        let currentSelection = docsVersionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        docsVersionCombo.removeAllItems()
        docsVersionCombo.addItems(withObjectValues: versions.sorted(by: >).map { "go\($0)" })
        if currentSelection.isEmpty {
            docsVersionCombo.stringValue = "go\(BundledGoCorpus.defaultVersion)"
        }

        let depPacks = d.installedDependencyPacks
        docsPruneDepsButton.isEnabled = !depPacks.isEmpty
        let webPack = d.installedWebsitePack
        docsDeleteWebsiteButton.isEnabled = webPack != nil
        let webSummaryLine: String? = webPack.map { w in
            let kb = max(1, w.sizeBytes / 1024)
            let mode = w.status == .ready ? "ready (FTS + semantic)" : "FTS-only"
            let commitPart = w.snapshotCommit.map { " @\($0)" } ?? ""
            return "• golang/website (snapshot \(w.snapshotDate)\(commitPart)): \(w.chunkCount) chunks, \(kb) KB [\(mode)]"
        }
        let depSummaryLine: String? = depPacks.isEmpty ? nil : {
            let totalKB = max(1, depPacks.reduce(Int64(0)) { $0 + $1.sizeBytes } / 1024)
            let totalChunks = depPacks.reduce(0) { $0 + $1.chunkCount }
            let partialCount = depPacks.filter(\.truncated).count
            let partialNote = partialCount > 0 ? ", \(partialCount) partial" : ""
            return "Dependency packs: \(depPacks.count) modules (\(totalChunks) chunks, \(totalKB) KB\(partialNote))"
        }()

        if packs.isEmpty {
            var lines = ["Installed packs: none (enabling installs bundled go\(BundledGoCorpus.defaultVersion) core pack offline)"]
            if let webSummaryLine { lines.append(webSummaryLine) }
            if let depSummaryLine { lines.append(depSummaryLine) }
            docsPacksLabel.stringValue = lines.joined(separator: "\n")
        } else {
            var lines = packs.map { p in
                let kb = max(1, p.sizeBytes / 1024)
                let mode = p.status == .ready ? "ready (FTS + semantic)" : "FTS-only"
                let legacyNote = p.needsReimport ? " — legacy v1 schema: re-import recommended" : ""
                return "• go\(p.goVersion): \(p.chunkCount) chunks, \(kb) KB [\(mode)]\(legacyNote)"
            }
            if let webSummaryLine { lines.append(webSummaryLine) }
            if let depSummaryLine { lines.append(depSummaryLine) }
            docsPacksLabel.stringValue = "Installed packs:\n" + lines.joined(separator: "\n")
        }

        if let p = d.activeProgress {
            docsProgressBar.doubleValue = p.fractionCompleted
            let estKB = max(1, p.estimatedBytes / 1024)
            let isRunning = p.phase == .extracting || p.phase == .buildingFTS || p.phase == .embedding || p.phase == .activating
            docsCancelButton.isEnabled = isRunning
            let targetLabel = (p.goVersion.contains("@") || p.goVersion.contains(" ")) ? p.goVersion : "go\(p.goVersion)"
            docsProgressLabel.stringValue = "Batch \(targetLabel): \(p.phase.rawValue) (\(p.processedChunks)/\(p.totalChunks) chunks, est. \(estKB) KB, reused \(p.reusedVectors))"
        } else if let err = d.lastError {
            docsProgressBar.doubleValue = 0
            docsCancelButton.isEnabled = false
            docsProgressLabel.stringValue = "Docs error: \(err)"
        } else {
            docsProgressBar.doubleValue = 0
            docsCancelButton.isEnabled = false
            docsProgressLabel.stringValue = "Batch: idle"
        }
    }

    private var knownDocsVersions: Set<String> {
        let d = DocsManager.shared
        var versions = Set(d.installedPacks.map(\.goVersion))
        if let detected = d.detectedToolchainVersion?.minorKey {
            versions.insert(detected)
        }
        versions.insert(BundledGoCorpus.defaultVersion)
        return versions
    }

    private func parsedSelectedDocsVersion() -> String? {
        let raw = docsVersionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        return GoVersion(parsing: raw)?.minorKey
    }

    private func showDocsAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w, completionHandler: nil) } else { alert.runModal() }
    }

    @objc private func docsEnabledChanged() {
        DocsManager.shared.enabled = docsEnabled.state == .on
        refreshDocs()
    }

    @objc private func docsErrorHintsEnabledChanged() {
        DocsManager.shared.errorHintsEnabled = docsErrorHintsEnabled.state == .on
        refreshDocs()
    }

    @objc private func docsSemanticEnabledChanged() {
        DocsServerManager.shared.enabled = docsSemanticEnabled.state == .on
        refreshDocs()
    }

    @objc private func docsEmbedModelChanged() {
        let text = docsEmbedModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = DocsEmbedModelPreset.all.first { $0.title == text || $0.id == text }
        let newID = preset?.id ?? text
        let newVer = preset?.version ?? "custom-v1"
        guard !newID.isEmpty else { return }
        var cfg = DocsServerManager.shared.config
        guard cfg.embedModel != newID else { return }

        // FR-27: warn before switching embedding models when Ready packs exist.
        let hasReady = DocsManager.shared.installedPacks.contains { $0.status == .ready }
        let applyChange: () -> Void = {
            cfg.embedModel = newID
            cfg.embedModelVersion = newVer
            DocsServerManager.shared.config = cfg
            self.refreshDocs()
        }
        if hasReady {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Switch Docs embedding model?"
            alert.informativeText = "Existing packs with embeddings will revert to FTS-only mode until you rebuild their embeddings with \"Build Embeddings\" (vectors from different models are never mixed)."
            alert.addButton(withTitle: "Switch Model")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    applyChange()
                } else {
                    self.refreshDocs()
                }
            }
            if let w = window {
                alert.beginSheetModal(for: w, completionHandler: handle)
            } else {
                handle(alert.runModal())
            }
        } else {
            applyChange()
        }
    }

    @objc private func docsRerankEnabledChanged() {
        var cfg = DocsServerManager.shared.config
        cfg.rerankEnabled = docsRerankEnabled.state == .on
        DocsServerManager.shared.config = cfg
        refreshDocs()
    }

    @objc private func docsRerankModelChanged() {
        let text = docsRerankModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = DocsRerankModelPreset.all.first { $0.title == text || $0.id == text }
        let newID = preset?.id ?? text
        guard !newID.isEmpty else { return }
        var cfg = DocsServerManager.shared.config
        guard cfg.rerankModel != newID else { return }
        cfg.rerankModel = newID
        DocsServerManager.shared.config = cfg
        refreshDocs()
    }

    @objc private func docsServerActionClicked() {
        let ds = DocsServerManager.shared
        switch ds.phase {
        case .failed: ds.retry()
        case .off: ds.enabled = true
        default: ds.restart()
        }
    }

    @objc private func docsReembedClicked() {
        guard let ver = parsedSelectedDocsVersion() else {
            showDocsAlert(
                message: "Invalid Go Version",
                info: "Select an installed Go pack version to build embeddings for."
            )
            return
        }
        DocsManager.shared.startReembedPack(goVersion: ver)
    }

    @objc private func docsPolicyChanged() {
        DocsManager.shared.batchPolicy = DocsBatchRunPolicy.allCases[max(0, docsBatchPolicy.indexOfSelectedItem)]
    }

    @objc private func docsInstallClicked() {
        guard let ver = parsedSelectedDocsVersion() else {
            showDocsAlert(
                message: "Invalid Go Version",
                info: "Enter a valid Go version such as go\(BundledGoCorpus.defaultVersion)."
            )
            return
        }
        // R-3: require explicit confirmation before creating a bundled-excerpt pack for an unverified version.
        if !knownDocsVersions.contains(ver) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Create pack for unverified Go version go\(ver)?"
            alert.informativeText = "go\(ver) was not detected among installed packs or your local Go toolchain. Bundled excerpts are curated for go\(BundledGoCorpus.defaultVersion); for an accurate pack of another Go version, use \"Import GOROOT…\" instead. Continue anyway?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create Pack")
            let proceed: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertSecondButtonReturn {
                    DocsManager.shared.startBundledPackIngestion(goVersion: ver)
                }
            }
            if let w = window {
                alert.beginSheetModal(for: w, completionHandler: proceed)
            } else {
                proceed(alert.runModal())
            }
            return
        }
        DocsManager.shared.startBundledPackIngestion(goVersion: ver)
    }

    @objc private func docsImportGorootClicked() {
        guard let ver = parsedSelectedDocsVersion() else {
            showDocsAlert(
                message: "Invalid Go Version",
                info: "Enter the Go version matching the GOROOT you are importing (e.g. go\(BundledGoCorpus.defaultVersion))."
            )
            return
        }
        Task { @MainActor [weak self] in
            let detected = await GoVersionResolver.detectGorootAsync()
            guard self != nil else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose a local GOROOT directory (containing src/) for go\(ver)"
            if let detected { panel.directoryURL = detected }
            if panel.runModal() == .OK, let url = panel.url {
                DocsManager.shared.startGorootIngestion(goroot: url, goVersion: ver)
            }
        }
    }

    @objc private func docsImportWebsiteClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a local golang/website checkout directory (containing _content/)"
        if panel.runModal() == .OK, let url = panel.url {
            DocsManager.shared.startWebsiteIngestion(websiteRoot: url)
        }
    }

    @objc private func docsDeleteWebsiteClicked() {
        DocsManager.shared.deleteWebsitePack()
    }

    @objc private func docsDeleteClicked() {
        guard let ver = parsedSelectedDocsVersion() else { return }
        DocsManager.shared.deletePack(goVersion: ver)
    }

    @objc private func docsPruneDepsClicked() {
        let openRoots = NSApp.windows.compactMap { ($0.windowController as? ProjectWindowController)?.context.root }
        DocsManager.shared.pruneUnusedDependencyPacks(keepingProjectRoots: openRoots)
    }

    @objc private func docsCancelClicked() {
        DocsManager.shared.cancelActiveBatch()
    }

    @objc private func docsLicenseClicked() {
        let alert = NSAlert()
        alert.messageText = "Go Documentation License (BSD-3-Clause)"
        alert.informativeText = DocsLicense.goBSD3Clause
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w, completionHandler: nil) } else { alert.runModal() }
    }

    @objc private func docsAnswerModeChanged() {
        var cfg = DocsAnswerServerManager.shared.config
        cfg.mode = DocsAnswerLLMMode.allCases[max(0, docsAnswerMode.indexOfSelectedItem)]
        DocsAnswerServerManager.shared.config = cfg
        refreshDocs()
    }

    @objc private func docsAnswerBackendChanged() {
        var cfg = DocsAnswerServerManager.shared.config
        let b = ModelBackend.allCases[max(0, docsAnswerBackend.indexOfSelectedItem)]
        cfg.backend = b
        if let firstPreset = DocsAnswerModelPreset.presets(for: b).first {
            cfg.model = firstPreset.id
        }
        DocsAnswerServerManager.shared.config = cfg
        refreshDocs()
    }

    @objc private func docsAnswerModelChanged() {
        let text = docsAnswerModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let preset = DocsAnswerModelPreset.all.first { $0.title == text || $0.id == text }
        var cfg = DocsAnswerServerManager.shared.config
        cfg.model = preset?.id ?? text
        DocsAnswerServerManager.shared.config = cfg
        refreshDocs()
    }

    @objc private func docsIncludeEditorContextChanged() {
        var cfg = DocsAnswerServerManager.shared.config
        cfg.includeEditorContext = docsIncludeEditorContext.state == .on
        DocsAnswerServerManager.shared.config = cfg
        DocsManager.shared.syncInferenceClients()
    }

    @objc private func docsAnswerActionClicked() {
        let mgr = DocsAnswerServerManager.shared
        switch mgr.phase {
        case .failed: mgr.retry()
        case .off: mgr.restart()
        default: mgr.restart()
        }
    }
}
