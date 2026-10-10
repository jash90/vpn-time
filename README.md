# VPN Time

English | [Polski](README.pl.md)

A macOS tracker for time spent on the VPN (Tunnelblick): a menu bar icon with a
counter for the current session and totals for today / this week / this month,
plus a terminal report.

It exists because Tunnelblick does not record cumulative time — the log of a
single connection is overwritten by the next one, and the macOS unified log
keeps only about two days. So there is nowhere to read "how many hours was I on
the VPN this month" from.

The interface is in English, or in Polish when Polish is the preferred macOS
language (System Settings → General → Language & Region).

## Architecture

Two independent parts:

- **Poller** (`vpn-track.sh`, launchd every 30 s) — the only source of raw data.
  It checks whether Tunnelblick's openvpn process is alive; on connect it writes
  `~/.vpn-sessions.state`, on disconnect it appends a row to
  `~/.vpn-sessions.csv`. Along the way it records runs of activity at the
  computer (`~/.vpn-activity.*`). It works regardless of whether the app is
  running.
- **View** (`VPN Time.app`) — reads those files every 15 s. It only writes the
  autostart plist and the history of workday starts (`~/.vpn-workdays.csv`)
  itself. Quitting the app does not stop data collection.

The core logic (`VPNTimeCore`) is separated from AppKit so it can be unit
tested; `AppDelegate` is thin and verified end-to-end.

## Components and install paths

| Item | Path |
|---|---|
| App | `~/Applications/VPN Time.app` |
| Poller | `~/.local/bin/vpn-track.sh` |
| CLI report | `~/.local/bin/vpn-report.sh` |
| Poller agent | `~/Library/LaunchAgents/com.redge.vpntrack.plist` |
| App agent | `~/Library/LaunchAgents/com.redge.vpntimebar.plist` |
| Data | `~/.vpn-sessions.csv`, `~/.vpn-sessions.state` |
| Activity | `~/.vpn-activity.csv` (closed runs), `~/.vpn-activity.state` (current) |
| Workdays | `~/.vpn-workdays.csv` (`date,start_iso,end_iso,source`) |

## Installation

```bash
./build.sh && ./install.sh
```

`install.sh` is idempotent and backs up the session data before every
replacement. After installation the app can take up to ~10 s to start —
LaunchServices assesses the freshly copied, ad-hoc signed bundle.

## Tests

```bash
./test/run-tests.sh      # Swift unit tests + tests of both bash scripts
./tools/verify-menu.sh   # running app's menu matches the specification
```

`verify-menu.sh` reads the menu through System Events, so the terminal it is run
from needs the **Accessibility** permission.

## Start of work

Below the connection state, the menu shows a line like
`Work since 08:12 (activity) · 6h 05m` (Polish: `Praca od 08:12 (aktywność) · 6h 05m`),
i.e. when the workday started and how much time has passed since. The counter is
gross time since the start; breaks are not subtracted.

How the app detects the start:

- Every 30 s the poller reads the keyboard and mouse idle time (`HIDIdleTime`).
  Activity within the last minute extends the current **activity run**. A break
  longer than **30 min** (including the Mac sleeping) closes the run and starts
  a new one.
- The start is **the beginning of the run in which today's first VPN connection
  happened**. A glance at the laptop at 7:00 does not count if the real work
  began at 8:40 and the VPN at 8:45 — the start is 8:40.
- If there has been no VPN connection yet today, the first activity run is shown
  with the suffix `(no VPN)` as a provisional start.
- The source in parentheses: `activity` (the run began before the VPN), `VPN`
  (no earlier activity), `manual`.

The **"Detect start of work"** (Polish: "Wykrywaj początek pracy") toggle in the
menu turns detection off. Then only the manual value counts, and without one the
menu shows `Work: not detected`.

## The "Work hours" form

The **"Start of work"** (Polish: "Początek pracy") and **"End of work"**
(Polish: "Koniec pracy") menu items open the settings window for **today**
(the "Work hours" form, Polish: "Czas pracy"):

