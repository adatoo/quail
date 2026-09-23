#!/usr/bin/env bash
# The PR `version` check (ADR D-024): this branch must carry exactly the bump
# its title calls for, relative to origin/main.
#
#   scripts/check-version.sh "<PR title>" ["<PR body>"]
#
# Set QUAIL_BASE_VERSION / QUAIL_BASE_BUILD to skip reading origin/main.
set -euo pipefail

ROOT="${QUAIL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION_SH="$(cd "$(dirname "$0")" && pwd)/version.sh"
title="${1:?PR title}"
body="${2:-}"

fail() {
  echo "::error::$1"
  echo
  echo "Fix: scripts/bump-version.sh --title \"$title\"   (then commit and push)"
  exit 1
}

"$VERSION_SH" valid-title "$title" \
  || fail "PR title isn't a Conventional Commits title: type(scope): summary — types: feat fix perf refactor docs test build ci chore revert style; add ! for a breaking change."

base="${QUAIL_BASE_VERSION:-$("$VERSION_SH" main-current)}"
base_build="${QUAIL_BASE_BUILD:-$("$VERSION_SH" main-build)}"
level="$("$VERSION_SH" level "$title" "$body")"
expected="$("$VERSION_SH" next "$level" "$base")"
actual="$("$VERSION_SH" current "$ROOT/project.yml")"
build="$("$VERSION_SH" build "$ROOT/project.yml")"

echo "main is $base (build $base_build); \"$title\" is a $level change → expected $expected; this branch has $actual (build $build)."

# 1.0.0 is a deliberate step (bump-version.sh 1.0.0), accepted from 0.x.
if [ "$actual" != "$expected" ] && ! [[ "$actual" == 1.0.0 && "$base" == 0.* ]]; then
  fail "project.yml's version is $actual; a $level change from $base should be $expected."
fi
[ "$build" -gt "$base_build" ] || fail "CURRENT_PROJECT_VERSION ($build) must be greater than main's ($base_build)."
grep -q "^## \[$actual\]" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no \"## [$actual]\" section."
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$actual" > /dev/null 2>&1 \
  || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/v$actual" > /dev/null 2>&1; then
  fail "Tag v$actual already exists."
fi
echo "Version OK: $actual"
