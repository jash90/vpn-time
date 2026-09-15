#!/bin/bash
# Verifies the running VPN Time menu against the recovered layout.
# Exits non-zero on any mismatch. Tolerates both VPN states.
#
# The recovery plan wanted this green on the ORIGINAL binary first. That binary
# never existed on this machine, so its first green run was the rebuilt app:
# it proves conformance to docs/recovered-api.md, not parity with the lost app.
set -uo pipefail

read_menu() {
  osascript <<'OSA'
tell application "System Events" to tell process "vpntime"
  set mb to menu bar item 1 of menu bar 1
  set out to ""
  repeat with mi in (every menu item of menu 1 of mb)
    set nm to name of mi
    if nm is missing value then
      set out to out & "SEP" & linefeed
    else
      set out to out & nm & linefeed
    end if
  end repeat
  return out
end tell
OSA
}

if ! pgrep -x vpntime > /dev/null; then
  echo "FAIL: vpntime is not running"
  exit 1
fi

menu="$(read_menu)"

if [ -z "$menu" ]; then
  echo "FAIL: could not read the menu (grant Accessibility permission)"
  exit 1
fi

fail=0
check() {
  local n="$1" pattern="$2"
  local line
  line="$(printf '%s\n' "$menu" | sed -n "${n}p")"

  if ! printf '%s' "$line" | grep -qE "$pattern"; then
    echo "FAIL line $n: expected /$pattern/, got [$line]"
    fail=1
  fi
}

check 1  '^Czas na VPN$'
check 2  '^SEP$'
check 3  '^Dziś:            [0-9]+h [0-9]{2}m$'
check 4  '^Ten tydzień:  [0-9]+h [0-9]{2}m$'
check 5  '^Ten miesiąc: [0-9]+h [0-9]{2}m$'
check 6  '^SEP$'
check 7  '^(● Połączony \(.+\) od [0-9]{2}:[0-9]{2}|○ Rozłączony)$'
check 8  '^SEP$'
check 9  '^Uruchamiaj przy logowaniu$'
check 10 '^SEP$'
check 11 '^Pokaż plik z historią$'
check 12 '^Odśwież$'
check 13 '^SEP$'
check 14 '^Zakończ$'

count="$(printf '%s\n' "$menu" | grep -c .)"

if [ "$count" -ne 14 ]; then
  echo "FAIL: expected 14 menu entries, got $count"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: menu matches the recovered layout ($count entries)"
fi

exit "$fail"
