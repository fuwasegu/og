import Darwin
import Foundation

/// Which local inference server og runs (spec/req/model_server.fsl, D-9).
public enum ModelBackend: String, Sendable, CaseIterable, Codable {
    case llamaCpp
    case mlx
    case custom

    public var title: String {
        switch self {
        case .llamaCpp: return "llama.cpp (llama-server)"
        case .mlx: return "MLX (mlx_lm.server via uvx)"
        case .custom: return "Custom command"
        }
    }
}

/// A selectable model. `id` is what the backend receives (preset flag, HF repo, or path).
public struct ModelPreset: Sendable, Hashable {
    public var backend: ModelBackend
    public var id: String
    public var title: String

    public static let all: [ModelPreset] = [
        ModelPreset(backend: .llamaCpp, id: "--fim-qwen-1.5b-default", title: "Qwen2.5 Coder 1.5B (fast)"),
        ModelPreset(backend: .llamaCpp, id: "--fim-qwen-3b-default", title: "Qwen2.5 Coder 3B"),
        ModelPreset(backend: .llamaCpp, id: "--fim-qwen-7b-default", title: "Qwen2.5 Coder 7B"),
        ModelPreset(backend: .mlx, id: "mlx-community/Qwen2.5-Coder-1.5B-4bit", title: "Qwen2.5 Coder 1.5B 4bit"),
        ModelPreset(backend: .mlx, id: "mlx-community/Qwen2.5-Coder-3B-4bit", title: "Qwen2.5 Coder 3B 4bit"),
        ModelPreset(backend: .mlx, id: "mlx-community/Qwen2.5-Coder-7B-4bit", title: "Qwen2.5 Coder 7B 4bit")
    ]

    public static func presets(for backend: ModelBackend) -> [ModelPreset] { all.filter { $0.backend == backend } }
}

public struct ModelServerConfig: Sendable, Hashable, Codable {
    public var backend: ModelBackend
    /// Preset flag (`--fim-…`), Hugging Face repo, local path (`.gguf` / directory).
    public var model: String
    /// Custom command for `.custom`; `{port}` is replaced with the chosen port.
    public var customCommand: String

    public init(backend: ModelBackend = .llamaCpp, model: String = "--fim-qwen-1.5b-default", customCommand: String = "") {
        self.backend = backend
        self.model = model
        self.customCommand = customCommand
    }

    /// API the completion client should speak to this server.
    public var api: LocalCompletionClient.API {
        switch backend {
        case .llamaCpp, .custom: return .llamaInfill
        case .mlx: return .openAIFIM(model: model)
        }
    }

    /// Health endpoint path (DES-2).
    public var healthPath: String {
        backend == .mlx ? "/v1/models" : "/health"
    }
}

public enum ModelServerCommandError: Error, LocalizedError, Sendable {
    case missingTool(String)
    case emptyCustomCommand

    public var errorDescription: String? {
        switch self {
        case .missingTool(let t): return "\(t) was not found. Install it (e.g. `brew install \(t == "uvx" ? "uv" : "llama.cpp")`) or choose another backend."
        case .emptyCustomCommand: return "The custom command is empty."
        }
    }
}

public enum ModelServerCommand {
    /// Builds argv for the server bound to 127.0.0.1:`port` (DES-1).
    public static func argv(for config: ModelServerConfig, port: Int, locator: ToolLocator = .shared) throws -> [String] {
        switch config.backend {
        case .llamaCpp:
            var cmd = try llamaServer(locator: locator)
            let m = config.model.trimmingCharacters(in: .whitespaces)
            if m.hasPrefix("--") {
                cmd.append(m)
            } else if m.hasSuffix(".gguf") || m.hasPrefix("/") || m.hasPrefix("~") {
                cmd += ["-m", (m as NSString).expandingTildeInPath]
            } else {
                cmd += ["-hf", m]
            }
            // Later flags override the preset's defaults.
            cmd += ["--host", "127.0.0.1", "--port", String(port)]
            return cmd
        case .mlx:
            guard let uvx = locator.find("uvx") else { throw ModelServerCommandError.missingTool("uvx") }
            return [uvx, "--from", "mlx-lm", "mlx_lm.server", "--model", config.model, "--host", "127.0.0.1", "--port", String(port)]
        case .custom:
            let raw = config.customCommand.replacingOccurrences(of: "{port}", with: String(port))
            let parts = shellSplit(raw)
            guard let first = parts.first else { throw ModelServerCommandError.emptyCustomCommand }
            if first.hasPrefix("/") { return parts }
            guard let exe = locator.find(first) else { throw ModelServerCommandError.missingTool(first) }
            return [exe] + parts.dropFirst()
        }
    }

    /// `llama-server`, going through `mise exec` when the PATH entry is a mise shim.
    static func llamaServer(locator: ToolLocator) throws -> [String] {
        guard let path = locator.find("llama-server") else { throw ModelServerCommandError.missingTool("llama-server") }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if resolved.lastPathComponent == "mise" {
            return [resolved.path, "exec", "llama.cpp", "--", "llama-server"]
        }
        return [path]
    }

    /// Minimal POSIX-like word splitting with single/double quotes.
    public static func shellSplit(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var inWord = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inWord = true
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord { out.append(cur); cur = ""; inWord = false }
            } else {
                cur.append(c); inWord = true
            }
        }
        if inWord { out.append(cur) }
        return out
    }

    /// A free TCP port on 127.0.0.1.
    public static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// True if GET `url` answers 200 within `timeout`.
    public static func healthy(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
