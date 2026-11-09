import AppKit

/// Main menu with GoLand (macOS keymap) shortcuts. Project actions travel the
/// responder chain to ProjectWindowController (see ProjectWindowController+Actions).
@MainActor
enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private static func fkey(_ n: Int) -> String {
        String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!))
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        for i in items { m.addItem(i) }
        top.submenu = m
        return top
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        typealias P = ProjectWindowController
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let backspace = String(Character(UnicodeScalar(8)))
        let enter = "\r"

        main.addItem(menu("og", [
            item("About og", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(P.ogShowSettings(_:)), ","),
            item("Setup Assistant…", #selector(AppDelegate.ogShowSetup(_:)), ""),
            .separator(),
            item("Hide og", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit og", #selector(NSApplication.terminate(_:)), "q")
        ]))

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentMenuDelegate.shared
        recent.submenu = recentMenu
        main.addItem(menu("File", [
            item("Open…", #selector(AppDelegate.openFolderPanel(_:)), "o"),
            recent,
            item("Welcome", #selector(P.ogShowWelcome(_:)), ""),
            .separator(),
            item("New Go File…", #selector(P.ogNewFile(_:)), "n"),
            item("Save", #selector(P.ogSave(_:)), "s"),
            item("Save All", #selector(P.ogSaveAll(_:)), "s", [.command, .option]),
            .separator(),
            item("Close Tab", #selector(P.ogCloseTab(_:)), "w"),
            item("Close Project", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        ]))

        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(P.ogFind(_:)), "f"),
            item("Replace…", #selector(P.ogReplace(_:)), "r"),
            item("Find Next", #selector(P.ogFindNext(_:)), "g"),
            item("Find Previous", #selector(P.ogFindPrevious(_:)), "g", [.command, .shift]),
            item("Find in Files…", #selector(P.ogFindInFiles(_:)), "f", [.command, .shift]),
            .separator(),
            item("Duplicate Line or Selection", #selector(CodeTextView.ogDuplicate(_:)), "d"),
            item("Delete Line", #selector(CodeTextView.ogDeleteLine(_:)), backspace),
            item("Comment with Line Comment", #selector(CodeTextView.ogToggleComment(_:)), "/"),
            item("Move Line Up", #selector(CodeTextView.ogMoveLineUp(_:)), up, [.option, .shift]),
            item("Move Line Down", #selector(CodeTextView.ogMoveLineDown(_:)), down, [.option, .shift]),
            item("Extend Selection", #selector(CodeTextView.ogExtendSelection(_:)), up, [.option]),
            item("Shrink Selection", #selector(CodeTextView.ogShrinkSelection(_:)), down, [.option])
        ]))

        main.addItem(menu("View", [
            item("Project", #selector(P.ogToggleSidebar(_:)), "1"),
            item("Run", #selector(P.ogShowRun(_:)), "4"),
            item("Debug", #selector(P.ogShowDebug(_:)), "5"),
            item("Problems", #selector(P.ogShowProblems(_:)), "6"),
            item("Commit", #selector(P.ogShowCommit(_:)), "0"),
            item("Terminal", #selector(P.ogShowTerminal(_:)), fkey(12), [.option]),
            item("Hide Bottom Panel", #selector(P.ogToggleBottomPanel(_:)), "j"),
            .separator(),
            item("Increase Font Size", #selector(P.ogZoomIn(_:)), "+"),
            item("Decrease Font Size", #selector(P.ogZoomOut(_:)), "-"),
            item("Reset Font Size", #selector(P.ogZoomReset(_:)), "0", [.command, .option])
        ]))

        main.addItem(menu("Navigate", [
            item("Go to File…", #selector(P.ogGotoFile(_:)), "o", [.command, .shift]),
            item("Go to Symbol…", #selector(P.ogGotoSymbol(_:)), "o", [.command, .option]),
            item("Recent Files…", #selector(P.ogRecentFiles(_:)), "e"),
            item("Go to Line…", #selector(P.ogGotoLine(_:)), "l"),
            .separator(),
            item("Declaration or Usages", #selector(P.ogGotoDeclaration(_:)), "b"),
            item("Implementation(s)", #selector(P.ogGotoImplementation(_:)), "b", [.command, .option]),
            item("Type Declaration", #selector(P.ogGotoTypeDeclaration(_:)), "b", [.control, .shift]),
            item("Find Usages", #selector(P.ogFindUsages(_:)), fkey(7), [.option]),
            item("File Structure", #selector(P.ogFileStructure(_:)), fkey(12), [.command]),
            .separator(),
            item("Back", #selector(P.ogBack(_:)), "["),
            item("Forward", #selector(P.ogForward(_:)), "]"),
            item("Next Error", #selector(P.ogNextError(_:)), fkey(2), []),
            item("Previous Error", #selector(P.ogPreviousError(_:)), fkey(2), [.shift]),
            item("Select Next Tab", #selector(P.ogNextTab(_:)), "]", [.command, .shift]),
            item("Select Previous Tab", #selector(P.ogPreviousTab(_:)), "[", [.command, .shift])
        ]))

        main.addItem(menu("Code", [
            item("Completion", #selector(P.ogComplete(_:)), " ", [.control]),
            item("Show Context Actions", #selector(P.ogQuickFix(_:)), enter, [.option]),
            item("Quick Documentation", #selector(P.ogQuickDoc(_:)), fkey(1), []),
            item("Parameter Info", #selector(P.ogParameterInfo(_:)), "p"),
            .separator(),
            item("Reformat Code", #selector(P.ogReformat(_:)), "l", [.command, .option]),
            item("Optimize Imports", #selector(P.ogOrganizeImports(_:)), "o", [.control, .option]),
            .separator(),
            item("Add Struct Tags (json)", #selector(P.ogStructTags(_:)), "t", [.command, .shift]),
            item("Generate Table Test", #selector(P.ogTableTest(_:)), "g", [.command, .shift, .option]),
            item("Request AI Completion", #selector(P.ogRequestAICompletion(_:)), "\\", [.option])
        ]))

        main.addItem(menu("Refactor", [
            item("Rename…", #selector(P.ogRename(_:)), fkey(6), [.shift]),
            item("Undo Last Rename", #selector(P.ogUndoRename(_:)), "")
        ]))

        main.addItem(menu("Run", [
            item("Run", #selector(P.ogRun(_:)), "r", [.control]),
            item("Debug", #selector(P.ogDebug(_:)), "d", [.control]),
            item("Rerun", #selector(P.ogRerun(_:)), "r", [.command, .control]),
            item("Stop", #selector(P.ogStop(_:)), fkey(2), [.command]),
            .separator(),
            item("Toggle Breakpoint", #selector(P.ogToggleBreakpoint(_:)), fkey(8), [.command]),
            item("Resume", #selector(P.ogResume(_:)), "r", [.command, .option]),
            item("Step Over", #selector(P.ogStepOver(_:)), fkey(8), []),
            item("Step Into", #selector(P.ogStepInto(_:)), fkey(7), []),
            item("Step Out", #selector(P.ogStepOut(_:)), fkey(8), [.shift]),
            .separator(),
            item("Test All Packages", #selector(P.ogTestAll(_:)), "")
        ]))

        main.addItem(menu("Git", [
            item("Commit…", #selector(P.ogShowCommit(_:)), "k"),
            item("Branches…", #selector(P.ogBranches(_:)), "b", [.control, .shift, .option]),
            item("Rollback File", #selector(P.ogRollbackFile(_:)), "z", [.command, .option])
        ]))

        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "")
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        return main
    }
}

@MainActor
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in RecentProjects.list {
            let i = NSMenuItem(title: (url.path as NSString).abbreviatingWithTildeInPath, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = url
            menu.addItem(i)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { AppDelegate.shared?.openProject(url) }
    }
}
