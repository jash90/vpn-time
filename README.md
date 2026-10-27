# VPN Time

English | [Polski](README.pl.md)

A macOS tracker for time spent on the VPN (Tunnelblick): a menu bar icon with
the running workday's time and totals for today / this week / this month,
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
  `~/.vpn-sessions.csv`. A run that comes more than 30 min after the previous
  one means the Mac slept: the session is closed when the Mac went to sleep
  and, if the VPN is still up, a new one starts at the wake. Along the way it records runs of activity at the
  computer (`~/.vpn-activity.*`). It works regardless of whether the app is
  running.
- **View** (`VPN Time.app`) — reads those files every 15 s. It only writes the
  autostart plist and the history of workdays (`~/.vpn-workdays.csv`)
  itself, plus `~/.vpn-sessions.stop` when inactivity ends the workday (see
  below). Quitting the app does not stop data collection.

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
| Workdays | `~/.vpn-workdays.csv` (`date,start_iso,end_iso,source,end_source`) |

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
- A VPN session still running from an earlier day counts as connected at
  today's first activity, so the start is not provisional.
- The source in parentheses: `activity` (the run began before the VPN), `VPN`
  (no earlier activity), `manual`.

The **"Detect start of work"** (Polish: "Wykrywaj początek pracy") switch in the
Settings window turns detection off. Then only the manual value counts, and
without one the menu shows `Work: not detected`.

## Settings

The **"Settings…"** item (Polish: "Ustawienia…", shortcut ⌘,) opens the window
with the persistent settings, in sections:

- **General**: **Launch at login** (Polish: "Uruchamiaj przy logowaniu") and
  **No-VPN mode** (below);
- **Start of work**: the **Detect start of work** switch;
- **End of work**: `Off`, `At` or `After … from the start of work`. The
  "End of work: …" item in the menu opens this window too;
- **End-of-work detection**: the **Detect end of work** switch and three times:
  **End after … without activity** (default 1 h), **Ask again every …** (default
  the same as "End after") and **Time to answer** (default 5 min).

`Save` applies everything at once. If the end according to the new settings has
already passed, nothing closes immediately. Today's manual end (from the workdays
table or from the idle prompt) is cleared only when the end rule or the start
detection changed, so a stopped day runs again then. Tuning the end detection or
launch at login does not resume a stopped day. Saving an unchanged end rule will
not fire it a second time on the same day.

### No-VPN mode

The **"No-VPN mode (work is measured from activity alone)"** switch (Polish:
"Tryb bez VPN (praca liczona z samej aktywności)") is for working without the
VPN:

- the workday starts with the first activity run of at least **15 min**, without
  the `(no VPN)` suffix and without waiting for a connection. A short glance at
  the laptop before work does not count. A VPN connection can only move the start
  earlier (when the run with the connection began earlier), never later;
- the day is ended by the inactivity question or the end rule, and past days
  without the VPN go into the history with the end at their last activity;
- a day stopped because the inactivity question went unanswered resumes after
  15 min of activity following the stop (in the normal mode, connecting the VPN
  again does that). A day ended with **"End work"** stays ended;
- the app never disconnects the VPN or quits Tunnelblick (neither after
  inactivity nor by the end rule).

Changing the mode resumes a stopped day, like changing the start detection.

## Time split: with and without the VPN

The menu totals are split into time with and without the VPN:
`Today: 7h 40m  (VPN 6h 10m · no VPN 1h 30m)`, and the same for the week and month.

- **VPN**: the connected time during the workday. A VPN left up after the day
  ended does not count;
- **no VPN**: the rest of the workday, when the VPN was not connected (work
  before connecting or after disconnecting, say);
- the first number is their sum, i.e. the period's workday time.

On a day without a recorded workday (with detection off, say, or a past day
without an end) all of that day's VPN time counts.

## The "Today" window

The **"Start of work"** menu item (Polish: "Początek pracy") opens the **"Today"**
window (Polish: "Dziś") for today's start:

- start: `Automatic` (with a preview of what was detected) or `Manual` with a
  time. A manual value applies **to that day only**; the next day the start is
  detected again;
- a live preview, e.g. `Today: 08:00 → 16:00 (8h 00m)`.

The end and the detection switches are in the Settings window. `Save` sets
today's start and always clears today's manual end (from the workdays table or
from the idle prompt), so a stopped day runs again.

## The "Work days" window

The **"Work days…"** (Polish: "Dni pracy…") item opens a separate window with the
days from `~/.vpn-workdays.csv`, including today (the `today` row). Above the
table are the totals for today / this week / this month with the same split as
the menu, and the table has the columns **VPN** and **No VPN** with each day's
split (together they make the **Duration** column). Today counts up to now or
until it was stopped; a past day without an end counts only its VPN time. The window
is a regular window: it stays on screen when you switch to another app.

Clicking a row loads the day for editing. Set the date, the `from` and `to`
times, then **"Save day"** (Polish: "Zapisz dzień"); picking a date that is not
in the table adds a new day. **"Remove day"** (Polish: "Usuń dzień") deletes the
row. Corrected past days get the source `edited` (start or end) and the app
no longer overwrites them.

