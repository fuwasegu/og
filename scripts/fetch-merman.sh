#!/usr/bin/env bash
# Downloads the merman native SDK (prebuilt, pinned by SHA-256) that renders Mermaid diagrams in the
# Markdown preview. Puts the library and its license files in .build/deps/merman/.
# Usage: scripts/fetch-merman.sh   (no-op when the pinned version is already there)
set -euo pipefail

VERSION="0.9.3"
ASSET="merman-sdk-native-standard-aarch64-apple-darwin"
SHA256="22409f79468ac0a13c57999e44614a634b0423dd08f9383f3aab495cc5abef8f"
URL="https://github.com/Latias94/merman/releases/download/v${VERSION}/${ASSET}.tar.xz"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/.build/deps/merman"
STAMP="$DEST/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -f "$DEST/lib/libmerman_ffi.dylib" ]]; then
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "▶ merman $VERSION"
curl -fsSL --retry 3 -o "$WORK/sdk.tar.xz" "$URL"
echo "$SHA256  $WORK/sdk.tar.xz" | shasum -a 256 -c - >/dev/null
tar -xf "$WORK/sdk.tar.xz" -C "$WORK"

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/licenses"
cp "$WORK/$ASSET/lib/libmerman_ffi.dylib" "$DEST/lib/"
cp -R "$WORK/$ASSET/THIRD_PARTY_LICENSES" "$DEST/licenses/"
cp "$WORK/$ASSET/LICENSE-MIT" "$WORK/$ASSET/LICENSE-APACHE" "$WORK/$ASSET/THIRD_PARTY_NOTICES.md" \
   "$WORK/$ASSET/SOURCE_AVAILABILITY.md" "$DEST/licenses/"
echo "$VERSION" > "$STAMP"
