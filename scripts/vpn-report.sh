#!/bin/bash
# Reports VPN session time from ~/.vpn-sessions.csv, bucketed by day, ISO week or month.
set -uo pipefail

CSV="$HOME/.vpn-sessions.csv"
STATE="$HOME/.vpn-sessions.state"
MODE="${1:-day}"

hours_minutes() {
  printf '%dh %02dm' "$(( $1 / 3600 ))" "$(( ($1 % 3600) / 60 ))"
}

bucket_of() {
  local day="$1"

  case "$MODE" in
    month) printf '%s' "${day:0:7}" ;;
    week)  date -j -f '%Y-%m-%d' "$day" '+%G-W%V' 2>/dev/null ;;
    *)     printf '%s' "$day" ;;
  esac
}

buckets() {
  [ -f "$CSV" ] || return 0

  tail -n +2 "$CSV" | while IFS=, read -r start_iso end_iso duration config; do
    case "${duration:-}" in
      ''|*[!0-9]*) continue ;;
    esac

    printf '%s\t%s\n' "$(bucket_of "${start_iso:0:10}")" "$duration"
  done
}

summed="$(buckets | awk -F'\t' '$1 != "" { s[$1] += $2 } END { for (k in s) printf "%s\t%d\n", k, s[k] }' | sort)"

case "$MODE" in
  week)  echo "Czas na VPN — tygodnie" ;;
  month) echo "Czas na VPN — miesiące" ;;
  *)     echo "Czas na VPN — dni" ;;
esac
echo

if [ -z "$summed" ]; then
  echo "Brak danych"
else
  total=0

  while IFS=$'\t' read -r label seconds; do
    printf '%-14s %s\n' "$label" "$(hours_minutes "$seconds")"
    total=$(( total + seconds ))
  done <<< "$summed"

  echo
  printf '%-14s %s\n' "RAZEM:" "$(hours_minutes "$total")"
fi

if [ -f "$STATE" ]; then
  epoch="$(cut -f1 "$STATE")"
  config="$(cut -f2 "$STATE")"

  case "${epoch:-}" in
    ''|*[!0-9]*) ;;
    *)
      echo
      printf 'Aktywna sesja (%s): %s\n' "$config" "$(hours_minutes "$(( $(date +%s) - epoch ))")"
      ;;
  esac
fi
