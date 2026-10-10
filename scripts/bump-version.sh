#!/bin/bash
# Writes a new version into every version file and commits it.
#
# The only version source is bundle/Info.plist: CFBundleShortVersionString (what
# the in-app updater compares with the release tag) and CFBundleVersion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/bundle/Info.plist"
BUDDY=/usr/libexec/PlistBuddy

log() { printf '== %s\n' "$*"; }
die() { printf 'bump-version: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: scripts/bump-version.sh X.Y.Z    set the version and commit "chore: release X.Y.Z"
       scripts/bump-version.sh --check  verify all version files agree, print the version

Version files: bundle/Info.plist (CFBundleShortVersionString, CFBundleVersion).
Does not tag or push; scripts/release.sh does that.
USAGE
}

read_versions() {
  SHORT="$("$BUDDY" -c 'Print :CFBundleShortVersionString' "$PLIST")"
  BUILD="$("$BUDDY" -c 'Print :CFBundleVersion' "$PLIST")"
}

check() {
  read_versions
  [ "$SHORT" = "$BUILD" ] \
    || die "bundle/Info.plist disagrees: CFBundleShortVersionString=$SHORT CFBundleVersion=$BUILD"
  [[ "$SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$SHORT' is not X.Y.Z"
  echo "$SHORT"
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --check) check; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

NEW="${1#v}"
[ $# -eq 1 ] || die "expected exactly one argument"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$1' is not a version (X.Y.Z)"

cd "$ROOT"
git diff --quiet -- "$PLIST" && git diff --cached --quiet -- "$PLIST" \
  || die "bundle/Info.plist has uncommitted changes"

read_versions
log "bumping $SHORT -> $NEW"
"$BUDDY" -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
"$BUDDY" -c "Set :CFBundleVersion $NEW" "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "Info.plist is no longer valid"

[ "$(check)" = "$NEW" ] || die "version files do not agree after the bump"

if git diff --quiet -- "$PLIST"; then
  log "already at $NEW, nothing to commit"
  exit 0
fi

git add "$PLIST"
git commit -q -m "chore: release $NEW"
log "committed: $(git log -1 --format='%h %s')"
log "next: scripts/release.sh --dry-run, then scripts/release.sh"
