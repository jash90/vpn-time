#!/bin/bash
# Runs the whole suite: Swift unit tests and the shell script tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0

echo "== swift test =="
(cd "$ROOT" && swift test) || status=1

for t in "$ROOT"/test/test-*.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || status=1
done

if [ "$status" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi

exit "$status"
