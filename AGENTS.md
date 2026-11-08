# AGENTS.md — AI-Driven Development Guardrails & Harness (`og`)

This document defines the non-negotiable architectural invariants, performance SLAs, and verification harness rules for AI agents and developers working on **`og` (Native macOS Go Editor in Swift 6)**.

---

## 1. Mandatory Verification Harness

Before proposing a commit or finishing any task, you **MUST** run the project verification harness:

```bash
make check
# or for rapid inner-loop iteration:
./scripts/harness.sh --quick
```

All 4 gates in `scripts/harness.sh` must pass with **0 warnings and 0 errors**:
1. **Gate 1 (Static Guardrails)**: No `WebKit`/`WKWebView`, no `as!` or `try!` in `Sources/`, `StrictConcurrency` enabled.
2. **Gate 2 (Strict Build)**: Swift 6.0 `StrictConcurrency` debug build.
3. **Gate 3 (Unit + Fuzz + Performance SLA Suite)**: All tests in `Tests/GoEditorCoreTests/`, including deterministic 300-step multi-byte fuzzing and latency SLA benchmarks.
4. **Gate 4 (Release Build)**: Full `-c release` optimization build.

---

## 2. Core Architectural Invariants (Non-Negotiable)

1. **100% Native Rendering (`AppKit` + `CoreText`, Zero WebViews)**
   - Never import `WebKit` or embed HTML/JS views. Both `EditorView` and `NativeTerminalView` must render directly via `CoreText` (`CTLineDraw`) inside flipped, layer-backed `NSView` canvases.
2. **Viewport-Sliced Rendering ($O(\text{visible\_rows})$)**
   - `EditorView.draw(_ dirtyRect:)` and `NativeTerminalView.draw(_ dirtyRect:)` must only iterate over rows intersecting `dirtyRect`.
   - `SyntaxHighlighter` must preserve its $O(1)$ version-keyed cache (`cachedBufferVersion == buffer.version`) so scrolling and cursor navigation never re-tokenize or re-allocate the document's `NSAttributedString`.
3. **Coordinate System Contract (Character vs UTF-8 vs UTF-16)**
   - `TextBuffer` stores text in localized chunks with cached character, UTF-8, and UTF-16 counts.
   - `CoreText` / `NSRange` and LSP (`gopls`) positions use **UTF-16 code units**. Always convert via `buffer.utf16Offset(forCharacterOffset:)`, `buffer.lspUTF16Column(for:)`, and `buffer.position(forLSPPosition:)`. Never pass raw character offsets into `NSRange`.
4. **Swift 6 Strict Concurrency**
   - UI views (`EditorView`, `NativeTerminalView`, `NativePTYSession`, `WorkspaceViewModel`, `InlineCompletionCoordinator`) are `@MainActor` isolated.
   - Background I/O and state engines (`GoplsClient`, `TransactionalRenameManager`, `GoTestRunner`) are Swift `actor`s or `Sendable` value types.
5. **Testing Framework Isolation**
   - Tests in `Tests/GoEditorCoreTests/` use Swift 6's native `import Testing` (`@Suite`, `@Test`, `#expect`).
   - To remain compatible with both Xcode and standalone macOS CommandLineTools (avoiding the `_Testing_Foundation` cross-import overlay issue on CLT), do **not** put `import Foundation` and `import Testing` in the same test file. Place `Foundation` utilities in `Tests/GoEditorCoreTests/TestHelpers.swift`.
