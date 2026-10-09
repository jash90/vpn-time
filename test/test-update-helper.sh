#!/bin/bash
# Tests update-helper.sh on fake bundles in a throwaway HOME, with launchctl and
# open stubbed out so nothing real is loaded or launched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/bundle/update-helper.sh"
fail=0

check() {
  local label="$1"
  shift

  if "$@"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label"
    fail=1
  fi
}

setup() {
  HOME="$(mktemp -d)"
  export HOME
  export VPNTIME_LOG="$HOME/update.log"
  STUBS="$HOME/stubs"
  mkdir -p "$STUBS" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/work"
  for cmd in launchctl open; do
    printf '#!/bin/bash\necho "%s $*" >> "$HOME/calls"\n' "$cmd" > "$STUBS/$cmd"
    chmod +x "$STUBS/$cmd"
  done
  export PATH="$STUBS:$PATH"

  DST="$HOME/Applications/VPN Time.app"
  NEW="$HOME/work/VPN Time.app"
  mkdir -p "$DST/Contents" "$NEW/Contents/Resources/scripts"
  echo old > "$DST/Contents/version"
  echo new > "$NEW/Contents/version"
  echo 'echo track-new' > "$NEW/Contents/Resources/scripts/vpn-track.sh"
  echo 'echo report-new' > "$NEW/Contents/Resources/scripts/vpn-report.sh"
  touch "$HOME/Library/LaunchAgents/com.redge.vpntrack.plist"
}

# A pid that has already exited, so the helper does not wait.
dead_pid() {
  bash -c 'echo $$'
}

echo "update-helper.sh swaps the bundle and refreshes the scripts"
setup
bash "$HELPER" "$(dead_pid)" "$NEW" "$DST" "$HOME/work"
check "new bundle in place" grep -qx new "$DST/Contents/version"
check "old bundle removed" test ! -e "$DST.old"
check "work dir removed" test ! -e "$HOME/work"
check "poller script installed" grep -qx 'echo track-new' "$HOME/.local/bin/vpn-track.sh"
check "report script installed" grep -qx 'echo report-new' "$HOME/.local/bin/vpn-report.sh"
check "scripts executable" test -x "$HOME/.local/bin/vpn-track.sh"
check "poller agent reloaded" grep -q "launchctl load $HOME/Library/LaunchAgents/com.redge.vpntrack.plist" "$HOME/calls"
check "app relaunched" grep -qx "open $DST" "$HOME/calls"
check "install logged" grep -q "update: installed" "$VPNTIME_LOG"

echo "update-helper.sh keeps the old bundle when the new one is missing"
setup
rm -rf "$NEW"
bash "$HELPER" "$(dead_pid)" "$NEW" "$DST" "$HOME/work"
check "exits with the old bundle still there" grep -qx old "$DST/Contents/version"
check "old app relaunched" grep -qx "open $DST" "$HOME/calls"
check "scripts untouched" test ! -e "$HOME/.local/bin/vpn-track.sh"

echo "update-helper.sh leaves scripts alone for a bundle without them"
setup
rm -rf "$NEW/Contents/Resources/scripts"
bash "$HELPER" "$(dead_pid)" "$NEW" "$DST"
check "new bundle in place" grep -qx new "$DST/Contents/version"
check "no scripts installed" test ! -e "$HOME/.local/bin/vpn-track.sh"
check "poller not reloaded" bash -c "! grep -q launchctl '$HOME/calls'"

echo "update-helper.sh waits for the app to quit"
setup
sleep 1 &
waiter=$!
bash "$HELPER" "$waiter" "$NEW" "$DST" "$HOME/work"
check "swapped after the app exited" grep -qx new "$DST/Contents/version"

if [ "$fail" -eq 0 ]; then
  echo "update-helper.sh: all passed"
fi

exit "$fail"
