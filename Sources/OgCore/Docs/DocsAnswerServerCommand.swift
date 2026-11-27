import Foundation

/// How Docs Phase 3 answer generation selects its local LLM (D-9, D-10, DOC-1, Issue #24).
public enum DocsAnswerLLMMode: String, Sendable, CaseIterable, Codable {
    /// Disabled (Phase 1/2 retrieval only).
    case off
    /// Dedicated og-owned local server slot running an Instruct model for Docs synthesis.
    case dedicated
    /// Reuse the inline completion server (`ModelServerManager`) when it exposes OpenAI `/v1/chat/completions`.
    case sharedCompletion

    public var title: String {
        switch self {
        case .off: return "Off (検索カードのみ)"
        case .dedicated: return "Dedicated Docs LLM (推奨: Instruct モデル)"
        case .sharedCompletion: return "Reuse Inline AI Server (補完サーバーを共用)"
        }
    }
}

/// Selectable local Instruct model presets for Docs Phase 3 answer synthesis (D-10, Issue #24).
public struct DocsAnswerModelPreset: Sendable, Hashable {
    public var backend: ModelBackend
    public var id: String
    public var title: String

    public init(backend: ModelBackend, id: String, title: String) {
        self.backend = backend
        self.id = id
        self.title = title
    }

    public static let all: [DocsAnswerModelPreset] = [
        DocsAnswerModelPreset(
            backend: .mlx,
            id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
            title: "Qwen2.5 Coder 3B Instruct 4bit MLX (Recommended)"
        ),
        DocsAnswerModelPreset(
            backend: .mlx,
            id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            title: "Qwen2.5 Coder 1.5B Instruct 4bit MLX (Lightweight)"
        ),
        DocsAnswerModelPreset(
            backend: .mlx,
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            title: "Qwen2.5 Coder 7B Instruct 4bit MLX (High Quality)"
        ),
        DocsAnswerModelPreset(
            backend: .llamaCpp,
            id: "Qwen/Qwen2.5-Coder-3B-Instruct-GGUF",
            title: "Qwen2.5 Coder 3B Instruct GGUF"
        )
    ]

    public static func presets(for backend: ModelBackend) -> [DocsAnswerModelPreset] {
        all.filter { $0.backend == backend }
    }
}

/// Persisted configuration for Docs Phase 3 answer generation (D-9, D-10, Issue #24).
public struct DocsAnswerServerConfig: Sendable, Hashable, Codable {
    public var mode: DocsAnswerLLMMode
    public var backend: ModelBackend
    public var model: String
    public var customCommand: String
    /// Whether to include active Go editor imports/context in the generation prompt (Issue #24: opt-outable).
    public var includeEditorContext: Bool

    public init(
        mode: DocsAnswerLLMMode = .off,
        backend: ModelBackend = .mlx,
        model: String = DocsAnswerModelPreset.all[0].id,
        customCommand: String = "",
        includeEditorContext: Bool = true
    ) {
        self.mode = mode
        self.backend = backend
        self.model = model
        self.customCommand = customCommand
        self.includeEditorContext = includeEditorContext
    }

    public var healthPath: String {
        backend == .mlx ? "/v1/models" : "/health"
    }
}

/// Builds launch argv for the dedicated Docs answer-generation LLM bound strictly to `127.0.0.1:<port>` (D-9, DES-A1).
public enum DocsAnswerServerCommand {
    public static func argv(
        for config: DocsAnswerServerConfig,
        port: Int,
        offline: Bool = false,
        locator: ToolLocator = .shared
    ) throws -> [String] {
        switch config.backend {
        case .mlx:
            guard let uvx = locator.find("uvx") else {
                throw ModelServerCommandError.missingTool("uvx")
            }
            let modelID = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else {
                throw ModelServerCommandError.emptyCustomCommand
            }
            var cmd = [uvx]
            if offline {
                cmd.append("--offline")
            }
            cmd += ["--from", "mlx-lm", "mlx_lm.server", "--model", modelID, "--host", "127.0.0.1", "--port", String(port)]
            return cmd

        case .llamaCpp:
            var cmd = try ModelServerCommand.llamaServer(locator: locator)
            let m = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !m.isEmpty else {
                throw ModelServerCommandError.emptyCustomCommand
            }
            if m.hasSuffix(".gguf") || m.hasPrefix("/") || m.hasPrefix("~") {
                cmd += ["-m", (m as NSString).expandingTildeInPath]
            } else {
                cmd += ["-hf", m]
            }
            cmd += ["--host", "127.0.0.1", "--port", String(port)]
            return cmd

        case .custom:
            let raw = config.customCommand.replacingOccurrences(of: "{port}", with: String(port))
            let parts = ModelServerCommand.shellSplit(raw)
            guard let first = parts.first else {
                throw ModelServerCommandError.emptyCustomCommand
            }
            if first.hasPrefix("/") { return parts }
            guard let exe = locator.find(first) else {
                throw ModelServerCommandError.missingTool(first)
            }
            return [exe] + parts.dropFirst()
        }
    }
}