Today's row is built from the settings: the start as shown in the menu, the end
according to the end-of-work rule (e.g. start + 11 h). Saving today's row in the
table sets a manual start and end for today. Once that end passes, the work
counter in the menu stops: `Work 08:00–15:30 (manual) · 7h 30m`. Whether
Tunnelblick gets closed is still decided by the rule. Today's row cannot be
removed — use `Automatic` for that.

The history has the columns `date,start_iso,end_iso,source,end_source`; older files
(without the end column or without the end source) are still read. A day's end is
detected the same way as its start: the end of that day's last VPN session,
extended by an activity run that continues after the disconnect (breaks up to
30 min). The source of the end is shown in the **End from** column: `VPN`,
`activity`, `inactivity`, `manual`, `plan` or `edited` (in the CSV: `vpn`,
`activity`, `idle`, `manual`, `planned`, `edited`). The planned end (from the
end-of-work rule) is only a guess; once the day is over, the detected end replaces
it. Missing past days are filled in at launch, once a day while the app is
running, and after saving a changed start detection in Settings — provided
**Detect start of work** is on. While a VPN session from an earlier day is still running, filling in waits
until it closes.
Days without a VPN connection do not go into the history.
`vpn-report.sh` (day view) appends them to the row:
`2026-10-02     7h 40m   start 08:12  end 16:30`. The report prints English, or
Polish when `VPN_REPORT_LANG`, `LC_ALL`, `LC_MESSAGES` or `LANG` starts with `pl`.

## End of work — detection

During the workday the app reads the time since the last keyboard or mouse use
every 5 s. When the idleness lasts as long as **End after … without activity**
(default 1 h), it shows a window **"Is this the end of work?"** (Polish: "Czy to
już koniec pracy?") with a countdown. This also works without the VPN, because
the question concerns the workday, not the connection. The window floats above
other windows on every desktop but does not take focus, so you answer with a
click:

- **"I'm working"** (Polish: "Pracuję") — nothing changes, that idleness counts as
  work. The next question comes after **Ask again every …** (by default the same as "End after"), counted
  from the answer.
- **"End work"** (Polish: "Zakończ pracę") or **no click within Time to answer**
  (default 5 min) — the workday ends at the moment the idleness began (no earlier
  than the start of work). The menu counter stops and the end goes into the
  history with the source `inactivity`. The VPN is disconnected and its session
  ends at the same moment, so the idleness does not count as VPN time either
  (the app writes `~/.vpn-sessions.stop`, which the poller applies once the VPN
  is down). The **"Disconnect the VPN when inactivity ends the day"** switch
  turns the disconnecting off. Connecting the VPN again the same day, after the
  app disconnected it, resumes the workday. Simply returning to the computer without clicking is not an answer.

A VPN session still running from an earlier day is watched as well, so working
past midnight and then walking away still ends it.

If the Mac was asleep (e.g. with the lid closed) for at least as long as **End
after**, the question appears on return with the text "No keyboard or mouse
activity from 12:10 to 14:40 (2h 30m)."

The settings are in the **Settings** window, in the "End-of-work detection"
section, with a minimum of 1 minute for each time. The **"Detect end of work"**
(Polish: "Wykrywaj koniec pracy") switch is there too. A switched-off switch
disables the question only; ends of past days are detected either way. In `defaults` these
values are stored in seconds under the keys `idleThresholdSeconds`,
`idleRepeatSeconds` and `idleGraceSeconds`.

Disconnecting the VPN does not hide the question. Only the end of the day or
turning detection off hides it, without stopping the time. Every question and its
outcome go to `~/Library/Logs/VPNTime.log`. A stopped day is resumed by `Save` in
the "Today" window, or by saving a changed end rule or start detection in Settings.
Saving only the end-detection times or launch at login leaves the day stopped.

For testing: the `VPNTIME_IDLE_FILE` variable supplies the idle time from a file,
and `VPNTIME_DATA_DIR` moves the data files to another folder.

## End of work

The end of work is set in the Settings window. **At** is any hour and
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
"Start of work" feature (with the "Settings…" window that holds its switches) and the bash scripts
themselves, which did not survive in any copy and were recreated from the
contracts frozen in the tests. Later came in-menu updates, the "Work days" window
and the idle prompt; `verify-menu.sh` now checks 21 items instead of 14.
The totals also differ from the original: only the part of a session inside
the day / week / month counts, so a connection left open overnight is split at
midnight (the original put a whole session into the bucket of its start), and
the menu bar shows the running workday's time (today's VPN total when no
workday is detected) instead of the time since the current connection started.
It stops when the workday ends (inactivity, an end set by hand, or the planned
end once it has passed); with end detection off it also stops when the VPN goes
down.
Inactivity that ends the workday also disconnects the VPN, and the poller
splits a session at a sleep. `vpn-report.sh` keeps the original rule and still counts
each finished session in the day it started.
