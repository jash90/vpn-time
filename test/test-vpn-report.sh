#!/bin/bash
# Tests vpn-report.sh against a fixed CSV in a throwaway HOME.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

assert_contains() {
  local haystack="$1" needle="$2" label="$3"

  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label — expected to find [$needle] in:"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    fail=1
  fi
}

# The Polish output is asserted first; the English one at the end.
export VPN_REPORT_LANG=pl

HOME="$(mktemp -d)"
export HOME

cat > "$HOME/.vpn-sessions.csv" <<'CSV'
start_iso,end_iso,duration_s,config
2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN
2026-07-08 07:43:15,2026-07-08 16:26:34,31399,Office_VPN
2026-07-09 09:00:00,2026-07-09 10:00:00,3600,Office_VPN
CSV

echo "vpn-report.sh day"
out="$(bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "2026-07-08     8h 57m" "8 July sums 839+31399 = 32238 s = 8h 57m"
assert_contains "$out" "2026-07-09     1h 00m" "9 July sums 3600 s"
assert_contains "$out" "RAZEM:         9h 57m" "35838 s total across both days"

echo "vpn-report.sh day with recorded workday starts"
cat > "$HOME/.vpn-workdays.csv" <<'CSV'
date,start_iso,end_iso,source
2026-07-08,2026-07-08 07:20:05,2026-07-08 16:30:00,edited
CSV
out="$(bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "2026-07-08     8h 57m   start 07:20  koniec 16:30" "start and end shown for a recorded day"

echo "vpn-report.sh day with an old three-column workdays file"
cat > "$HOME/.vpn-workdays.csv" <<'CSV'
date,start_iso,source
2026-07-08,2026-07-08 07:20:05,activity
CSV
out="$(bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "2026-07-08     8h 57m   start 07:20" "start shown from an old row"
if printf '%s' "$out" | grep -q 'koniec'; then
  echo "  FAIL: old row must not show an end"
  fail=1
fi
assert_contains "$out" "$(printf '2026-07-09     1h 00m\n')" "day without a start unchanged"
if printf '%s' "$out" | grep -q '2026-07-09.*start'; then
  echo "  FAIL: unexpected start on 9 July"
  fail=1
fi

echo "vpn-report.sh month"
out="$(bash "$ROOT/scripts/vpn-report.sh" month)"
assert_contains "$out" "2026-07        9h 57m" "July bucket"

echo "vpn-report.sh with no data"
HOME="$(mktemp -d)"
export HOME
out="$(bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "Brak danych" "empty-state message"

echo "vpn-report.sh with an active session"
HOME="$(mktemp -d)"
export HOME
printf '%s\tOffice_VPN\n' "$(( $(date +%s) - 7200 ))" > "$HOME/.vpn-sessions.state"
out="$(bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "Aktywna sesja (Office_VPN): 2h 00m" "active session line"

echo "vpn-report.sh in English"
HOME="$(mktemp -d)"
export HOME
cat > "$HOME/.vpn-sessions.csv" <<'CSV'
start_iso,end_iso,duration_s,config
2026-07-08 07:27:37,2026-07-08 16:26:34,32338,Office_VPN
CSV
cat > "$HOME/.vpn-workdays.csv" <<'CSV'
date,start_iso,end_iso,source
2026-07-08,2026-07-08 07:20:05,2026-07-08 16:30:00,edited
CSV
printf '%s\tOffice_VPN\n' "$(( $(date +%s) - 3600 ))" > "$HOME/.vpn-sessions.state"
out="$(VPN_REPORT_LANG=en bash "$ROOT/scripts/vpn-report.sh" day)"
assert_contains "$out" "VPN time — days" "English title"
assert_contains "$out" "2026-07-08     8h 58m   start 07:20  end 16:30" "English workday end"
assert_contains "$out" "TOTAL:         8h 58m" "English total"
assert_contains "$out" "Active session (Office_VPN): 1h 00m" "English active session"
out="$(VPN_REPORT_LANG='' LC_ALL='' LC_MESSAGES='' LANG=pl_PL.UTF-8 bash "$ROOT/scripts/vpn-report.sh" week)"
assert_contains "$out" "Czas na VPN — tygodnie" "Polish picked from LANG"
out="$(VPN_REPORT_LANG='' LC_ALL='' LC_MESSAGES='' LANG=de_DE.UTF-8 bash "$ROOT/scripts/vpn-report.sh" month)"
assert_contains "$out" "VPN time — months" "English fallback for other languages"

exit "$fail"
