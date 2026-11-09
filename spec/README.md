# og specification

`og` の要件は FSL で書き、`fslc` で検証する。`.fsl` が仕様書そのもので、別の散文の仕様書は置かない。

## 決定事項

| ID | 決定 |
|---|---|
| D-1 | 範囲は GoLand 相当 |
| D-2 | 保存は GoLand 風の自動保存（フォーカス喪失・タブ切替・アイドル時）。`⌘S` も使える。閉じるときに確認しない |
| D-3 | 外部変更は、未編集のタブなら自動で読み直す。未保存の変更があれば衝突として選ばせる |
| D-4 | デバッガ（delve）と Git（commit・ブランチ）を含める |
| D-5 | ローカル AI 補完（llama-server）を残す |
| D-6 | 保存に失敗したら、タブは未保存のままエラーを出す。保存できるか変更を破棄するまで、そのタブとプロジェクトを閉じられない |
| D-7 | 自動保存は 1 ファイルずつ書き込む |
| D-8 | UI は AppKit 中心で組み、周辺の画面だけ SwiftUI を使う |

仮定（`ASSUME-n`）は各 `.fsl` の冒頭にあり、2026-11-09 にすべてオーナーが承認した（`confirmed`）。

## 要件 ID と検証先

FSL で表せるのは、操作の順序や組み合わせで壊れうる部分だけである。描画速度、構文ハイライト、補完の質などは、ハーネスのテストで確かめる。

| 領域 | ID | 検証先 |
|---|---|---|
| ワークスペース | WS-1, FT-2, ED-1, ED-2, ED-3, ED-6 | `req/workspace.fsl` |
| gopls | LSP-1, LSP-2, LSP-4, LSP-5, LSP-6 | `req/lsp.fsl` |
| リファクタ | RF-1 | `req/refactor.fsl` |
| 実行・デバッグ | RUN-1, RUN-2, RUN-3, RUN-4 | `req/run_debug.fsl` |
| Git | VCS-1, VCS-2, VCS-3 | `req/vcs.fsl` |
| 補完 | GO-1（Tab の優先順位）, GO-5 | `req/completion.fsl` |
| テストで確認 | WS-2, WS-3, FT-1, FT-3, ED-4, ED-5 | UI テスト |
| テストで確認 | NAV-1〜NAV-6, LSP-3 | gopls 結合テスト（読み取りのみ） |
| テストで確認 | TERM-1, GO-1〜GO-4 の変換内容 | ユニットテスト |
| テストで確認 | NFR-1, NFR-2, NFR-3 | `scripts/harness.sh` |

### 要件 ID の一覧

- WS-1 フォルダを開く（`go.mod` / `go.work` を認識）、WS-2 最近のプロジェクト、WS-3 前回のタブと配置を復元
- FT-1 ファイルツリーの表示、FT-2 作成・名前変更・削除・移動、FT-3 外部での変更を反映
- ED-1 複数タブ、ED-2 保存（自動保存）、ED-3 編集と Undo/Redo、ED-4 ファイル内の検索・置換、ED-5 分割表示、ED-6 外部変更との衝突
- NAV-1 ファイルへ移動、NAV-2 シンボルへ移動、NAV-3 全文検索、NAV-4 定義・使用箇所・実装へ移動、NAV-5 戻る・進む、NAV-6 ファイル構造
- LSP-1 診断と文書同期、LSP-2 補完、LSP-3 ホバー・シグネチャ、LSP-4 クイックフィックス、LSP-5 import 整理、LSP-6 gopls の起動と自動復旧
- RF-1 プレビュー付きリネームと全ファイルのロールバック
- RUN-1 実行構成、RUN-2 ガターからの実行、RUN-3 テスト結果、RUN-4 デバッガ
- TERM-1 複数タブのネイティブ PTY ターミナル
- VCS-1 ツリー上の状態表示、VCS-2 差分ガター、VCS-3 commit・ブランチ・stash
- GO-1 Postfix 補完、GO-2 Struct タグ生成、GO-3 Table Test 生成、GO-4 implements 表示、GO-5 ローカル AI 補完
- NFR-1 WebView なし、NFR-2 120 fps と表示行だけの描画、NFR-3 Swift 6 の厳格な並行性チェック

## 設計層

設計層は `spec/design/` にあり、`fslc refine` で要件層を満たすことを確かめる。

| 領域 | 設計 | マッピング | 状態 |
|---|---|---|---|
| ワークスペース | `design/workspace.fsl` | `design/workspace_refines_req.fsl` | refines |
| gopls | `design/lsp.fsl` | `design/lsp_refines_req.fsl` | refines |
| リファクタ | `design/refactor.fsl` | `design/refactor_refines_req.fsl` | refines |
| 実行・デバッグ | `design/run_debug.fsl` | `design/run_debug_refines_req.fsl` | refines |
| Git | `design/vcs.fsl` | `design/vcs_refines_req.fsl` | refines |
| 補完 | `design/completion.fsl` | `design/completion_refines_req.fsl` | refines |

```sh
fslc refine spec/design/workspace.fsl spec/req/workspace.fsl spec/design/workspace_refines_req.fsl
```

## 検証コマンド

すべての仕様をまとめて検証する。

```sh
make spec
```

個別に動かすときは次のとおり。

```sh
fslc check spec/req/workspace.fsl --strict-tags
```

```sh
fslc verify spec/req/workspace.fsl --depth 8 --vacuity error
```

```sh
fslc verify spec/req/workspace.fsl --engine induction
```
