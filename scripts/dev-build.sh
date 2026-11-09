#!/usr/bin/env bash
# Local fallback build that drives swiftc directly (no SwiftPM).
#
# Use this when `swift build` is unavailable (e.g. a broken CommandLineTools
# install where swift-package fails to load). CI keeps using SwiftPM.
#
#   scripts/dev-build.sh            # debug build of the app -> .build/dev/og
#   scripts/dev-build.sh test       # build and run OgCore tests
#   scripts/dev-build.sh release    # optimized build
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
OUT=".build/dev"
DEPS=".build/deps"
TARGET="arm64-apple-macosx14.0"
mkdir -p "$OUT" "$DEPS"

# Pick an SDK whose Swift interface matches the compiler.
if [[ -z "${SDKROOT:-}" ]]; then
  compiler=$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk "$(xcrun --show-sdk-path 2>/dev/null)" 2>/dev/null | sort -rV); do
    iface="$sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
    [[ -f "$iface" ]] || continue
    v=$(sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' "$iface" | head -1)
    if [[ "${v%.*}" == "${compiler%.*}" ]]; then export SDKROOT="$sdk"; break; fi
  done
fi
echo "SDK: ${SDKROOT:-default}"

OPT=(-Onone -g -enable-testing)
[[ "$MODE" == "release" ]] && OPT=(-O)
COMMON=(-target "$TARGET" "${OPT[@]}" -j8)

# SwiftTerm (pinned like Package.swift).
if [[ ! -d "$DEPS/SwiftTerm" ]]; then
  git clone -q --depth 1 --branch v1.20.0 https://github.com/migueldeicaza/SwiftTerm.git "$DEPS/SwiftTerm"
fi
if [[ ! -f "$OUT/libSwiftTerm.a" || "$MODE" == "release" ]]; then
  cat > "$OUT/SwiftTermBuildInfo.swift" <<'EOF'
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = nil
    public static let version: String = "v1.20.0"
}
EOF
  find "$DEPS/SwiftTerm/Sources/SwiftTerm" -name '*.swift' -not -path '*/iOS/*' > "$OUT/swiftterm.files"
  echo "$OUT/SwiftTermBuildInfo.swift" >> "$OUT/swiftterm.files"
  echo "▶ SwiftTerm"
  swiftc "${COMMON[@]}" -swift-version 5 -parse-as-library -module-name SwiftTerm \
    -emit-module -emit-module-path "$OUT/SwiftTerm.swiftmodule" \
    -emit-library -static -o "$OUT/libSwiftTerm.a" @"$OUT/swiftterm.files" 2>&1 | grep -E "error" || true
fi

echo "▶ OgCore"
find Sources/OgCore -name '*.swift' > "$OUT/ogcore.files"
swiftc "${COMMON[@]}" -swift-version 6 -parse-as-library -module-name OgCore \
  -emit-module -emit-module-path "$OUT/OgCore.swiftmodule" \
  -emit-library -static -o "$OUT/libOgCore.a" @"$OUT/ogcore.files"

if [[ "$MODE" == "test" ]]; then
  echo "▶ OgCoreTests"
  CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
  find Tests/OgCoreTests -name '*.swift' > "$OUT/tests.files"
  cat > "$OUT/TestMain.swift" <<'EOF'
import Testing
@main struct Runner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
EOF
  swiftc "${COMMON[@]}" -swift-version 6 -module-name OgCoreTests -I "$OUT" -L "$OUT" -lOgCore \
    -F "$CLT_FW" -Xlinker -rpath -Xlinker "$CLT_FW" \
    -plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/usr/lib \
    -o "$OUT/og-tests" @"$OUT/tests.files" "$OUT/TestMain.swift"
  "$OUT/og-tests"
  exit $?
fi

echo "▶ og app"
find Sources/OgApp -name '*.swift' > "$OUT/ogapp.files"
swiftc "${COMMON[@]}" -swift-version 6 -module-name OgApp -I "$OUT" -L "$OUT" -lOgCore -lSwiftTerm \
  -o "$OUT/og" @"$OUT/ogapp.files"
echo "✅ $OUT/og"
