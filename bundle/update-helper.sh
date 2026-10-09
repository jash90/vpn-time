#!/bin/bash
# Swaps in a downloaded, already verified VPN Time.app once the running app has
# quit, refreshes the tracker scripts and relaunches the app.
#
#   update-helper.sh <pid> <new_app> <dst_app> [work_dir]
#
# Runs detached from the app it replaces, so it never reads from the old bundle
# after the swap. On a failed swap the old bundle is put back and relaunched.
set -uo pipefail

PID="${1:?pid}"
NEW="${2:?new app}"
DST="${3:?destination app}"
WORK="${4:-}"
OLD="$DST.old"
LOG="${VPNTIME_LOG:-$HOME/Library/Logs/VPNTime.log}"
BIN="$HOME/.local/bin"
POLLER="$HOME/Library/LaunchAgents/com.redge.vpntrack.plist"

log() {
  mkdir -p "$(dirname "$LOG")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) update: $*" >> "$LOG"
}

waited=0
while kill -0 "$PID" 2>/dev/null && [ "$waited" -lt 300 ]; do
  sleep 0.1
  waited=$((waited + 1))
done

if kill -0 "$PID" 2>/dev/null; then
  log "app (pid $PID) did not quit, update aborted"
  exit 1
fi

if [ ! -d "$NEW" ]; then
  log "new bundle missing at $NEW, update aborted"
  open "$DST"
  exit 1
fi

rm -rf "$OLD"

if ! mv "$DST" "$OLD"; then
  log "could not move the current bundle aside, update aborted"
  open "$DST"
  exit 1
fi

if ! mv "$NEW" "$DST"; then
  log "could not move the new bundle in, rolling back"
  rm -rf "$DST"
  mv "$OLD" "$DST"
  open "$DST"
  exit 1
fi

SCRIPTS="$DST/Contents/Resources/scripts"

if [ -d "$SCRIPTS" ]; then
  mkdir -p "$BIN"
  for script in vpn-track.sh vpn-report.sh; do
    if [ -f "$SCRIPTS/$script" ]; then
      install -m 755 "$SCRIPTS/$script" "$BIN/$script" && log "installed $BIN/$script"
    fi
  done

  if [ -f "$POLLER" ]; then
    launchctl unload "$POLLER" 2>/dev/null || true
    launchctl load "$POLLER" && log "reloaded the poller agent"
  fi
else
  log "new bundle carries no scripts, ~/.local/bin left as is"
fi

open "$DST"
rm -rf "$OLD"

if [ -n "$WORK" ]; then
  rm -rf "$WORK"
fi

log "installed $DST"
