import Foundation

/// Built-in core Go documentation pack shipped inside `og` (Q-1 / Q-4).
///
/// Covers core Go language syntax, Effective Go idioms, and essential standard library
/// symbols with accurate `since` versions so offline lookup (UC-1, UC-2, UC-3) and
/// version gating work immediately even without network access or a local Go install.
///
/// `searchAliases` use general domain vocabulary only — never verbatim test queries (H-2).
/// Release notes newer than the requested pack version are omitted (L-7).
///
/// All excerpts and signatures follow Go's official documentation (BSD-3-Clause, `DocsLicense.goBSD3Clause`).
public enum BundledGoCorpus {
    /// Default Go minor version for the bundled core pack.
    public static let defaultVersion = "1.23"

    /// Generates the core Go documentation chunks stamped for `goVersion`.
    public static func chunks(forGoVersion goVersion: String = defaultVersion) -> [DocsChunk] {
        let targetVer = GoVersion(parsing: goVersion)

        var items: [DocsChunk] = [
            // MARK: - UC-1: Language Spec & Effective Go (control flow & idioms)

            DocsChunk(
                goVersion: goVersion,
                source: .spec,
                packageName: "",
                documentID: "go_spec",
                symbol: "for",
                kind: .syntax,
                title: "For statements (classic 3-clause, condition-only, infinite)",
                anchor: "#For_statements",
                since: "1.0",
                summary: "Go のループは for のみ。C 風 3 節（カウンタ）、条件のみ（while 相当）、条件省略（無限ループ）の 3 形式＋for range を使う。",
                signature: "for init; cond; post { ... }  |  for cond { ... }  |  for { ... }",
                example: """
                for i := 0; i < 5; i++ {
                \tfmt.Println(i)
                }
                """,
                body: """
                A "for" statement specifies repeated execution of a block. There are three core forms in all Go versions:
                1. Single condition (`for cond { ... }`) — Go's equivalent of `while`.
                2. Classic for clause (`for i := 0; i < n; i++ { ... }`) — index/counter loop.
                3. Infinite loop (`for { ... }`) — exit with `break` or `return`.
                Choose `for range` when iterating over slices, maps, strings, or channels.
                """,
                searchAliases: ["for", "loop", "while", "ループ", "繰り返し", "反復"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .guide,
                packageName: "",
                documentID: "effective_go",
                symbol: "for range",
                kind: .guide,
                title: "Effective Go: For (iterating slices, maps, strings, channels)",
                anchor: "#for",
                since: "1.0",
                summary: "スライス・マップ・文字列・チャネルの走査には for range を使う。不要な値やインデックスはブランク識別子 `_` で捨てる。",
                signature: "for idx, val := range collection { ... }",
                example: """
                for i, v := range items {
                \tfmt.Printf("%d: %v\\n", i, v)
                }
                """,
                body: """
                Effective Go recommends `for range` for iterating over arrays, slices, strings, maps, and channels.
                Use `for _, v := range xs` when you only need the value, and `for i := range xs` when you only need the index or key.
                For strings, `range` decodes UTF-8 runes rather than raw bytes.
                """,
                searchAliases: ["for", "range", "foreach", "iterate", "ループ", "走査", "反復"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .spec,
                packageName: "",
                documentID: "go_spec",
                symbol: "for range int",
                kind: .syntax,
                title: "For statements with range over integer (Go 1.22+)",
                anchor: "#For_range_int",
                since: "1.22",
                summary: "Go 1.22 以降では整数 n に対して `for i := range n` で 0 から n-1 まで反復できる。",
                signature: "for i := range n { ... }  // Go 1.22+",
                example: """
                for i := range 10 {
                \tfmt.Println(i)
                }
                """,
                body: """
                Starting in Go 1.22, a `for` statement with a `range` clause may iterate over an integer value `n`, producing values 0 through n-1.
                In Go 1.21 and earlier, use the classic `for i := 0; i < n; i++` form instead.
                """,
                searchAliases: ["for", "range", "integer", "整数", "ループ"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .spec,
                packageName: "",
                documentID: "go_spec",
                symbol: "for range func",
                kind: .syntax,
                title: "For statements with range over function iterators (Go 1.23+)",
                anchor: "#For_range_func",
                since: "1.23",
                summary: "Go 1.23 以降では `iter.Seq` / `iter.Seq2` などのイテレータ関数を `for v := range seq` で直接反復できる。",
                signature: "for v := range seq { ... }  // Go 1.23+, iter.Seq[V]",
                example: """
                for v := range slices.Values(items) {
                \tfmt.Println(v)
                }
                """,
                body: """
                Starting in Go 1.23, `for range` supports function iterators matching `func(func() bool)`, `func(func(K) bool)` (`iter.Seq`), and `func(func(K, V) bool)` (`iter.Seq2`).
                """,
                searchAliases: ["for", "range", "iterator", "iter.Seq", "イテレータ"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .spec,
                packageName: "",
                documentID: "go_spec",
                symbol: "switch",
                kind: .syntax,
                title: "Switch statements (expression switch and type switch)",
                anchor: "#Switch_statements",
                since: "1.0",
                summary: "Go の switch は自動で break する（fallthrough は明示が必要）。条件式なし switch は長い if-else の代わりに使える。",
                signature: "switch expr { case v1: ... default: ... }",
                example: """
                switch status {
                case "ok":
                \tfmt.Println("success")
                default:
                \tfmt.Println("other")
                }
                """,
                body: """
                Switch statements provide multi-way execution. Cases do not fall through automatically.
                A tagless `switch { case cond: ... }` is an idiomatic replacement for long if-else-if chains.
                A type switch `switch v := x.(type)` branches on the dynamic type of an interface value.
                """,
                searchAliases: ["switch", "branch", "条件分岐", "型スイッチ"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .guide,
                packageName: "",
                documentID: "effective_go",
                symbol: "defer",
                kind: .guide,
                title: "Effective Go: Defer (cleanup on function return)",
                anchor: "#defer",
                since: "1.0",
                summary: "ファイルやロックの解放には `defer` を使い、リソース取得の直後に解放処理を記述する（LIFO 順で実行）。",
                signature: "defer f.Close()",
                example: """
                f, err := os.Open(path)
                if err != nil {
                \treturn err
                }
                defer f.Close()
                """,
                body: """
                Go's `defer` statement schedules a function call to be run immediately before the surrounding function returns.
                Deferred calls execute in LIFO order and are evaluated when the `defer` statement runs.
                Use `defer` right after checking an acquisition error so resources are never leaked.
                """,
                searchAliases: ["defer", "cleanup", "finally", "後処理", "リソース解放"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .guide,
                packageName: "",
                documentID: "effective_go",
                symbol: "error wrapping",
                kind: .guide,
                title: "Error wrapping with fmt.Errorf (%w), errors.Is, and errors.As",
                anchor: "#errors",
                since: "1.13",
                summary: "呼び出し元がエラー種別を判定できる必要がある場合は `fmt.Errorf(\"...: %w\", err)` でラップし、`errors.Is` / `errors.As` で検査する。",
                signature: "fmt.Errorf(\"context: %w\", err)",
                example: """
                if err != nil {
                \treturn fmt.Errorf("read config: %w", err)
                }
                """,
                body: """
                Wrap errors with `%w` when callers should be able to match the underlying error using `errors.Is` or `errors.As`.
                Use `%v` instead if you intentionally want to hide implementation details at a package boundary.
                """,
                searchAliases: ["error", "wrap", "Errorf", "errors.Is", "errors.As", "エラー", "ラップ"]
            ),

            // MARK: - UC-2 & UC-3: Standard Library

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "bufio",
                symbol: "Scanner",
                kind: .type,
                title: "bufio.Scanner — read input line by line",
                anchor: "bufio.Scanner",
                since: "1.1",
                summary: "ファイルや io.Reader を 1 行ずつ読む標準の手段。`scanner.Scan()` ループの後に必ず `scanner.Err()` を確認する。",
                signature: "func NewScanner(r io.Reader) *Scanner",
                example: """
                f, err := os.Open("input.txt")
                if err != nil {
                \treturn err
                }
                defer f.Close()

                scanner := bufio.NewScanner(f)
                for scanner.Scan() {
                \tline := scanner.Text()
                \tfmt.Println(line)
                }
                if err := scanner.Err(); err != nil {
                \treturn err
                }
                """,
                body: """
                Scanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.
                Successive calls to the Scan method step through the tokens of a file, splitting on lines by default (ScanLines).
                Always check `scanner.Err()` after the loop finishes. Default maximum token size is 64 KiB; call `scanner.Buffer` for longer lines.
                """,
                searchAliases: ["bufio", "Scanner", "ScanLines", "行単位", "テキスト読込"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "os",
                symbol: "ReadFile",
                kind: .function,
                title: "os.ReadFile — read entire file into memory",
                anchor: "os.ReadFile",
                since: "1.16",
                summary: "小さいファイルを丸ごとバイト列として読み込むなら `os.ReadFile` が最も簡潔。大きいファイルを 1 行ずつ読む場合は `bufio.Scanner` を使う。",
                signature: "func ReadFile(name string) ([]byte, error)",
                example: """
                data, err := os.ReadFile("input.txt")
                if err != nil {
                \treturn err
                }
                fmt.Println(string(data))
                """,
                body: """
                ReadFile reads the named file and returns the contents. A successful call returns err == nil, not err == EOF.
                Replaced the deprecated `ioutil.ReadFile` in Go 1.16.
                """,
                searchAliases: ["os", "ReadFile", "ファイル読込"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "os",
                symbol: "WriteFile",
                kind: .function,
                title: "os.WriteFile — write bytes to a file",
                anchor: "os.WriteFile",
                since: "1.16",
                summary: "バイト列をファイルに書き出す標準関数。既存ファイルは上書き（切り詰め）される。",
                signature: "func WriteFile(name string, data []byte, perm FileMode) error",
                example: """
                if err := os.WriteFile("out.txt", []byte("hello\\n"), 0o644); err != nil {
                \treturn err
                }
                """,
                body: """
                WriteFile writes data to the named file, creating it if necessary. If the file does not exist, WriteFile creates it with permissions perm; otherwise WriteFile truncates it before writing.
                """,
                searchAliases: ["os", "WriteFile", "ファイル書込"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "encoding/json",
                symbol: "MarshalIndent",
                kind: .function,
                title: "encoding/json.MarshalIndent — pretty-print JSON bytes",
                anchor: "encoding/json.MarshalIndent",
                since: "1.0",
                summary: "構造体やマップをインデント付きで整形した JSON（`[]byte`）に変換する標準関数。",
                signature: "func MarshalIndent(v any, prefix, indent string) ([]byte, error)",
                example: """
                b, err := json.MarshalIndent(v, "", "  ")
                if err != nil {
                \treturn err
                }
                fmt.Println(string(b))
                """,
                body: """
                MarshalIndent is like Marshal but applies Indent to format the output.
                Each JSON element in the output begins on a new line beginning with prefix followed by one or more copies of indent according to the indentation nesting.
                """,
                searchAliases: ["json", "MarshalIndent", "indent", "整形"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "encoding/json",
                symbol: "Encoder",
                kind: .type,
                title: "encoding/json.Encoder — stream JSON to an io.Writer (with SetIndent)",
                anchor: "encoding/json.Encoder",
                since: "1.0",
                summary: "`io.Writer`（標準出力・HTTP レスポンス・ファイル等）へ直接 JSON を書き出す。`enc.SetIndent(\"\", \"  \")` で整形出力もできる。",
                signature: "func NewEncoder(w io.Writer) *Encoder  // enc.SetIndent(prefix, indent); enc.Encode(v)",
                example: """
                enc := json.NewEncoder(os.Stdout)
                enc.SetIndent("", "  ")
                if err := enc.Encode(v); err != nil {
                \treturn err
                }
                """,
                body: """
                An Encoder writes JSON values to an output stream (`io.Writer`).
                Call `enc.SetIndent("", "  ")` before `enc.Encode(v)` to emit pretty-printed JSON directly to the writer without buffering an intermediate byte slice.
                """,
                searchAliases: ["json", "Encoder", "SetIndent", "Encode", "整形"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "encoding/json",
                symbol: "Unmarshal",
                kind: .function,
                title: "encoding/json.Unmarshal — parse JSON bytes into a struct or map",
                anchor: "encoding/json.Unmarshal",
                since: "1.0",
                summary: "JSON バイト列を構造体ポインタ（`&dst`）へデコードする標準関数。フィールドには `json:\"name\"` タグを付ける。",
                signature: "func Unmarshal(data []byte, v any) error",
                example: """
                var cfg Config
                if err := json.Unmarshal(data, &cfg); err != nil {
                \treturn err
                }
                """,
                body: """
                Unmarshal parses the JSON-encoded data and stores the result in the value pointed to by v.
                Struct fields must be exported (capitalized) to be populated by `encoding/json`.
                """,
                searchAliases: ["json", "Unmarshal", "parse", "デコード"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "slices",
                symbol: "Compact",
                kind: .function,
                title: "slices.Compact — deduplicate consecutive equal elements (sort + compact)",
                anchor: "slices.Compact",
                since: "1.21",
                summary: "標準ライブラリ `slices` でスライスの重複を取り除く場合、`slices.Sort` してから `slices.Compact` を呼ぶ（順序維持が必要なら `map[T]struct{}` を使う）。",
                signature: "func Compact[S ~[]E, E comparable](s S) S",
                example: """
                slices.Sort(items)
                items = slices.Compact(items)
                """,
                body: """
                Compact replaces consecutive runs of equal elements with a single copy.
                Because it only removes adjacent duplicates, sort the slice first with `slices.Sort(items)` when order does not need to be preserved.
                To remove duplicates while preserving original order, track seen elements with `seen := make(map[T]struct{})`.
                """,
                searchAliases: ["slices", "Compact", "deduplicate", "unique", "重複"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .guide,
                packageName: "",
                documentID: "effective_go",
                symbol: "deduplicate map pattern",
                kind: .guide,
                title: "Order-preserving deduplication with map[T]struct{} (Set idiom)",
                anchor: "#maps",
                since: "1.0",
                summary: "元の順序を保ったまま重複を取り除く場合や Go 1.20 以前では、`map[T]struct{}` を集合（Set）として使うのが Go の標準イディオム。",
                signature: "seen := make(map[T]struct{}, len(items))",
                example: """
                seen := make(map[string]struct{}, len(items))
                out := make([]string, 0, len(items))
                for _, v := range items {
                \tif _, ok := seen[v]; !ok {
                \t\tseen[v] = struct{}{}
                \t\tout = append(out, v)
                \t}
                }
                """,
                body: """
                Go does not have a built-in set type; `map[T]struct{}` (zero-byte value) is the idiomatic set representation.
                Use this pattern to deduplicate a slice while preserving first-seen order in any Go version.
                """,
                searchAliases: ["map", "set", "deduplicate", "unique", "重複", "集合"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "slices",
                symbol: "Sort",
                kind: .function,
                title: "slices.Sort & slices.SortFunc — sort a slice in place",
                anchor: "slices.Sort",
                since: "1.21",
                summary: "スライスの昇順ソートは `slices.Sort`、カスタム比較は `slices.SortFunc` を使う（`sort.Slice` より型安全で高速）。",
                signature: "func Sort[S ~[]E, E cmp.Ordered](x S)",
                example: """
                slices.Sort(nums)
                """,
                body: """
                Sort sorts a slice of any ordered type in ascending order. For custom ordering or structs, use `slices.SortFunc` with `cmp.Compare`.
                """,
                searchAliases: ["slices", "Sort", "SortFunc", "ソート", "並べ替え"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "context",
                symbol: "WithTimeout",
                kind: .function,
                title: "context.WithTimeout — attach a timeout / deadline to an operation",
                anchor: "context.WithTimeout",
                since: "1.7",
                summary: "処理にタイムアウトを付ける標準の手段。返される `cancel` 関数はリーク防止のため必ず `defer cancel()` する。",
                signature: "func WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc)",
                example: """
                ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
                defer cancel()

                req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
                if err != nil {
                \treturn err
                }
                """,
                body: """
                WithTimeout returns a copy of parent with a deadline of `time.Now().Add(timeout)`.
                Canceling this context releases resources associated with it, so code should call `defer cancel()` as soon as the operations running in this Context complete.
                Pass `ctx` as the first argument to downstream I/O, HTTP, database, and `exec.CommandContext` calls.
                """,
                searchAliases: ["context", "WithTimeout", "deadline", "timeout", "タイムアウト"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "regexp",
                symbol: "Compile",
                kind: .function,
                title: "regexp — regular expression matching in the standard library",
                anchor: "regexp.Compile",
                since: "1.0",
                summary: "標準ライブラリに正規表現パッケージ `regexp` がある（RE2 構文・線形時間保証）。固定パターンは `regexp.MustCompile` をパッケージ変数で 1 回だけコンパイルする。",
                signature: "func Compile(expr string) (*Regexp, error)  |  func MustCompile(str string) *Regexp",
                example: """
                re := regexp.MustCompile(`^[a-z]+\\d+$`)
                matched := re.MatchString("item42")
                """,
                body: """
                Package `regexp` implements regular expression search in the Go standard library using RE2 syntax (guaranteed O(n) time, no backreferences).
                Use `regexp.Compile` for dynamic patterns and `regexp.MustCompile` for constant patterns initialized once.
                """,
                searchAliases: ["regexp", "regex", "Compile", "MatchString", "正規表現"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "io",
                symbol: "EOF",
                kind: .variable,
                title: "io.EOF — end-of-input sentinel error",
                anchor: "io.EOF",
                since: "1.0",
                summary: "ストリームの正常な終端を表す標準のセンチネルエラー。`errors.Is(err, io.EOF)` で判定する。",
                signature: "var EOF = errors.New(\"EOF\")",
                example: """
                if errors.Is(err, io.EOF) {
                \tbreak
                }
                """,
                body: """
                EOF is the error returned by Read when no more input is available.
                """,
                searchAliases: ["io", "EOF", "終端"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "strings",
                symbol: "Builder",
                kind: .type,
                title: "strings.Builder — efficiently build strings without repeated allocation",
                anchor: "strings.Builder",
                since: "1.10",
                summary: "ループ内で文字列を連結するなら `+` ではなく `strings.Builder` を使う。",
                signature: "var b strings.Builder; b.WriteString(s); b.String()",
                example: """
                var b strings.Builder
                for _, part := range parts {
                \tb.WriteString(part)
                }
                result := b.String()
                """,
                body: """
                A Builder is used to efficiently build a string using Write methods. It minimizes memory copying.
                The zero value is ready to use.
                """,
                searchAliases: ["strings", "Builder", "concat", "文字列連結"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "strconv",
                symbol: "Atoi",
                kind: .function,
                title: "strconv.Atoi & strconv.Itoa — convert between string and int",
                anchor: "strconv.Atoi",
                since: "1.0",
                summary: "文字列と int の相互変換は `strconv.Atoi`（文字列→int）と `strconv.Itoa`（int→文字列）を使う。",
                signature: "func Atoi(s string) (int, error)  |  func Itoa(i int) string",
                example: """
                n, err := strconv.Atoi("42")
                if err != nil {
                \treturn err
                }
                s := strconv.Itoa(n)
                """,
                body: """
                Atoi is equivalent to ParseInt(s, 10, 0), converted to type int. Itoa is equivalent to FormatInt(int64(i), 10).
                """,
                searchAliases: ["strconv", "Atoi", "Itoa", "数値変換"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "time",
                symbol: "Format",
                kind: .method,
                title: "time.Time.Format & time.Parse — format and parse timestamps",
                anchor: "time.Time.Format",
                since: "1.0",
                summary: "Go の日時フォーマットは `YYYY-MM-DD` ではなく基準日時 `2006-01-02 15:04:05`（または `time.RFC3339` / `time.DateTime`）をレイアウトに使う。",
                signature: "func (t Time) Format(layout string) string  |  func Parse(layout, value string) (Time, error)",
                example: """
                now := time.Now()
                fmt.Println(now.Format(time.RFC3339))
                """,
                body: """
                Format returns a textual representation of the time value formatted according to the reference time `Mon Jan 2 15:04:05 MST 2006`.
                Standard layout constants include `time.RFC3339`, and since Go 1.20 `time.DateTime`, `time.DateOnly`, and `time.TimeOnly`.
                """,
                searchAliases: ["time", "Format", "Parse", "RFC3339", "日時"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "sync",
                symbol: "WaitGroup",
                kind: .type,
                title: "sync.WaitGroup — wait for a collection of goroutines to finish",
                anchor: "sync.WaitGroup",
                since: "1.0",
                summary: "複数の goroutine の完了を待つ標準の仕組み。`wg.Add(1)` は goroutine 起動前に呼び、goroutine 内で `defer wg.Done()` する。",
                signature: "var wg sync.WaitGroup; wg.Add(1); defer wg.Done(); wg.Wait()",
                example: """
                var wg sync.WaitGroup
                for _, job := range jobs {
                \twg.Add(1)
                \tgo func() {
                \t\tdefer wg.Done()
                \t\tprocess(job)
                \t}()
                }
                wg.Wait()
                """,
                body: """
                A WaitGroup waits for a collection of goroutines to finish. The main goroutine calls Add to set the number of goroutines to wait for, each goroutine calls Done when finished, and Wait blocks until all goroutines have finished.
                """,
                searchAliases: ["sync", "WaitGroup", "goroutine", "並行処理"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "net/http",
                symbol: "Client",
                kind: .type,
                title: "net/http.Client — make HTTP requests with timeout and context",
                anchor: "net/http.Client",
                since: "1.0",
                summary: "HTTP リクエストを送る場合はデフォルトの `http.Get` ではなく、タイムアウト付き `http.Client` と `http.NewRequestWithContext` を使い、`resp.Body.Close()` を defer する。",
                signature: "client := &http.Client{Timeout: 10 * time.Second}",
                example: """
                client := &http.Client{Timeout: 10 * time.Second}
                req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
                if err != nil {
                \treturn err
                }
                resp, err := client.Do(req)
                if err != nil {
                \treturn err
                }
                defer resp.Body.Close()
                """,
                body: """
                A Client is an HTTP client. Always set a Timeout or pass a context with deadline, and always close `resp.Body` when `err == nil`.
                """,
                searchAliases: ["net/http", "Client", "HTTP", "request"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "path/filepath",
                symbol: "WalkDir",
                kind: .function,
                title: "path/filepath.WalkDir — recursively traverse a directory tree",
                anchor: "path/filepath.WalkDir",
                since: "1.16",
                summary: "ディレクトリを再帰的に走査する標準関数。旧 `filepath.Walk` より高速（不要な `Lstat` を避ける）。",
                signature: "func WalkDir(root string, fn fs.WalkDirFunc) error",
                example: """
                err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
                \tif err != nil {
                \t\treturn err
                \t}
                \tif !d.IsDir() {
                \t\tfmt.Println(path)
                \t}
                \treturn nil
                })
                """,
                body: """
                WalkDir walks the file tree rooted at root, calling fn for each file or directory in the tree, including root.
                """,
                searchAliases: ["filepath", "WalkDir", "walk", "ディレクトリ走査"]
            ),

            DocsChunk(
                goVersion: goVersion,
                source: .stdlib,
                packageName: "maps",
                symbol: "Keys",
                kind: .function,
                title: "maps.Keys & maps.Collect — collect map keys as an iterator/slice (Go 1.23+)",
                anchor: "maps.Keys",
                since: "1.23",
                summary: "Go 1.23 以降では `slices.Collect(maps.Keys(m))` でマップのキー一覧をスライス化できる（1.22 以前は `for k := range m` で append）。",
                signature: "func Keys[Map ~map[K]V, K comparable, V any](m Map) iter.Seq[K]  // Go 1.23+",
                example: """
                keys := slices.Collect(maps.Keys(m))
                """,
                body: """
                Keys returns an iterator over keys in m. Combine with `slices.Collect` or `slices.Sorted` to obtain a slice of keys.
                """,
                searchAliases: ["maps", "Keys", "Collect", "マップ"]
            )
        ]

        // L-7: Only include release notes whose version is <= the pack's target Go version.
        if targetVer.map({ $0.isAtLeast(GoVersion(major: 1, minor: 22)) }) ?? true {
            items.append(DocsChunk(
                goVersion: goVersion,
                source: .release,
                packageName: "",
                documentID: "go1.22_release_notes",
                symbol: "Go 1.22 release notes",
                kind: .releaseNote,
                title: "Go 1.22: range over integers and per-iteration loop variables",
                anchor: "#go1.22",
                since: "1.22",
                summary: "Go 1.22 で `for i := range n`（整数 range）とループ変数のイテレーション毎スコープが導入された。",
                signature: "for i := range 10 { ... }",
                example: """
                for i := range 10 {
                \tfmt.Println(i)
                }
                """,
                body: """
                Go 1.22 introduced two major `for` loop improvements:
                1. Variables declared by a `for` loop are created once per iteration, eliminating accidental closure capture bugs.
                2. `for` loops may range over integers (`for i := range 10`).
                """,
                searchAliases: ["release", "go1.22", "range", "ループ変数"]
            ))
        }

        // R-9: mark every bundled curated chunk with `.bundledCurated` provenance so citations
        // clearly distinguish curated summaries from directly extracted official GoDoc.
        items = items.map { c in
            DocsChunk(
                goVersion: c.goVersion,
                source: c.source,
                provenance: .bundledCurated,
                packageName: c.packageName,
                documentID: c.documentID,
                symbol: c.symbol,
                kind: c.kind,
                title: c.title,
                anchor: c.anchor,
                since: c.since,
                summary: c.summary,
                signature: c.signature,
                example: c.example,
                body: c.body,
                searchAliases: c.searchAliases
            )
        }
        items.sort { $0.stableID < $1.stableID }
        return items
    }

    /// Data-driven temporary Phase 1 Japanese/English cross-lingual concept expansion rules (R-1).
    /// Separated from router code so new concepts or pack-supplied rules can be added as data
    /// until Phase 2 cross-lingual embeddings replace/augment lexical expansion.
    public static let defaultConceptRules: [DocsConceptRule] = [
        DocsConceptRule(triggers: ["1行ずつ", "一行ずつ", "行ごと", "行単位", "line by line", "read line"], expansions: ["bufio", "Scanner", "Scan", "ScanLines"]),
        DocsConceptRule(triggers: ["ファイル", "read file", "write file"], excludeIfPresent: ["1行ずつ", "一行ずつ", "行ごと", "行単位", "line by line"], expansions: ["os", "ReadFile", "WriteFile", "bufio", "Scanner"]),
        DocsConceptRule(triggers: ["json", "整形", "インデント", "きれいに", "pretty print", "indent"], expansions: ["json", "MarshalIndent", "Encoder", "SetIndent", "Unmarshal"]),
        DocsConceptRule(triggers: ["重複", "取り除", "ユニーク", "deduplicate", "dedup", "unique"], expansions: ["slices", "Compact", "Sort", "deduplicate", "map"]),
        DocsConceptRule(triggers: ["タイムアウト", "timeout", "deadline", "期限", "キャンセル"], expansions: ["context", "WithTimeout", "deadline", "cancel"]),
        DocsConceptRule(triggers: ["正規表現", "regex", "regexp", "パターンマッチ"], expansions: ["regexp", "Compile", "MustCompile", "MatchString"]),
        DocsConceptRule(triggers: ["for", "ループ", "繰り返し", "while", "反復", "loop", "iterate"], expansions: ["for", "range", "For_statements"]),
        DocsConceptRule(triggers: ["switch", "条件分岐", "型スイッチ"], expansions: ["switch", "Switch_statements"]),
        DocsConceptRule(triggers: ["defer", "後処理", "リソース解放", "finally"], expansions: ["defer", "Close"]),
        DocsConceptRule(triggers: ["ソート", "並べ替え", "sort"], expansions: ["slices", "Sort", "SortFunc"]),
        DocsConceptRule(triggers: ["文字列", "連結", "結合", "concat", "string builder"], expansions: ["strings", "Builder", "WriteString"]),
        DocsConceptRule(triggers: ["数値", "変換", "atoi", "itoa", "parse int"], expansions: ["strconv", "Atoi", "Itoa"]),
        DocsConceptRule(triggers: ["日時", "日付", "時間", "フォーマット", "date format", "timestamp"], expansions: ["time", "Format", "Parse", "RFC3339"]),
        DocsConceptRule(triggers: ["goroutine", "並行", "完了待ち", "waitgroup"], expansions: ["sync", "WaitGroup", "Done", "Wait"]),
        DocsConceptRule(triggers: ["http", "リクエスト", "api", "クライアント"], expansions: ["net/http", "Client", "NewRequestWithContext"]),
        DocsConceptRule(triggers: ["ディレクトリ", "再帰", "ファイル一覧", "walk"], expansions: ["path/filepath", "WalkDir"]),
        DocsConceptRule(triggers: ["マップ", "キー一覧", "map keys"], expansions: ["maps", "Keys", "Collect"]),
        DocsConceptRule(triggers: ["エラー", "ラップ", "wrap error", "errors.is", "errors.as"], expansions: ["error", "Errorf", "errors.Is", "errors.As"]),
        DocsConceptRule(triggers: ["整数 range", "range over int", "イテレータ", "iter.seq"], expansions: ["range", "iter.Seq", "For_range", "1.22", "1.23"])
    ]
}
