#!/usr/bin/env bash
# Fetch a pinned llama.cpp macOS arm64 release, verify it, and stage llama-server + dylibs in Vendor/llama.cpp.
#
# Usage: scripts/vendor-llama.sh [TAG]
#   TAG defaults to the value in scripts/llama.version
#   scripts/llama.sha256 must contain "<sha256>  <asset-name>" for that tag (update it when bumping).
#
# After staging, every Mach-O is rewritten so dylibs resolve via @executable_path and ad-hoc signed for local builds.
# Release signing (Developer ID, hardened runtime) happens in scripts/sign-and-notarize.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(cat "$ROOT/scripts/llama.version")}"
ASSET="llama-${TAG}-bin-macos-arm64.zip"     # verify this pattern against the release page when bumping
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}"
OUT="$ROOT/Vendor/llama.cpp"
TMP="$(mktemp -d)"

echo "==> fetching $URL"
curl -fsSL -o "$TMP/$ASSET" "$URL"

echo "==> verifying sha256"
( cd "$TMP" && grep " $ASSET\$" "$ROOT/scripts/llama.sha256" | shasum -a 256 -c - )

echo "==> unpacking"
unzip -q "$TMP/$ASSET" -d "$TMP/unz"
BIN_DIR="$(find "$TMP/unz" -type d -name bin | head -n1)"
[ -n "$BIN_DIR" ] || { echo "no bin/ directory in asset"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$BIN_DIR/llama-server" "$OUT/"
cp "$BIN_DIR"/*.dylib "$OUT/"

echo "==> rewriting install names"
cd "$OUT"
for lib in *.dylib; do
  install_name_tool -id "@executable_path/$lib" "$lib"
done
for f in llama-server *.dylib; do
  for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '(@rpath/|^/opt/homebrew|^/usr/local|^\./|libggml|libllama|libmtmd)' || true); do
    base="$(basename "$dep")"
    [ -f "$base" ] && install_name_tool -change "$dep" "@executable_path/$base" "$f"
  done
done

echo "==> ad-hoc signing for local builds"
for f in *.dylib llama-server; do codesign --force --sign - "$f"; done

echo "==> result"
otool -L llama-server | sed 's/^/   /'
echo "staged in $OUT (tag $TAG)"
rm -rf "$TMP"
