# AGENTS.md — og development rules

`og` is a native macOS Go IDE (GoLand-like) written in Swift 6 with AppKit. This file is for humans and AI agents working on the code.

## 1. Specification first (FSL)

The requirements and design live in `spec/` as FSL and are verified by `fslc`. Read `spec/README.md` before changing behavior.

- A behavior change starts in `spec/req/*.fsl` (requirements) or `spec/design/*.fsl` (design), not in Swift.
- Never weaken a requirement to make a design pass. Ask the owner.
- `make spec` must stay green (check, bounded verify, induction, refine for every area).

## 2. Verification harness

Before committing, run:

```bash
make check        # SwiftPM: guardrails + debug build + tests + release build
make spec         # FSL specs (requires fslc)
```

If SwiftPM is broken on the machine (e.g. `swift build` fails with a dyld error from a half-updated CommandLineTools), use the swiftc-only fallback:

```bash
scripts/dev-build.sh            # debug app -> .build/dev/og
scripts/dev-build.sh release    # optimized build
```

The build must have 0 errors and 0 warnings.

### Headless UI checks

The app has a script driver for UI self-tests that never shows a window on screen (alpha 0, no activation):

```bash
OG_DEBUG_SCRIPT=/path/to/script.og .build/dev/og /path/to/project
```

Commands: `wait`, `open`, `type`, `key`, `action <selector>`, `caret`, `snap <png>`, `dump`, `log`, `quit` (see `Sources/OgApp/Shared/DebugDriver.swift`). Use `snap` instead of screen capture so you never record the user's screen.

## 3. Architecture

| Target | Contents | Rules |
|---|---|---|
| `OgCore` | LSP/DAP JSON-RPC, gopls session, git, search, run/test, Go features, rename transaction, lexer | Foundation only. `Sendable` values and `actor`s. Unit-testable. |
| `OgApp` | Windows, editor, panels | AppKit, `@MainActor`. SwiftUI only for peripheral screens. |

Key types: `ProjectContext` (one per window, the contract for panels), `DocumentStore` / `Document` (buffers, autosave, compare-before-replace writes), `EditorController` + `CodeTextView` (editor), `GoplsSession` (generations, backoff, replay).

## 4. Invariants (non-negotiable)

1. **Native only.** No `WebKit` / `WKWebView`, no Electron-style embedding. The editor is `NSTextView` on TextKit 1; the terminal is SwiftTerm (AppKit).
2. **UTF-16 everywhere.** `NSRange` and LSP positions are UTF-16. Convert through `TextLines` (`offset(for:)`, `position(forOffset:)`, `nsRange(for:)`). Never feed character counts into `NSRange`.
3. **No silent data loss** (`spec/req/workspace.fsl`). Autosave never overwrites a file that changed on disk unseen; a dirty buffer with an external change becomes a conflict; a failed save keeps the tab dirty and blocks closing.
4. **Version-safe LSP** (`spec/req/lsp.fsl`). Await `DocumentStore.flush(_:)` before a request. Apply server edits only if the document version is unchanged. Responses from an older gopls process are dropped.
5. **Local-only AI** (`spec/req/completion.fsl`). The completion endpoint must be a loopback address.
6. **Swift 6 strict concurrency.** No `as!`, no `try!` in `Sources/`.

## 5. Tests

- Tests in `Tests/OgCoreTests/` use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- Do not put `import Foundation` and `import Testing` in the same file; Foundation helpers go in `TestHelpers.swift`.
