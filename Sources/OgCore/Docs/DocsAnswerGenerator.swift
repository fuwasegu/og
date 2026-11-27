import Foundation

/// Outcome of local Go type/build verification for a Phase 3 generated snippet (DOC-11, Issue #24).
public enum DocsSnippetVerificationStatus: Sendable, Hashable {
    case verified
    case unverified(reason: String)
    case failed(errorSummary: String)
    case newerVersionRequired(since: GoVersion)

    /// Only `.verified` snippets are permitted to be presented as usable / insertable (`FailedOrNewerSnippetNeverUsable`).
    public var isUsable: Bool {
        if case .verified = self { return true }
        return false
    }

    public var badgeLabel: String {
        switch self {
        case .verified:
            return "検証済み"
        case .unverified(let reason):
            return "未検証（\(reason)）"
        case .failed(let summary):
            return "検証失敗（\(summary)）"
        case .newerVersionRequired(let since):
            return "go\(since.minorKey) 以降が必要（挿入不可）"
        }
    }
}

/// Phase 3 grounded answer synthesized strictly from retrieved documentation cards (DOC-11, Issue #24).
public struct DocsGeneratedAnswer: Sendable, Hashable {
    public var explanation: String
    public var snippet: String?
    public var citations: [String]
    public var targetVersion: GoVersion
    public var verification: DocsSnippetVerificationStatus
    public var modelID: String

    public init(
        explanation: String,
        snippet: String?,
        citations: [String],
        targetVersion: GoVersion,
        verification: DocsSnippetVerificationStatus,
        modelID: String
    ) {
        self.explanation = explanation
        self.snippet = snippet
        self.citations = citations
        self.targetVersion = targetVersion
        self.verification = verification
        self.modelID = modelID
    }

    /// True only when a non-empty snippet exists AND passed local verification for `targetVersion` (DOC-11, DOC-9).
    public var canInsert: Bool {
        guard let s = snippet, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return verification.isUsable
    }
}

/// Evidence chunk passed to the Phase 3 answer generator.
public struct DocsAnswerEvidence: Sendable, Hashable {
    public var citation: String
    public var title: String
    public var packageName: String
    public var symbol: String
    public var signature: String?
    public var summary: String
    public var example: String?
    public var body: String
    public var since: String?

    public init(
        citation: String,
        title: String,
        packageName: String,
        symbol: String,
        signature: String?,
        summary: String,
        example: String?,
        body: String,
        since: String?
    ) {
        self.citation = citation
        self.title = title
        self.packageName = packageName
        self.symbol = symbol
        self.signature = signature
        self.summary = summary
        self.example = example
        self.body = body
        self.since = since
    }
}

/// Input payload for Phase 3 answer synthesis.
public struct DocsAnswerGenerationRequest: Sendable, Hashable {
    public var query: String
    public var language: DocsLanguage
    public var targetVersion: GoVersion
    public var evidence: [DocsAnswerEvidence]
    public var editorContext: DocsEditorContext?

    public init(
        query: String,
        language: DocsLanguage,
        targetVersion: GoVersion,
        evidence: [DocsAnswerEvidence],
        editorContext: DocsEditorContext? = nil
    ) {
        self.query = query
        self.language = language
        self.targetVersion = targetVersion
        self.evidence = evidence
        self.editorContext = editorContext
    }
}

/// Raw structured output parsed from the local LLM before citation & build verification.
public struct DocsAnswerGenerationOutput: Sendable, Hashable {
    public var explanation: String
    public var snippet: String?
    public var citedLabels: [String]
    public var insufficientEvidence: Bool
    public var requiredNewerGoVersion: GoVersion?

    public init(
        explanation: String,
        snippet: String? = nil,
        citedLabels: [String] = [],
        insufficientEvidence: Bool = false,
        requiredNewerGoVersion: GoVersion? = nil
    ) {
        self.explanation = explanation
        self.snippet = snippet
        self.citedLabels = citedLabels
        self.insufficientEvidence = insufficientEvidence
        self.requiredNewerGoVersion = requiredNewerGoVersion
    }
}

/// Protocol for local-only Phase 3 answer synthesis (DOC-6, DOC-11).
public protocol DocsAnswerGenerator: Sendable {
    var modelID: String { get }
    func generate(request: DocsAnswerGenerationRequest) async throws -> DocsAnswerGenerationOutput?
}

/// Loopback-only OpenAI-compatible `/v1/chat/completions` client for Phase 3 answer generation (DES-A1, DOC-6).
public final class LoopbackChatAnswerGenerator: DocsAnswerGenerator, Sendable {
    public let endpoint: URL
    public let modelID: String
    private let session: URLSession

