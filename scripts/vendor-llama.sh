#!/usr/bin/env bash
# Fetch a pinned llama.cpp macOS arm64 release, verify it, and stage llama-server
# plus its dylib closure in Vendor/llama.cpp.
#
# Usage: scripts/vendor-llama.sh [TAG]
#   TAG defaults to the value in scripts/llama.version
#   scripts/llama.sha256 must contain "<sha256>  <asset-name>" for that tag (update it when bumping).
#
# As of the b11xxx releases, llama-server and every ggml-org dylib already
# carry an @loader_path LC_RPATH and an @rpath/<name> install name/ID, so no
# install_name_tool rewriting is needed as long as the whole dependency
# closure sits next to the binary. This script computes that closure by
# walking `otool -L` recursively from llama-server, rather than hardcoding a
# library list, so it keeps working if llama.cpp adds or renames a dylib. If
# a future release ships non-@rpath-relative or absolute-path dependencies,
# the script fails loudly in the verification step below instead of
# silently producing a broken bundle — fix the rewrite step at that point.
#
# Release signing (Developer ID, hardened runtime, notarization timestamps)
# happens at Xcode build time via the "Embed llama.cpp" run script phase
# (scripts/embed-llama.sh), which re-signs everything with the project's
# resolved signing identity. The ad-hoc signature applied here just lets the
# binary run locally right after vendoring (e.g. to smoke-test it by hand).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(cat "$ROOT/scripts/llama.version")}"
ASSET="llama-${TAG}-bin-macos-arm64.tar.gz"   # verify this pattern against the release page when bumping
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}"
OUT="$ROOT/Vendor/llama.cpp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching $URL"
curl -fsSL -o "$TMP/$ASSET" "$URL"

echo "==> verifying sha256"
( cd "$TMP" && grep " $ASSET\$" "$ROOT/scripts/llama.sha256" | shasum -a 256 -c - )

echo "==> unpacking"
mkdir -p "$TMP/unz"
tar xzf "$TMP/$ASSET" -C "$TMP/unz"
SRC_DIR="$(find "$TMP/unz" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/llama-server" ] || { echo "error: llama-server not found in extracted asset"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"

# --- Copy llama-server and the full @rpath dependency closure -------------
declare -A COPIED=()

copy_with_deps() {
  local name="$1"
  [ -n "${COPIED[$name]:-}" ] && return 0
  [ -e "$OUT/$name" ] && { COPIED[$name]=1; return 0; }

  local src="$SRC_DIR/$name"
  [ -e "$src" ] || { echo "error: $name is a dependency but was not found in the release asset"; exit 1; }
  cp -a "$src" "$OUT/$name"
  COPIED[$name]=1

  # If we copied a symlink, also stage its target (by name) so it resolves.
  if [ -L "$OUT/$name" ]; then
    local target
    target="$(readlink "$OUT/$name")"
    copy_with_deps "$(basename "$target")"
  fi

  # Recurse into this file's own @rpath dependencies (resolve symlinks; they
  # only ever point at a sibling file in this same flat release layout).
  local real="$name"
  while [ -L "$SRC_DIR/$real" ]; do
    real="$(readlink "$SRC_DIR/$real")"
  done
  real="$SRC_DIR/$real"
  local dep depname
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    depname="${dep#@rpath/}"
    copy_with_deps "$depname"
  done < <(otool -L "$real" | awk 'NR>1 {print $1}' | grep '^@rpath/' || true)
}

cp -a "$SRC_DIR/llama-server" "$OUT/llama-server"
while IFS= read -r dep; do
  [ -z "$dep" ] && continue
  copy_with_deps "${dep#@rpath/}"
done < <(otool -L "$SRC_DIR/llama-server" | awk 'NR>1 {print $1}' | grep '^@rpath/' || true)

[ -f "$SRC_DIR/LICENSE" ] && cp "$SRC_DIR/LICENSE" "$OUT/LICENSE-llama.cpp"

echo "==> verifying every dependency is @rpath-relative or a system path"
"$ROOT/scripts/verify-macho.sh" "$OUT"

echo "==> ad-hoc signing for local builds (Xcode re-signs at build time)"
for f in "$OUT"/*.dylib "$OUT/llama-server"; do
  [ -L "$f" ] && continue
  codesign --force --sign - "$f"
done

echo "==> result"
otool -L "$OUT/llama-server" | sed 's/^/   /'
echo "staged $(find "$OUT" -type f | wc -l | tr -d ' ') files in $OUT (tag $TAG)"
