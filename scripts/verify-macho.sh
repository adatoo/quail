#!/usr/bin/env bash
# Verify every Mach-O in a directory (recursively) only depends on @rpath/,
# @loader_path/, @executable_path/, or a system path — never an absolute
# build-machine or Homebrew path, and never a bare relative name that would
# only resolve by accident from a particular working directory.
#
# Usage: scripts/verify-macho.sh <dir>   (defaults to Vendor/llama.cpp)
#
# Used by vendor-llama.sh right after staging, and can be pointed at a built
# .app's Contents/MacOS as a release-time check (see docs/IMPLEMENTATION_PLAN.md,
# "Vendor check").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/Vendor/llama.cpp}"

[ -d "$DIR" ] || { echo "error: $DIR does not exist"; exit 1; }

FAIL=0

is_macho() {
  local magic
  magic="$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    cffaedfe|feedfacf|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue

  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*) ;;
      /usr/lib/*|/System/*) ;;
      *)
        echo "FAIL: $f depends on non-relocatable path: $dep"
        FAIL=1
        ;;
    esac
  done < <(otool -L "$f" | awk 'NR>1 {print $1}')
done < <(find "$DIR" -type f -print0)

if [ "$FAIL" -ne 0 ]; then
  echo "verify-macho: one or more Mach-O files have non-relocatable dependencies"
  exit 1
fi

echo "verify-macho: OK — all Mach-O files in $DIR are relocatable"
