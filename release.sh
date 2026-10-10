#!/bin/bash
# Backward-compatible entry point. The release script lives in scripts/release.sh;
# the old form `./release.sh vX.Y.Z [notes-file]` still works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
args=()

if [ $# -ge 1 ] && [[ "$1" == v* ]]; then
  args+=(--tag "$1")
  shift
  if [ $# -ge 1 ] && [[ "$1" != -* ]]; then
    args+=(--notes "$1")
    shift
  fi
fi

exec "$ROOT/scripts/release.sh" ${args[@]+"${args[@]}"} "$@"
