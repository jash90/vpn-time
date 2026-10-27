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

# Activity tests run with the VPN down so only the activity code reacts.
fake_idle() {
  export VPN_TRACK_IDLE_CMD="echo $1"
}

# Every test below that does not care about activity reports the user as away.
fake_idle 9999

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
before="$(cut -f1,2 "$HOME/.vpn-sessions.state")"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1,2 "$HOME/.vpn-sessions.state")" "$before" "start and config untouched"
seen="$(cut -f3 "$HOME/.vpn-sessions.state")"
assert_eq "$([ "$seen" -ge $(( $(date +%s) - 2 )) ] && echo ok || echo "$seen")" "ok" "last seen moved to now"

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

echo "activity: an idle user records nothing"
setup
fake_disconnected
fake_idle 300
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-activity.state" ] && echo yes || echo no)" "no" "no activity state"

echo "activity: an active user opens a streak"
fake_idle 5
bash "$ROOT/scripts/vpn-track.sh"
now="$(date +%s)"
start="$(cut -f1 "$HOME/.vpn-activity.state")"
assert_eq "$([ $(( now - 5 - start )) -le 2 ] && [ $(( now - 5 - start )) -ge 0 ] && echo ok || echo "$start")" "ok" \
  "streak starts at now minus idle"
assert_eq "$(cut -f2 "$HOME/.vpn-activity.state")" "$start" "last activity equals the start"
assert_eq "$([ -f "$HOME/.vpn-activity.csv" ] && echo yes || echo no)" "no" "no CSV for an open streak"

echo "activity: a short break extends the streak"
seed_start=$(( now - 1200 ))
printf '%s\t%s\n' "$seed_start" "$(( now - 600 ))" > "$HOME/.vpn-activity.state"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-activity.state")" "$seed_start" "streak start kept"
last="$(cut -f2 "$HOME/.vpn-activity.state")"
assert_eq "$([ "$last" -ge $(( now - 6 )) ] && echo ok || echo "$last")" "ok" "last activity moved to now"
assert_eq "$([ -f "$HOME/.vpn-activity.csv" ] && echo yes || echo no)" "no" "still no CSV"

echo "activity: a break over 30 minutes closes the streak"
old_start=$(( now - 7200 ))
old_end=$(( now - 3600 ))
printf '%s\t%s\n' "$old_start" "$old_end" > "$HOME/.vpn-activity.state"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(head -1 "$HOME/.vpn-activity.csv")" "start_iso,end_iso" "activity CSV header"
assert_eq "$(tail -1 "$HOME/.vpn-activity.csv")" \
  "$(date -r "$old_start" '+%Y-%m-%d %H:%M:%S'),$(date -r "$old_end" '+%Y-%m-%d %H:%M:%S')" \
  "finished streak appended"
new_start="$(cut -f1 "$HOME/.vpn-activity.state")"
assert_eq "$([ "$new_start" -ge $(( now - 6 )) ] && echo ok || echo "$new_start")" "ok" "a new streak opened"

echo "activity: a corrupt state file is replaced"
printf 'garbage\n' > "$HOME/.vpn-activity.state"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-activity.state" | grep -c '^[0-9][0-9]*$')" "1" "state rewritten with an epoch"

echo "activity and VPN tracking work in the same run"
setup
fake_connected
fake_idle 0
printf '%s Mon Jul  8 07:27:37 2026 OpenVPN starting\n' "$(( $(date +%s) - 60 ))" \
  > "$VPN_TRACK_LOGDIR/d.openvpn.log"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.state" ] && echo yes || echo no)" "yes" "VPN state written"
assert_eq "$([ -f "$HOME/.vpn-activity.state" ] && echo yes || echo no)" "yes" "activity state written"

# Each case below seeds the state file directly: start, config, last seen.
seed_state() {
  printf '%s\t%s\t%s\n' "$1" "Office_VPN" "$2" > "$HOME/.vpn-sessions.state"
}

csv_row() {
  printf '%s,%s,%s,Office_VPN' \
    "$(date -r "$1" '+%Y-%m-%d %H:%M:%S')" "$(date -r "$2" '+%Y-%m-%d %H:%M:%S')" "$(( $2 - $1 ))"
}

