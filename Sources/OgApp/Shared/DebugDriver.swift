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
