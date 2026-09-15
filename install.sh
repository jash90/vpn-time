#!/bin/bash
# Installs the tracker scripts, the app bundle and the launchd agents.
# Idempotent. Never touches ~/.vpn-sessions.csv beyond making a backup.
set -euo pipefail

cd "$(dirname "$0")"

STAMP="$(date +%Y-%m-%d-%H%M%S)"
APP_SRC="build/VPN Time.app"
APP_DST="$HOME/Applications/VPN Time.app"
AGENTS="$HOME/Library/LaunchAgents"

if [ ! -d "$APP_SRC" ]; then
  echo "error: $APP_SRC missing — run ./build.sh first" >&2
  exit 1
fi

echo "== backing up session data =="
for f in "$HOME/.vpn-sessions.csv" "$HOME/.vpn-sessions.state"; do
  if [ -f "$f" ]; then
    cp "$f" "$f.bak-$STAMP"
    echo "  $f -> $f.bak-$STAMP"
  fi
done

echo "== installing scripts =="
mkdir -p "$HOME/.local/bin"
install -m 755 scripts/vpn-track.sh "$HOME/.local/bin/vpn-track.sh"
install -m 755 scripts/vpn-report.sh "$HOME/.local/bin/vpn-report.sh"

echo "== rendering launchd agents =="
mkdir -p "$AGENTS"
for label in com.redge.vpntrack com.redge.vpntimebar; do
  sed "s|__HOME__|$HOME|g" "launchd/$label.plist.template" > "$AGENTS/$label.plist"
  echo "  $AGENTS/$label.plist"
done

echo "== swapping the app bundle =="
launchctl unload "$AGENTS/com.redge.vpntimebar.plist" 2>/dev/null || true
pkill -x vpntime 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "== loading agents =="
launchctl load "$AGENTS/com.redge.vpntimebar.plist"
launchctl unload "$AGENTS/com.redge.vpntrack.plist" 2>/dev/null || true
launchctl load "$AGENTS/com.redge.vpntrack.plist"

echo "== done =="
launchctl list | grep -E 'com\.redge\.vpn' || true
