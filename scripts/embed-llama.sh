#!/usr/bin/env bash
# Xcode Run Script build phase: embed the vendored llama-server + dylibs into
# Contents/MacOS and sign each one with the identity Xcode resolved for this
# build (matches docs/ARCHITECTURE.md §9 "sign inside-out").
#
# Runs on every build of the Quail target. If Vendor/llama.cpp hasn't been
# populated by scripts/vendor-llama.sh yet, this is a no-op with a warning
# rather than a build failure, so a fresh checkout still builds the app
# shell (see docs/IMPLEMENTATION_PLAN.md Phase 1 step 2).
set -euo pipefail

VENDOR="${SRCROOT}/Vendor/llama.cpp"
DEST="${CODESIGNING_FOLDER_PATH}/Contents/MacOS"

if [ ! -d "$VENDOR" ] || [ ! -f "$VENDOR/llama-server" ]; then
  echo "warning: Vendor/llama.cpp not found — run scripts/vendor-llama.sh, then rebuild. Quail will have no bundled runtime until then."
  exit 0
fi

mkdir -p "$DEST"
# No --delete: Contents/MacOS also holds the app's own executable (Quail),
# which must not be touched by this phase.
rsync -a --exclude 'LICENSE-llama.cpp' "$VENDOR"/ "$DEST"/
mkdir -p "${CODESIGNING_FOLDER_PATH}/Contents/Resources"
cp "$VENDOR/LICENSE-llama.cpp" "${CODESIGNING_FOLDER_PATH}/Contents/Resources/LICENSE-llama.cpp"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  echo "note: CODE_SIGNING_ALLOWED=NO — ad-hoc signing embedded llama.cpp binaries."
  SIGN_ARGS=(--force --sign -)
elif [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  SIGN_ARGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime)
  # A secure timestamp is a network round-trip to Apple, needed only for
  # notarization — not on every local Debug build (Config/LocalSigning.xcconfig).
  case "${CONFIGURATION:-}" in
    Release*) SIGN_ARGS+=(--timestamp) ;;
  esac
else
  SIGN_ARGS=(--force --sign -)
fi

SIGNED=0
for src in "$VENDOR"/*.dylib "$VENDOR/llama-server"; do
  [ -e "$src" ] || continue
  f="$DEST/$(basename "$src")"
  [ -e "$f" ] && [ ! -L "$f" ] || continue
  codesign "${SIGN_ARGS[@]}" "$f"
  SIGNED=$((SIGNED + 1))
done

echo "embed-llama: staged and signed $SIGNED files from Vendor/llama.cpp into $DEST"
