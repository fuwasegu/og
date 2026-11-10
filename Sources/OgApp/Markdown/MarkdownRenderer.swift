import AppKit
import OgCore

extension NSAttributedString.Key {
    /// Mermaid source of a diagram attachment (filled in asynchronously).
    static let ogMermaid = NSAttributedString.Key("og.mermaid")
}

/// Turns parsed Markdown into styled text for the preview's NSTextView (TextKit 1: tables are
/// NSTextTable, code and quotes are NSTextBlock). Pure layout work; Mermaid images come from
/// `MermaidRenderer` and are swapped in when ready.
@MainActor
struct MarkdownRenderer {
    var baseURL: URL
    /// Width available to images and diagrams.
    var contentWidth: CGFloat
    /// Diagrams already rendered for the current theme, by source.
    var diagrams: [String: NSImage]

    private let bodySize: CGFloat = 14

    func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for b in blocks { out.append(render(block: b)) }
        return out
    }

    /// One top-level block (the preview caches these and replaces only the ones that changed).
    func render(block: MarkdownBlock) -> NSAttributedString {
        let out = NSMutableAttributedString()
        append(block, to: out, depth: 0, quote: [])
        return out
    }

    // MARK: - Blocks

    private func append(_ block: MarkdownBlock, to out: NSMutableAttributedString, depth: Int, quote: [NSTextBlock]) {
        let start = out.length
        switch block {
        case .heading(let level, let text, _):
            let sizes: [CGFloat] = [26, 21, 17.5, 15, 14, 13]
            let font = NSFont.systemFont(ofSize: sizes[min(level, 6) - 1], weight: level <= 2 ? .bold : .semibold)
            let p = paragraphStyle(quote: quote, spacingBefore: level <= 2 ? 18 : 14, spacingAfter: 8)
            if level <= 2 {
                // GitHub-style rule under h1 / h2.
                let rule = NSTextBlock()
                rule.setValue(100, type: .percentageValueType, for: .width)
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(Theme.border, for: .maxY)
                rule.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                p.textBlocks = quote + [rule]
            }
            out.append(inline(text, font: font, color: Theme.text))
            out.append(NSAttributedString(string: "\n"))
            out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))

        case .paragraph(let text, _):
            out.append(inline(text, font: bodyFont, color: Theme.text))
            out.append(NSAttributedString(string: "\n"))
            out.addAttribute(.paragraphStyle, value: paragraphStyle(quote: quote, spacingAfter: 10), range: NSRange(location: start, length: out.length - start))

        case .code(let language, let text, _):
            if language == "mermaid" {
                appendMermaid(text, to: out, quote: quote)
            } else {
                appendCode(text, language: language, to: out, quote: quote)
            }

        case .list(let ordered, let first, let items, _):
            for (n, item) in items.enumerated() {
                let marker: String
                if let checked = item.checked { marker = checked ? "☑" : "☐" }
                else if ordered { marker = "\(first + n)." }
                else { marker = ["•", "◦", "▪"][depth % 3] }
                appendListItem(item, marker: marker, to: out, depth: depth, quote: quote)
            }
            if depth == 0 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: paragraphStyle(quote: quote, spacingAfter: 0)]))
            }

        case .quote(let blocks, _):
            let q = NSTextBlock()
            q.setValue(100, type: .percentageValueType, for: .width)
            q.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            q.setBorderColor(Theme.secondaryText.withAlphaComponent(0.5), for: .minX)
            q.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            q.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            let inner = NSMutableAttributedString()
            for b in blocks {
                append(b, to: inner, depth: depth, quote: quote + [q])
            }
            inner.addAttribute(.foregroundColor, value: Theme.secondaryText, range: NSRange(location: 0, length: inner.length))
            out.append(inner)

        case .table(let header, let aligns, let rows, _):
            appendTable(header: header, aligns: aligns, rows: rows, to: out, quote: quote)

        case .rule:
            let b = NSTextBlock()
            b.setValue(100, type: .percentageValueType, for: .width)
            b.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            b.setBorderColor(Theme.border, for: .maxY)
            let p = paragraphStyle(quote: quote, spacingBefore: 6, spacingAfter: 14)
            p.textBlocks = quote + [b]
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: p]))

        case .html(let raw, _):
            appendCode(raw, language: "html", to: out, quote: quote)
        }
    }

    private func appendListItem(_ item: MarkdownListItem, marker: String, to out: NSMutableAttributedString, depth: Int, quote: [NSTextBlock]) {
        let indent = CGFloat(depth + 1) * 22
        for (i, b) in item.blocks.enumerated() {
            let start = out.length
            switch b {
            case .paragraph(let text, _), .heading(_, let text, _):
                if i == 0 {
                    let color = item.checked == true ? Theme.accent : Theme.secondaryText
                    out.append(NSAttributedString(string: "\t\(marker)\t", attributes: [.font: bodyFont, .foregroundColor: color]))
                }
                let body = inline(text, font: bodyFont, color: Theme.text)
                if item.checked == true {
                    let done = NSMutableAttributedString(attributedString: body)
                    done.addAttribute(.foregroundColor, value: Theme.secondaryText, range: NSRange(location: 0, length: done.length))
                    out.append(done)
                } else {
                    out.append(body)
                }
                out.append(NSAttributedString(string: "\n"))
                let p = paragraphStyle(quote: quote, spacingAfter: 3)
                p.headIndent = indent
                p.firstLineHeadIndent = i == 0 ? indent - 20 : indent
                p.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
            case .list:
                append(b, to: out, depth: depth + 1, quote: quote)
            default:
                if i == 0 {
                    out.append(NSAttributedString(string: "\t\(marker)\t\n", attributes: [.font: bodyFont, .foregroundColor: Theme.secondaryText]))
                    let p = paragraphStyle(quote: quote, spacingAfter: 0)
                    p.firstLineHeadIndent = indent - 20
                    p.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
                    out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
                }
                let inner = NSMutableAttributedString()
                append(b, to: inner, depth: depth, quote: quote)
                inner.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: inner.length)) { v, r, _ in
                    guard let ps = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    ps.headIndent += indent
                    ps.firstLineHeadIndent += indent
                    inner.addAttribute(.paragraphStyle, value: ps, range: r)
                }
                out.append(inner)
            }
        }
    }

    private func appendCode(_ text: String, language: String, to out: NSMutableAttributedString, quote: [NSTextBlock]) {
        let start = out.length
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let codeFont = NSFont(name: Theme.editorFont.fontName, size: 12.5) ?? font
        let code = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: codeFont, .foregroundColor: Theme.text])
        if language == "go" {
            for t in GoLexer.tokenize(text) {
                guard let c = Theme.color(for: t.kind), NSMaxRange(t.range) <= code.length else { continue }
                code.addAttribute(.foregroundColor, value: c, range: t.range)
            }
        }
        out.append(code)
        out.append(NSAttributedString(string: "\n", attributes: [.font: codeFont]))
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.backgroundColor = Theme.panelBackground
        block.setWidth(12, type: .absoluteValueType, for: .padding)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(Theme.border)
        let p = paragraphStyle(quote: quote, spacingAfter: 0)
        p.textBlocks = quote + [block]
        p.lineHeightMultiple = 1.15
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.paragraphStyle, value: p, range: range)
        // Space after the block (outside it).
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6), .paragraphStyle: paragraphStyle(quote: quote, spacingAfter: 0)]))
    }

    private func appendMermaid(_ source: String, to out: NSMutableAttributedString, quote: [NSTextBlock]) {
        let start = out.length
        let attachment = NSTextAttachment()
        if let img = diagrams[source] {
            attachment.image = img
            attachment.bounds = fitted(img.size)
        } else {
            // Placeholder until the diagram arrives (a few ms): keeps the layout from jumping much.
            attachment.image = NSImage(size: NSSize(width: 1, height: 1))
            attachment.bounds = NSRect(x: 0, y: 0, width: 1, height: 40)
        }
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttribute(.ogMermaid, value: source, range: NSRange(location: 0, length: s.length))
        out.append(s)
        out.append(NSAttributedString(string: "\n"))
        let p = paragraphStyle(quote: quote, spacingBefore: 4, spacingAfter: 12)
        p.alignment = .center
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
    }

    private func appendTable(header: [[MarkdownInline]], aligns: [MarkdownAlignment], rows: [[[MarkdownInline]]],
                             to out: NSMutableAttributedString, quote: [NSTextBlock]) {
        let table = NSTextTable()
        table.setValue(100, type: .percentageValueType, for: .width)
        table.numberOfColumns = max(1, aligns.count)
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        let all = [header] + rows
        for (r, row) in all.enumerated() {
            for c in 0..<table.numberOfColumns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(Theme.border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                if r == 0 { cell.backgroundColor = Theme.panelBackground }
                else if r % 2 == 0 { cell.backgroundColor = Theme.currentLine }
                let start = out.length
                let content = c < row.count ? row[c] : []
                out.append(inline(content, font: r == 0 ? NSFont.systemFont(ofSize: bodySize, weight: .semibold) : bodyFont, color: Theme.text))
                out.append(NSAttributedString(string: "\n"))
                let p = paragraphStyle(quote: quote, spacingAfter: 0)
                p.textBlocks = quote + [cell]
                switch c < aligns.count ? aligns[c] : .none {
                case .center: p.alignment = .center
                case .right: p.alignment = .right
                default: p.alignment = .left
                }
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
            }
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6), .paragraphStyle: paragraphStyle(quote: quote, spacingAfter: 0)]))
    }

    // MARK: - Inlines

    private var bodyFont: NSFont { NSFont.systemFont(ofSize: bodySize) }

    private func inline(_ nodes: [MarkdownInline], font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for n in nodes { appendInline(n, to: out, font: font, color: color) }
        return out
    }

    private func appendInline(_ n: MarkdownInline, to out: NSMutableAttributedString, font: NSFont, color: NSColor) {
        switch n {
        case .text(let s):
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        case .lineBreak:
            out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font]))
        case .code(let s):
            let mono = NSFont(name: Theme.editorFont.fontName, size: font.pointSize * 0.9) ?? NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            out.append(NSAttributedString(string: "\u{2009}\(s)\u{2009}", attributes: [
                .font: mono, .foregroundColor: color, .backgroundColor: Theme.panelBackground,
            ]))
        case .emphasis(let c):
            for x in c { appendInline(x, to: out, font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), color: color) }
        case .strong(let c):
            let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
            for x in c { appendInline(x, to: out, font: font.fontDescriptor.symbolicTraits.contains(.bold) ? font : bold, color: color) }
        case .strike(let c):
            let start = out.length
            for x in c { appendInline(x, to: out, font: font, color: color) }
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: start, length: out.length - start))
        case .link(let text, let url):
            let start = out.length
            for x in text { appendInline(x, to: out, font: font, color: Theme.accent) }
            if let u = resolve(url) {
                out.addAttribute(.link, value: u, range: NSRange(location: start, length: out.length - start))
            }
        case .image(let alt, let url):
            if let u = resolve(url), u.isFileURL, let img = NSImage(contentsOf: u) {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = fitted(img.size)
                out.append(NSAttributedString(attachment: a))
            } else {
                // Remote images are not fetched: the preview never goes to the network on its own.
                out.append(NSAttributedString(string: "🖼 \(alt.isEmpty ? url : alt)", attributes: [
                    .font: font, .foregroundColor: Theme.accent, .link: resolve(url) as Any,
                ]))
            }
        }
    }

    // MARK: - Helpers

    private func resolve(_ s: String) -> URL? {
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("mailto:") { return URL(string: s) }
        if s.hasPrefix("#") { return nil }
        let path = s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appendingPathComponent(decoded).standardizedFileURL
    }

    func fitted(_ size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let w = min(size.width, max(contentWidth, 100))
        return NSRect(x: 0, y: 0, width: w, height: size.height * w / size.width)
    }

    private func paragraphStyle(quote: [NSTextBlock], spacingBefore: CGFloat = 0, spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.textBlocks = quote
        return p
    }
}
