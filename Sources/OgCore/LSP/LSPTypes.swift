import Foundation

public struct LSPPosition: Codable, Sendable, Hashable, Comparable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) { self.line = line; self.character = character }
    public static func < (a: LSPPosition, b: LSPPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.character < b.character
    }
}

public struct LSPRange: Codable, Sendable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition
    public init(start: LSPPosition, end: LSPPosition) { self.start = start; self.end = end }
}

public struct LSPLocation: Codable, Sendable, Hashable {
    public var uri: String
    public var range: LSPRange
    public init(uri: String, range: LSPRange) { self.uri = uri; self.range = range }
    public var url: URL? { URL(string: uri) }
}

public enum LSPSeverity: Int, Codable, Sendable {
    case error = 1, warning = 2, information = 3, hint = 4
}

public struct LSPDiagnostic: Codable, Sendable, Hashable {
    public var range: LSPRange
    public var severity: LSPSeverity?
    public var code: JSONValue?
    public var source: String?
    public var message: String
    public init(range: LSPRange, severity: LSPSeverity?, message: String, source: String? = nil) {
        self.range = range; self.severity = severity; self.message = message; self.source = source
    }
}

public struct LSPTextEdit: Codable, Sendable, Hashable {
    public var range: LSPRange
    public var newText: String
    public init(range: LSPRange, newText: String) { self.range = range; self.newText = newText }
}

/// Normalized workspace edit: file URI -> edits.
public struct LSPWorkspaceEdit: Sendable, Hashable {
    public var changes: [String: [LSPTextEdit]]
    public init(changes: [String: [LSPTextEdit]]) { self.changes = changes }

    public init(json: JSONValue) {
        var result: [String: [LSPTextEdit]] = [:]
        if let changes = json["changes"]?.objectValue {
            for (uri, edits) in changes {
                result[uri, default: []] += (try? edits.decode([LSPTextEdit].self)) ?? []
            }
        }
        if let docChanges = json["documentChanges"]?.arrayValue {
            for change in docChanges {
                guard let uri = change["textDocument"]?["uri"]?.stringValue,
                      let edits = change["edits"] else { continue }
                result[uri, default: []] += (try? edits.decode([LSPTextEdit].self)) ?? []
            }
        }
        self.changes = result
    }
}

