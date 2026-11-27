import Foundation

/// Detected query language used to match response phrasing (UX-7).
public enum DocsLanguage: String, Sendable, Hashable, Codable {
    case japanese
    case english

    public static func detect(in text: String) -> DocsLanguage {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) {
                return .japanese
            }
        }
        return .english
    }
}

/// Rule-based query intent classification (FR-1, §6.1, §7.3).
public enum DocsQueryIntent: Sendable, Hashable {
    case exactSymbol(String)
    case syntaxHowTo
    case existenceCheck
    case needsReverseLookup
    case releaseSince
    case idiomOrWhy
}

/// Output of the deterministic rule-based router (§6.1, §7.3 step 1).
public struct DocsRoutingPlan: Sendable, Hashable {
    public var originalQuery: String
    public var language: DocsLanguage
    public var intent: DocsQueryIntent
    /// Explicit `pkg.Symbol` or stdlib package name extracted from the query, if any.
    public var exactSymbolCandidate: String?
    /// Meaningful search terms (stop-words removed, cross-lingual synonyms expanded).
    public var searchTerms: [String]
    /// Core intent terms that MUST appear in a candidate to avoid stop-word false positives (FR-14).
    public var requiredSignalTerms: [String]

    public init(
        originalQuery: String,
        language: DocsLanguage,
        intent: DocsQueryIntent,
        exactSymbolCandidate: String?,
        searchTerms: [String],
        requiredSignalTerms: [String]
    ) {
        self.originalQuery = originalQuery
        self.language = language
        self.intent = intent
        self.exactSymbolCandidate = exactSymbolCandidate
        self.searchTerms = searchTerms
        self.requiredSignalTerms = requiredSignalTerms
    }
}

/// Weak local editor context signal for ranking (FR-3; never sent off-machine).
public struct DocsEditorContext: Sendable, Hashable {
    public var packageName: String?
    public var importedPackages: [String]

    public init(packageName: String? = nil, importedPackages: [String] = []) {
        self.packageName = packageName
        self.importedPackages = importedPackages
    }

    /// Parses package name and imported paths from the currently edited Go buffer.
    public static func parse(goSource: String) -> DocsEditorContext {
        var pkg: String?
        var imports: [String] = []
        var inImportBlock = false
        for raw in goSource.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if pkg == nil, line.hasPrefix("package ") {
                pkg = String(line.dropFirst(8)).split(separator: " ").first.map(String.init)
                continue
            }
            if line.hasPrefix("import (") {
                inImportBlock = true
                continue
            }
            if inImportBlock {
                if line.hasPrefix(")") { inImportBlock = false; continue }
                if let path = extractQuotedString(line) { imports.append(path) }
            } else if line.hasPrefix("import ") {
                if let path = extractQuotedString(line) { imports.append(path) }
            }
        }
        return DocsEditorContext(packageName: pkg, importedPackages: imports)
    }

    private static func extractQuotedString(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\""),
              let second = line[line.index(after: first)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: first)..<second])
    }
}

/// Data-driven temporary Phase 1 Japanese/English cross-lingual concept expansion rule (R-1).
/// Separated from router code so rules can be extended or supplied as data without code changes
/// until Phase 2 cross-lingual embeddings replace/augment lexical expansion.
public struct DocsConceptRule: Sendable, Hashable, Codable {
    public var triggers: [String]
    public var excludeIfPresent: [String]
    public var expansions: [String]

    public init(triggers: [String], excludeIfPresent: [String] = [], expansions: [String]) {
        self.triggers = triggers
        self.excludeIfPresent = excludeIfPresent
        self.expansions = expansions
    }
}

