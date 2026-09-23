#!/usr/bin/env bash
# Quail's version arithmetic (ADR D-024). The version lives in project.yml:
# MARKETING_VERSION (SemVer) and CURRENT_PROJECT_VERSION (the build number,
# +1 per release). Used by bump-version.sh, check-version.sh and the release
# workflow; tested by test-versioning.sh.
#
#   version.sh current [project.yml]      → 0.2.0
#   version.sh build   [project.yml]      → 2
#   version.sh main-current | main-build  → the same, from origin/main
#   version.sh level "<PR title>" ["<PR body>"]  → patch | minor | major
#   version.sh next <patch|minor|major> <X.Y.Z>  → the next version
#   version.sh valid-title "<PR title>"   → exit 0 if Conventional Commits
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPES="feat|fix|perf|refactor|docs|test|build|ci|chore|revert|style"

read_key() { # key file
  sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$2" | head -1
}

main_file() {
  local tmp
  tmp="$(mktemp)"
  git -C "$ROOT" show origin/main:project.yml > "$tmp"
  echo "$tmp"
}

valid_title() {
  [[ "$1" =~ ^($TYPES)(\([^\)]+\))?!?:\ .+ ]]
}

level() { # title [body]
  local title="$1" body="${2:-}"
  valid_title "$title" || { echo "invalid"; return 1; }
  if [[ "$title" =~ ^[a-z]+(\([^\)]+\))?!: ]] || grep -q '^BREAKING[ -]CHANGE:' <<< "$body"; then
    echo major
  elif [[ "$title" =~ ^feat(\(|:|!) ]]; then
    echo minor
  else
    echo patch
  fi
}

next() { # level version
  local lvl="$1" v="$2" major minor patch
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "not a version: $v" >&2; return 1; }
  major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  # SemVer's pre-1.0 convention: while 0.x, a breaking change bumps minor.
  # 1.0.0 is a deliberate `bump-version.sh 1.0.0`.
  if [[ "$lvl" == major && "$major" == 0 ]]; then
    lvl=minor
  fi
  case "$lvl" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) echo "unknown level: $lvl" >&2; return 1 ;;
  esac
}

cmd="${1:-}"
shift || true
case "$cmd" in
  current) read_key MARKETING_VERSION "${1:-$ROOT/project.yml}" ;;
  build) read_key CURRENT_PROJECT_VERSION "${1:-$ROOT/project.yml}" ;;
  main-current) f="$(main_file)"; read_key MARKETING_VERSION "$f"; rm -f "$f" ;;
  main-build) f="$(main_file)"; read_key CURRENT_PROJECT_VERSION "$f"; rm -f "$f" ;;
  level) level "$@" ;;
  next) next "$@" ;;
  valid-title) valid_title "$1" ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
