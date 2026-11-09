import AppKit
import OgCore

/// All diagnostics in the project, grouped by file.
@MainActor
final class ProblemsPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let context: ProjectContext
    private let outline = NSOutlineView()
    private var files: [(uri: String, items: [LSPDiagnostic])] = []
    private var timer: Timer?

    final class Row: NSObject {
        let uri: String
        let diag: LSPDiagnostic?
        init(uri: String, diag: LSPDiagnostic?) { self.uri = uri; self.diag = diag }
    }
    private var fileRows: [Row] = []
    private var childRows: [String: [Row]] = [:]

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("p"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
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
        NotificationCenter.default.addObserver(forName: .ogDiagnosticsChanged, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    private func scheduleReload() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let sorted = context.diagnostics.sorted { $0.key < $1.key }
        fileRows = sorted.map { Row(uri: $0.key, diag: nil) }
        childRows = Dictionary(uniqueKeysWithValues: sorted.map { k, v in
            (k, v.sorted { ($0.severity?.rawValue ?? 4, $0.range.start.line) < ($1.severity?.rawValue ?? 4, $1.range.start.line) }.map { Row(uri: k, diag: $0) })
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
            let msg = NSTextField(labelWithString: d.message.replacingOccurrences(of: "\n", with: " "))
            msg.font = Theme.uiFont
            msg.textColor = Theme.text
            msg.lineBreakMode = .byTruncatingTail
            let loc = NSTextField(labelWithString: ":\(d.range.start.line + 1)")
            loc.font = Theme.smallFont
            loc.textColor = Theme.secondaryText
            return NSStackView(views: [sev, msg, loc])
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
}
