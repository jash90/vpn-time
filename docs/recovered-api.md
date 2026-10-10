# VPN Time — recovered API specification

**Status:** source of truth for recreating the app.

**Where this comes from.** The `main.swift` sources were created on 2026-07-08 in an ephemeral session
scratchpad and were deleted along with it. The specification below was recovered empirically from a
running installation on **another machine** (user `redge`):

- type names and signatures — from demangled Swift symbols (`nm -U` + `swift demangle`),
- long UI literals — from the binary's `__TEXT` section,
- short literals (≤15 bytes, stored inline as immediates) — by reading the live
  menu of the running app through System Events,
- SF Symbol names, the timer interval and AppKit constants — by decoding immediates
  from `otool -tV`.

**Note to the reader.** On the machine where the code was recreated (`bartlomiejzimny`,
2026-09-15), the original binary **does not exist**. So there is no `docs/evidence/` and no
way to take a fresh dump — this document cites the recreation plan
(`docs/superpowers/plans/2026-09-15-vpn-time-recreate.md`), not the binary.

> **Note on currency (2026-09-15):** the menu dump below describes the **original**.
> The running app has one more item — `Koniec pracy: …` ("End of work") right after
> `Uruchamiaj przy logowaniu` ("Launch at login") — added at the user's request after
> the recreation. Items 1–9 are unchanged.

---

## Recovered specification (source of truth for parity)

### Swift project structure (from symbols)

```
struct Session { let start: Date; let duration: Int }      // init(start:duration:)
enum Bucket: Hashable                                       // 3 cases: today / week / month
final class VPNStore {
    private let csvPath: String                             // ~/.vpn-sessions.csv
    private let statePath: String                           // ~/.vpn-sessions.state
    private let parser: DateFormatter                       // initialised by a closure
    func sessions() -> [Session]
    func activeSession() -> (Date, String)?
}
class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem: NSStatusItem
    private let store: VPNStore
    private var timer: Timer?
    private let calendar: Calendar
    private let agentLabel: String                          // "com.redge.vpntimebar"
    func applicationDidFinishLaunching(_: Notification)
    private func refresh()                                  // @objc
    private func rebuildMenu(sessions: [Session], active: (Date, String)?)
    private func total(_: Bucket, sessions: [Session], active: (Date, String)?) -> Int
    //   ^ contains nested: func inBucket(_ date: Date) -> Bool
    private func autostartEnabled() -> Bool
    private func toggleAutostart()                          // @objc
    private func runLaunchctl(_: [String])
    private func revealCSV()                                // @objc
    private func quit()                                     // @objc
}
let app = NSApplication.shared                              // global `app` and `delegate`
let delegate = AppDelegate()                                //   => top-level code in main.swift
```

### AppKit constants (decoded from `otool -tV`)

| Call | Value | Meaning |
|---|---|---|
| `setActivationPolicy:` | `1` | `.accessory` |
| `statusItemWithLength:` | `-1.0` | `NSStatusItem.variableLength` |
| `setImagePosition:` | `7` | `.imageLeading` |
| `scheduledTimerWithTimeInterval:repeats:block:` | `15.0`, `repeats = true` | refresh every 15 s |

### Icon and accessibility description (decoded from immediates)

| State | `systemSymbolName` | `accessibilityDescription` |
|---|---|---|
| connected | `lock.fill` | `VPN on` |
| disconnected | `lock.open` | `VPN off` |

### Status item title and tooltip

- connected title: `" %d:%02d"` with the **duration of the active session** (verified: `" 120:47"` for a session since 10.09 07:44, read on 15.09 ~08:31) — note, this is **not** today's total,
- disconnected title: empty (`""`),
- connected tooltip: `"VPN aktywny: " + config`,
- disconnected tooltip: `"VPN rozłączony"`.

### Menu — verbatim dump from the running app (15.09.2026, VPN connected)

```
[Czas na VPN]                                          enabled=false
[SEP]
[Dziś:            0h 00m]                              enabled=false
[Ten tydzień:  0h 00m]                                 enabled=false
[Ten miesiąc: 250h 48m]                                enabled=false
[SEP]
[● Połączony (Office_VPN_bartlomiej_zimny) od 07:44]   enabled=false
[SEP]
[Uruchamiaj przy logowaniu]                            enabled=true, mark=✓
[SEP]
[Pokaż plik z historią]                                enabled=true
[Odśwież]                                              enabled=true
[SEP]
[Zakończ]                                              enabled=true
```

The bucket labels are **hard-coded padded literals**, not alignment computed in code (confirmed: `'Dziś:            '` sits in the binary's string table as a single 17-character literal):

| Literal | Length | Appended value |
|---|---|---|
| `"Dziś:            "` | 17 characters (`Dziś:` + 12 spaces) | `hoursMinutes(...)` |
| `"Ten tydzień:  "` | 14 characters (`Ten tydzień:` + 2 spaces) | `hoursMinutes(...)` |
| `"Ten miesiąc: "` | 13 characters (`Ten miesiąc:` + 1 space) | `hoursMinutes(...)` |

Value format: `String(format: "%dh %02dm", h, m)`.

State line: `"● Połączony (" + config + ") od " + HH:mm(start)` or `"○ Rozłączony"`.

### Bucket semantics (verified empirically)

`inBucket` takes **one** date — a session belongs entirely to the bucket of its **start**. Evidence from the live app on 15.09.2026 (Tuesday):
- the active session has been running since 10.09 (the previous ISO week), `Dziś: 0h 00m` and `Ten tydzień: 0h 00m`, but `Ten miesiąc: 250h 48m` includes its 120h 47m,
- the CSV record `2026-09-07 07:31:22 → 2026-09-09 18:31:02` (212380 s) counts entirely toward 7 September.

**Splitting sessions at midnight is out of scope.** This is a recreation, not a redesign.

### Data format

`~/.vpn-sessions.csv` (header + rows, 70 lines as of 15.09.2026):
```
start_iso,end_iso,duration_s,config
2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
```
`~/.vpn-sessions.state` (exists only while the VPN is active): `epoch<TAB>config`.

Parser: `dateFormat = "yyyy-MM-dd HH:mm:ss"`, `locale = en_US_POSIX`, **`timeZone = .current`** — the CSV is written by `date -r` in local time; parsing in UTC would shift every session by 2 h and break the `Dziś` (today) bucket around midnight.

### Deliberate deviations from the original

1. `total(_:sessions:active:)` moves from `AppDelegate` to `VPNTimeCore` (type `Totals`) — signature and name unchanged, only its home changes, so it can be tested without AppKit.
2. `VPNStore.init` gets `csvPath:`/`statePath:` parameters with `~/...` defaults — tests point them at a temporary directory.
3. `Calendar(identifier: .iso8601)` instead of `.current` — so that a week in the app means the same as `%G-W%V` in `vpn-report.sh`.
4. Target `macos13.0` (see Global Constraints).
5. `vpn-track.sh` gets `VPN_TRACK_LOGDIR` and `VPN_TRACK_PS_CMD` — without them the script tests cannot be run.

---

