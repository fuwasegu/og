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
│   │   ├── SyntaxHighlighter.swift      # swift-tree-sitter (tree-sitter-go) 0ms ハイライト & AST解析
│   │   ├── GoplsClient.swift            # gopls 専用 JSON-RPC 2.0 クライアント & オートヒーリング監視
│   │   ├── GoToolingEngine.swift        # アトミック・シンボルリネーム (Diffプレビュー/ロールバック) & go test
│   │   ├── InlineCompletion.swift       # ローカルLLM (llama-server FIM) ストリーミング補完
│   │   └── EditorView.swift             # AppKit NSView + CoreText 等幅ダイレクト描画キャンバス
│   └── GoEditorApp/                     # macOS 実行可能ターゲット (@main)
│       └── GoEditorApp.swift            # SwiftUI ウィンドウシェル・ツールバー・リネームプレビューシート
└── Tests/
    └── GoEditorCoreTests/               # Swift Testing 単体テストターゲット
        ├── TextBufferTests.swift        # Rope編集・UTF-8/UTF-16変換・AST解析・FIMプロンプト・リネーム検証
        └── TestHelpers.swift            # テスト用ワークスペース・一時ファイルヘルパー
```

## ビルド・テスト・実行方法

```bash
swift build
swift test --parallel
swift run og
```
