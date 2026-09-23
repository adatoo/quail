#!/usr/bin/env bash
# Packages a signed, notarized Quail.app (scripts/sign-and-notarize.sh's
# output) into a distributable .dmg, then signs the DMG itself — the last
# step of docs/ARCHITECTURE.md §9's pipeline diagram ("create-dmg, sign
# DMG"). The .app inside already carries its own notarization staple
# (checked by Gatekeeper when it's actually launched), so this doesn't
# re-notarize the DMG container itself — only the contents need the
# ticket.
#
# Requires `create-dmg` (https://github.com/create-dmg/create-dmg):
#   brew install create-dmg
#
# Usage: scripts/make-dmg.sh [path-to-Quail.app]
#   Defaults to build/export/Quail.app (sign-and-notarize.sh's output).
# Output: build/Quail-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_PATH="${1:-$BUILD_DIR/export/Quail.app}"
IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application: Arif Datoo (QKAYS6D525)}"

[ -d "$APP_PATH" ] || {
  echo "error: $APP_PATH not found — run scripts/sign-and-notarize.sh first" >&2
  exit 1
}

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not found. Install it with:" >&2
  echo "       brew install create-dmg" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$BUILD_DIR/Quail-$VERSION.dmg"
rm -f "$DMG_PATH"

echo "==> Building $DMG_PATH..."
create-dmg \
  --volname "Quail $VERSION" \
  --app-drop-link 450 150 \
  --icon "Quail.app" 150 150 \
  --window-size 600 300 \
  "$DMG_PATH" \
  "$APP_PATH" \
  || true # create-dmg exits non-zero on the harmless "no volume icon set" case

[ -f "$DMG_PATH" ] || { echo "error: create-dmg finished but $DMG_PATH is missing"; exit 1; }

echo "==> Signing the DMG ($IDENTITY)..."
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo ""
codesign --verify --verbose=2 "$DMG_PATH"
echo "Done: $DMG_PATH"
