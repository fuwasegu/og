# og — Native macOS Go Editor (Swift 6)

Apple Silicon (macOS 14.0+) に最適化した、入力遅延ゼロ（AppKit `NSView` + `CoreText` 120fps描画）を目指す Go 言語特化型ネイティブコードエディタです。

## ディレクトリ構成（Swift Package Manager 標準レイアウト）

```text
og/
├── .github/
│   └── workflows/
│       └── ci.yml                       # GitHub Actions (macOS 15 / Xcode 16 / Swift 6 / gopls)
├── .gitignore                           # SPM / Xcode / macOS 標準除外設定
├── Package.swift                        # Swift 6.0 マニフェスト (StrictConcurrency 有効)
├── README.md                            # アーキテクチャ & ビルド手順書
├── Sources/
│   ├── GoEditorCore/                    # コアライブラリターゲット (UI / テストから参照)
│   │   ├── TextBuffer.swift             # Rope ベース O(log N) テキストバッファ & Undo/Redo
│   │   ├── SyntaxHighlighter.swift      # swift-tree-sitter 0ms ハイライトキャッシュ & AST解析
│   │   ├── GoplsClient.swift            # gopls 専用 JSON-RPC 2.0 クライアント & オートヒーリング監視
│   │   ├── GoToolingEngine.swift        # アトミック・シンボルリネーム (Diffプレビュー/ロールバック) & go test
│   │   ├── InlineCompletion.swift       # ローカルLLM (llama-server FIM) ストリーミング補完
│   │   ├── NativeTerminal.swift         # Darwin openpty + CoreText 120fps ネイティブ PTY ターミナル
│   │   └── EditorView.swift             # AppKit NSView + CoreText ビューポート限定 120fps 描画キャンバス
│   └── GoEditorApp/                     # macOS 実行可能ターゲット (@main)
│       └── GoEditorApp.swift            # SwiftUI ウィンドウシェル・統合ターミナルドック・リネームシート
└── Tests/
    └── GoEditorCoreTests/               # Swift Testing 単体テストターゲット
        ├── TextBufferTests.swift        # Rope編集・UTF-8/UTF-16変換・AST解析・FIM・PTYターミナル検証
        └── TestHelpers.swift            # テスト用ワークスペース・一時ファイルヘルパー
```

## 主なショートカット

- `⌘J` : ネイティブ PTY ターミナルの表示 / 非表示トグル
- `⌘S` : ファイル保存 + `gofmt` 自動フォーマット
- `⌘O` : `.go` ファイルを開く
- `⌘/` : 行コメント (`//`) トグル
- `⌘⇧R` : トランザクショナル・シンボルリネーム（Unified Diff プレビュー付き）
- `Tab` : インライン AI 補完（Ghost Text）確定

## ビルド・テスト・実行方法

```bash
swift build -c release
swift test --parallel
swift run og
```
