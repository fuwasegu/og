import AppKit
import CMerman
import Darwin

/// Renders Mermaid diagrams to PNG with merman, a native Rust implementation of Mermaid
/// (`libmerman_ffi.dylib`, loaded at run time). One engine for the process, created on first use;
/// a diagram takes a few milliseconds.
actor MermaidRenderer {
    static let shared = MermaidRenderer()

    struct Output: Sendable {
        /// PNG bytes at `scale`.
        var png: Data?
        var error: String?
        var scale: Double
    }

    struct Key: Hashable, Sendable {
        var source: String
        var dark: Bool
        var background: String
    }

    private var api = MermanNativeApi()
    private var engine: MermanNativeEngineToken = 0
    private var state: State = .unloaded
    private enum State { case unloaded, ready, unavailable(String) }
    private var cache: [Key: Output] = [:]
    private var order: [Key] = []

    /// Why diagrams cannot be rendered, or nil when they can (loads the library on first call).
    func unavailableReason() -> String? {
        load()
        if case .unavailable(let why) = state { return why }
        return nil
    }

    func render(_ key: Key, scale: Double = 2) -> Output {
        if let hit = cache[key] { return hit }
        load()
        guard case .ready = state else {
            if case .unavailable(let why) = state { return Output(png: nil, error: why, scale: scale) }
            return Output(png: nil, error: "merman is not loaded", scale: scale)
        }
        let options = """
        {"site_config":{"theme":"\(key.dark ? "dark" : "default")"},\
        "raster":{"scale":\(scale),"background":"\(key.background)"}}
        """
        let out = execute(source: key.source, options: options, scale: scale)
        cache[key] = out
        order.append(key)
        if order.count > 128 { cache[order.removeFirst()] = nil }
        return out
    }

    // MARK: - Loading

    private func load() {
        guard case .unloaded = state else { return }
        guard let path = Self.libraryPath() else {
            state = .unavailable("Mermaid renderer not found (run scripts/fetch-merman.sh)")
            return
        }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            state = .unavailable("Could not load merman: \(String(cString: dlerror()))")
            return
        }
        guard let sym = dlsym(handle, "merman_get_native_api") else {
            state = .unavailable("merman: missing merman_get_native_api")
            return
        }
        typealias GetAPI = @convention(c) (UnsafePointer<MermanNativeApiRequest>?, UnsafeMutablePointer<MermanNativeApi>?) -> MermanNativeStatus
        let getAPI = unsafeBitCast(sym, to: GetAPI.self)
        let digest = Array(MERMAN_NATIVE_ABI_MINIMUM_PREFIX_LAYOUT_DIGEST.utf8)
        var api = MermanNativeApi()
        api.struct_size = UInt32(MemoryLayout<MermanNativeApi>.size)
        let status: MermanNativeStatus = digest.withUnsafeBufferPointer { d in
            var req = MermanNativeApiRequest()
            req.struct_size = UInt32(MemoryLayout<MermanNativeApiRequest>.size)
            req.expected_abi_version = UInt32(MERMAN_NATIVE_ABI_VERSION)
            req.expected_minimum_prefix_layout_digest = Self.slice(d)
            return getAPI(&req, &api)
        }
        guard status == MERMAN_NATIVE_STATUS_OK, api.abi_version == UInt32(MERMAN_NATIVE_ABI_VERSION),
              let newEngine = api.engine_new_with_fonts, api.execute_collect != nil, api.result_free != nil else {
            state = .unavailable("merman: incompatible library (status \(status))")
            return
        }
        self.api = api
        // Hiragino for Japanese labels; merman's bundled fonts cover the rest.
        let fonts = Self.fontFiles.compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        var token: MermanNativeEngineToken = 0
        var result = Self.emptyResult()
        let options = Array("{}".utf8)
        let s: MermanNativeStatus = options.withUnsafeBufferPointer { o in
            Self.withSlices(fonts) { slices in
                slices.withUnsafeBufferPointer { fs in
                    var config = MermanNativeFontEngineConfig()
                    config.struct_size = UInt32(MemoryLayout<MermanNativeFontEngineConfig>.size)
                    config.options_json = Self.slice(o)
                    config.fonts = fs.baseAddress
                    config.font_count = fs.count
                    config.use_bundled_fonts = 1
                    return newEngine(&config, &token, &result)
                }
            }
        }
        let message = Self.errorMessage(result)
        api.result_free?(&result)
        guard s == MERMAN_NATIVE_STATUS_OK, token != 0 else {
            state = .unavailable("merman: engine failed (\(message ?? "status \(s)"))")
            return
        }
        engine = token
        state = .ready
    }

    private static let fontFiles = [
        "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
        "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc",
    ]

    /// og.app/Contents/Frameworks, `OG_MERMAN_LIB`, or `.build/deps/merman` above a development binary.
    nonisolated static func libraryPath() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["OG_MERMAN_LIB"], fm.fileExists(atPath: env) { return env }
        if let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("libmerman_ffi.dylib"), fm.fileExists(atPath: fw.path) {
            return fw.path
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("deps/merman/lib/libmerman_ffi.dylib")
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Rendering

    private func execute(source: String, options: String, scale: Double) -> Output {
        guard let exec = api.execute_collect else { return Output(png: nil, error: "merman unavailable", scale: scale) }
        let src = Array(source.utf8)
        let opts = Array(options.utf8)
        var result = Self.emptyResult()
        let engine = self.engine
        let status: MermanNativeStatus = src.withUnsafeBufferPointer { s in
            opts.withUnsafeBufferPointer { o in
                var req = MermanNativeOperationRequest()
                req.struct_size = UInt32(MemoryLayout<MermanNativeOperationRequest>.size)
                req.operation = MermanNativeOperationCode(MERMAN_NATIVE_OPERATION_PNG)
                req.source = Self.slice(s)
                req.uri = Self.slice(UnsafeBufferPointer(start: nil, count: 0))
                req.options_json = Self.slice(o)
                return exec(engine, &req, &result)
            }
        }
        defer { api.result_free?(&result) }
        if status == MERMAN_NATIVE_STATUS_OK, result.status == MERMAN_NATIVE_STATUS_OK, let p = result.data.data, result.data.len > 0 {
            return Output(png: Data(bytes: p, count: result.data.len), error: nil, scale: scale)
        }
        return Output(png: nil, error: Self.errorMessage(result) ?? "Mermaid error (status \(status))", scale: scale)
    }

    // MARK: - C helpers

    private static func emptyResult() -> MermanNativeResult {
        var r = MermanNativeResult()
        r.struct_size = UInt32(MemoryLayout<MermanNativeResult>.size)
        return r
    }

    private static func slice(_ b: UnsafeBufferPointer<UInt8>) -> MermanNativeSlice {
        var s = MermanNativeSlice()
        s.struct_size = UInt32(MemoryLayout<MermanNativeSlice>.size)
        s.data = b.count == 0 ? nil : b.baseAddress
        s.len = b.count
        return s
    }

    /// Borrowed slices over each `Data` for the duration of `body`.
    private static func withSlices<R>(_ datas: [Data], _ body: ([MermanNativeSlice]) -> R) -> R {
        func go(_ i: Int, _ acc: [MermanNativeSlice]) -> R {
            guard i < datas.count else { return body(acc) }
            return datas[i].withUnsafeBytes { raw in
                go(i + 1, acc + [slice(raw.bindMemory(to: UInt8.self))])
            }
        }
        return go(0, [])
    }

    /// The human-readable message in a result's error JSON.
    private static func errorMessage(_ r: MermanNativeResult) -> String? {
        guard let p = r.metadata_or_error_json.data, r.metadata_or_error_json.len > 0 else { return nil }
        let data = Data(bytes: p, count: r.metadata_or_error_json.len)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail"] {
                if let m = obj[key] as? String { return m }
                if let e = obj[key] as? [String: Any], let m = e["message"] as? String { return m }
            }
        }
        return String(data: data, encoding: .utf8)
    }
}