- start: `Automatic` (with a preview of what was detected) or `Manual` with a
  time. A manual value applies **to that day only**; the next day the start is
  detected again;
- the detection toggle;
- end: `Off`, `At` or `After … from the start of work`;
- a live preview, e.g. `Today: 08:00 → 16:00 (8h 00m)`.

`Save` applies everything at once. If the end according to the new settings has
already passed, nothing closes immediately. Saving without changing the end rule
will not fire it a second time on the same day. `Save` also clears today's
manual end (from the workdays table or from the idle prompt), so a stopped day
runs again.

## The "Work days" window

The **"Work days…"** (Polish: "Dni pracy…") item opens a separate window with the
days from `~/.vpn-workdays.csv`, including today (the `today` row). Above the
table are the totals: `Today … · this week … · this month …`. Today counts up to
now or until it was stopped; a past day without an end counts as 0. The window
is a regular window: it stays on screen when you switch to another app.

Clicking a row loads the day for editing. Set the date, the `from` and `to`
times, then **"Save day"** (Polish: "Zapisz dzień"); picking a date that is not
in the table adds a new day. **"Remove day"** (Polish: "Usuń dzień") deletes the
row. Corrected past days get the source `edited` and the app no longer
overwrites them.

Today's row is built from the settings: the start as shown in the menu, the end
according to the end-of-work rule (e.g. start + 11 h). Saving today's row in the
table sets a manual start and end for today. Once that end passes, the work
counter in the menu stops: `Work 08:00–15:30 (manual) · 7h 30m`. Whether
Tunnelblick gets closed is still decided by the rule. Today's row cannot be
removed — use `Automatic` for that.

The history has the columns `date,start_iso,end_iso,source`; older files without
the end column are still read. On launch the app fills in missing past days:
the start according to the detection rule, the end as the end of that day's last
VPN session. Days without a VPN connection do not go into the history.
`vpn-report.sh` (day view) appends them to the row:
`2026-10-02     7h 40m   start 08:12  end 16:30`. The report prints English, or
Polish when `VPN_REPORT_LANG`, `LC_ALL`, `LC_MESSAGES` or `LANG` starts with `pl`.

## Idleness

During a VPN session, within the workday, the app reads the time since the last
keyboard or mouse use every 5 s. After **1 h** without activity it shows an
**"Are you still working?"** (Polish: "Czy nadal pracujesz?") window with a
countdown. The window floats above other windows on every desktop but does not
take focus, so you answer with a click:

- **"I'm working"** (Polish: "Pracuję") — nothing changes, that hour counts as
  work. The next prompt comes no earlier than after the next full hour of
  idleness.
- **"End work"** (Polish: "Zakończ pracę") or **no click within 5 min** — the
  workday ends at the moment the idleness began (no earlier than the start of
  work). The menu counter stops and the end goes into the history. The VPN stays
  connected. Simply returning to the computer without clicking is not an answer.

Disconnecting the VPN or the end of the day while the prompt is up hides the
window without stopping the time. Every prompt and its outcome go to
`~/Library/Logs/VPNTime.log`. A stopped day is resumed with `Save` in the
"Work hours" window.

For testing: the hidden settings `idleThresholdSeconds` and `idleGraceSeconds`
(`defaults write com.redge.vpntimebar …`) shorten both times, the
`VPNTIME_IDLE_FILE` variable supplies the idle time from a file, and
`VPNTIME_DATA_DIR` moves the data files to another folder.

## End of work

The end of work is set in the "Work hours" form. **At** is any hour and
minute. **After … from the start of work** is e.g. `08:00`, i.e. 8 h after the
detected or manually set start. When that moment arrives, the app disconnects
the VPN and quits Tunnelblick, which closes the session in the CSV.

Things worth knowing:

- Quitting fires **only during an active VPN session**. A configured time does
  nothing while the VPN is disconnected; it also will not quit Tunnelblick if
  you reconnect after the end-of-work time.
- It fires **once a day**. The date of the last firing is kept in the
  preferences, so restarting the app in the evening will not trigger the quit a
  second time.