/// Deterministic rule-based query router and data-driven Japanese->English Go concept expander (FR-1, §6.1, R-1).
public enum DocsQueryRouter {
    /// Known Go standard library package names for deterministic detection.
    public static let knownStdlibPackages: Set<String> = [
        "bufio", "bytes", "cmp", "context", "crypto", "database/sql", "embed",
        "encoding/json", "encoding/xml", "encoding/csv", "encoding/hex", "encoding/base64",
        "errors", "flag", "fmt", "html/template", "io", "io/fs", "iter", "log", "log/slog",
        "maps", "math", "math/rand", "net", "net/http", "net/url", "os", "os/exec",
        "path", "path/filepath", "reflect", "regexp", "runtime", "slices", "sort",
        "strconv", "strings", "sync", "sync/atomic", "testing", "text/template", "time", "unicode"
    ]

    /// Generic filler words that must NEVER trigger a match on their own (prevents hallucination / false hits).
    private static let stopWords: Set<String> = [
        "標準ライブラリ", "標準", "ライブラリ", "stdlib", "standard", "library",
        "go", "golang", "言語", "関数", "メソッド", "パッケージ", "機能", "方法", "書き方",
        "ある", "あります", "ありますか", "ない", "できる", "できますか", "どう", "使う", "使い方",
        "したい", "やりたい", "教えて", "調べたい", "について", "とは", "なぜ", "なんで",
        "how", "to", "in", "of", "the", "a", "an", "is", "are", "does", "do", "can", "use",
        "with", "for", "from", "what", "when", "why", "there", "have", "has", "using", "no", "not"
    ]

