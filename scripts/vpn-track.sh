#!/bin/bash
# Polls for a running Tunnelblick openvpn process and records finished sessions.
# Writes ~/.vpn-sessions.state while connected and appends a row to
# ~/.vpn-sessions.csv on disconnect. Safe to run repeatedly; each run is a no-op
# unless the connection state changed.
set -uo pipefail

LOGDIR="${VPN_TRACK_LOGDIR:-/Library/Application Support/Tunnelblick/Logs}"
CSV="$HOME/.vpn-sessions.csv"
STATE="$HOME/.vpn-sessions.state"

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
    candidate="$(printf '%s' "$first" | awk '{print $1}')"

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