- Choosing a time that **has already passed today** does not close anything
  immediately — the setting takes effect from the next day. The same applies to
  manually changing the start of work so that the "start + N h" deadline turns
  out to have already passed.
- In "after a duration" mode nothing fires without a known start. Once the end
  has fired on a given day, moving the start later will not fire it again.

The accuracy is ±15 s (the app's timer interval). The result of every quit
attempt goes to `~/Library/Logs/VPNTime.log`.

## Updates

At the bottom of the menu there is a `Version 1.3.0` line and a
**"Check for updates…"** (Polish: "Sprawdź aktualizacje…") item. The app asks
GitHub for the latest release (`jash90/vpn-time`, the `releases/latest`
endpoint). A manual check always ends with a dialog: "you have the latest
version", an error, or an install offer with the release notes. In addition,
once every 24 h the app checks silently; when it finds something, the item
changes to **"Install update v1.4.0…"** (Polish: "Zainstaluj aktualizację
v1.4.0…"). Nothing is installed without a click.

Installation:

1. Download `VPN-Time-<tag>.zip` from the release.
2. Compare the archive's SHA-256 with the checksum GitHub publishes for the
   file. A release without that checksum is not offered at all.
3. Unpack and verify the signature: Developer ID of team `H2X8YGN869`,
   identifier `com.redge.vpntimebar`.
4. The version in the downloaded `Info.plist` must be higher than the current
   one.
5. The app launches `update-helper.sh` (from its own bundle) and quits. The
   helper waits for it to exit, replaces the bundle (the old one is moved aside
   and restored if the replacement fails), installs `vpn-track.sh` and
   `vpn-report.sh` from the new bundle into `~/.local/bin`, reloads the poller
   agent and launches the app.

Every step goes to `~/Library/Logs/VPNTime.log`. Updating only works where the
app can write to its parent folder (`~/Applications` by default).

Releases are built, notarised and published locally with `scripts/release.sh`,
which refuses to release when the tag does not match
`CFBundleShortVersionString` in `bundle/Info.plist`. See [RELEASING.md](RELEASING.md).

## Aliases

```
alias vpntime='~/.local/bin/vpn-report.sh'
alias vpntime-week='~/.local/bin/vpn-report.sh week'
alias vpntime-month='~/.local/bin/vpn-report.sh month'
```

## Disabling

```bash
launchctl unload ~/Library/LaunchAgents/com.redge.vpntimebar.plist  # menu bar app only
launchctl unload ~/Library/LaunchAgents/com.redge.vpntrack.plist    # data collection
```

## Known limitations

- Session end accuracy is ±30 s (the polling interval). The start is exact — it
  comes from the openvpn log, not from the moment of polling.
- **A session counts entirely toward the bucket of its start.** A session that
  starts on Monday and lasts until Wednesday lands entirely on Monday, so
  "Today" (Polish: "Dziś") can show `0h 00m` despite an active VPN. This is the
  original's behaviour, frozen by tests, not a bug.
- The "since HH:mm" line shows no date, so for multi-day sessions the time alone
  can be misleading.
- Weeks are counted per ISO (starting Monday), consistent with `%G-W%V` in the
  CLI report.

## How this repo came about

The `main.swift` sources were lost on 2026-07-08 along with an ephemeral session
scratchpad. The specification was reconstructed empirically from the running
binary on another machine — demangled Swift symbols, literals from the `__TEXT`
section, a dump of the live menu via System Events, AppKit constants decoded
from `otool -tV`. The record of that investigation:
[`docs/recovered-api.md`](docs/recovered-api.md); the full recreation plan:
[`docs/superpowers/plans/`](docs/superpowers/plans/).

Five things in this repo do **not** come from the original and are deliberate
changes: the app icon (the original had none), a custom menu bar glyph instead
of the system `lock.fill` / `lock.open` symbols, the "End of work" feature, the
"Start of work" feature (four new menu items in total) and the bash scripts
themselves, which did not survive in any copy and were recreated from the
contracts frozen in the tests. Later came in-menu updates, the "Work days" window
and the idle prompt; `verify-menu.sh` now checks 22 items instead of 14.
