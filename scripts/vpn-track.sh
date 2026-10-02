#!/bin/bash
# Polls for a running Tunnelblick openvpn process and records finished sessions.
# Writes ~/.vpn-sessions.state while connected and appends a row to
# ~/.vpn-sessions.csv on disconnect. Safe to run repeatedly; each run is a no-op
# unless the connection state changed.
#
# Also records streaks of user activity (keyboard/mouse) in ~/.vpn-activity.state
# and ~/.vpn-activity.csv, which the app uses to detect when the workday started.
set -uo pipefail

LOGDIR="${VPN_TRACK_LOGDIR:-/Library/Application Support/Tunnelblick/Logs}"
CSV="$HOME/.vpn-sessions.csv"
STATE="$HOME/.vpn-sessions.state"
ACTIVITY_CSV="$HOME/.vpn-activity.csv"
ACTIVITY_STATE="$HOME/.vpn-activity.state"
ACTIVE_IDLE=60
STREAK_GAP=1800

idle_seconds() {
  if [ -n "${VPN_TRACK_IDLE_CMD:-}" ]; then
    eval "$VPN_TRACK_IDLE_CMD"
    return
  fi

  ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'
}

# A streak is a run of activity with no break longer than STREAK_GAP. The open
# one lives in the state file; it is moved to the CSV once a later activity
# shows that the break was long enough to end it. Sleep produces such breaks
# naturally, since launchd does not run this job while the Mac is asleep.
track_activity() {
  local idle now active streak_start="" last_active=""

  idle="$(idle_seconds 2>/dev/null)"

  case "${idle:-}" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$idle" -ge "$ACTIVE_IDLE" ]; then
    return
  fi

  now="$(date +%s)"
  active=$(( now - idle ))

  if [ -f "$ACTIVITY_STATE" ]; then
    streak_start="$(cut -f1 "$ACTIVITY_STATE")"
    last_active="$(cut -f2 "$ACTIVITY_STATE")"
  fi

  case "$streak_start" in
    ''|*[!0-9]*) last_active="" ;;
  esac

  case "$last_active" in
    ''|*[!0-9]*)
      printf '%s\t%s\n' "$active" "$active" > "$ACTIVITY_STATE"
      return
      ;;
  esac

  if [ $(( active - last_active )) -gt "$STREAK_GAP" ]; then
    if [ ! -f "$ACTIVITY_CSV" ]; then
      echo "start_iso,end_iso" > "$ACTIVITY_CSV"
    fi

    printf '%s,%s\n' \
      "$(date -r "$streak_start" '+%Y-%m-%d %H:%M:%S')" \
      "$(date -r "$last_active" '+%Y-%m-%d %H:%M:%S')" >> "$ACTIVITY_CSV"
    streak_start="$active"
  fi

  if [ "$active" -gt "$last_active" ]; then
    last_active="$active"
  fi

  printf '%s\t%s\n' "$streak_start" "$last_active" > "$ACTIVITY_STATE"
}

track_activity

running_cmd="$(${VPN_TRACK_PS_CMD:-ps -axww -o command=} | grep 'Tunnelblick.app/Contents/Resources/openvpn' | grep -v grep | head -1)"

config_name() {
  local name

  name="$(printf '%s' "$running_cmd" | sed -n 's|.*/\([^/]*\)\.tblk/.*|\1|p')"

  if [ -z "$name" ]; then
    name="openvpn"
  fi

  printf '%s' "$name"
}

connection_start() {
  local log first candidate

  log="$(ls -t "$LOGDIR"/*.openvpn.log 2>/dev/null | head -1)"

  if [ -n "$log" ]; then
    first="$(head -1 "$log")"

    # Tunnelblick runs openvpn with --machine-readable-output, which stamps each
    # line with a fractional epoch (1789458856.140523). Seconds are all we store.
    candidate="$(printf '%s' "$first" | awk '{print $1}')"
    candidate="${candidate%%.*}"

    case "$candidate" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$candidate"; return ;;
    esac

    candidate="$(date -j -f '%Y-%m-%d %H:%M:%S' "$(printf '%s' "$first" | cut -c1-19)" +%s 2>/dev/null)"

    if [ -n "$candidate" ]; then
      printf '%s' "$candidate"
      return
    fi
  fi

  date +%s
}

if [ -n "$running_cmd" ]; then
  if [ ! -f "$STATE" ]; then
    printf '%s\t%s\n' "$(connection_start)" "$(config_name)" > "$STATE"
  fi

  exit 0
fi

if [ ! -f "$STATE" ]; then
  exit 0
fi

start="$(cut -f1 "$STATE")"
config="$(cut -f2 "$STATE")"
rm -f "$STATE"

case "${start:-}" in
  ''|*[!0-9]*) exit 0 ;;
esac

end="$(date +%s)"

if [ ! -f "$CSV" ]; then
  echo "start_iso,end_iso,duration_s,config" > "$CSV"
fi

printf '%s,%s,%s,%s\n' \
  "$(date -r "$start" '+%Y-%m-%d %H:%M:%S')" \
  "$(date -r "$end" '+%Y-%m-%d %H:%M:%S')" \
  "$(( end - start ))" \
  "$config" >> "$CSV"
