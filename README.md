<p align="center">
  <img src="docs/assets/icon.png" width="120" height="120" alt="og icon">
</p>

<h1 align="center">og</h1>

<p align="center">
  Go を書くためだけに作られた、120fps ネイティブ macOS エディタ。<br>
  Electron 不使用。起動した瞬間からキー入力・構文解析・内蔵ターミナルまで遅延ゼロ。
</p>

<p align="center">
  <a href="https://github.com/fuwasegu/og/releases/latest">ダウンロード</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14+-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Go-gopls-00ADD8" alt="Go / gopls">
</p>

## インストール

```sh
brew install --cask fuwasegu/tap/og
```

アップデート時:

```sh
brew upgrade --cask fuwasegu/tap/og
```

要件は **macOS 14 (Sonoma) 以降**。または [Releases](https://github.com/fuwasegu/og/releases/latest) から `og.app.zip` を直接ダウンロードできます。

## 特徴

- **WebView ゼロ・120fps の入力体験** — Electron や WKWebView を一切使わず、エディタも内蔵ターミナルも AppKit (`NSView`) + `CoreText` で直接描画。画面に見えている行だけをスライス描画し、構文ハイライトも編集が起きた瞬間だけ差分更新するため、スクロールや高速タイピング中も ProMotion 120Hz に張り付いたまま動きます。
- **GoLand ゆずりの Postfix 補完 (`Tab`)** — 式の後ろに `.err` / `.var` / `.forr` / `.for` / `.nn` / `.nil` / `.return` / `.print` / `.len` を打って `Tab` を押すだけで、Go 特有の定型コードへ即座に展開（例: `err.err` → `if err != nil { return err }`、`NewServer().var` → `server := NewServer()`）。入力中はカーソル横に展開プレビューバッジが表示されます。
- **ワンクリック Struct タグ自動生成 (`⌘⇧T` / `🏷 +json tags`)** — `struct` の宣言行に表示される `🏷 +json tags` バッジをクリックするかツールバー / `⌘⇧T` を押すだけで、フィールド名を自動で `snake_case` や `camelCase` に変換し、`json` / `yaml` / `db` タグを一括付与・更新します。
- **Table-Driven Test 自動生成 (`⌘⇧G` / `🧪 +Table Test`)** — 関数やメソッド横の `🧪 +Table Test` バッジ（または `⌘⇧G`）から、Go 標準イディオムである `tests := []struct{ ... }` + `t.Run` 形式のテーブル駆動テストを自動生成してジャンプします。
- **暗黙インターフェースの双方向ジャンプ (`⇄ implements` / `⇣ implemented by`)** — AST 解析により、`struct` には満たしているインターフェース（`⇄ implements Handler`）、`interface` には実装している構造体（`⇣ implemented by Server`）をインライン表示。バッジのクリックや `⌘B` / `⌘クリック`、上部の **Structure** メニューから宣言元へ一瞬でジャンプできます。
- **設定不要でつながる `gopls` と自動復旧** — ファイルを開くとバックグラウンドで `gopls` を自動起動し、リアルタイムの型チェック・エラー箇所の波線表示・LSP 応答レイテンシ計測を行います。万が一 `gopls` プロセスがクラッシュしても、指数バックオフで自動再起動し開いているドキュメントの状態をそのまま復元します。
- **保存と同時に `gofmt` 自動整形** — `⌘S` で保存すると自動的に `gofmt` を走らせ、カーソル位置を維持したままフォーマットを適用します。括弧・クォートの自動ペア補完（`{}` / `()` / `[]` / `""`）や `⌘/` による行コメント切り替えなど、Go の読み書きに必要な操作が最初から揃っています。
- **Diff プレビュー付きの安全なシンボルリネーム (`⌘⇧R`)** — パッケージをまたぐ関数名・型名・変数名のリネームを、適用前に **Unified Diff で一覧プレビュー**。確定すると一時ファイル経由のアトミック置換を行い、途中で1ファイルでも失敗した場合は全ファイルを元の状態へ自動ロールバックします。
- **エディタ内から即実行 (`▶ Run Test` / `▶ Bench` / `▶ Run main`)** — テスト関数・ベンチマーク・`func main()` の横に実行バッジを表示し、クリック1つで個別テスト実行や `go run .` を走らせます。
- **`⌘J` で即座に開くネイティブ PTY ターミナル** — エディタ下部に Darwin `openpty` 直結のネイティブターミナルを内蔵。24-bit TrueColor・ANSI カラー・高速スクロールに対応し、別ウィンドウに切り替えずその場で `go run` や `git`、CLI エージェントを動かせます。
- **クラウド不要のローカル AI インライン補完** — ローカルの `llama-server`（Fill-in-the-Middle）と連携し、コードを外部へ一切送信せずにカーソル位置の先読み補完（Ghost Text）をストリーミング表示します。

## ショートカット・操作

| キー / 操作 | 動作 |
|---|---|
| `Tab` | Postfix 補完の展開（`.err`, `.var`, `.forr`, `.nn`, `.return` 等） / AI 補完（Ghost Text）の確定 |
| `⌘B` / `⌘クリック` | カーソル下の型・関数・メソッドの宣言へジャンプ |
| `⌘⇧T` | カーソル位置の `struct` に `json` タグ（`snake_case`）を自動生成 |
| `⌘⇧G` | カーソル位置の関数に対する Table-Driven Test を自動生成 |
| `⌘⇧R` | シンボルリネーム（Unified Diff プレビュー & 自動ロールバック付き） |
| `⌘D` | 現在の行または選択範囲を複製（GoLand スタイル） |
| `⌥⇧↑` / `⌥⇧↓` | 現在の行を上下へ移動 |
| `⌘/` | 選択行のコメント (`//`) トグル |
| `⌘O` | `.go` ファイルを開く |
| `⌘S` | 保存 + `gofmt` 自動フォーマット |
| `⌘J` | 内蔵ネイティブターミナルの表示 / 非表示トグル |
| `⌘C` / `⌘X` / `⌘V` | コピー / カット / ペースト（未選択時は行単位） |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
| ダブル / トリプルクリック | 単語選択（識別子単位） / 行全体を選択 |

## 要件

- **macOS 14 (Sonoma)** 以降
- **[Go](https://go.dev/)** および **[`gopls`](https://pkg.go.dev/golang.org/x/tools/gopls)**（コード診断・リネーム・`gofmt`・`go test` 連携に使用）
  ```sh
  brew install go gopls
  ```
- **（任意）ローカル AI 補完を使う場合**: `127.0.0.1:8080` で FIM 対応モデルを載せた `llama-server` を起動しておくと、自動的にインライン補完が有効になります（起動していなくてもエディタはそのまま動作します）。

## 開発

Swift 6.0 (Swift Package Manager) で構成されたネイティブ macOS アプリです。

```sh
# ビルドして起動
make run

# .app バンドルをビルド (build/og.app)
make app
```

<details>
<summary>品質検証ハーネス & リリース手順</summary>

ローカル開発および CI では、4段階の検証ハーネス（静的ガードレール / StrictConcurrency ビルド / 300ステップ決定論的ファジング + レイテンシ SLA ベンチマーク / Release ビルド）を実行できます。

```sh
# Git フック（pre-commit / pre-push）の有効化
make install-hooks

# 全4ゲートのフル検証
make check
```

`VERSION` を更新して `v*` タグを push すると、GitHub Actions (`.github/workflows/release.yml`) がハーネス検証 → `og.app` のビルド・署名 → GitHub Release 公開 → `fuwasegu/homebrew-tap` の Cask 更新まで自動実行します。

```sh
git tag v0.2.0 && git push origin main --tags
```

</details>
