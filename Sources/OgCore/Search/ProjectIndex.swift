import Foundation

// CONTRACT (owned by the Search agent; keep these signatures).

public struct FuzzyMatch: Sendable, Hashable {
    public var relativePath: String
    public var score: Int
    /// UTF-16 offsets into `relativePath` that matched (for highlighting).
    public var matchedOffsets: [Int]

    public init(relativePath: String, score: Int, matchedOffsets: [Int]) {
        self.relativePath = relativePath
        self.score = score
        self.matchedOffsets = matchedOffsets
    }
}

public struct SearchHit: Sendable, Hashable {
    public var url: URL
    public var line: Int          // 0-based
    public var column: Int        // UTF-16, 0-based
    public var length: Int        // UTF-16
    public var lineText: String
    /// UTF-16 offset within the line where `lineText` starts. 0 unless the line is very
    /// long (> `TextSearch.maxPreviewLength`) and `lineText` is a clip around the match.
    public var lineTextOffset: Int = 0

    public init(url: URL, line: Int, column: Int, length: Int, lineText: String) {
        self.url = url
        self.line = line
        self.column = column
        self.length = length
        self.lineText = lineText
    }
}

public struct SearchOptions: Sendable, Hashable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false
    public var fileGlob: String? = nil
    public init() {}
}

/// Planned rewrite of one file for "Replace All" (computed off the main thread, applied by the UI).
public struct ReplacePlan: Sendable, Hashable {
    public var url: URL
    public var original: String
    public var replaced: String
    public var count: Int
}

