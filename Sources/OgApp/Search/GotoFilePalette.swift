import AppKit
import OgCore

/// GoLand-style quick open: files (Cmd-Shift-O), symbols (Cmd-Alt-O), recent files (Cmd-E).
@MainActor
enum GotoFilePalette {
    /// Cmd-Shift-O: fuzzy file search over context.index; opens the chosen file.
    static func showFiles(in context: ProjectContext) {
        let index = context.index
        let root = context.root
        let palette = QuickPalette.show(over: context.window?.window, title: "Go to File", placeholder: "File name or path") { [weak context] query in
            guard let context else { return [] }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty query: recently opened files first (like GoLand).
                return (context.window?.editorArea.recent ?? []).map { url in
                    let rel = context.relativePath(url)
                    return QuickPalette.fileItem(relativePath: rel, offsets: []) { [weak context] in context?.open(url) }
                }
            }
            // "file.go:12" jumps to a line.
            let (q, line) = splitLineSuffix(query)
            let matches = await index.fuzzy(q, limit: 200)
            return matches.map { m in
                let url = root.appendingPathComponent(m.relativePath)
                return QuickPalette.fileItem(relativePath: m.relativePath, offsets: m.matchedOffsets) { [weak context] in
                    context?.open(url, line: line, column: line == nil ? nil : 0)
                }
            }
        }
        // Pick up files created since the last scan, then refresh the visible list.
        Task { [weak palette] in
            await index.refresh()
            palette?.requery()
        }
    }

    /// Cmd-Alt-O: workspace symbol search via context.gopls.workspaceSymbols.
    static func showSymbols(in context: ProjectContext) {
        let gopls = context.gopls
        QuickPalette.show(over: context.window?.window, title: "Go to Symbol", placeholder: "Type, function, method, field…",
                          debounce: 0.15, initialQuery: wordAtCaret(context)) { [weak context] query in
            guard let context, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            let symbols = await gopls.workspaceSymbols(query: query)
            return symbols.prefix(300).compactMap { sym in
                guard let uri = sym.uri, let url = URL(string: uri) else { return nil }
                let location = LSPLocation(uri: uri, range: sym.selectionRange)
                let rel = context.relativePath(url)
                var detail = rel + ":\(sym.range.start.line + 1)"
                if let c = sym.containerName, !c.isEmpty { detail = c + " · " + detail }
                return PaletteItem(title: sym.name,
                                   titleHighlights: FuzzyMatcher.match(query, in: sym.name, pathAware: false)?.offsets ?? [],
                                   detail: detail,
                                   badge: sym.kindLabel,
                                   icon: symbolIcon(sym.kind),
                                   open: { [weak context] in context?.open(location) })
            }
        }
    }

    /// Cmd-E: recent files. `recent[0]` is the current file; the list starts with the
    /// second most recent so Cmd-E, Enter toggles between the last two files.
    static func showRecent(in context: ProjectContext, recent: [URL]) {
        let ordered = recent.count > 1 ? Array(recent.dropFirst()) + [recent[0]] : recent
        let entries = ordered.map { (url: $0, rel: context.relativePath($0)) }
        QuickPalette.show(over: context.window?.window, title: "Recent Files", placeholder: "Filter recent files") { [weak context] query in
            let q = query.trimmingCharacters(in: .whitespaces)
            var rows: [(entry: (url: URL, rel: String), score: Int, offsets: [Int], order: Int)] = []
            for (i, e) in entries.enumerated() {
                if q.isEmpty { rows.append((e, 0, [], i)); continue }
                if let m = FuzzyMatcher.match(q, in: e.rel) { rows.append((e, m.score, m.offsets, i)) }
            }
            rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            return rows.map { r in
                let url = r.entry.url
                return QuickPalette.fileItem(relativePath: r.entry.rel, offsets: r.offsets) { [weak context] in context?.open(url) }
            }
        }
    }

    // MARK: - Helpers

    /// "path/to/file.go:42" -> ("path/to/file.go", 41)
    static func splitLineSuffix(_ query: String) -> (String, Int?) {
        guard let colon = query.lastIndex(of: ":") else { return (query, nil) }
        let tail = query[query.index(after: colon)...]
        guard let n = Int(tail), n > 0 else { return (query, nil) }
        return (String(query[..<colon]), n - 1)
    }

    private static func wordAtCaret(_ context: ProjectContext) -> String {
        guard let editor = context.currentEditor else { return "" }
        let tv = editor.textView
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        if sel.length > 0 && sel.length < 200 {
            let s = ns.substring(with: sel)
            return s.contains("\n") ? "" : s
        }
        return ""
    }

    private static func symbolIcon(_ kind: Int) -> NSImage? {
        let name: String
        switch kind {
        case 5, 23: name = "c.square"            // class / struct
        case 11: name = "i.square"               // interface
        case 6, 9: name = "m.square"             // method / constructor
        case 12: name = "f.square"               // function
        case 8, 7: name = "square.dotted"        // field / property
        case 13: name = "v.square"               // variable
        case 14: name = "k.square"               // constant
        case 2, 3, 4: name = "shippingbox"       // module / namespace / package
        default: name = "number.square"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return img?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }
}
