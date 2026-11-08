<p align="center">
  <img src="docs/assets/icon.png" width="120" height="120" alt="og icon">
</p>

<h1 align="center">og</h1>

<p align="center">
  A 120fps native macOS code editor built exclusively for Go.<br>
  Zero Electron, zero WebViews — instant startup, sub-millisecond typing, and a built-in native PTY terminal.
</p>

<p align="center">
  <a href="https://github.com/fuwasegu/og/releases/latest">Download</a> ·
  <a href="README.md">日本語</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14+-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Go-gopls-00ADD8" alt="Go / gopls">
</p>

## Install

```sh
brew install --cask fuwasegu/tap/og
```

To upgrade:

```sh
brew upgrade --cask fuwasegu/tap/og
```

Requires **macOS 14 (Sonoma)+**. Or grab `og.app.zip` directly from [Releases](https://github.com/fuwasegu/og/releases/latest).

## Features

- **Zero WebViews, True 120fps Rendering** — Both the code editor and the integrated terminal render directly via AppKit (`NSView`) and `CoreText` on GPU-backed layers. Only visible rows intersecting the viewport are drawn, and syntax highlighting is cached per buffer version so scrolling and rapid typing stay locked at 120Hz.
- **Zero-Config `gopls` with Auto-Healing** — Automatically spawns and supervises `gopls` over JSON-RPC 2.0 for live diagnostics, inline error underlines, and latency telemetry. If `gopls` ever crashes, `og` restarts it with exponential backoff and seamlessly restores your open buffer state.
- **Automatic `gofmt` on Save** — Pressing `⌘S` formats your Go file via `gofmt` while preserving your cursor position, alongside smart bracket/quote auto-pairing (`{}` / `()` / `[]` / `""`) and `⌘/` line comment toggling.
- **Transactional Symbol Rename with Diff Preview (`⌘⇧R`)** — Preview cross-file symbol renames as a Unified Diff before touching disk. Changes are committed atomically via temporary files and automatically roll back across all files if any write fails.
- **One-Click `go test` Runner** — Run `go test -v -json ./...` right from the toolbar and see pass/fail counts and execution time in the status bar.
- **Built-in Native PTY Terminal (`⌘J`)** — Toggle a dockable terminal backed directly by Darwin `openpty` and `DispatchSourceRead` with 24-bit TrueColor and ANSI support — run `go run`, `git`, or CLI agents without leaving the editor.
- **100% Local AI Inline Completion (FIM)** — Connects to a local `llama-server` (`127.0.0.1:8080`) for Fill-in-the-Middle streaming ghost text. Press `Tab` to accept, or keep typing to dismiss — zero cloud calls.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘O` | Open `.go` file |
| `⌘S` | Save + auto-format with `gofmt` |
| `⌘J` | Toggle built-in native PTY terminal |
| `⌘/` | Toggle line comment (`//`) |
| `⌘⇧R` | Transactional symbol rename (with Unified Diff preview) |
| `Tab` | Accept inline AI completion (Ghost Text) |
| `⌘C` / `⌘X` / `⌘V` | Copy / Cut / Paste |
| `⌘A` | Select All |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
| Double-click | Select word / identifier |
| Triple-click | Select full line |

## Requirements

- **macOS 14 (Sonoma)** or later
- **[Go](https://go.dev/)** and **[`gopls`](https://pkg.go.dev/golang.org/x/tools/gopls)**
  ```sh
  brew install go gopls
  ```
- *(Optional)* Local `llama-server` running on `http://127.0.0.1:8080` for local FIM inline completions.

## Development

```sh
# Build and launch from source
make run

# Package build/og.app bundle (with AppIcon.icns)
make app
```

<details>
<summary>Verification Harness & Releasing</summary>

```sh
# Install pre-commit / pre-push guardrails
make install-hooks

# Run all 4 verification gates (Static Guardrails, StrictConcurrency Debug, 300-step Fuzz + Latency SLAs, Release)
make check
```

Pushing a `v*` tag triggers GitHub Actions (`.github/workflows/release.yml`) to run the harness, package and sign `og.app`, publish a GitHub Release, and update `fuwasegu/homebrew-tap` automatically.

</details>
