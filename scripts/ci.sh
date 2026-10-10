#!/bin/bash
# Local CI: the full check suite every change must pass before it is pushed.
#
#   1. bash -n on every shell script (syntax)
#   2. shellcheck on every shell script, when shellcheck is installed
#   3. version files agree (bundle/Info.plist)
#   4. test/run-tests.sh: Swift unit tests + shell script tests
#   5. swift build -c release (the configuration build.sh ships)
#
# There is no hosted CI workflow for this repo; this script is the CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ci: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: scripts/ci.sh [--help]

Runs syntax checks, shellcheck (if installed), the version consistency check,
the Swift + shell test suite and a release build. Exits non-zero on the first
failing stage.
USAGE
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; die "unknown argument: $1" ;;
esac

cd "$ROOT"

SHELL_SCRIPTS=()
while IFS= read -r f; do
  SHELL_SCRIPTS+=("$f")
done < <(git ls-files '*.sh' .githooks/pre-push 2>/dev/null | while IFS= read -r f; do [ -f "$f" ] && echo "$f"; done)
[ "${#SHELL_SCRIPTS[@]}" -gt 0 ] || die "no shell scripts found (run from a git checkout)"

log "bash -n (${#SHELL_SCRIPTS[@]} scripts)"
for f in "${SHELL_SCRIPTS[@]}"; do
  bash -n "$f" || die "syntax error in $f"
done
echo "ok"

log "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${SHELL_SCRIPTS[@]}" || die "shellcheck reported warnings"
  echo "ok"
else
  echo "skipped (shellcheck not installed: brew install shellcheck)"
fi

log "version files"
"$ROOT/scripts/bump-version.sh" --check

log "tests"
"$ROOT/test/run-tests.sh" || die "test suite failed"

log "release build"
swift build -c release || die "release build failed"

log "CI PASSED"
