<p align="center">
  <img src="docs/assets/icon.png" width="120" height="120" alt="og icon">
</p>

<h1 align="center">og</h1>

<p align="center">
  A native macOS IDE for Go — GoLand-style workflows, built with AppKit only.
</p>

## Install

```sh
brew install --cask fuwasegu/tap/og
brew install go gopls delve
```

Requires macOS 14 or later.

## Features

- Projects: open a folder (`go.mod` / `go.work`), file tree, tabs, session restore
- Editing: Go syntax highlighting, smart indent, bracket pairing, duplicate / move / comment lines, extend selection, IME
- Saving: GoLand-style autosave (focus loss, tab switch, idle); `⌘S` organizes imports and runs gofmt
- External changes: clean buffers reload silently; a buffer with unsaved edits shows a conflict bar
- gopls: completion, diagnostics, hover, signature help, go to definition / implementation / type, find usages, quick fixes, file structure, automatic restart
- Refactoring: rename with a diff preview, all-or-nothing apply with rollback, one-step undo
- Run & test: gutter ▶ for `go run`, tests and benchmarks, with a test tree
- Debugger: delve breakpoints, stepping, variables, evaluate
- Git: tree and gutter status, commit, branch checkout / create, stash
- Search: go to file / symbol, recent files, find and replace in files
- Terminal: tabbed xterm-compatible terminal
- Go helpers: postfix completion (`.err`, `.var`, `.for`, `.nn`, …), struct tags, table-driven test generation
- Local AI completion: og starts, supervises and stops llama.cpp (`llama-server`) or MLX (`mlx_lm.server`) itself; pick the model in Settings. Bound to 127.0.0.1 only; off by default

The first debug session triggers macOS's "Developer Tools Access" prompt; `sudo DevToolsSecurity -enable` removes it.

## Development

Specs live in `spec/` (FSL, verified with `fslc`). See `spec/README.md` and `AGENTS.md`.

```sh
make check
make spec
make app
```
