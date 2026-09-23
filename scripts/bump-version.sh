#!/usr/bin/env bash
# Bumps Quail's version for this PR (ADR D-024): every PR carries its own
# bump, computed from origin/main's version, so re-running after main moves
# re-targets rather than double-bumping.
#
#   scripts/bump-version.sh --title "feat(bench): …" [--body "…"]   # from the PR title
#   scripts/bump-version.sh patch|minor|major
#   scripts/bump-version.sh 1.0.0                                  # explicit
#
# Updates project.yml (MARKETING_VERSION, CURRENT_PROJECT_VERSION = main's
# build + 1), cuts CHANGELOG.md's [Unreleased] into a [X.Y.Z] section, and
# regenerates the Xcode project. Set QUAIL_BASE_VERSION / QUAIL_BASE_BUILD
# to override the base (tests do; so can a repo with no origin/main).
set -euo pipefail

ROOT="${QUAIL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION_SH="$(cd "$(dirname "$0")" && pwd)/version.sh"
PROJECT="$ROOT/project.yml"
CHANGELOG="$ROOT/CHANGELOG.md"

title="" body="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    *) target="$1"; shift ;;
  esac
done
[ -n "$title" ] || [ -n "$target" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

if [ -z "${QUAIL_BASE_VERSION:-}" ]; then
  git -C "$ROOT" fetch -q origin main 2>/dev/null || true
fi
base="${QUAIL_BASE_VERSION:-$("$VERSION_SH" main-current)}"
base_build="${QUAIL_BASE_BUILD:-$("$VERSION_SH" main-build)}"

if [ -n "$title" ]; then
  level="$("$VERSION_SH" level "$title" "$body")" || {
    echo "error: \"$title\" isn't a Conventional Commits title (type(scope): summary; types: feat fix perf refactor docs test build ci chore revert style)" >&2
    exit 1
  }
  new="$("$VERSION_SH" next "$level" "$base")"
elif [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  new="$target"
else
  new="$("$VERSION_SH" next "$target" "$base")"
fi
new_build=$((base_build + 1))
current="$("$VERSION_SH" current "$PROJECT")"

perl -0pi -e "s/(MARKETING_VERSION:\s*)\"?[0-9.]+\"?/\${1}\"$new\"/; s/(CURRENT_PROJECT_VERSION:\s*)\"?[0-9]+\"?/\${1}\"$new_build\"/" "$PROJECT"

# CHANGELOG: re-running after main moved renames this branch's own section;
# otherwise [Unreleased] becomes [new] under a fresh, empty [Unreleased].
today="$(date +%Y-%m-%d)"
if grep -q "^## \[$new\]" "$CHANGELOG"; then
  : # already cut
elif [ "$current" != "$base" ] && grep -q "^## \[$current\]" "$CHANGELOG" \
  && ! git -C "$ROOT" show origin/main:CHANGELOG.md 2>/dev/null | grep -q "^## \[$current\]"; then
  perl -pi -e "s/^## \\[\Q$current\E\\] - .*/## [$new] - $today/" "$CHANGELOG"
else
  perl -0pi -e "s/^## \\[Unreleased\\][ \\t]*\\n/## [Unreleased]\\n\\n## [$new] - $today\\n/m" "$CHANGELOG"
fi

if [ -z "${QUAIL_SKIP_XCODEGEN:-}" ] && command -v xcodegen > /dev/null; then
  (cd "$ROOT" && xcodegen generate --quiet)
fi

echo "$base → $new (build $new_build)"
