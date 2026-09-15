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

exit "$fail"
