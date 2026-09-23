#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Quail installer for macOS
#
# Vendors llama.cpp, builds Quail, signs it with a Developer ID Application
# certificate, submits it to Apple for notarization, and installs the
# stapled result to ~/Apps/Quail.app. Gatekeeper accepts the result outright
# — no ad-hoc signing or xattr stripping needed. Mirrors the same pattern
# used for the LookOut app (same Apple Developer account), adapted for a
# native Xcode project instead of electron-builder.
#
# Run from inside the Quail project folder:
#     bash scripts/install.sh
#
# Requires (one-time setup — see docs/DECISIONS.md D-018):
#   - A "Developer ID Application" certificate + private key in the login
#     keychain (security find-identity -v -p codesigning should list it).
#   - APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD in the environment, for
#     notarization. Generate an app-specific password at
#     https://account.apple.com/account/manage (Sign-In and Security ->
#     App-Specific Passwords).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

APPS_DIR="$HOME/Apps"
APP_NAME="Quail.app"

for var in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "! \$$var is not set — see this script's own header for how to get one."
    exit 1
  fi
done

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "! No \"Developer ID Application\" certificate found in the login keychain."
  echo "  See docs/DECISIONS.md D-018 for how to request one and import it."
  exit 1
fi

echo "==> 1/4  Vendoring llama.cpp and generating the Xcode project..."
scripts/vendor-llama.sh
xcodegen generate

echo "==> 2/4  Building, signing, and notarizing $APP_NAME ..."
echo "    (notarization typically takes 1-5 minutes)"
export APPLE_ID APPLE_APP_SPECIFIC_PASSWORD
scripts/sign-and-notarize.sh

APP_PATH="build/export/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
  echo "    ! Build finished but $APP_PATH was not found."
  exit 1
fi
echo "    built: $APP_PATH"

echo "==> 3/4  Installing to $APPS_DIR ..."
mkdir -p "$APPS_DIR"
rm -rf "${APPS_DIR:?}/$APP_NAME"
# ditto (not cp -R) preserves the code signature, extended attributes, and
# the stapled notarization ticket exactly as xcodebuild/notarytool produced
# them.
ditto "$APP_PATH" "$APPS_DIR/$APP_NAME"

echo "==> 4/4  Verifying signature, notarization, and Gatekeeper acceptance..."
codesign --verify --deep --strict --verbose=2 "$APPS_DIR/$APP_NAME"
xcrun stapler validate "$APPS_DIR/$APP_NAME"
spctl -a -vvv -t exec "$APPS_DIR/$APP_NAME"
echo "    all checks passed"

echo ""
echo "Done. Launch it with:"
echo "    open ~/Apps/$APP_NAME"
