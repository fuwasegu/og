import AppKit
import OgCore

/// Menu / shortcut actions. Delivered through the responder chain.
extension ProjectWindowController: NSMenuItemValidation {
    private var editor: EditorController? { editorArea.current }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsEditor: Set<Selector> = [
            #selector(ogSave(_:)), #selector(ogCloseTab(_:)), #selector(ogFind(_:)), #selector(ogReplace(_:)),
            #selector(ogFindNext(_:)), #selector(ogFindPrevious(_:)), #selector(ogGotoLine(_:)),
            #selector(ogGotoDeclaration(_:)), #selector(ogGotoImplementation(_:)), #selector(ogGotoTypeDeclaration(_:)),
            #selector(ogFindUsages(_:)), #selector(ogFileStructure(_:)), #selector(ogNextError(_:)), #selector(ogPreviousError(_:)),
            #selector(ogComplete(_:)), #selector(ogQuickFix(_:)), #selector(ogQuickDoc(_:)), #selector(ogParameterInfo(_:)),
            #selector(ogReformat(_:)), #selector(ogOrganizeImports(_:)), #selector(ogStructTags(_:)), #selector(ogTableTest(_:)),
            #selector(ogRename(_:)), #selector(ogToggleBreakpoint(_:)), #selector(ogRollbackFile(_:)), #selector(ogRequestAICompletion(_:))
        ]
        if let action = menuItem.action, needsEditor.contains(action) { return editor != nil }
        let debugActions: Set<Selector> = [#selector(ogResume(_:)), #selector(ogStepOver(_:)), #selector(ogStepInto(_:)), #selector(ogStepOut(_:))]
        if let action = menuItem.action, debugActions.contains(action) { return bottomPanel.debugPanel.isDebugging }
        if menuItem.action == #selector(ogUndoRename(_:)) { return RenameSheet.lastRecord != nil }
        if menuItem.action == #selector(ogToggleMarkdownPreview(_:)) {
            menuItem.state = editor?.markdownPreview?.view.isHidden == false ? .on : .off
            return editor?.markdownPreview != nil
        }
        return true
    }

    // MARK: - File

    @objc func ogShowWelcome(_ sender: Any?) { AppDelegate.shared?.showWelcome() }
    @objc func ogShowSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(nil) }
    @objc func ogNewFile(_ sender: Any?) { sidebar.tree.newFile() }

    @objc func ogSave(_ sender: Any?) {
        guard let editor else { return }
        context.documents.saveWithFormatting(editor.document, editor: editor)
    }

    @objc func ogToggleMarkdownPreview(_ sender: Any?) { editor?.toggleMarkdownPreview() }

    @objc func ogSaveAll(_ sender: Any?) {
        if !context.saveAll() { context.setStatus("Some files could not be saved") }
    }

    @objc func ogCloseTab(_ sender: Any?) { editorArea.closeCurrent() }

    // MARK: - Edit / find

    private func finder(_ action: NSTextFinder.Action) {
        guard let tv = editor?.textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.performFindPanelAction(item)
    }

    @objc func ogFind(_ sender: Any?) { finder(.showFindInterface) }
    @objc func ogReplace(_ sender: Any?) { finder(.showReplaceInterface) }
    @objc func ogFindNext(_ sender: Any?) { finder(.nextMatch) }
    @objc func ogFindPrevious(_ sender: Any?) { finder(.previousMatch) }

    @objc func ogFindInFiles(_ sender: Any?) {
        let sel = editor.map { ($0.document.storage.string as NSString).substring(with: $0.textView.selectedRange()) } ?? ""
        bottomPanel.findPanel.findInFiles(sel.contains("\n") ? "" : sel)
        bottomPanel.show(.find)
    }

    // MARK: - View

    @objc func ogToggleSidebar(_ sender: Any?) { toggleSidebar() }
    @objc func ogShowRun(_ sender: Any?) { bottomPanel.show(.run) }
    @objc func ogShowDebug(_ sender: Any?) { bottomPanel.show(.debug) }
    @objc func ogShowProblems(_ sender: Any?) { bottomPanel.show(.problems) }
    @objc func ogShowCommit(_ sender: Any?) { bottomPanel.show(.git); bottomPanel.gitPanel.focusCommit() }

    @objc func ogShowTerminal(_ sender: Any?) {
        if isBottomPanelVisible && bottomPanel.selected == .terminal {
            toggleBottomPanel()
            editor?.focus()
        } else {
            bottomPanel.show(.terminal)
            bottomPanel.terminalPanel.focus()
        }
    }

    @objc func ogToggleBottomPanel(_ sender: Any?) { toggleBottomPanel() }

    private func setFontSize(_ size: CGFloat) {
        Theme.setFont(family: Theme.fontFamily, size: max(9, min(32, size)))
    }

    @objc func ogZoomIn(_ sender: Any?) { setFontSize(Theme.fontSize + 1) }
    @objc func ogZoomOut(_ sender: Any?) { setFontSize(Theme.fontSize - 1) }
    @objc func ogZoomReset(_ sender: Any?) { setFontSize(13) }

    // MARK: - Navigate

    @objc func ogGotoFile(_ sender: Any?) { GotoFilePalette.showFiles(in: context) }
    @objc func ogGotoSymbol(_ sender: Any?) { GotoFilePalette.showSymbols(in: context) }
    @objc func ogRecentFiles(_ sender: Any?) { GotoFilePalette.showRecent(in: context, recent: editorArea.recent) }

    @objc func ogGotoLine(_ sender: Any?) {
        guard let editor, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line:Column"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let p = editor.caretPosition
        field.stringValue = "\(p.line + 1):\(p.character + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return }
            self?.editorArea.pushHistory()
            editor.reveal(line: max(0, line - 1), column: max(0, (parts.count > 1 ? parts[1] : 1) - 1), length: 0)
            editor.focus()
        }
    }

    @objc func ogGotoDeclaration(_ sender: Any?) { editor?.gotoDeclaration() }
    @objc func ogGotoImplementation(_ sender: Any?) { editor?.gotoImplementation() }
    @objc func ogGotoTypeDeclaration(_ sender: Any?) { editor?.gotoTypeDeclaration() }
    @objc func ogFindUsages(_ sender: Any?) { editor?.findUsages() }
    @objc func ogFileStructure(_ sender: Any?) { sidebar.showStructure() }
    @objc func ogBack(_ sender: Any?) { editorArea.goBack() }
    @objc func ogForward(_ sender: Any?) { editorArea.goForward() }
    @objc func ogNextError(_ sender: Any?) { editor?.gotoNextError(forward: true) }
    @objc func ogPreviousError(_ sender: Any?) { editor?.gotoNextError(forward: false) }
    @objc func ogNextTab(_ sender: Any?) { editorArea.selectNext(1) }
    @objc func ogPreviousTab(_ sender: Any?) { editorArea.selectNext(-1) }

    // MARK: - Code

    @objc func ogComplete(_ sender: Any?) { editor?.requestCompletion(explicit: true) }
    @objc func ogQuickFix(_ sender: Any?) { editor?.showCodeActions() }
    @objc func ogQuickDoc(_ sender: Any?) { editor?.showDocumentationAtCaret() }
    @objc func ogParameterInfo(_ sender: Any?) { editor?.showSignatureHelp() }
    @objc func ogReformat(_ sender: Any?) { editor?.reformat() }
    @objc func ogOrganizeImports(_ sender: Any?) { editor?.organizeImports() }
    @objc func ogStructTags(_ sender: Any?) { editor?.addStructTags() }
    @objc func ogTableTest(_ sender: Any?) { editor?.generateTableTest() }
    @objc func ogRequestAICompletion(_ sender: Any?) {
        guard EditorController.aiEnabled else { context.setStatus("Enable local AI completion in Settings (⌘,)"); return }
        guard ModelServerManager.shared.client != nil else { context.setStatus(ModelServerManager.shared.statusText); return }
        editor?.requestGhost()
    }

    // MARK: - Refactor

    @objc func ogRename(_ sender: Any?) { editor?.startRename() }
    @objc func ogUndoRename(_ sender: Any?) { RenameSheet.undoLast(context: context) }

    // MARK: - Run / debug

    /// Run target for the caret: the test/bench func under the caret, else the package.
    private func runTarget() -> RunRequest {
        guard let editor else { return .runMain(packageDir: context.root) }
        let dir = editor.document.url.deletingLastPathComponent()
        let lines = TextLines(nsString: editor.document.storage.string as NSString)
        var line = editor.caretPosition.line
        while line >= 0 {
            let t = lines.lineText(line)
            if t.hasPrefix("func ") {
                if let name = GutterView.funcName(t) {
                    if name.hasPrefix("Test") && t.contains("*testing.T") { return .test(packageDir: dir, name: name) }
                    if name.hasPrefix("Benchmark") && t.contains("*testing.B") { return .bench(packageDir: dir, name: name) }
                    if name == "main" { return .runMain(packageDir: dir) }
                }
                break
            }
            line -= 1
        }
        if editor.document.url.lastPathComponent.hasSuffix("_test.go") { return .test(packageDir: dir, name: nil) }
        let text = editor.document.text
        if text.contains("package main") && text.contains("func main()") { return .runMain(packageDir: dir) }
        return .test(packageDir: dir, name: nil)
    }

    @objc func ogRun(_ sender: Any?) { context.run(runTarget()) }
    @objc func ogDebug(_ sender: Any?) {
        let t = runTarget()
        if case .bench = t { context.run(t) } else { context.debug(t) }
    }
    @objc func ogRerun(_ sender: Any?) { bottomPanel.runPanel.rerun(); bottomPanel.show(.run) }
    @objc func ogStop(_ sender: Any?) {
        if bottomPanel.debugPanel.isDebugging { bottomPanel.debugPanel.stop() } else { bottomPanel.runPanel.stop() }
    }
    @objc func ogTestAll(_ sender: Any?) { context.run(.test(packageDir: context.root, name: "./...")) }

    @objc func ogToggleBreakpoint(_ sender: Any?) {
        guard let editor else { return }
        context.breakpoints.toggle(editor.document.url, line: editor.caretPosition.line)
    }

    @objc func ogResume(_ sender: Any?) { bottomPanel.debugPanel.resume() }
    @objc func ogStepOver(_ sender: Any?) { bottomPanel.debugPanel.stepOver() }
    @objc func ogStepInto(_ sender: Any?) { bottomPanel.debugPanel.stepInto() }
    @objc func ogStepOut(_ sender: Any?) { bottomPanel.debugPanel.stepOut() }

    // MARK: - Git

    @objc func ogBranches(_ sender: Any?) {
        bottomPanel.gitPanel.showBranchMenu(from: statusBar)
    }

    @objc func ogRollbackFile(_ sender: Any?) {
        guard let editor, let window else { return }
        let rel = context.relativePath(editor.document.url)
        let alert = NSAlert()
        alert.messageText = "Rollback \(editor.document.url.lastPathComponent)?"
        alert.informativeText = "All local changes to this file will be discarded."
        alert.addButton(withTitle: "Rollback")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let doc = editor.document
            doc.markSaved(doc.text)  // drop pending autosave
            Task {
                do {
                    try await self.context.git.rollback(relativePath: rel)
                    if let text = try? String(contentsOf: doc.url, encoding: .utf8) {
                        editor.reloadPreservingSelection(text)
                        doc.markSaved(text)
                    }
                    self.context.refreshGit()
                } catch {
                    let a = NSAlert()
                    a.messageText = "Rollback failed"
                    a.informativeText = error.localizedDescription
                    if let w = self.window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
                }
            }
        }
    }
}
