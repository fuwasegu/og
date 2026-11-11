import AppKit
import OgCore

/// Headless self-test driver, active only when `OG_DEBUG_SCRIPT` points to a script file.
/// Lets developers (and CI) exercise the UI and capture window snapshots without
/// touching the real screen. One command per line:
///
///     wait 2                       sleep seconds
///     open <path> [line] [col]     open a file (absolute or project-relative)
///     type <text>                  insert text at the caret (\n, \t escapes)
///     key <name>                   tab | enter | esc | backspace | up | down
///     action <selector>            send a menu action through the responder chain, e.g. ogGotoFile:
///     caret <line> <col>           move caret (1-based)
///     snap <path.png>              write a PNG of the project window
///     log <text>                   print to stdout
///     dump                         print editor text + diagnostics count
///     diags                        print every diagnostic (gopls + og style) of the editor
///     completions                  request completion at the caret and print the listed labels
///     accept [label]               accept the listed completion whose label contains `label`
///     quit
@MainActor
enum DebugDriver {
    static var isActive: Bool { ProcessInfo.processInfo.environment["OG_DEBUG_SCRIPT"] != nil }

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["OG_DEBUG_SCRIPT"],
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        Task { @MainActor in
            for line in lines { await run(line) }
        }
    }

    private static var project: ProjectWindowController? { AppDelegate.shared?.activeProject ?? AppDelegate.shared?.anyProject }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "-": 27
    ]

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    private static func run(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1_000_000_000))
        case "open":
            let a = arg.split(separator: " ").map(String.init)
            guard let p = project, let first = a.first else { return }
            let url = first.hasPrefix("/") ? URL(fileURLWithPath: first) : p.context.root.appendingPathComponent(first)
            let lineNo = a.count > 1 ? Int(a[1]).map { $0 - 1 } : nil
            let col = a.count > 2 ? Int(a[2]).map { $0 - 1 } : nil
            p.context.open(url, line: lineNo, column: col)
        case "type":
            guard let tv = project?.editorArea.current?.textView else { return }
            for ch in unescape(arg) {
                if ch == "\n" { tv.insertNewline(nil) } else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        case "newfile":
            // newfile DIR/NAME.go: the sidebar's New Go File.
            guard let p = project else { return }
            let url = p.context.root.appendingPathComponent(arg)
            p.sidebar.tree.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
        case "term":
            // term TEXT: type into the terminal (\\r = Return, \\e = Esc); prints the line and the faint hint.
            guard let tp = project?.bottomPanel.terminalPanel else { return }
            tp.debugType(unescape(arg).replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\r", with: "\r"))
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("term: line=\(tp.debugLine) ghost=\(tp.debugGhost ?? "-")")
        case "mark":
            // mark TEXT: IME composition (marked text), as an input method would send it.
            guard let tv = project?.editorArea.current?.textView else { return }
            let t = unescape(arg)
            tv.setMarkedText(t, selectedRange: NSRange(location: (t as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            print("mark: marked=\(tv.hasMarkedText()) popup=\(project?.editorArea.current?.completion?.isVisible == true)")
        case "fonts":
            // fonts: font runs of the caret's line.
            guard let ed = project?.editorArea.current else { return }
            let st = ed.document.storage
            let lr = (st.string as NSString).lineRange(for: NSRange(location: ed.caretOffset, length: 0))
            st.enumerateAttribute(.font, in: lr) { v, r, _ in
                print("fonts: \((st.string as NSString).substring(with: r).debugDescription) -> \((v as? NSFont)?.fontName ?? "nil")")
            }
        case "panes":
            // panes: the split tree and each pane's tabs.
            print("panes: \(project?.editorArea.layoutSummary ?? "-")")
        case "ime":
            // ime KEYS: real key events through the Japanese IME (romaji), e.g. `ime nihongo<space><enter>`.
            guard let tv = project?.editorArea.current?.textView, let window = tv.window else { return }
            tv.window?.makeFirstResponder(tv)
            let ctx = tv.inputContext
            ctx?.activate()
            let jp = ctx?.keyboardInputSources?.first { $0.contains("Japanese") && !$0.contains("Katakana") }
            print("ime: sources=\(ctx?.keyboardInputSources ?? []) using=\(jp ?? "none")")
            if let jp { ctx?.selectedKeyboardInputSource = jp }
            var keys: [(UInt16, String)] = []
            var rest = Substring(arg)
            while let c = rest.first {
                if rest.hasPrefix("<space>") { keys.append((49, " ")); rest = rest.dropFirst(7); continue }
                if rest.hasPrefix("<enter>") { keys.append((36, "\r")); rest = rest.dropFirst(7); continue }
                if let code = keyCodes[c] { keys.append((code, String(c))) }
                rest = rest.dropFirst()
            }
            for (code, chars) in keys {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                    if type == .keyDown { tv.keyDown(with: ev) } else { tv.keyUp(with: ev) }
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
                print("ime: key=\(chars.debugDescription) marked=\(tv.hasMarkedText()) text=\(tv.string.suffix(20).debugDescription)")
            }
        case "commit":
            // commit TEXT: the IME commits its composition.
            guard let tv = project?.editorArea.current?.textView else { return }
            tv.insertText(unescape(arg), replacementRange: NSRange(location: NSNotFound, length: 0))
            print("commit: marked=\(tv.hasMarkedText())")
        case "key":
            guard let tv = project?.editorArea.current?.textView else { return }
            let codes: [String: (UInt16, String)] = ["tab": (48, "\t"), "enter": (36, "\r"), "esc": (53, "\u{1b}"), "backspace": (51, "\u{7f}"),
                                                    "up": (126, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
                                                    "down": (125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))]
            guard let (code, chars) = codes[arg], let window = tv.window,
                  let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            tv.keyDown(with: ev)
        case "action":
            guard let p = project else { return }
            let sel = NSSelectorFromString(arg)
            // The headless window is never key, so walk its own responder chain.
            if let tv = p.editorArea.current?.textView { p.window?.makeFirstResponder(tv) }
            var responder: NSResponder? = p.window?.firstResponder
            var done = false
            while let r = responder, !done {
                if r.responds(to: sel) { r.perform(sel, with: nil); done = true }
                responder = r.nextResponder
            }
            if !done { _ = p.tryToPerform(sel, with: nil) }
        case "caret":
            let a = arg.split(separator: " ").compactMap { Int($0) }
            guard a.count == 2, let ed = project?.editorArea.current else { return }
            let t0 = Date()
            ed.reveal(line: a[0] - 1, column: a[1] - 1, length: 0)
            ed.textView.window?.displayIfNeeded()
            print(String(format: "caret %d: %.1fms", a[0], Date().timeIntervalSince(t0) * 1000))
        case "complbench":
            // complbench TEXT: type TEXT, then report how long until the completion popup is visible.
            guard let ed = project?.editorArea.current else { return }
            let tv = ed.textView
            ed.completion?.close()
            for ch in arg { tv.insertText(String(ch), replacementRange: tv.selectedRange()) }
            let t0 = Date()
            Task { @MainActor in
                while ed.completion?.isVisible != true, Date().timeIntervalSince(t0) < 3 { try? await Task.sleep(nanoseconds: 2_000_000) }
                print(ed.completion?.isVisible == true ? "completion after \(Int(Date().timeIntervalSince(t0) * 1000)) ms" : "completion: none")
            }
        case "scrollbench":
            // scrollbench N: scroll N frames of 60 px and report per-frame cost (scroll + display).
            guard let ed = project?.editorArea.current, let window = ed.textView.window else { return }
            let n = Int(arg) ?? 200
            let clip = ed.scrollView.contentView
            var costs: [Double] = []
            for _ in 0..<n {
                let t0 = Date()
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 60))
                ed.scrollView.reflectScrolledClipView(clip)
                window.displayIfNeeded()
                costs.append(Date().timeIntervalSince(t0) * 1000)
            }
            costs.sort()
            print(String(format: "scroll frames=%d p50=%.2fms p95=%.2fms max=%.2fms", n, costs[n / 2], costs[n * 95 / 100], costs[n - 1]))
        case "openbench":
            let t0 = Date()
            project?.context.open(URL(fileURLWithPath: arg))
            project?.window?.displayIfNeeded()
            print(String(format: "open %.1fms", Date().timeIntervalSince(t0) * 1000))
        case "keybench":
            // keybench down|up N: move the caret N times and report per-move cost (move + display).
            guard let ed = project?.editorArea.current, let window = ed.textView.window else { return }
            let parts = arg.split(separator: " ")
            let n = parts.count > 1 ? Int(parts[1]) ?? 200 : 200
            var costs: [Double] = []
            for _ in 0..<n {
                let t0 = Date()
                if parts.first == "up" { ed.textView.moveUp(nil) } else { ed.textView.moveDown(nil) }
                window.displayIfNeeded()
                costs.append(Date().timeIntervalSince(t0) * 1000)
            }
            costs.sort()
            print(String(format: "keys=%d p50=%.2fms p95=%.2fms max=%.2fms", n, costs[n / 2], costs[n * 95 / 100], costs[n - 1]))
        case "onboard":
            // onboard <step> <png>: snapshot a setup-assistant step.
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let n = Int(parts[0]),
                  let view = OnboardingWindowController.shared.debugRender(step: n),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: parts[1])); print("snap \(parts[1])") }
        case "which":
            print("which \(arg): \(ToolLocator.shared.find(arg) ?? "not found")")
        case "theme":
            // theme dark|light|system
            if let m = ThemeMode(rawValue: arg) { Theme.mode = m }
        case "font":
            // font <size> [family…]  ("-" = system monospaced)
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let size = CGFloat(Double(parts.first ?? "") ?? Double(Theme.fontSize))
            let fam = parts.count > 1 ? (parts[1] == "-" ? nil : parts[1]) : Theme.fontFamily
            Theme.setFont(family: fam, size: size)
        case "bench":
            // bench N: type N characters at the caret like a fast typist (25 ms apart) and report
            // per-keystroke time (insert + display) and the worst main-thread stall seen meanwhile.
            guard let ed = project?.editorArea.current, let window = ed.textView.window else { return }
            let n = Int(arg) ?? 100
            let tv = ed.textView
            Task { @MainActor in
                var costs: [Double] = []
                var worstLag = 0.0
                var last = Date()
                var keyIndex = 0
                let beat = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = Date()
                        let lag = now.timeIntervalSince(last) - 0.002
                        if lag > 0.008 { print(String(format: "stall %.1fms at key %d", lag * 1000, keyIndex)) }
                        worstLag = max(worstLag, lag)
                        last = now
                    }
                }
                let chars = Array("abc de(fg) hij\n")
                for i in 0..<n {
                    keyIndex = i
                    let c = String(chars[i % chars.count])
                    let t0 = Date()
                    if c == "\n" { tv.insertNewline(nil) } else { tv.insertText(c, replacementRange: tv.selectedRange()) }
                    window.displayIfNeeded()
                    costs.append(Date().timeIntervalSince(t0) * 1000)
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                beat.invalidate()
                costs.sort()
                func pct(_ p: Double) -> String { String(format: "%.2f", costs[min(costs.count - 1, Int(Double(costs.count) * p))]) }
                print("bench keys=\(n) p50=\(pct(0.5))ms p95=\(pct(0.95))ms max=\(pct(1.0))ms worstStall=\(String(format: "%.1f", worstLag * 1000))ms")
            }
        case "codeaction":
            // codeaction [title substring]: list gopls actions at the caret; apply the first match.
            guard let ed = project?.editorArea.current else { return }
            ed.debugCodeActions(apply: arg.isEmpty ? nil : arg)
        case "hover":
            // hover L C: simulate the mouse resting on line L, column C; prints when the card shows.
            let a = arg.split(separator: " ").compactMap { Int($0) }
            guard a.count == 2, let ed = project?.editorArea.current else { return }
            ed.reveal(line: a[0] - 1, column: a[1] - 1, length: 0)
            let off = ed.caretOffset
            let started = Date()
            ed.hoverMoved(to: off, rect: NSRect(x: 80, y: 200, width: 8, height: 16))
            Task { @MainActor in
                while ed.info?.isVisible != true, Date().timeIntervalSince(started) < 5 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                print(ed.info?.isVisible == true ? "hover shown after \(Int(Date().timeIntervalSince(started) * 1000)) ms" : "hover: nothing")
            }
        case "snap":
            guard let window = project?.window, let view = window.contentView?.superview ?? window.contentView else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            // Child panels (completion / hover) are separate windows: composite them.
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            if !window.childWindows.isNullOrEmpty {
                image.lockFocus()
                for child in window.childWindows ?? [] where child.isVisible {
                    guard let cv = child.contentView, let crep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
                    cv.cacheDisplay(in: cv.bounds, to: crep)
                    let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
                    crep.draw(in: NSRect(origin: origin, size: cv.bounds.size))
                }
                image.unlockFocus()
            }
            if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arg))
                print("snap \(arg)")
            }
        case "mdpreview":
            // mdpreview [toggle]: state of the current editor's Markdown preview.
            guard let ed = project?.editorArea.current else { return }
            if arg == "toggle" { ed.toggleMarkdownPreview() }
            print("mdpreview: \(ed.markdownPreview.map { ($0.view.isHidden ? "hidden " : "") + $0.debugSummary + " width=\(Int($0.view.frame.width))/\(Int(ed.view.frame.width))" } ?? "none")")
        case "geom":
            guard let ed = project?.editorArea.current else { return }
            print("clip=\(ed.scrollView.contentView.bounds) tv=\(ed.textView.frame) doc=\(ed.scrollView.documentVisibleRect) caret=\(ed.caretScreenRect())")
        case "rename":
            RenameSheet.debugPreview(arg)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("rename preview: \(RenameSheet.debugStatus)")
            RenameSheet.debugApply()
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("rename: \(RenameSheet.debugStatus)")
        case "ai":
            let m = ModelServerManager.shared
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch a.first ?? "" {
            case "custom": var c = m.config; c.backend = .custom; c.customCommand = a.count > 1 ? a[1] : ""; m.config = c
            case "on": m.enabled = true
            case "off": m.enabled = false
            case "restart": m.restart()
            case "pid": print("ai pids: \(m.debugPIDs)")
            default: break
            }
            print("ai: \(m.statusText) phase=\(m.phase)")
        case "ghost":
            guard let ed = project?.editorArea.current else { return }
            ed.requestGhost()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("ghost: \(ed.textView.ghostText ?? "(none)")")
        case "diags":
            // diags: every diagnostic of the current editor (gopls + og style), one per line.
            guard let ed = project?.editorArea.current else { return }
            for d in ed.diagnostics.sorted(by: { $0.range.start < $1.range.start }) {
                print("diag \(d.range.start.line + 1):\(d.range.start.character + 1) [\(d.source ?? "")\(d.code.flatMap { $0.stringValue }.map { " " + $0 } ?? "")] \(d.message)")
            }
        case "completions":
            // completions: request completion at the caret and print the items (og's first).
            guard let ed = project?.editorArea.current else { return }
            ed.requestCompletion(explicit: true)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            print("completions: " + ed.debugCompletionLabels().prefix(12).joined(separator: " | "))
        case "accept":
            // accept [label substring]: accept the first visible completion matching the label.
            guard let ed = project?.editorArea.current else { return }
            ed.debugAcceptCompletion(matching: arg)
            try? await Task.sleep(nanoseconds: 300_000_000)
        case "log":
            print(arg)
        case "dump":
            guard let ed = project?.editorArea.current else { print("dump: no editor"); return }
            print("---- \(ed.document.url.lastPathComponent) dirty=\(ed.document.dirty) diags=\(ed.diagnostics.count) caret=\(ed.caretPosition)")
            print(ed.document.text)
            print("----")
        case "quit":
            fflush(stdout)
            NSApp.terminate(nil)
        default:
            print("unknown command: \(line)")
        }
        fflush(stdout)
    }
}

private extension Optional where Wrapped: Collection {
    var isNullOrEmpty: Bool { self?.isEmpty ?? true }
}
