#!/usr/bin/env bash
# Fetch a pinned uv macOS arm64 release, verify it, and stage `uv` in Vendor/uv.
#
# Usage: scripts/vendor-uv.sh [VERSION]
#   VERSION defaults to the value in scripts/uv.version (no leading "v")
#
# uv publishes a <asset>.sha256 file alongside each release asset, so unlike
# vendor-llama.sh there's no separate scripts/uv.sha256 to maintain — this
# script fetches and checks against that file directly.
#
# `uv` is not embedded in the app bundle in Phase 1/2 — it's only needed for
# the optional Rapid-MLX/oMLX install flow (Phase 3, see
# docs/IMPLEMENTATION_PLAN.md). This script exists now so the Vendor/ layout
# and pinning approach are established early, per docs/ARCHITECTURE.md §5.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$ROOT/scripts/uv.version")}"
ASSET="uv-aarch64-apple-darwin.tar.gz"
BASE_URL="https://github.com/astral-sh/uv/releases/download/${VERSION}"
OUT="$ROOT/Vendor/uv"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching ${BASE_URL}/${ASSET}"
curl -fsSL -o "$TMP/$ASSET" "${BASE_URL}/${ASSET}"

echo "==> fetching and verifying sha256"
curl -fsSL -o "$TMP/$ASSET.sha256" "${BASE_URL}/${ASSET}.sha256"
( cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" )

echo "==> unpacking"
tar xzf "$TMP/$ASSET" -C "$TMP"
SRC_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'uv-*' -print -quit)"
[ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/uv" ] || { echo "error: uv binary not found in extracted asset"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$SRC_DIR/uv" "$OUT/uv"

echo "==> verifying dependencies are system-only"
"$ROOT/scripts/verify-macho.sh" "$OUT"

echo "==> ad-hoc signing for local builds"
codesign --force --sign - "$OUT/uv"

echo "==> result"
otool -L "$OUT/uv" | sed 's/^/   /'
echo "staged uv $VERSION in $OUT"