/// File list of a project (skips .git, vendor/, node_modules/, build output).
public actor ProjectIndex {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    private var files: [String] = []
    private var candidates: [FuzzyCandidate] = []
    private var loaded = false
    private var inFlight: Task<[String], Never>?
    private var lastRefresh: Date = .distantPast
    /// Incremental fuzzy cache: indices that matched `lastQuery` (extending the query only shrinks the set).
    private var lastQuery: FuzzyQuery?
    private var lastMatches: [Int] = []

    /// Minimum interval between two directory scans; calls inside it are free.
    public static let refreshInterval: TimeInterval = 0.5
    public static let maxFiles = 300_000
    static let skippedDirectories: Set<String> = ["vendor", "node_modules", ".build", ".git"]

    /// Rescans the file list. Concurrent calls share one scan; calls within
    /// `refreshInterval` of the previous scan return immediately.
    public func refresh() async {
        if let inFlight { _ = await inFlight.value; return }
        if loaded && Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        let root = self.root
        let task = Task.detached(priority: .userInitiated) { ProjectIndex.listFiles(root: root) }
        inFlight = task
        let list = await task.value
        inFlight = nil
        lastRefresh = Date()
        if !loaded || list != files {
            files = list
            candidates = Self.prepare(list)
            lastQuery = nil
            lastMatches = []
        }
        loaded = true
    }

    private func ensureLoaded() async {
        if !loaded { await refresh() }
    }

    public func allFiles() async -> [String] {
        await ensureLoaded()
        return files
    }

    public func fuzzy(_ query: String, limit: Int = 100) async -> [FuzzyMatch] {
        await ensureLoaded()
        let q = FuzzyQuery(query)
        if q.isEmpty {
            let order = files.indices.sorted { (files[$0].utf16.count, files[$0]) < (files[$1].utf16.count, files[$1]) }
            return order.prefix(limit).map { FuzzyMatch(relativePath: files[$0], score: 0, matchedOffsets: []) }
        }
        // Reuse the previous candidate set when the query only grew.
        let pool: [Int]?
        if let lq = lastQuery, lq.caseSensitive == q.caseSensitive, q.normalized.hasPrefix(lq.normalized) {
            pool = lastMatches
        } else {
            pool = nil
        }
        let scored = Self.score(q, candidates, pool: pool)
        lastQuery = q
        lastMatches = scored.map(\.index).sorted()
        return Self.rank(scored, q, candidates, limit: limit)
    }

    /// Find in files. Files are searched concurrently; results are ordered by path, then line, then column.
    /// When more than `limit` hits exist, the result is truncated to `limit`.
    public func search(_ query: String, options: SearchOptions, limit: Int = 5000) async -> [SearchHit] {
        guard !query.isEmpty, limit > 0, let compiled = try? TextSearch.compile(query, options: options) else { return [] }
        await ensureLoaded()
        let mask = FileMask(options.fileGlob)
        let targets = mask.isEmpty ? files : files.filter(mask.matches)
        let urls = targets.map { root.appendingPathComponent($0) }
        let perFile = await Self.searchConcurrently(urls, query: compiled, limit: limit)
        var hits: [SearchHit] = []
        for i in urls.indices {
            if let h = perFile[i] { hits.append(contentsOf: h) }
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    /// Computes (but does not write) the result of replacing every match in the project.
    public func planReplace(_ query: String, options: SearchOptions, replacement: String) async -> [ReplacePlan] {
        guard !query.isEmpty, let compiled = try? TextSearch.compile(query, options: options) else { return [] }
        let hits = await search(query, options: options, limit: .max)
        var seen = Set<URL>()
        let urls = hits.map(\.url).filter { seen.insert($0).inserted }
        let useTemplate = options.regex
        return await withTaskGroup(of: ReplacePlan?.self) { group in
            for url in urls {
                group.addTask {
                    guard let text = TextSearch.readText(url)?.text else { return nil }
                    let r = TextSearch.replace(in: text, query: compiled, replacement: replacement, regexTemplate: useTemplate)
                    guard r.count > 0, r.text != text else { return nil }
                    return ReplacePlan(url: url, original: text, replaced: r.text, count: r.count)
                }
            }
            var plans: [ReplacePlan] = []
            for await p in group { if let p { plans.append(p) } }
            return plans.sorted { $0.url.path < $1.url.path }
        }
    }

    // MARK: - Fuzzy internals

    struct Scored: Sendable { var index: Int; var score: Int }

    static func prepare(_ files: [String]) -> [FuzzyCandidate] {
        files.map { FuzzyCandidate($0) }
    }

    /// Scores every candidate (or only `pool`) in parallel chunks.
    static func score(_ q: FuzzyQuery, _ cands: [FuzzyCandidate], pool: [Int]?) -> [Scored] {
        let total = pool?.count ?? cands.count
        if total == 0 { return [] }
        let chunks = total < 4000 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount * 2, total / 2000)
        let results = Locked<[[Scored]]>(Array(repeating: [], count: chunks))
        let size = (total + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var matcher = FuzzyMatcher()
            var out: [Scored] = []
            let lo = c * size, hi = min(total, lo + size)
            if lo < hi {
                for k in lo..<hi {
                    let i = pool?[k] ?? k
                    if let s = matcher.score(q, cands[i]) { out.append(Scored(index: i, score: s)) }
                }
            }
            results.withLock { $0[c] = out }
        }
        return results.current.flatMap { $0 }
    }

    /// Best first; ties go to shorter paths, then alphabetical. Offsets are computed for the top `limit` only.
    static func rank(_ scored: [Scored], _ q: FuzzyQuery, _ cands: [FuzzyCandidate], limit: Int) -> [FuzzyMatch] {
        let top = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = cands[a.index].chars.count, lb = cands[b.index].chars.count
            if la != lb { return la < lb }
            return cands[a.index].text < cands[b.index].text
        }.prefix(limit)
        var matcher = FuzzyMatcher()
        return top.map { s in
            let offsets = matcher.match(q, cands[s.index])?.offsets ?? []
            return FuzzyMatch(relativePath: cands[s.index].text, score: s.score, matchedOffsets: offsets)
        }
    }

    // MARK: - Search internals

    /// Runs `TextSearch.searchFile` over `urls` with one worker per core pulling from a shared cursor.
    static func searchConcurrently(_ urls: [URL], query: CompiledQuery, limit: Int) async -> [[SearchHit]?] {
        let cursor = Locked(0)
        let found = Locked(0)
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, urls.count))
        let batch = 8
        return await withTaskGroup(of: [(Int, [SearchHit])].self) { group in
            for _ in 0..<workers {
                group.addTask {
                    var out: [(Int, [SearchHit])] = []
                    while !Task.isCancelled && found.current < limit {
                        let start = cursor.withLock { c -> Int in let s = c; c += batch; return s }
                        if start >= urls.count { break }
                        for i in start..<min(urls.count, start + batch) {
                            let h = TextSearch.searchFile(urls[i], query: query, limit: limit)
                            if !h.isEmpty {
                                out.append((i, h))
                                found.withLock { $0 += h.count }
                            }
                        }
                    }
                    return out
                }
            }
            var perFile = [[SearchHit]?](repeating: nil, count: urls.count)
            for await part in group { for (i, h) in part { perFile[i] = h } }
            return perFile
        }
    }

    // MARK: - File listing

    static func listFiles(root: URL) -> [String] {
        if let viaGit = gitFiles(root: root) { return viaGit }
        return walk(root: root)
    }

    /// `git ls-files -co --exclude-standard` (tracked + untracked, minus ignored); nil if not a repo.
    static func gitFiles(root: URL) -> [String]? {
        guard let git = ToolLocator.shared.find("git") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: git)
        proc.arguments = ["-C", root.path, "ls-files", "-z", "-co", "--exclude-standard"]
        proc.environment = ToolLocator.shared.environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        let base = root.path
        for chunk in data.split(separator: 0) {
            guard let rel = String(data: Data(chunk), encoding: .utf8), !rel.isEmpty else { continue }
            guard seen.insert(rel).inserted else { continue }
            // Drop index entries deleted from the worktree, and submodule directories.
            var st = stat()
            guard stat(base + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            result.append(rel)
            if result.count >= maxFiles { break }
        }
        result.sort()
        return result
    }

    /// Plain directory walk for non-git projects.
    static func walk(root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let altBase = root.standardizedFileURL.path
        var result: [String] = []
        while let next = e.nextObject() {
            guard let url = next as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let p = url.standardizedFileURL.path
            let rel: String
            if p.hasPrefix(base + "/") { rel = String(p.dropFirst(base.count + 1)) }
            else if p.hasPrefix(altBase + "/") { rel = String(p.dropFirst(altBase.count + 1)) }
            else { continue }
            result.append(rel)
            if result.count >= maxFiles { break }
        }
        result.sort()
        return result
    }
}
