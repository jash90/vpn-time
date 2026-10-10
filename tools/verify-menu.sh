#!/bin/bash
# Verifies the running VPN Time menu against the recovered layout.
# Exits non-zero on any mismatch. Tolerates both VPN states.
#
# The recovery plan wanted this green on the ORIGINAL binary first. That binary
# never existed on this machine, so its first green run was the rebuilt app:
# it proves conformance to docs/recovered-api.md, not parity with the lost app.
#
# 2026-09-15: layout extended by 'Koniec pracy: …' after the autostart toggle.
# Entries 1-9 still match the recovered layout; 10 is new and 11-15 are shifted.
# 2026-10-02: 'Praca …' after the connection line, 'Początek pracy' and the
# detection toggle before 'Koniec pracy' — 18 entries. Recovered entries are
# 1-7 and 9-10 (the autostart toggle).
# 2026-10-09: version line and the update item before 'Zakończ' — 21 entries.
# 2026-10-10: 'Dni pracy…' after 'Koniec pracy', and a stopped workday shows
# 'Praca 08:00–14:05 (…)' — 22 entries.
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

# The app is localized (English default, Polish); the first line tells which
# language the running instance uses.
if [ "$(printf '%s\n' "$menu" | sed -n 1p)" = "Czas na VPN" ]; then
  check 1  '^Czas na VPN$'
  check 2  '^SEP$'
  check 3  '^Dziś:            [0-9]+h [0-9]{2}m$'
  check 4  '^Ten tydzień:  [0-9]+h [0-9]{2}m$'
  check 5  '^Ten miesiąc: [0-9]+h [0-9]{2}m$'
  check 6  '^SEP$'
  check 7  '^(● Połączony \(.+\) od [0-9]{2}:[0-9]{2}|○ Rozłączony)$'
  check 8  '^(Praca od [0-9]{2}:[0-9]{2}|Praca [0-9]{2}:[0-9]{2}–[0-9]{2}:[0-9]{2}) \((ręcznie|VPN|aktywność|bez VPN|poprawiony)\) · [0-9]+h [0-9]{2}m$|^Praca: nie wykryto$'
  check 9  '^SEP$'
  check 10 '^Uruchamiaj przy logowaniu$'
  check 11 '^Początek pracy: (auto|ręcznie [0-9]{2}:[0-9]{2})$'
  check 12 '^Wykrywaj początek pracy$'
  check 13 '^Koniec pracy: (wyłączony|[0-9]{2}:[0-9]{2}|[0-9]+h [0-9]{2}m od startu)$'
  check 14 '^Dni pracy…$'
  check 15 '^SEP$'
  check 16 '^Pokaż plik z historią$'
  check 17 '^Odśwież$'
  check 18 '^SEP$'
  check 19 '^Wersja [0-9]+(\.[0-9]+)*$'
  check 20 '^(Sprawdź aktualizacje…|Sprawdzanie aktualizacji…|Zainstaluj aktualizację v[0-9.]+…|Pobieranie aktualizacji…)$'
  check 21 '^SEP$'
  check 22 '^Zakończ$'
else
  check 1  '^VPN time$'
  check 2  '^SEP$'
  check 3  '^Today:           [0-9]+h [0-9]{2}m$'
  check 4  '^This week:     [0-9]+h [0-9]{2}m$'
  check 5  '^This month:  [0-9]+h [0-9]{2}m$'
  check 6  '^SEP$'
  check 7  '^(● Connected \(.+\) since [0-9]{2}:[0-9]{2}|○ Disconnected)$'
  check 8  '^(Work since [0-9]{2}:[0-9]{2}|Work [0-9]{2}:[0-9]{2}–[0-9]{2}:[0-9]{2}) \((manual|VPN|activity|no VPN|edited)\) · [0-9]+h [0-9]{2}m$|^Work: not detected$'
  check 9  '^SEP$'
  check 10 '^Launch at login$'
  check 11 '^Start of work: (auto|manual [0-9]{2}:[0-9]{2})$'
  check 12 '^Detect start of work$'
  check 13 '^End of work: (off|[0-9]{2}:[0-9]{2}|[0-9]+h [0-9]{2}m after start)$'
  check 14 '^Work days…$'
  check 15 '^SEP$'
  check 16 '^Show history file$'
  check 17 '^Refresh$'
  check 18 '^SEP$'
  check 19 '^Version [0-9]+(\.[0-9]+)*$'
  check 20 '^(Check for updates…|Checking for updates…|Install update v[0-9.]+…|Downloading update…)$'
  check 21 '^SEP$'
  check 22 '^Quit$'
fi

count="$(printf '%s\n' "$menu" | grep -c .)"

if [ "$count" -ne 22 ]; then
  echo "FAIL: expected 22 menu entries, got $count"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: menu matches the recovered layout ($count entries)"
fi

exit "$fail"
