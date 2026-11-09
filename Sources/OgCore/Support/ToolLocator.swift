import Foundation

/// Finds developer tools (go, gopls, dlv, git) for a GUI app.
///
/// Apps launched from Finder get a minimal PATH, so the user's login-shell PATH
/// is captured once and merged with well-known Go/Homebrew locations.
public final class ToolLocator: Sendable {
    public static let shared = ToolLocator()

    public let searchPath: [String]
    public let environment: [String: String]

    public init() {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = []
        if let shellPath = ToolLocator.loginShellPath() {
            dirs.append(contentsOf: shellPath.split(separator: ":").map(String.init))
        }
        dirs.append(contentsOf: (env["PATH"] ?? "").split(separator: ":").map(String.init))
        let home = NSHomeDirectory()
        let gopath = env["GOPATH"] ?? "\(home)/go"
        dirs.append(contentsOf: [
            "\(gopath)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ])
        var seen = Set<String>()
        let unique = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = unique.joined(separator: ":")
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        self.searchPath = unique
        self.environment = env
    }

    /// Absolute path of an executable, or nil.
    public func find(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty ?? true) ? nil : path
    }
}
