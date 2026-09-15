#!/bin/bash
# Tests vpn-track.sh state transitions with a faked ps and Tunnelblick log dir.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"

  if [ "$actual" = "$expected" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label — expected [$expected], got [$actual]"
    fail=1
  fi
}

setup() {
  HOME="$(mktemp -d)"
  export HOME
  VPN_TRACK_LOGDIR="$HOME/logs"
  export VPN_TRACK_LOGDIR
  mkdir -p "$VPN_TRACK_LOGDIR"
}

fake_connected() {
  export VPN_TRACK_PS_CMD="echo /Applications/Tunnelblick.app/Contents/Resources/openvpn --config /Library/Application Support/Tunnelblick/Shared/Office_VPN.tblk/Contents/Resources/config.ovpn"
}

fake_disconnected() {
  export VPN_TRACK_PS_CMD="true"
}

echo "connecting writes the state file"
setup
fake_connected
printf '%s Mon Jul  8 07:27:37 2026 OpenVPN starting\n' "$(( $(date +%s) - 3600 ))" \
  > "$VPN_TRACK_LOGDIR/a.openvpn.log"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.state" ] && echo yes || echo no)" "yes" "state file created"
assert_eq "$(cut -f2 "$HOME/.vpn-sessions.state")" "Office_VPN" "config name parsed from the tblk path"
assert_eq "$([ -f "$HOME/.vpn-sessions.csv" ] && echo yes || echo no)" "no" "no CSV row while still connected"

echo "staying connected does not duplicate the state"
before="$(cat "$HOME/.vpn-sessions.state")"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cat "$HOME/.vpn-sessions.state")" "$before" "state file untouched"

echo "disconnecting appends a CSV row and clears the state"
fake_disconnected
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.state" ] && echo yes || echo no)" "no" "state file removed"
assert_eq "$(head -1 "$HOME/.vpn-sessions.csv")" "start_iso,end_iso,duration_s,config" "CSV header written"
assert_eq "$(wc -l < "$HOME/.vpn-sessions.csv" | tr -d ' ')" "2" "one data row"
assert_eq "$(tail -1 "$HOME/.vpn-sessions.csv" | cut -d, -f4)" "Office_VPN" "config recorded"

duration="$(tail -1 "$HOME/.vpn-sessions.csv" | cut -d, -f3)"
assert_eq "$([ "$duration" -ge 3595 ] && [ "$duration" -le 3605 ] && echo ok || echo "$duration")" "ok" \
  "duration taken from the openvpn log start (~3600 s)"

echo "disconnecting while already disconnected is a no-op"
rows_before="$(wc -l < "$HOME/.vpn-sessions.csv")"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(wc -l < "$HOME/.vpn-sessions.csv")" "$rows_before" "no extra row"

echo "openvpn 2.7 stamps a local timestamp instead of an epoch"
setup
fake_connected
printf '2026-09-15 09:23:11 OpenVPN 2.7.7 aarch64-apple-darwin25.6.0\n' \
  > "$VPN_TRACK_LOGDIR/b.openvpn.log"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-sessions.state")" \
  "$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-09-15 09:23:11' +%s)" \
  "start parsed from a 'YYYY-MM-DD HH:MM:SS' log line"

echo "Tunnelblick stamps a fractional epoch (--machine-readable-output)"
setup
fake_connected
printf '1789458856.140523 1 OpenVPN 2.7.7 [git:9/a15b444bef68de96+] aarch64-apple-darwin\n' \
  > "$VPN_TRACK_LOGDIR/c.openvpn.log"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-sessions.state")" "1789458856" \
  "fractional epoch truncated to whole seconds"

exit "$fail"
