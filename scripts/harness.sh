#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/og-clang-module-cache}"

echo "========================================================"
echo "🛡️  og — AI & Local Verification Harness"
echo "========================================================"

# ---------------------------------------------------------
# Gate 1: Architectural & Static Guardrails
# ---------------------------------------------------------
echo "▶ [Gate 1/4] Checking architectural & static guardrails..."

if grep -rnE "import WebKit|WKWebView" Sources/; then
    echo "❌ GUARDRAIL VIOLATION: WebKit/WKWebView is strictly forbidden. Use AppKit + CoreText."
    exit 1
fi

if grep -rnE "\bas!\b|\btry!\b" Sources/; then
    echo "❌ GUARDRAIL VIOLATION: Force-cast (as!) or force-try (try!) found in Sources/."
    exit 1
fi

if ! grep -q 'StrictConcurrency' Package.swift; then
    echo "❌ GUARDRAIL VIOLATION: StrictConcurrency must remain enabled in Package.swift."
    exit 1
fi

echo "✅ Gate 1 passed: Zero forbidden patterns, StrictConcurrency verified."

# ---------------------------------------------------------
# Detect Swift Testing framework flags (Xcode vs CommandLineTools)
# ---------------------------------------------------------
TEST_FLAGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || echo "")"
CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ "$DEV_DIR" == *"CommandLineTools"* ]] && [[ -d "$CLT_FW" ]]; then
    TEST_FLAGS+=(
        -Xswiftc "-F$CLT_FW"
        -Xlinker "-F$CLT_FW"
        -Xlinker -rpath -Xlinker "$CLT_FW"
    )
fi

# ---------------------------------------------------------
# Gate 2: Swift 6 Strict Concurrency Debug Build
# ---------------------------------------------------------
echo "▶ [Gate 2/4] Building Debug targets (Swift 6 StrictConcurrency)..."
swift build --disable-sandbox "${TEST_FLAGS[@]}"
echo "✅ Gate 2 passed: Debug build clean."

# ---------------------------------------------------------
# Gate 3: Unit, Deterministic Fuzzing & Performance SLA Suite
# ---------------------------------------------------------
echo "▶ [Gate 3/4] Running Unit + Fuzz + Performance SLA tests..."
swift test --disable-sandbox "${TEST_FLAGS[@]}"
echo "✅ Gate 3 passed: All unit, fuzz, and performance SLA tests passed."

# ---------------------------------------------------------
# Gate 4: Release Binary Build Verification (optional --quick skip)
# ---------------------------------------------------------
if [[ "${1:-}" != "--quick" ]]; then
    echo "▶ [Gate 4/4] Verifying Release build (-c release)..."
    swift build --disable-sandbox -c release
    echo "✅ Gate 4 passed: Release executable built cleanly."
else
    echo "⏭️  [Gate 4/4] Skipped release build (--quick mode)."
fi

echo "========================================================"
echo "🎉 All og Harness Guardrails PASSED!"
echo "========================================================"
