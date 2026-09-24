#!/usr/bin/env bash
# Xcode Run Script build phase: copy `quail-server` (the QuailServer target)
# into Quail.app/Contents/MacOS and sign it with the identity Xcode resolved
# for this build. Unlike the CLI it ships in the App Store build too — it needs
# no Python and no executable-code download (docs/ARCHITECTURE.md §2).
set -euo pipefail

SRC="${BUILT_PRODUCTS_DIR}/quail-server"
DEST="${CODESIGNING_FOLDER_PATH}/Contents/MacOS"
if [ ! -f "$SRC" ]; then
  echo "warning: ${SRC} not built — quail-server won't be in this app"
  exit 0
fi
mkdir -p "$DEST"
cp -f "$SRC" "$DEST/quail-server"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  codesign --force --sign - "$DEST/quail-server"
elif [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  ARGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime --identifier com.datoos.quail.server)
  case "${CONFIGURATION:-}" in Release*) ARGS+=(--timestamp) ;; esac
  codesign "${ARGS[@]}" "$DEST/quail-server"
else
  codesign --force --sign - "$DEST/quail-server"
fi
echo "embed-quail-server: staged and signed quail-server into $DEST"