public enum LSPCompletionKind: Int, Codable, Sendable {
    case text = 1, method, function, constructor, field, variable, `class`, interface, module, property,
         unit, value, `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant,
         `struct`, event, `operator`, typeParameter
}

public struct LSPCompletionItem: Sendable, Hashable {
    public var label: String
    public var kind: LSPCompletionKind?
    public var detail: String?
    public var documentation: String?
    public var sortText: String?
    public var filterText: String?
    public var insertText: String
    public var isSnippet: Bool
    public var textEdit: LSPTextEdit?
    public var additionalTextEdits: [LSPTextEdit]
    /// og's own item: its `textEdit` is computed on the current buffer, so it holds even when the
    /// gopls answer it was merged into is stale.
    public var isLocal = false

    /// A locally generated item (og's own suggestions).
    public init(label: String, detail: String?, snippet: String, filterText: String, sortText: String) {
        self.label = label
        kind = .snippet
        self.detail = detail
        documentation = nil
        self.sortText = sortText
        self.filterText = filterText
        insertText = snippet
        isSnippet = true
        textEdit = nil
        additionalTextEdits = []
        isLocal = true
    }

    public init(json: JSONValue) {
        label = json["label"]?.stringValue ?? ""
        kind = json["kind"]?.intValue.flatMap(LSPCompletionKind.init(rawValue:))
        detail = json["detail"]?.stringValue
        if let doc = json["documentation"] {
            documentation = doc.stringValue ?? doc["value"]?.stringValue
        }
        sortText = json["sortText"]?.stringValue
        filterText = json["filterText"]?.stringValue
        isSnippet = json["insertTextFormat"]?.intValue == 2
        if let te = json["textEdit"] {
            if let range = try? (te["range"] ?? te["replace"] ?? .null).decode(LSPRange.self) {
                textEdit = LSPTextEdit(range: range, newText: te["newText"]?.stringValue ?? "")
            }
        }
        insertText = textEdit?.newText ?? json["insertText"]?.stringValue ?? label
        additionalTextEdits = (try? (json["additionalTextEdits"] ?? .array([])).decode([LSPTextEdit].self)) ?? []
    }

    /// Insert text with snippet placeholders removed; returns text and caret offset (UTF-16) inside it.
    public var plainInsertion: (text: String, caret: Int) {
        guard isSnippet else { return (insertText, (insertText as NSString).length) }
        return Snippet.expand(insertText)
    }
}

public enum Snippet {
    /// Expands an LSP snippet to plain text. The caret goes to `$1`/`${1:...}` if present, else `$0`, else end.
    public static func expand(_ snippet: String) -> (text: String, caret: Int) {
        var out = ""
        var caret: Int?
        var finalCaret: Int?
        var chars = Array(snippet)
        var i = 0
        func utf16Count(_ s: String) -> Int { (s as NSString).length }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1]); i += 2; continue
            }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    // ${n:default} or ${n}
                    var j = i + 2
                    var num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    var placeholder = ""
                    if j < chars.count, chars[j] == ":" {
                        j += 1
                        var depth = 0
                        while j < chars.count {
                            if chars[j] == "{" { depth += 1 }
                            if chars[j] == "}" { if depth == 0 { break }; depth -= 1 }
                            placeholder.append(chars[j]); j += 1
                        }
                    }
                    while j < chars.count, chars[j] != "}" { j += 1 }
                    let n = Int(num) ?? 0
                    let pos = utf16Count(out)
                    if n == 1 && caret == nil { caret = pos }
                    if n == 0 { finalCaret = pos }
                    out += Snippet.expand(placeholder).text
                    i = j + 1
                    continue
                } else if chars[i + 1].isNumber {
                    var j = i + 1
                    var num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    let pos = utf16Count(out)
                    let n = Int(num) ?? 0
                    if n == 1 && caret == nil { caret = pos }
                    if n == 0 { finalCaret = pos }
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return (out, caret ?? finalCaret ?? utf16Count(out))
    }
}

public struct LSPSymbol: Sendable, Hashable {
    public var name: String
    public var detail: String?
    public var kind: Int
    public var range: LSPRange
    public var selectionRange: LSPRange
    public var children: [LSPSymbol]
    public var containerName: String?
    public var uri: String?

    public init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        detail = json["detail"]?.stringValue
        kind = json["kind"]?.intValue ?? 0
        containerName = json["containerName"]?.stringValue
        if let loc = json["location"] {
            uri = loc["uri"]?.stringValue
            let r = (try? (loc["range"] ?? .null).decode(LSPRange.self)) ?? LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
            range = r
            selectionRange = r
        } else {
            range = (try? (json["range"] ?? .null).decode(LSPRange.self)) ?? LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
            selectionRange = (try? (json["selectionRange"] ?? .null).decode(LSPRange.self)) ?? range
        }
        children = (json["children"]?.arrayValue ?? []).map(LSPSymbol.init(json:))
    }

    public var kindLabel: String {
        switch kind {
        case 5: return "type"
        case 6: return "method"
        case 8: return "field"
        case 11: return "interface"
        case 12: return "func"
        case 13: return "var"
        case 14: return "const"
        case 23: return "struct"
        default: return "symbol"
        }
    }
}

public struct LSPCodeAction: Sendable, Hashable {
    public var title: String
    public var kind: String?
    public var edit: LSPWorkspaceEdit?
    public var command: JSONValue?
    public var isPreferred: Bool
    /// The original JSON, for `codeAction/resolve`.
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        title = json["title"]?.stringValue ?? ""
        kind = json["kind"]?.stringValue
        edit = json["edit"].map(LSPWorkspaceEdit.init(json:))
        // A bare Command has "command" as a string; a CodeAction nests a Command object.
        if json["command"]?.stringValue != nil {
            command = json
        } else {
            command = json["command"]
        }
        isPreferred = json["isPreferred"]?.boolValue ?? false
    }
}

public struct LSPSignatureHelp: Sendable, Hashable {
    public var label: String
    public var activeParameterRange: NSRange?

    public init?(json: JSONValue) {
        guard let sigs = json["signatures"]?.arrayValue, !sigs.isEmpty else { return nil }
        let active = json["activeSignature"]?.intValue ?? 0
        let sig = sigs[min(max(active, 0), sigs.count - 1)]
        label = sig["label"]?.stringValue ?? ""
        let paramIndex = sig["activeParameter"]?.intValue ?? json["activeParameter"]?.intValue ?? 0
        if let params = sig["parameters"]?.arrayValue, paramIndex < params.count {
            let p = params[paramIndex]["label"]
            if let s = p?.stringValue {
                let r = (label as NSString).range(of: s)
                activeParameterRange = r.location == NSNotFound ? nil : r
            } else if let arr = p?.arrayValue, arr.count == 2, let a = arr[0].intValue, let b = arr[1].intValue {
                activeParameterRange = NSRange(location: a, length: b - a)
            }
        }
    }
}

public extension URL {
    /// LSP-style file URI.
    var lspURI: String { absoluteURL.standardizedFileURL.absoluteString }
}
