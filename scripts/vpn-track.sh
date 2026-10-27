#!/bin/bash
# Polls for a running Tunnelblick openvpn process and records finished sessions.
# Writes ~/.vpn-sessions.state while connected and appends a row to
# ~/.vpn-sessions.csv on disconnect. Safe to run repeatedly.
#
# The state file is "start<TAB>config<TAB>last_seen". launchd does not run this
# job while the Mac sleeps, so a last_seen older than SLEEP_GAP means the Mac
# slept: the session is closed at last_seen and a new one starts now, even when
# Tunnelblick reconnected on its own after the wake.
#
# ~/.vpn-sessions.stop ("session_start<TAB>end") is written by the app when
# inactivity ends the workday: the session it names ends at that time rather
# than at the moment the VPN actually went down.
#
# Also records streaks of user activity (keyboard/mouse) in ~/.vpn-activity.state
# and ~/.vpn-activity.csv, which the app uses to detect when the workday started.
set -uo pipefail

LOGDIR="${VPN_TRACK_LOGDIR:-/Library/Application Support/Tunnelblick/Logs}"
CSV="$HOME/.vpn-sessions.csv"
STATE="$HOME/.vpn-sessions.state"
STOP="$HOME/.vpn-sessions.stop"
ACTIVITY_CSV="$HOME/.vpn-activity.csv"
ACTIVITY_STATE="$HOME/.vpn-activity.state"
ACTIVE_IDLE=60
STREAK_GAP=1800
SLEEP_GAP="${VPN_TRACK_SLEEP_GAP:-1800}"

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

# Appends a finished session; an end not after the start records nothing.
append_session() {
  local start="$1" end="$2" config="$3"

  if [ "$end" -le "$start" ]; then
    return
  fi

  if [ ! -f "$CSV" ]; then
    echo "start_iso,end_iso,duration_s,config" > "$CSV"
  fi

  printf '%s,%s,%s,%s\n' \
    "$(date -r "$start" '+%Y-%m-%d %H:%M:%S')" \
    "$(date -r "$end" '+%Y-%m-%d %H:%M:%S')" \
    "$(( end - start ))" \
    "$config" >> "$CSV"
}

# The end the app asked for, when the stop file names this session.
requested_end() {
  local start="$1" stop_start stop_end

  [ -f "$STOP" ] || return

  stop_start="$(cut -f1 "$STOP")"
  stop_end="$(cut -f2 "$STOP")"

  case "$stop_start$stop_end" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$stop_start" = "$start" ]; then
    printf '%s' "$stop_end"
  fi
}

write_state() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

now="$(date +%s)"

start=""
config=""
last_seen=""

if [ -f "$STATE" ]; then
  start="$(cut -f1 "$STATE")"
  config="$(cut -f2 "$STATE")"
  last_seen="$(cut -f3 -s "$STATE")"
fi

case "${start:-}" in
  ''|*[!0-9]*) start="" ;;
esac

# A state file from before last_seen existed has not been seen asleep.
case "${last_seen:-}" in
  ''|*[!0-9]*) last_seen="$now" ;;
esac

if [ -n "$running_cmd" ]; then
  if [ -z "$start" ]; then
    # A stop file can only name a session that is already over.
    rm -f "$STOP"
    write_state "$(connection_start)" "$(config_name)" "$now"
    exit 0
  fi

  if [ $(( now - last_seen )) -gt "$SLEEP_GAP" ]; then
    end="$last_seen"
    requested="$(requested_end "$start")"

    if [ -n "$requested" ] && [ "$requested" -lt "$end" ]; then
      end="$requested"
    fi

    append_session "$start" "$end" "$config"
    rm -f "$STOP"
    write_state "$now" "$config" "$now"
    exit 0
  fi

  write_state "$start" "$config" "$now"
  exit 0
fi

if [ ! -f "$STATE" ]; then
  exit 0
fi

rm -f "$STATE"

if [ -z "$start" ]; then
  rm -f "$STOP"
  exit 0
fi

# Down after a sleep: the session ended when the Mac went to sleep.
end="$now"

if [ $(( now - last_seen )) -gt "$SLEEP_GAP" ]; then
  end="$last_seen"
fi

requested="$(requested_end "$start")"

if [ -n "$requested" ] && [ "$requested" -lt "$end" ]; then
  end="$requested"
fi

rm -f "$STOP"
append_session "$start" "$end" "$config"
