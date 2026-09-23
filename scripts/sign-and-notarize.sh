#!/usr/bin/env bash
# Archives Quail with a real Developer ID identity (not the ad-hoc signing
# every plain `xcodebuild build` uses), exports a signed .app, submits it to
# Apple's notary service, and staples the ticket — the "D" step of
# docs/ARCHITECTURE.md §9's pipeline diagram, done non-interactively so it
# works the same locally and in CI (see scripts/install.sh for the local
# entry point, and .github/workflows/release.yml for CI).
#
# Requires (see docs/DECISIONS.md D-018):
#   - A "Developer ID Application" certificate + private key in whichever
#     keychain is unlocked/default (`security find-identity -v -p
#     codesigning` should list it). Locally that's the login keychain;
#     in CI, release.yml imports one into a dedicated build keychain first.
#   - An Apple ID app-specific password (or an App Store Connect API key —
#     not used here, notarytool's simpler --apple-id path is) for
#     notarization: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD.
#
# Usage: scripts/sign-and-notarize.sh
# Output: build/export/Quail.app — signed, notarized, and stapled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Quail.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Quail.app"

IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application: Arif Datoo (QKAYS6D525)}"
TEAM_ID="${APPLE_TEAM_ID:-QKAYS6D525}"

for var in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "error: \$$var is not set — see this script's own header for what's required." >&2
    exit 1
  fi
done

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no \"Developer ID Application\" certificate in the active keychain." >&2
  echo "       security find-identity -v -p codesigning   # to check" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> 1/4  Archiving (Release, $IDENTITY)..."
xcodebuild archive \
  -project "$ROOT/Quail.xcodeproj" \
  -scheme Quail \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  | xcbeautify || true

echo "==> 2/4  Exporting a signed .app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-DeveloperID.plist" \
  | xcbeautify || true

[ -d "$APP_PATH" ] || { echo "error: export finished but $APP_PATH is missing"; exit 1; }

echo "==> 3/4  Submitting to Apple notary (this typically takes 1-5 minutes)..."
ZIP_PATH="$BUILD_DIR/Quail-for-notarization.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait
rm -f "$ZIP_PATH"

echo "==> 4/4  Stapling the notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo ""
echo "Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vvv -t exec "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo ""
echo "Done: $APP_PATH is signed, notarized, and stapled."