echo "a state file without last seen is kept going, not split"
setup
fake_connected
now="$(date +%s)"
printf '%s\t%s\n' "$(( now - 90000 ))" "Office_VPN" > "$HOME/.vpn-sessions.state"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-sessions.state")" "$(( now - 90000 ))" "start kept"
assert_eq "$([ -f "$HOME/.vpn-sessions.csv" ] && echo yes || echo no)" "no" "no CSV row"

echo "waking from sleep with the VPN still up splits the session"
setup
fake_connected
now="$(date +%s)"
seed_state "$(( now - 50000 ))" "$(( now - 36000 ))"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(tail -1 "$HOME/.vpn-sessions.csv")" "$(csv_row $(( now - 50000 )) $(( now - 36000 )))" \
  "the session before the sleep ends when the Mac went to sleep"
new_start="$(cut -f1 "$HOME/.vpn-sessions.state")"
assert_eq "$([ "$new_start" -ge "$now" ] && echo ok || echo "$new_start")" "ok" "a new session starts at the wake"
assert_eq "$(cut -f2 "$HOME/.vpn-sessions.state")" "Office_VPN" "config carried over"

echo "a short gap does not split the session"
setup
fake_connected
now="$(date +%s)"
seed_state "$(( now - 7200 ))" "$(( now - 600 ))"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cut -f1 "$HOME/.vpn-sessions.state")" "$(( now - 7200 ))" "start kept"
assert_eq "$([ -f "$HOME/.vpn-sessions.csv" ] && echo yes || echo no)" "no" "no CSV row"

echo "the VPN down after a sleep ends the session at the sleep"
setup
fake_disconnected
now="$(date +%s)"
seed_state "$(( now - 50000 ))" "$(( now - 36000 ))"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(tail -1 "$HOME/.vpn-sessions.csv")" "$(csv_row $(( now - 50000 )) $(( now - 36000 )))" \
  "ended at last seen"

echo "a stop file for this session ends it at the requested time"
setup
fake_disconnected
now="$(date +%s)"
seed_state "$(( now - 20000 ))" "$(( now - 10 ))"
printf '%s\t%s\n' "$(( now - 20000 ))" "$(( now - 4000 ))" > "$HOME/.vpn-sessions.stop"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(tail -1 "$HOME/.vpn-sessions.csv")" "$(csv_row $(( now - 20000 )) $(( now - 4000 )))" \
  "ended when the inactivity began"
assert_eq "$([ -f "$HOME/.vpn-sessions.stop" ] && echo yes || echo no)" "no" "stop file removed"

echo "a stop file for another session is ignored"
setup
fake_disconnected
now="$(date +%s)"
seed_state "$(( now - 20000 ))" "$(( now - 10 ))"
printf '%s\t%s\n' "$(( now - 90000 ))" "$(( now - 80000 ))" > "$HOME/.vpn-sessions.stop"
bash "$ROOT/scripts/vpn-track.sh"
end="$(tail -1 "$HOME/.vpn-sessions.csv" | cut -d, -f3)"
assert_eq "$([ "$end" -ge 20000 ] && echo ok || echo "$end")" "ok" "ended now"
assert_eq "$([ -f "$HOME/.vpn-sessions.stop" ] && echo yes || echo no)" "no" "stale stop file removed"

echo "a stop file at the session start drops the session"
setup
fake_disconnected
now="$(date +%s)"
seed_state "$(( now - 600 ))" "$(( now - 10 ))"
printf '%s\t%s\n' "$(( now - 600 ))" "$(( now - 600 ))" > "$HOME/.vpn-sessions.stop"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.csv" ] && echo yes || echo no)" "no" "no CSV row"

echo "a new connection removes a leftover stop file"
setup
fake_connected
printf '%s Mon Jul  8 07:27:37 2026 OpenVPN starting\n' "$(( $(date +%s) - 60 ))" \
  > "$VPN_TRACK_LOGDIR/e.openvpn.log"
printf '1\t2\n' > "$HOME/.vpn-sessions.stop"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.stop" ] && echo yes || echo no)" "no" "stop file removed"

exit "$fail"