    public static func route(
        _ rawQuery: String,
        conceptRules: [DocsConceptRule] = BundledGoCorpus.defaultConceptRules
    ) -> DocsRoutingPlan {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = DocsLanguage.detect(in: query)
        let lower = query.lowercased()

        // 1. Check for explicit `pkg.Symbol` (e.g. `json.Encoder`, `bufio.Scanner`, `encoding/json.MarshalIndent`).
        let exactSymbol = extractSymbolReference(from: query)

        // 2. Classify intent deterministically.
        let intent: DocsQueryIntent
        if let sym = exactSymbol, isStandaloneSymbolQuery(query: query, symbol: sym) {
            intent = .exactSymbol(sym)
        } else if lower.contains("いつから") || lower.contains("since") || lower.contains("変わった") || lower.contains("release note") {
            intent = .releaseSince
        } else if lower.contains("ある？") || lower.contains("ある?") || lower.contains("ありますか") || lower.contains("標準ライブラリに") || lower.contains("does go have") || (lower.contains("is there") && !lower.contains("why ")) {
            intent = .existenceCheck
        } else if lower.contains("書き方") || lower.contains("構文") || lower.contains("syntax") || lower.contains("how to write") || lower.contains("ループ") {
            intent = .syntaxHowTo
        } else if lower.contains("べき") || lower.contains("どっち") || lower.contains("なぜ") || lower.contains("なんで") || lower.contains("why ") || lower.contains("should i") {
            intent = .idiomOrWhy
        } else if let sym = exactSymbol {
            intent = .exactSymbol(sym)
        } else {
            intent = .needsReverseLookup
        }

        // 3. Extract raw tokens and expand cross-lingual concepts.
        var expanded: [String] = []
        var signalTerms: [String] = []

        if let sym = exactSymbol {
            expanded.append(sym)
            signalTerms.append(sym.lowercased())
            for part in sym.split(whereSeparator: { $0 == "." || $0 == "/" }) {
                let s = String(part)
                if !s.isEmpty {
                    expanded.append(s)
                    signalTerms.append(s.lowercased())
                }
            }
        }

        var matchedConcept = false
        for rule in conceptRules {
            if rule.excludeIfPresent.contains(where: { lower.contains($0) }) {
                continue
            }
            let hit = rule.triggers.contains { trigger in
                if trigger == "for" {
                    // Match "for" as a standalone word (avoid matching "format", "before", etc.)
                    return lower.range(of: #"(^|[^a-z])for([^a-z]|$)"#, options: .regularExpression) != nil
                }
                return lower.contains(trigger)
            }
            if hit {
                matchedConcept = true
                expanded.append(contentsOf: rule.expansions)
                signalTerms.append(contentsOf: rule.expansions.map { $0.lowercased() })
            }
        }

        let asciiTokens = extractASCIITokens(from: query)
        for tok in asciiTokens {
            let l = tok.lowercased()
            // Keep "for" if explicitly typed in a syntax query
            if l == "for" && (intent == .syntaxHowTo || lower.contains("loop") || lower.contains("ループ")) {
                expanded.append("for")
                signalTerms.append("for")
                continue
            }
            if !stopWords.contains(l) && l.count >= 2 {
                expanded.append(tok)
                signalTerms.append(l)
            }
        }

        // Extract meaningful Japanese segments (katakana / kanji runs) for direct CJK FTS matching
        // when no predefined concept matched (or to narrow down matches).
        if !matchedConcept || exactSymbol == nil {
            for jpToken in extractMeaningfulJapaneseTokens(from: query) {
                if !stopWords.contains(jpToken) {
                    expanded.append(jpToken)
                    if !matchedConcept {
                        signalTerms.append(jpToken)
                    }
                }
            }
        }

        return DocsRoutingPlan(
            originalQuery: query,
            language: language,
            intent: intent,
            exactSymbolCandidate: exactSymbol,
            searchTerms: uniquePreservingOrder(expanded),
            requiredSignalTerms: uniquePreservingOrder(signalTerms)
        )
    }

    private static func extractSymbolReference(from query: String) -> String? {
        // Backticked symbol e.g. `json.Encoder` or `github.com/go-chi/chi/v5.NewRouter`
        if let tickRange = query.range(of: #"`([a-zA-Z0-9_./-]+\.[A-Za-z0-9_]+)`"#, options: .regularExpression) {
            return String(query[tickRange]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        // Full module/package path qualified symbol e.g. github.com/go-chi/chi/v5.NewRouter
        if let modQualRange = query.range(of: #"\b([a-z0-9][a-z0-9._-]*/[a-zA-Z0-9_./-]+\.[A-Z][A-Za-z0-9_]*)\b"#, options: .regularExpression) {
            return String(query[modQualRange])
        }
        // Bare qualified symbol e.g. bufio.Scanner, encoding/json.MarshalIndent, json.Encoder, chi.NewRouter
        if let qualRange = query.range(of: #"\b([a-z][a-z0-9]*(?:/[a-z][a-z0-9]*)?\.[A-Z][A-Za-z0-9_]*)\b"#, options: .regularExpression) {
            return String(query[qualRange])
        }
        // Standalone known stdlib package name
        let trimmed = query.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`")))
        if knownStdlibPackages.contains(trimmed) {
            return trimmed
        }
        return nil
    }

    private static func isStandaloneSymbolQuery(query: String, symbol: String) -> Bool {
        let stripped = query
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped == symbol
    }

    private static func extractASCIITokens(from text: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        for scalar in text.unicodeScalars {
            let c = Character(scalar)
            if (scalar.isASCII && (c.isLetter || c.isNumber || c == "_" || c == ".")) {
                cur.append(c)
            } else {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    private static func extractMeaningfulJapaneseTokens(from text: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var curKind: Int = 0 // 1 = kanji, 2 = katakana
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if t.count >= 2 && !stopWords.contains(t) {
                tokens.append(t)
            }
            cur = ""
            curKind = 0
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let kind: Int
            if (0x4E00...0x9FFF).contains(v) {
                kind = 1
            } else if (0x30A0...0x30FF).contains(v) || v == 0x30FC {
                kind = 2
            } else {
                kind = 0
            }
            if kind == 0 {
                flush()
            } else if kind == curKind || curKind == 0 {
                curKind = kind
                cur.append(Character(scalar))
            } else {
                flush()
                curKind = kind
                cur.append(Character(scalar))
            }
        }
        flush()
        return tokens
    }

    private static func uniquePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let key = item.lowercased()
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out
    }
}
