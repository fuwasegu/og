import AppKit

/// Start screen: open a folder or pick a recent project.
@MainActor
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var items: [URL] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        items = RecentProjects.list
        table.reloadData()
        super.showWindow(sender)
    }

    private func build() {
        guard let window else { return }
        let content = NSView()

        let left = NSView()
        left.wantsLayer = true
        left.layer?.backgroundColor = Theme.sidebarBackground.cgColor
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "og")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.textColor = Theme.text
        let subtitle = NSTextField(labelWithString: "Go editor for macOS")
        subtitle.textColor = Theme.secondaryText
        let open = NSButton(title: "Open Folder…", target: AppDelegate.shared, action: #selector(AppDelegate.openFolderPanel(_:)))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.controlSize = .large
        let tools = NSTextField(wrappingLabelWithString: toolSummary())
        tools.font = Theme.smallFont
        tools.textColor = Theme.secondaryText
        let stack = NSStackView(views: [icon, title, subtitle, open, tools])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(stack)

        let column = NSTableColumn(identifier: .init("p"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.backgroundColor = Theme.background
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for v in [left, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            left.topAnchor.constraint(equalTo: content.topAnchor),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 260),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -40),
            scroll.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        window.contentView = content
    }

    private func toolSummary() -> String {
        let t = ToolLocatorSummary.current
        return t
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = items[row]
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.text
        let path = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        path.font = Theme.smallFont
        path.textColor = Theme.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [name, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        return stack
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < items.count else { return }
        let url = items[row]
        if FileManager.default.fileExists(atPath: url.path) {
            AppDelegate.shared?.openProject(url)
        } else {
            RecentProjects.remove(url)
            items = RecentProjects.list
            table.reloadData()
        }
    }
}

import OgCore

enum ToolLocatorSummary {
    static var current: String {
        let tools = ["go", "gopls", "dlv", "git"]
        return tools.map { name in
            ToolLocator.shared.find(name) != nil ? "✓ \(name)" : "✗ \(name) (not found)"
        }.joined(separator: "\n")
    }
}
