#!/usr/bin/env bash
# Tests for version.sh, bump-version.sh and check-version.sh (ADR D-024).
# Runs locally and in the `version` CI job. No network; works on a temp copy.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
V="$DIR/version.sh"
failures=0

eq() { # description expected actual
  if [ "$2" == "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

ok() { # description command...
  local d="$1"; shift
  if "$@" > /dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d"; failures=$((failures + 1)); fi
}

not() { # description command...
  local d="$1"; shift
  if "$@" > /dev/null 2>&1; then echo "FAIL $d (should have failed)"; failures=$((failures + 1)); else echo "ok   $d"; fi
}

# --- SemVer arithmetic
eq "patch" 1.2.4 "$("$V" next patch 1.2.3)"
eq "minor resets patch" 1.3.0 "$("$V" next minor 1.2.3)"
eq "major resets minor and patch" 2.0.0 "$("$V" next major 1.2.3)"
eq "major while 0.x bumps minor" 0.3.0 "$("$V" next major 0.2.5)"
eq "minor while 0.x" 0.3.0 "$("$V" next minor 0.2.5)"
not "rejects a non-version" "$V" next patch 1.2

# --- Title → level
eq "feat → minor" minor "$("$V" level 'feat: add benchmark')"
eq "feat(scope) → minor" minor "$("$V" level 'feat(bench): add benchmark')"
eq "fix → patch" patch "$("$V" level 'fix: runaway poll')"
for type in perf refactor docs test build ci chore revert style; do
  eq "$type → patch" patch "$("$V" level "$type: something")"
done
eq "chore(deps) → patch" patch "$("$V" level 'chore(deps): bump actions/checkout from 6 to 7')"
eq "! → major" major "$("$V" level 'feat!: new control protocol')"
eq "scope + ! → major" major "$("$V" level 'fix(cli)!: rename bench flags')"
eq "BREAKING CHANGE in body → major" major "$("$V" level 'fix: x' $'Some text\nBREAKING CHANGE: y')"
not "no type" "$V" valid-title 'Add benchmark'
not "unknown type" "$V" valid-title 'feature: add benchmark'
not "missing space" "$V" valid-title 'feat:add'
ok "valid title" "$V" valid-title 'feat(release): SemVer releases'

# --- Reading project.yml
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/project.yml" << 'EOF'
settings:
  base:
    SWIFT_VERSION: 6.0
    MARKETING_VERSION: "0.4.1"
    CURRENT_PROJECT_VERSION: "7"
EOF
cat > "$tmp/CHANGELOG.md" << 'EOF'
# Changelog

## [Unreleased]

### Added

- A thing.

## [0.4.1] - 2026-01-01

- Older.
EOF
eq "reads the version" 0.4.1 "$("$V" current "$tmp/project.yml")"
eq "reads the build" 7 "$("$V" build "$tmp/project.yml")"

# --- Bump
bump() { QUAIL_ROOT="$tmp" QUAIL_BASE_VERSION=0.4.1 QUAIL_BASE_BUILD=7 QUAIL_SKIP_XCODEGEN=1 "$DIR/bump-version.sh" "$@"; }
check() { QUAIL_ROOT="$tmp" QUAIL_BASE_VERSION=0.4.1 QUAIL_BASE_BUILD=7 "$DIR/check-version.sh" "$@"; }

not "check fails before a bump" check 'feat: a thing'
bump --title 'feat: a thing' > /dev/null
eq "bump sets the version" 0.5.0 "$("$V" current "$tmp/project.yml")"
eq "bump sets build = main's + 1" 8 "$("$V" build "$tmp/project.yml")"
eq "CHANGELOG gets a fresh Unreleased above the new section" \
  "## [Unreleased]|## [0.5.0] - $(date +%Y-%m-%d)|## [0.4.1] - 2026-01-01" \
  "$(grep '^## ' "$tmp/CHANGELOG.md" | paste -sd '|' -)"
eq "the entries moved into the new section" 1 \
  "$(awk '/^## \[0.5.0\]/{f=1;next} /^## /{f=0} f && /A thing/' "$tmp/CHANGELOG.md" | wc -l | tr -d ' ')"
ok "check passes after the bump" check 'feat: a thing'
not "check fails when the title says a different level" check 'fix: a thing'
not "check fails on an invalid title" check 'A thing'

# Title changed to fix: re-running re-targets instead of double-bumping.
bump --title 'fix: a thing' > /dev/null
eq "re-bump re-targets" 0.4.2 "$("$V" current "$tmp/project.yml")"
eq "re-bump keeps one build step" 8 "$("$V" build "$tmp/project.yml")"
eq "re-bump renames this branch's section" 1 "$(grep -c '^## \[0.4.2\]' "$tmp/CHANGELOG.md")"
eq "…and leaves no stale one" 0 "$(grep -c '^## \[0.5.0\]' "$tmp/CHANGELOG.md")"
ok "check passes for the new title" check 'fix: a thing'

bump 1.0.0 > /dev/null
ok "1.0.0 is accepted from 0.x whatever the title" check 'feat: one point oh'

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "All versioning tests passed."
