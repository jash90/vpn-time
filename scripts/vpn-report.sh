#!/bin/bash
# Reports VPN session time from ~/.vpn-sessions.csv, bucketed by day, ISO week or month.
set -uo pipefail

CSV="$HOME/.vpn-sessions.csv"
STATE="$HOME/.vpn-sessions.state"
WORKDAYS="$HOME/.vpn-workdays.csv"
MODE="${1:-day}"

# English by default; Polish when VPN_REPORT_LANG, LC_ALL, LC_MESSAGES or LANG
# (first one set) starts with "pl".
REPORT_LANG="${VPN_REPORT_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}}"

if [[ "$REPORT_LANG" == pl* ]]; then
  T_TITLE_DAY="Czas na VPN — dni"
  T_TITLE_WEEK="Czas na VPN — tygodnie"
  T_TITLE_MONTH="Czas na VPN — miesiące"
  T_NO_DATA="Brak danych"
  T_TOTAL="RAZEM:"
  T_END="koniec"
  T_ACTIVE="Aktywna sesja"
else
  T_TITLE_DAY="VPN time — days"
  T_TITLE_WEEK="VPN time — weeks"
  T_TITLE_MONTH="VPN time — months"
  T_NO_DATA="No data"
  T_TOTAL="TOTAL:"
  T_END="end"
  T_ACTIVE="Active session"
fi

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

# "start HH:MM" plus "end HH:MM" (localized) when known, from the app's
# ~/.vpn-workdays.csv. Old rows have no end column (date,start_iso,source).
workday_of() {
  [ -f "$WORKDAYS" ] || return 0
  awk -F, -v day="$1" -v end_label="$T_END" '
    $1 == day {
      out = "start " substr($2, 12, 5)
      if (NF >= 4 && $3 != "") out = out "  " end_label " " substr($3, 12, 5)
      print out
      exit
    }' "$WORKDAYS"
}

buckets() {
  [ -f "$CSV" ] || return 0

  tail -n +2 "$CSV" | while IFS=, read -r start_iso _end_iso duration config; do
    case "${duration:-}" in
      ''|*[!0-9]*) continue ;;
    esac

    printf '%s\t%s\n' "$(bucket_of "${start_iso:0:10}")" "$duration"
  done
}

summed="$(buckets | awk -F'\t' '$1 != "" { s[$1] += $2 } END { for (k in s) printf "%s\t%d\n", k, s[k] }' | sort)"

case "$MODE" in
  week)  echo "$T_TITLE_WEEK" ;;
  month) echo "$T_TITLE_MONTH" ;;
  *)     echo "$T_TITLE_DAY" ;;
esac
echo

if [ -z "$summed" ]; then
  echo "$T_NO_DATA"
else
  total=0

  while IFS=$'\t' read -r label seconds; do
    line="$(printf '%-14s %s' "$label" "$(hours_minutes "$seconds")")"

    if [ "$MODE" = "day" ]; then
      workday="$(workday_of "$label")"

      if [ -n "$workday" ]; then
        line="$line   $workday"
      fi
    fi

    printf '%s\n' "$line"
    total=$(( total + seconds ))
  done <<< "$summed"

  echo
  printf '%-14s %s\n' "$T_TOTAL" "$(hours_minutes "$total")"
fi

if [ -f "$STATE" ]; then
  epoch="$(cut -f1 "$STATE")"
  config="$(cut -f2 "$STATE")"

  case "${epoch:-}" in
    ''|*[!0-9]*) ;;
    *)
      echo
      printf '%s (%s): %s\n' "$T_ACTIVE" "$config" "$(hours_minutes "$(( $(date +%s) - epoch ))")"
      ;;
  esac
fi
