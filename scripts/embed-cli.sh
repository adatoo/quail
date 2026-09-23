#!/usr/bin/env bash
# Xcode Run Script build phase: copy the `quail` CLI (QuailCLI target) into
# Quail.app/Contents/Helpers and sign it with the identity Xcode resolved
# for this build. Skipped for the App Store build: a sandboxed Store app
# can't ship a command-line tool the user runs outside the sandbox.
set -euo pipefail

case "${CONFIGURATION:-}" in
  *AppStore*)
    echo "embed-cli: App Store build — no CLI"
    exit 0
    ;;
esac

SRC="${BUILT_PRODUCTS_DIR}/quail"
DEST="${CODESIGNING_FOLDER_PATH}/Contents/Helpers"
if [ ! -f "$SRC" ]; then
  echo "warning: ${SRC} not built — the quail CLI won't be in this app"
  exit 0
fi
mkdir -p "$DEST"
cp -f "$SRC" "$DEST/quail"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  codesign --force --sign - "$DEST/quail"
elif [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  ARGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime --identifier com.datoos.quail.cli)
  case "${CONFIGURATION:-}" in Release*) ARGS+=(--timestamp) ;; esac
  codesign "${ARGS[@]}" "$DEST/quail"
else
  codesign --force --sign - "$DEST/quail"
fi
echo "embed-cli: staged and signed quail into $DEST"
