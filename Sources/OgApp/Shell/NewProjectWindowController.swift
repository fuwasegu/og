import AppKit
import OgCore

/// File ▸ New Project…: location, name, module path, template, git. Creates the module and opens it.
@MainActor
final class NewProjectWindowController: NSWindowController, NSTextFieldDelegate {
    private let locationField = NSTextField()
    private let nameField = NSTextField()
    private let moduleField = NSTextField()
    private let templatePopup = NSPopUpButton()
    private let gitCheck = NSButton(checkboxWithTitle: "Create a Git repository", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    /// The module path follows the name until the user edits it.
    private var moduleEdited = false
    private var creating = false

    private static let locationKey = "og.newProject.location"
    private static let templateKey = "og.newProject.template"
    private static let gitKey = "og.newProject.git"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New Project"
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    /// Where new projects go: the last location used, else the folder of the most recent project, else home.
    static var defaultLocation: URL {
        if let s = UserDefaults.standard.string(forKey: locationKey), FileManager.default.fileExists(atPath: s) {
            return URL(fileURLWithPath: s)
        }
        if let recent = RecentProjects.list.first { return recent.deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func build() {
        guard let window else { return }
        locationField.stringValue = (Self.defaultLocation.path as NSString).abbreviatingWithTildeInPath
        nameField.placeholderString = "myapp"
        moduleField.placeholderString = "github.com/you/myapp"
        for f in [locationField, nameField, moduleField] {
            f.delegate = self
            f.font = Theme.uiFont
            f.lineBreakMode = .byTruncatingMiddle
            f.cell?.usesSingleLineMode = true
        }
        for t in ProjectTemplate.allCases {
            templatePopup.addItem(withTitle: t.title)
            templatePopup.lastItem?.representedObject = t.rawValue
        }
        let savedTemplate = UserDefaults.standard.string(forKey: Self.templateKey) ?? ProjectTemplate.app.rawValue
        if let i = ProjectTemplate.allCases.firstIndex(where: { $0.rawValue == savedTemplate }) { templatePopup.selectItem(at: i) }
        templatePopup.target = self
        templatePopup.action = #selector(changed)
        gitCheck.state = UserDefaults.standard.object(forKey: Self.gitKey) as? Bool == false ? .off : .on
        gitCheck.target = self
        gitCheck.action = #selector(changed)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseLocation))
        choose.bezelStyle = .rounded

        summary.font = Theme.smallFont
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingMiddle
        summary.maximumNumberOfLines = 2
        summary.cell?.truncatesLastVisibleLine = true

        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let locationRow = NSStackView(views: [locationField, choose])
        locationRow.spacing = 8
        // Long paths truncate in the middle instead of widening the window.
        for v in [locationField, summary] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Location:"), locationRow],
            [label("Name:"), nameField],
            [label("Module path:"), moduleField],
            [label("Template:"), templatePopup],
            [NSGridCell.emptyContentView, gitCheck]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let buttons = NSStackView(views: [cancel, createButton])
        buttons.spacing = 10
        for v in [grid, summary, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        let content = NSView()
        content.addSubview(grid)
        content.addSubview(summary)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nameField.widthAnchor.constraint(equalToConstant: 400),
            moduleField.widthAnchor.constraint(equalTo: nameField.widthAnchor),
            locationRow.widthAnchor.constraint(equalTo: nameField.widthAnchor),
            summary.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: summary.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.contentView = content
        window.initialFirstResponder = nameField
        refresh()
    }

    // MARK: - Form state

    private var location: URL {
        URL(fileURLWithPath: (locationField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
    }

    private var name: String { nameField.stringValue }
    private var module: String { moduleField.stringValue.trimmingCharacters(in: .whitespaces) }

    private var template: ProjectTemplate {
        (templatePopup.selectedItem?.representedObject as? String).flatMap(ProjectTemplate.init(rawValue:)) ?? .app
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === moduleField { moduleEdited = !moduleField.stringValue.isEmpty }
        refresh()
    }

    @objc private func changed() { refresh() }

    /// Follows the name with the module path and shows where the project goes, or what is wrong.
    private func refresh() {
        if !moduleEdited {
            moduleField.stringValue = name.isEmpty ? "" : ProjectScaffold.suggestedModule(parentPath: location.path, name: name)
        }
        let problem = currentProblem()
        createButton.isEnabled = problem == nil && !creating
        if let problem, !name.isEmpty || problem != "Enter a project name" {
            summary.textColor = Theme.error
            summary.stringValue = problem
        } else if name.isEmpty {
            summary.textColor = Theme.secondaryText
            summary.stringValue = "Creates a folder with go.mod" + (template == .empty ? "" : " and a starter file")
        } else {
            summary.textColor = Theme.secondaryText
            let path = (location.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath
            let scaffold = ProjectScaffold(name: name, module: module, template: template, gitInit: gitCheck.state == .on)
            let files = ["go.mod"] + scaffold.files.map(\.path)
            summary.stringValue = "Creates \(path) with \(files.joined(separator: ", "))"
        }
    }

    private func currentProblem() -> String? {
        if let p = ProjectScaffold.nameProblem(name) { return p }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: location.path, isDirectory: &isDir) || !isDir.boolValue {
            return "The location folder does not exist"
        }
        let target = location.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? ["?"]
            if !entries.allSatisfy({ $0 == ".DS_Store" }) { return "\(name) already exists in this folder" }
        }
        return ProjectScaffold.moduleProblem(module)
    }

    /// Debug driver: type a name as the user would.
    func debugSetName(_ s: String) {
        nameField.stringValue = s
        refresh()
    }

    // MARK: - Actions

    @objc private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = location
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                self.locationField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
                self.refresh()
            }
        }
    }

    @objc private func cancel() { close() }

    @objc private func create() {
        guard currentProblem() == nil, !creating else { NSSound.beep(); return }
        let scaffold = ProjectScaffold(name: name, module: module, template: template, gitInit: gitCheck.state == .on)
        let parent = location
        UserDefaults.standard.set(parent.path, forKey: Self.locationKey)
        UserDefaults.standard.set(template.rawValue, forKey: Self.templateKey)
        UserDefaults.standard.set(gitCheck.state == .on, forKey: Self.gitKey)
        creating = true
        refresh()
        summary.textColor = Theme.secondaryText
        summary.stringValue = "Creating…"
        Task { [weak self] in
            let result = await Task.detached { Result { try scaffold.create(in: parent) } }.value
            guard let self else { return }
            self.creating = false
            switch result {
            case .success(let dir):
                self.close()
                Self.open(dir, scaffold: scaffold)
            case .failure(let error):
                self.refresh()
                self.summary.textColor = Theme.error
                self.summary.stringValue = error.localizedDescription
            }
        }
    }

    /// Opens the new project and its starter file.
    static func open(_ dir: URL, scaffold: ProjectScaffold) {
        guard let app = AppDelegate.shared else { return }
        app.openProject(dir)
        guard let file = scaffold.primaryFile, let project = app.projects.first(where: { $0.context.root == dir.standardizedFileURL }) else { return }
        let line = scaffold.template == .app ? 5 : 0
        project.context.open(dir.appendingPathComponent(file), line: line, column: 1)
    }
}
