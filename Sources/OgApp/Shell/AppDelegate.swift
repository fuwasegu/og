import AppKit
import OgCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var projects: [ProjectWindowController] = []
    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
        _ = ToolLocator.shared
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            openProject(URL(fileURLWithPath: path))
        } else if let last = RecentProjects.list.first, (UserDefaults.standard.object(forKey: "og.reopenLast") as? Bool) ?? true,
                  FileManager.default.fileExists(atPath: last.path) {
            openProject(last)
        } else {
            showWelcome()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openProject(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for p in projects {
            guard let w = p.window else { continue }
            if !p.windowShouldClose(w) { return .terminateCancel }
        }
        for p in projects { p.editorArea.saveSession(); p.context.shutdown() }
        return .terminateNow
    }

    // MARK: - Projects

    func showWelcome() {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openFolderPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Go project folder"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    func openProject(_ url: URL) {
        var root = url.standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        var fileToOpen: URL?
        if !isDir.boolValue {
            fileToOpen = root
            root = GoModule.findRoot(from: root.deletingLastPathComponent()) ?? root.deletingLastPathComponent()
        }
        if let existing = projects.first(where: { $0.context.root == root }) {
            existing.showWindow(nil)
            if let f = fileToOpen { existing.context.open(f) }
            return
        }
        let context = ProjectContext(root: root)
        let controller = ProjectWindowController(context: context)
        projects.append(controller)
        controller.showWindow(nil)
        context.start()
        controller.editorArea.restoreSession()
        if let f = fileToOpen { context.open(f) }
        RecentProjects.add(root)
        welcome?.close()
    }

    func projectClosed(_ controller: ProjectWindowController) {
        projects.removeAll { $0 === controller }
        if projects.isEmpty { showWelcome() }
    }

    var activeProject: ProjectWindowController? {
        projects.first { $0.window?.isKeyWindow == true } ?? projects.first { $0.window?.isMainWindow == true }
    }
}

enum GoModule {
    /// Nearest ancestor containing go.work or go.mod.
    static func findRoot(from dir: URL) -> URL? {
        var d = dir.standardizedFileURL
        var best: URL?
        while d.path != "/" {
            let fm = FileManager.default
            if fm.fileExists(atPath: d.appendingPathComponent("go.work").path) { return d }
            if best == nil, fm.fileExists(atPath: d.appendingPathComponent("go.mod").path) { best = d }
            d = d.deletingLastPathComponent()
        }
        return best
    }
}

@MainActor
enum RecentProjects {
    static var list: [URL] {
        (UserDefaults.standard.stringArray(forKey: "og.recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = list.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(15)), forKey: "og.recentProjects")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func remove(_ url: URL) {
        UserDefaults.standard.set(list.map(\.path).filter { $0 != url.path }, forKey: "og.recentProjects")
    }
}