    public init?(endpoint: URL, modelID: String, timeoutInterval: TimeInterval = 45) {
        guard LocalCompletionClient.isLoopback(endpoint) else { return nil }
        self.endpoint = endpoint
        self.modelID = modelID
        let cfg = LocalCompletionClient.sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        cfg.timeoutIntervalForRequest = timeoutInterval
        cfg.timeoutIntervalForResource = timeoutInterval
        self.session = URLSession(configuration: cfg, delegate: LoopbackOnlySessionDelegate.shared, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func generate(request: DocsAnswerGenerationRequest) async throws -> DocsAnswerGenerationOutput? {
        guard !request.evidence.isEmpty else { return nil }

        var req = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = Self.buildMessages(for: request)
        let body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": 1024,
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocsStorageError.rerankFailed("answer generation HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return Self.parseOutput(content)
    }

    static func buildMessages(for request: DocsAnswerGenerationRequest) -> [[String: String]] {
        let langHint = request.language == .japanese ? "Japanese" : "English"
        let systemPrompt = """
        You are an offline Go documentation assistant for Go \(request.targetVersion.minorKey).
        Rules:
        1. Answer ONLY using the provided Evidence. Never invent Go symbols or packages.
        2. If no Evidence entry can answer the query, write `CITATIONS: none` and `SNIPPET: none`.
        3. Reply using these exact headers:
           CITATIONS: <copy exact citation strings from Evidence, separated by |>
           REQUIRES_NEWER_GO: none
           EXPLANATION:
           <1-2 concise sentences in \(langHint)>
           SNIPPET:
           ```go
           <self-contained, compilable Go code (declare/initialize any needed variables such as req/url/f instead of referencing undefined context variables; include every used stdlib package if writing import)>
           ```
        """

        var userParts: [String] = ["Query: \(request.query)", "Target Go version: \(request.targetVersion.minorKey)"]
        if let ctx = request.editorContext, !ctx.importedPackages.isEmpty {
            userParts.append("Current file imports: \(ctx.importedPackages.sorted().joined(separator: ", "))")
        }
        userParts.append("Evidence:")
        for ev in request.evidence {
            var block = "citation: \(ev.citation)\ntitle: \(ev.title)"
            if let sig = ev.signature, !sig.isEmpty { block += "\nsignature: \(sig)" }
            if let since = ev.since, !since.isEmpty { block += "\nsince: \(since)" }
            block += "\nsummary: \(ev.summary)"
            if let ex = ev.example, !ex.isEmpty { block += "\nexample:\n\(ex)" }
            let trimmedBody = String(ev.body.prefix(600))
            if !trimmedBody.isEmpty { block += "\ndoc: \(trimmedBody)" }
            userParts.append(block)
        }

        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userParts.joined(separator: "\n\n")]
        ]
    }

    /// Parses structured section format or JSON output from LLM text output.
    public static func parseOutput(_ raw: String) -> DocsAnswerGenerationOutput? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let sectioned = parseSectionedOutput(trimmed) {
            return sectioned
        }

        let jsonString: String
        if let start = trimmed.range(of: "{"),
           let end = trimmed.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            jsonString = String(trimmed[start.lowerBound..<end.upperBound])
        } else {
            return nil
        }

        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let insufficient = (obj["insufficient_evidence"] as? Bool) ?? false
        if insufficient {
            return DocsAnswerGenerationOutput(
                explanation: (obj["explanation"] as? String) ?? "",
                snippet: nil,
                citedLabels: [],
                insufficientEvidence: true
            )
        }

        let explanation = (obj["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !explanation.isEmpty else { return nil }

        let rawSnippet = (obj["snippet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = (rawSnippet?.isEmpty == false) ? rawSnippet : nil
        let citations = (obj["citations"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let newerVer = (obj["requires_newer_go"] as? String).flatMap { GoVersion(parsing: $0) }

        return DocsAnswerGenerationOutput(
            explanation: explanation,
            snippet: snippet,
            citedLabels: citations,
            insufficientEvidence: false,
            requiredNewerGoVersion: newerVer
        )
    }

    private static func parseSectionedOutput(_ text: String) -> DocsAnswerGenerationOutput? {
        guard text.contains("EXPLANATION:") || text.contains("INSUFFICIENT_EVIDENCE:") else {
            return nil
        }
        var insufficient = false
        var newerVer: GoVersion?
        var citations: [String] = []
        var explanationLines: [String] = []
        var snippetLines: [String] = []

        enum Section { case none, explanation, snippet }
        var section: Section = .none
        var inCodeFence = false

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("INSUFFICIENT_EVIDENCE:") {
                let val = t.dropFirst("INSUFFICIENT_EVIDENCE:".count).trimmingCharacters(in: .whitespaces).lowercased()
                insufficient = (val == "true" || val == "yes")
                section = .none
                continue
            }
            if t.hasPrefix("REQUIRES_NEWER_GO:") {
                let val = t.dropFirst("REQUIRES_NEWER_GO:".count).trimmingCharacters(in: .whitespaces)
                if val.lowercased() != "none" && val.lowercased() != "null" && !val.isEmpty {
                    newerVer = GoVersion(parsing: val)
                }
                section = .none
                continue
            }
            if t.hasPrefix("CITATIONS:") {
                let val = String(t.dropFirst("CITATIONS:".count))
                let trimmedVal = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmedVal == "none" || trimmedVal == "null" {
                    insufficient = true
                    citations = []
                } else {
                    // Z-7: Split only on `|` so spec/guide titles containing commas stay intact.
                    citations = val.split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                section = .none
                continue
            }
            if t.hasPrefix("EXPLANATION:") {
                let rest = t.dropFirst("EXPLANATION:".count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { explanationLines.append(rest) }
                section = .explanation
                continue
            }
            if t.hasPrefix("SNIPPET:") {
                section = .snippet
                continue
            }
            switch section {
            case .explanation:
                if !t.isEmpty { explanationLines.append(line) }
            case .snippet:
                if t.hasPrefix("```") {
                    inCodeFence.toggle()
                    continue
                }
                if inCodeFence || !t.isEmpty || !snippetLines.isEmpty {
                    snippetLines.append(line)
                }
            case .none:
                break
            }
        }

        if insufficient {
            return DocsAnswerGenerationOutput(
                explanation: explanationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                snippet: nil,
                citedLabels: [],
                insufficientEvidence: true
            )
        }
        let explanation = explanationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !explanation.isEmpty else { return nil }
        let rawSnippet = snippetLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = rawSnippet.isEmpty ? nil : rawSnippet
        return DocsAnswerGenerationOutput(
            explanation: explanation,
            snippet: snippet,
            citedLabels: citations,
            insufficientEvidence: false,
            requiredNewerGoVersion: newerVer
        )
    }
}
