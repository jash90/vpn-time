# VPN Time — source recreation and consolidation into a repo (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recreate the lost sources of the "VPN Time" menu-bar app and gather the whole VPN time tracker (Swift app + two bash scripts + two launchd agents) into a single versioned repo `~/Projects/vpn-time`, without interrupting the current installation or losing the history in the CSV.

**Architecture:** An SPM repo split into a testable core without AppKit (`VPNTimeCore`: CSV/state parsing, time buckets, formatting) and a thin UI layer (`VPNTime`: `AppDelegate` + `main.swift` on AppKit). The bash scripts get injectable dependencies (`VPN_TRACK_LOGDIR`, `VPN_TRACK_PS_CMD`) so they can be tested under `HOME=$(mktemp -d)`. The launchd plists are kept as templates (launchd does not expand `~`) and rendered by `install.sh`. Parity with the original is verified by a zero-dependency AppleScript smoke test, run **first against the old, working app** — only a test that passes on the original is trustworthy for the new binary.

**Tech Stack:** Swift 6.3 toolchain / swift-tools-version 6.0 in Swift 5 language mode, AppKit (`NSStatusItem`), XCTest, bash, launchd, `osascript`/System Events, ad-hoc `codesign`. Zero external dependencies.

**Spec:** `docs/recovered-api.md` (created in Task 1) — the record of the investigation of the binary `~/Applications/VPN Time.app/Contents/MacOS/vpntime`. The full recovered specification is also pasted below under "Recovered specification", so that this plan is self-contained.

---

## Context: why this plan exists

The `main.swift` source was created on 8 July 2026 in an ephemeral session scratchpad and was deleted along with it. Only the compiled binary survived (arm64, ad-hoc signed, no debug info). The bash scripts and launchd plists survived because they live in `~/.local/bin` and `~/Library/LaunchAgents`.

Checked and ruled out: `find`/Spotlight across the whole `$HOME`, the transcripts in `~/.claude/projects/**` (session `1010cebb-…` no longer exists), `dwarfdump` (no debug info), Time Machine (`No machine directory found for host`).

**The entire specification below was recovered empirically**, not guessed:
- type names and signatures — from demangled Swift symbols (`nm -U` + `swift demangle`),
- long UI literals — from the binary's `__TEXT` section,
- short literals (≤15 bytes, stored inline as immediates) — by reading the **live menu of the running app** through System Events,
- SF Symbol names, the timer interval and AppKit constants — by decoding immediates from `otool -tV`.

---

## Global Constraints

Every task inherits these requirements.

- **Language:** plan prose, README and ticket text in Polish; **code, code comments, branch names and commit messages in English** (global `CLAUDE.md`).
- **Code comments are very rare.** Instead of a comment — name the condition, extract a function, use a named constant. Rationale goes into the README/commit message, not inline.
- **Blank lines around `if`** — before and after an `if` block, but never directly after `{` or before `}`.
- **The `dry-js-ts` skill** applies to JS/TS; there is no JS/TS here, but its principles apply in spirit: platform before dependency, zero external libraries, types derived, not restated.
- **Zero external dependencies.** Neither in Swift (`dependencies: []`) nor in the bash tests (no `bats`).
- **Recovered names are kept verbatim:** `Session(start:duration:)`, `Bucket` (`Hashable`), `VPNStore.sessions() -> [Session]`, `VPNStore.activeSession() -> (Date, String)?`, `total(_:sessions:active:) -> Int` with a nested `inBucket(_:) -> Bool`, `AppDelegate.rebuildMenu(sessions:active:)`, `refresh()`, `toggleAutostart()`, `autostartEnabled() -> Bool`, `runLaunchctl(_: [String])`, `revealCSV()`, `quit()`, the field `agentLabel = "com.redge.vpntimebar"`, `csvPath`, `statePath`, `parser`, `statusItem`, `store`, `timer`, `calendar`.
- **UI texts in Polish, verbatim** from the list in "Recovered specification". No rewording, no punctuation fixes — even the space padding is part of the contract.
- **Platform target: macOS 13** (`platforms: [.macOS(.v13)]`, `-target arm64-apple-macos13.0`). The original declared `LSMinimumSystemVersion 13.0` in `Info.plist`, but the binary had `VersionMin 26.0` — that was an inconsistency; this plan fixes it deliberately.
- **Swift 5 language mode** (`swiftLanguageModes: [.v5]` with `swift-tools-version: 6.0`). The original was built with bare `swiftc` in the default mode; enabling mode 6 would drag `NSStatusItem` and the `Timer` closure into strict concurrency, which is pure wasted time for a recreation.
- **Signing:** ad-hoc, `codesign --force --deep -s - <bundle>`; `CFBundleIdentifier = com.redge.vpntimebar`, `CFBundleExecutable = vpntime`.
- **Untouchable:** the file `~/.vpn-sessions.csv` and the agent `com.redge.vpntrack`. Data collection must not stop or lose a record at any stage.
- **Commits:** frequent, one commit per task (or per step when a task is long); format `feat:` / `fix:` / `test:` / `docs:` / `chore:`.

---

## Recovered specification (source of truth for parity)

### Swift project structure (from symbols)

```
struct Session { let start: Date; let duration: Int }      // init(start:duration:)
enum Bucket: Hashable                                       // 3 cases: today / week / month
final class VPNStore {
    private let csvPath: String                             // ~/.vpn-sessions.csv
    private let statePath: String                           // ~/.vpn-sessions.state
    private let parser: DateFormatter                       // initialized with a closure
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
    //   ^ contains a nested: func inBucket(_ date: Date) -> Bool
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
| `"Dziś:            "` (Today) | 17 characters (`Dziś:` + 12 spaces) | `hoursMinutes(...)` |
| `"Ten tydzień:  "` (This week) | 14 characters (`Ten tydzień:` + 2 spaces) | `hoursMinutes(...)` |
| `"Ten miesiąc: "` (This month) | 13 characters (`Ten miesiąc:` + 1 space) | `hoursMinutes(...)` |

Value format: `String(format: "%dh %02dm", h, m)`.

Status row: `"● Połączony (" + config + ") od " + HH:mm(start)` ("Connected (…) since") or `"○ Rozłączony"` (Disconnected).

### Bucket semantics (verified empirically)

`inBucket` takes **a single** date — a session belongs entirely to the bucket of its **start**. Evidence from the live app on 15.09.2026 (Tuesday):
- the active session has been running since 10.09 (previous ISO week), `Dziś: 0h 00m` and `Ten tydzień: 0h 00m`, but `Ten miesiąc: 250h 48m` includes its 120h 47m,
- the CSV record `2026-09-07 07:31:22 → 2026-09-09 18:31:02` (212380 s) counts entirely towards 7 September.

**Splitting sessions at midnight is out of scope.** This is a recreation, not a redesign.

### Data format

`~/.vpn-sessions.csv` (header + rows, 70 lines as of 15.09.2026):
```
start_iso,end_iso,duration_s,config
2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
```
`~/.vpn-sessions.state` (exists only while the VPN is active): `epoch<TAB>config`.

Parser: `dateFormat = "yyyy-MM-dd HH:mm:ss"`, `locale = en_US_POSIX`, **`timeZone = .current`** — the CSV is written by `date -r` in local time; parsing in UTC would shift every session by 2 h and throw the `Dziś` (Today) bucket off around midnight.

### Deliberate deviations from the original

1. `total(_:sessions:active:)` moves from `AppDelegate` to `VPNTimeCore` (type `Totals`) — signature and name unchanged, only its home changes, so it can be tested without AppKit.
2. `VPNStore.init` gets `csvPath:`/`statePath:` parameters with `~/...` defaults — tests target a temporary directory.
3. `Calendar(identifier: .iso8601)` instead of `.current` — so that a week in the app means the same as `%G-W%V` in `vpn-report.sh`.
4. Target `macos13.0` (see Global Constraints).
5. `vpn-track.sh` gets `VPN_TRACK_LOGDIR` and `VPN_TRACK_PS_CMD` — without them the script tests cannot be run.

---

## File Structure

```
~/Projects/vpn-time/
├── .gitignore                          # .build/, build/, *.bak-*
├── README.md                           # architecture, installation, investigation history
├── Package.swift                       # SPM: VPNTimeCore (lib) + VPNTime (exe)
├── Sources/
│   ├── VPNTimeCore/
│   │   ├── Session.swift               # struct Session
│   │   ├── Bucket.swift                # enum Bucket + Calendar.vpnTimeISO
│   │   ├── VPNStore.swift              # reads the CSV + state file
│   │   ├── Totals.swift                # total(_:sessions:active:) + inBucket
│   │   └── TimeFormat.swift            # hoursMinutes(_:) and counter(_:)
│   └── VPNTime/
│       ├── AppDelegate.swift           # NSStatusItem, menu, timer, autostart
│       └── main.swift                  # global app/delegate, NSApp.run()
├── Tests/
│   └── VPNTimeCoreTests/
│       ├── VPNStoreTests.swift
│       ├── TotalsTests.swift
│       └── TimeFormatTests.swift
├── scripts/
│   ├── vpn-track.sh                    # poller (with injectable LOGDIR/PS_CMD)
│   └── vpn-report.sh                   # CLI report
├── test/
│   ├── run-tests.sh                    # runs both of the below
│   ├── test-vpn-track.sh
│   └── test-vpn-report.sh
├── launchd/
│   ├── com.redge.vpntrack.plist.template
│   └── com.redge.vpntimebar.plist.template
├── bundle/
│   └── Info.plist
├── tools/
│   └── verify-menu.sh                  # menu parity smoke test via System Events
├── build.sh                            # swift build + .app assembly + codesign
├── install.sh                          # backup, deploy, launchctl
└── docs/
    ├── recovered-api.md                # forensic spec (Task 1)
    ├── evidence/
    │   ├── menu-2026-09-15.txt
    │   ├── symbols-2026-09-15.txt
    │   └── strings-2026-09-15.txt
    └── superpowers/plans/2026-09-15-vpn-time-recreate.md
```

The `VPNTimeCore` / `VPNTime` split is driven by testability: SPM does not test executable targets in any meaningful way, and all the valuable logic (parsing, buckets, formatting) does not need AppKit. `AppDelegate` stays thin and is verified end-to-end by `verify-menu.sh`.

---

## Task 1: Repo, forensic evidence and data backup

First we persist what has been recovered. The source was lost once because of an ephemeral location — the first commit is meant to make sure that does not happen again.

**Files:**
- Create: `~/Projects/vpn-time/.gitignore`
- Create: `~/Projects/vpn-time/docs/recovered-api.md`
- Create: `~/Projects/vpn-time/docs/evidence/menu-2026-09-15.txt`
- Create: `~/Projects/vpn-time/docs/evidence/symbols-2026-09-15.txt`
- Create: `~/Projects/vpn-time/docs/evidence/strings-2026-09-15.txt`
- Already present: `docs/superpowers/plans/2026-09-15-vpn-time-recreate.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a git repo with a `main` branch; `docs/recovered-api.md` as the spec for Tasks 2–8.

- [ ] **Step 1: Secure the production data (before anything else)**

```bash
cp ~/.vpn-sessions.csv ~/.vpn-sessions.csv.bak-2026-09-15
cp ~/.vpn-sessions.state ~/.vpn-sessions.state.bak-2026-09-15 2>/dev/null || true
ls -la ~/.vpn-sessions.csv.bak-2026-09-15
```

Expected: the backup file exists and has the same size as the original.

- [ ] **Step 2: Initialize the repo**

```bash
cd ~/Projects/vpn-time
git init -b main
printf '%s\n' '.build/' 'build/' '*.bak-*' '.DS_Store' > .gitignore
```

- [ ] **Step 3: Dump the evidence from the binary into `docs/evidence/`**

```bash
cd ~/Projects/vpn-time
B="$HOME/Applications/VPN Time.app/Contents/MacOS/vpntime"

nm -U "$B" | awk '{print $3}' | grep '^_\$s7vpntime' | sed 's/^_//' \
  | xargs -n1 swift demangle \
  | grep -vE 'type metadata|value witness|witness table|field offset|reflection|method descriptor|nominal type|outlined|protocol conformance|module descriptor|metadata accessor' \
  | sort -u > docs/evidence/symbols-2026-09-15.txt

strings -a "$B" | sort -u > docs/evidence/strings-2026-09-15.txt

wc -l docs/evidence/symbols-2026-09-15.txt docs/evidence/strings-2026-09-15.txt
```

Expected: `symbols-…txt` contains, among others, `vpntime.VPNStore.activeSession() -> (Foundation.Date, Swift.String)?`.

- [ ] **Step 4: Dump the live menu of the old app (while it still works)**

```bash
cd ~/Projects/vpn-time
osascript -e 'tell application "System Events" to tell process "vpntime"
  set mb to menu bar item 1 of menu bar 1
  set out to "AXTitle=[" & (value of attribute "AXTitle" of mb) & "]" & linefeed
  set out to out & "AXDescription=[" & (value of attribute "AXDescription" of mb) & "]" & linefeed
  set out to out & "AXHelp=[" & (value of attribute "AXHelp" of mb) & "]" & linefeed
  repeat with mi in (every menu item of menu 1 of mb)
    set nm to name of mi
    if nm is missing value then
      set out to out & "[SEP]" & linefeed
    else
      set out to out & "[" & nm & "]|enabled=" & (enabled of mi) & "|mark=" & (value of attribute "AXMenuItemMarkChar" of mi) & linefeed
    end if
  end repeat
  return out
end tell' > docs/evidence/menu-2026-09-15.txt
cat docs/evidence/menu-2026-09-15.txt
```

Expected: 14 menu entries, starting with `[Czas na VPN]` (Time on VPN).

If `osascript` returns `-1719` or a permission error: in System Settings → Privacy & Security → Accessibility, add the terminal/Claude Code. Without it, Tasks 2 and 12 have no way to verify parity.

- [ ] **Step 5: Write `docs/recovered-api.md`**

Copy the "Recovered specification" section of this plan into it in full (the tables of constants, icons, menu, bucket semantics, data format, deviations) and add a header describing the recovery method and the date. This is the spec — Tasks 2–8 refer to it.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/vpn-time
git add -A
git commit -m "docs: recover VPN Time app spec from compiled binary and live menu

Source main.swift was lost with an ephemeral scratchpad on 2026-07-08.
Recovered the API surface from demangled Swift symbols, the long UI
literals from the __TEXT string table, the short inline literals by
reading the running app's menu via System Events, and the SF Symbol
names, timer interval and AppKit constants by decoding immediates."
```

---

## Task 2: Menu parity smoke test, validated on the original

This test is written **before** any new code appears, and it must pass on the **old** binary. A test that has never gone green on a known-good system proves nothing.

**Files:**
- Create: `~/Projects/vpn-time/tools/verify-menu.sh`

**Interfaces:**
- Consumes: `docs/evidence/menu-2026-09-15.txt` (reference shape).
- Produces: `tools/verify-menu.sh` — used in Task 12 (cutover) as the acceptance gate.

- [ ] **Step 1: Write `tools/verify-menu.sh`**

```bash
#!/bin/bash
# Verifies the running VPN Time menu against the recovered layout.
# Exits non-zero on any mismatch. Tolerates both VPN states.
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
```

- [ ] **Step 2: Run it against the OLD, working app**

```bash
chmod +x ~/Projects/vpn-time/tools/verify-menu.sh
~/Projects/vpn-time/tools/verify-menu.sh
```

Expected: `OK: menu matches the recovered layout (14 entries)`.

If the test does not pass on the original — **fix the test, not the original.** The patterns must describe reality, not wishes.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/vpn-time
git add tools/verify-menu.sh
git commit -m "test: add menu parity smoke test, validated against the original binary"
```

---

## Task 3: SPM skeleton + `Session` and `Bucket`

**Files:**
- Create: `~/Projects/vpn-time/Package.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Session.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Bucket.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TotalsTests.swift` (only the calendar test for now)

**Interfaces:**
- Consumes: the spec from Task 1.
- Produces: `Session(start: Date, duration: Int)` with `start`/`duration` fields; `enum Bucket: Hashable { case today, week, month }`; `Calendar.vpnTimeISO`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPNTime",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VPNTimeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "VPNTime",
            dependencies: ["VPNTimeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VPNTimeCoreTests",
            dependencies: ["VPNTimeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write the calendar test (red first)**

File `Tests/VPNTimeCoreTests/TotalsTests.swift`:

```swift
import XCTest
@testable import VPNTimeCore

final class TotalsTests: XCTestCase {
    func testISOCalendarStartsWeekOnMonday() {
        let calendar = Calendar.vpnTimeISO
        XCTAssertEqual(calendar.firstWeekday, 2)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)
    }
}
```

- [ ] **Step 3: Run the test and confirm it does not compile**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: a compilation error — `cannot find 'Calendar.vpnTimeISO'` / missing module.

- [ ] **Step 4: Write `Sources/VPNTimeCore/Session.swift`**

```swift
import Foundation

public struct Session {
    public let start: Date
    public let duration: Int

    public init(start: Date, duration: Int) {
        self.start = start
        self.duration = duration
    }
}
```

- [ ] **Step 5: Write `Sources/VPNTimeCore/Bucket.swift`**

```swift
import Foundation

public enum Bucket: Hashable {
    case today
    case week
    case month
}

public extension Calendar {
    static var vpnTimeISO: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }
}
```

- [ ] **Step 6: Run the test and confirm it passes**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/vpn-time
git add Package.swift Sources/VPNTimeCore Tests
git commit -m "feat: add SPM skeleton with Session and Bucket"
```

---

## Task 4: `VPNStore` — CSV parsing

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/VPNStore.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/VPNStoreTests.swift`

**Interfaces:**
- Consumes: `Session` from Task 3.
- Produces: `VPNStore(csvPath:statePath:)`, `sessions() -> [Session]`, `activeSession() -> (Date, String)?`.

- [ ] **Step 1: Write the CSV parsing tests (red first)**

File `Tests/VPNTimeCoreTests/VPNStoreTests.swift`:

```swift
import XCTest
@testable import VPNTimeCore

final class VPNStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(csv: String? = nil, state: String? = nil) throws -> VPNStore {
        let csvURL = dir.appendingPathComponent("sessions.csv")
        let stateURL = dir.appendingPathComponent("sessions.state")

        if let csv {
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        }

        if let state {
            try state.write(to: stateURL, atomically: true, encoding: .utf8)
        }

        return VPNStore(csvPath: csvURL.path, statePath: stateURL.path)
    }

    func testParsesRowsAndSkipsHeader() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
        2026-07-08 07:43:15,2026-07-08 16:26:34,31399,Office_VPN_bartlomiej_zimny
        """
        let sessions = try store(csv: csv).sessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].duration, 839)
        XCTAssertEqual(sessions[1].duration, 31399)
    }

    func testParsesStartInLocalTime() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
        """
        let sessions = try store(csv: csv).sessions()

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 8
        components.hour = 7
        components.minute = 27
        components.second = 37
        components.timeZone = .current
        let expected = Calendar.vpnTimeISO.date(from: components)

        XCTAssertEqual(sessions[0].start, expected)
    }

    func testSkipsMalformedRows() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        not-a-date,2026-07-08 07:41:36,839,Office
        2026-07-08 07:43:15,2026-07-08 16:26:34,notanumber,Office
        2026-07-08 07:43:15,2026-07-08 16:26:34,31399,Office
        """
        XCTAssertEqual(try store(csv: csv).sessions().count, 1)
    }

    func testMissingCSVYieldsNoSessions() throws {
        XCTAssertTrue(try store().sessions().isEmpty)
    }
}
```

`Session` is deliberately not `Equatable` (the original was not either), which is why an empty result is checked with `isEmpty` rather than by comparing with `[]`.

- [ ] **Step 2: Run the tests and confirm they do not compile**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `cannot find 'VPNStore' in scope`.

- [ ] **Step 3: Write `Sources/VPNTimeCore/VPNStore.swift`**

```swift
import Foundation

public final class VPNStore {
    private let csvPath: String
    private let statePath: String

    private let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    public init(
        csvPath: String = NSString(string: "~/.vpn-sessions.csv").expandingTildeInPath,
        statePath: String = NSString(string: "~/.vpn-sessions.state").expandingTildeInPath
    ) {
        self.csvPath = csvPath
        self.statePath = statePath
    }

    public func sessions() -> [Session] {
        guard let raw = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
            return []
        }

        return raw
            .split(separator: "\n")
            .dropFirst()
            .compactMap(session(from:))
    }

    public func activeSession() -> (Date, String)? {
        guard let raw = try? String(contentsOfFile: statePath, encoding: .utf8) else {
            return nil
        }

        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")

        guard fields.count >= 2, let epoch = TimeInterval(fields[0]) else {
            return nil
        }

        return (Date(timeIntervalSince1970: epoch), String(fields[1]))
    }

    private func session(from line: Substring) -> Session? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)

        guard fields.count >= 3,
              let start = parser.date(from: String(fields[0])),
              let duration = Int(fields[2]) else {
            return nil
        }

        return Session(start: start, duration: duration)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/VPNStore.swift Tests/VPNTimeCoreTests/VPNStoreTests.swift
git commit -m "feat: parse the session CSV in VPNStore"
```

---

## Task 5: `VPNStore.activeSession()` — state file

**Files:**
- Modify: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/VPNStoreTests.swift`

**Interfaces:**
- Consumes: `VPNStore` from Task 4 (the `activeSession()` implementation is already there).
- Produces: a confirmed `(Date, String)?` contract.

- [ ] **Step 1: Add the state file tests**

Add to `VPNStoreTests`:

```swift
    func testReadsActiveSessionFromStateFile() throws {
        let subject = try store(state: "1789019070\tOffice_VPN_bartlomiej_zimny\n")
        let active = subject.activeSession()

        XCTAssertEqual(active?.0, Date(timeIntervalSince1970: 1789019070))
        XCTAssertEqual(active?.1, "Office_VPN_bartlomiej_zimny")
    }

    func testNoActiveSessionWhenStateFileMissing() throws {
        XCTAssertNil(try store().activeSession())
    }

    func testNoActiveSessionWhenStateFileMalformed() throws {
        XCTAssertNil(try store(state: "garbage\n").activeSession())
    }
```

- [ ] **Step 2: Run the tests**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `Executed 8 tests, with 0 failures`. If any of them fails — we fix `activeSession()`, not the test.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/vpn-time
git add Tests/VPNTimeCoreTests/VPNStoreTests.swift
git commit -m "test: cover the active-session state file contract"
```

---

## Task 6: `Totals` — summing per bucket

The most important task in terms of parity. The "a session belongs to the bucket of its start" semantics is non-obvious and was confirmed on the live system — the tests must freeze it.

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Totals.swift`
- Modify: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TotalsTests.swift`

**Interfaces:**
- Consumes: `Session`, `Bucket`, `Calendar.vpnTimeISO`.
- Produces: `Totals(calendar:now:)` and `total(_ bucket: Bucket, sessions: [Session], active: (Date, String)?) -> Int`.

- [ ] **Step 1: Add the bucket tests (red first)**

Add to `TotalsTests`:

```swift
    private let calendar = Calendar.vpnTimeISO

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    func testMultiDaySessionCountsWhollyIntoItsStartDay() {
        let now = date("2026-09-09 20:00:00")
        let totals = Totals(calendar: calendar, now: now)
        let sessions = [Session(start: date("2026-09-07 07:31:22"), duration: 212380)]

        XCTAssertEqual(totals.total(.today, sessions: sessions, active: nil), 0)
        XCTAssertEqual(totals.total(.week, sessions: sessions, active: nil), 212380)
    }

    func testActiveSessionCountsIntoTheBucketOfItsStart() {
        let now = date("2026-09-15 08:31:30")
        let start = date("2026-09-10 07:44:00")
        let totals = Totals(calendar: calendar, now: now)
        let active = (start, "Office_VPN_bartlomiej_zimny")

        XCTAssertEqual(totals.total(.today, sessions: [], active: active), 0)
        XCTAssertEqual(totals.total(.week, sessions: [], active: active), 0)
        XCTAssertEqual(
            totals.total(.month, sessions: [], active: active),
            Int(now.timeIntervalSince(start))
        )
    }

    func testTodayBucketSumsFinishedSessionsStartedToday() {
        let now = date("2026-09-15 18:00:00")
        let totals = Totals(calendar: calendar, now: now)
        let sessions = [
            Session(start: date("2026-09-15 08:00:00"), duration: 3600),
            Session(start: date("2026-09-15 10:00:00"), duration: 1800),
            Session(start: date("2026-09-14 10:00:00"), duration: 9999),
        ]

        XCTAssertEqual(totals.total(.today, sessions: sessions, active: nil), 5400)
    }

    func testWeekBucketUsesISOWeekSoSundayBelongsToTheWeekThatStartedMonday() {
        let totals = Totals(calendar: calendar, now: date("2026-09-20 12:00:00"))
        let sessions = [Session(start: date("2026-09-14 09:00:00"), duration: 600)]

        XCTAssertEqual(totals.total(.week, sessions: sessions, active: nil), 600)
    }
```

- [ ] **Step 2: Run the tests and confirm they do not compile**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `cannot find 'Totals' in scope`.

- [ ] **Step 3: Write `Sources/VPNTimeCore/Totals.swift`**

```swift
import Foundation

public struct Totals {
    private let calendar: Calendar
    private let now: Date

    public init(calendar: Calendar = .vpnTimeISO, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    public func total(_ bucket: Bucket, sessions: [Session], active: (Date, String)?) -> Int {
        func inBucket(_ date: Date) -> Bool {
            switch bucket {
            case .today:
                return calendar.isDate(date, inSameDayAs: now)
            case .week:
                return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .month:
                return calendar.isDate(date, equalTo: now, toGranularity: .month)
            }
        }

        var seconds = sessions
            .filter { inBucket($0.start) }
            .reduce(0) { $0 + $1.duration }

        if let active, inBucket(active.0) {
            seconds += Int(now.timeIntervalSince(active.0))
        }

        return seconds
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/Totals.swift Tests/VPNTimeCoreTests/TotalsTests.swift
git commit -m "feat: bucket session totals by the day the session started"
```

---

## Task 7: Time formatting

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/TimeFormat.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TimeFormatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `hoursMinutes(_ seconds: Int) -> String` ("`250h 48m`"), `counter(_ seconds: Int) -> String` ("` 120:47`", with a leading space).

- [ ] **Step 1: Write the tests (red first)**

File `Tests/VPNTimeCoreTests/TimeFormatTests.swift`:

```swift
import XCTest
@testable import VPNTimeCore

final class TimeFormatTests: XCTestCase {
    func testHoursMinutesPadsMinutesToTwoDigits() {
        XCTAssertEqual(hoursMinutes(0), "0h 00m")
        XCTAssertEqual(hoursMinutes(5400), "1h 30m")
        XCTAssertEqual(hoursMinutes(902880), "250h 48m")
    }

    func testHoursMinutesTruncatesSeconds() {
        XCTAssertEqual(hoursMinutes(59), "0h 00m")
        XCTAssertEqual(hoursMinutes(3659), "1h 00m")
    }

    func testCounterKeepsTheLeadingSpaceThatSeparatesItFromTheIcon() {
        XCTAssertEqual(counter(434820), " 120:47")
        XCTAssertEqual(counter(0), " 0:00")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they do not compile**

```bash
cd ~/Projects/vpn-time && swift test --filter TimeFormatTests 2>&1 | tail -20
```

Expected: `cannot find 'hoursMinutes' in scope`.

- [ ] **Step 3: Write `Sources/VPNTimeCore/TimeFormat.swift`**

```swift
import Foundation

public func hoursMinutes(_ seconds: Int) -> String {
    String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
}

public func counter(_ seconds: Int) -> String {
    String(format: " %d:%02d", seconds / 3600, (seconds % 3600) / 60)
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/TimeFormat.swift Tests/VPNTimeCoreTests/TimeFormatTests.swift
git commit -m "feat: format bucket totals and the status bar counter"
```

---

## Task 8: `AppDelegate` and `main.swift`

The AppKit layer. There are no unit tests here — verification is `tools/verify-menu.sh` in Task 12.

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTime/AppDelegate.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTime/main.swift`

**Interfaces:**
- Consumes: `VPNStore`, `Totals`, `Bucket`, `hoursMinutes(_:)`, `counter(_:)`.
- Produces: the executable target `VPNTime` (binary `.build/release/VPNTime`).

- [ ] **Step 1: Write `Sources/VPNTime/AppDelegate.swift`**

```swift
import AppKit
import VPNTimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = VPNStore()
    private let calendar = Calendar.vpnTimeISO
    private let agentLabel = "com.redge.vpntimebar"
    private var timer: Timer?

    private var agentPath: String {
        NSString(string: "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath
    }

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        let sessions = store.sessions()
        let active = store.activeSession()

        if let active {
            statusItem.button?.image = NSImage(
                systemSymbolName: "lock.fill",
                accessibilityDescription: "VPN on"
            )
            statusItem.button?.title = counter(Int(Date().timeIntervalSince(active.0)))
            statusItem.button?.toolTip = "VPN aktywny: \(active.1)"
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "lock.open",
                accessibilityDescription: "VPN off"
            )
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "VPN rozłączony"
        }

        rebuildMenu(sessions: sessions, active: active)
    }

    private func rebuildMenu(sessions: [Session], active: (Date, String)?) {
        let totals = Totals(calendar: calendar, now: Date())
        let menu = NSMenu()

        menu.addItem(disabled("Czas na VPN"))
        menu.addItem(.separator())
        menu.addItem(disabled("Dziś:            " + hoursMinutes(totals.total(.today, sessions: sessions, active: active))))
        menu.addItem(disabled("Ten tydzień:  " + hoursMinutes(totals.total(.week, sessions: sessions, active: active))))
        menu.addItem(disabled("Ten miesiąc: " + hoursMinutes(totals.total(.month, sessions: sessions, active: active))))
        menu.addItem(.separator())

        if let active {
            menu.addItem(disabled("● Połączony (\(active.1)) od \(clock.string(from: active.0))"))
        } else {
            menu.addItem(disabled("○ Rozłączony"))
        }

        menu.addItem(.separator())

        let autostart = NSMenuItem(
            title: "Uruchamiaj przy logowaniu",
            action: #selector(toggleAutostart),
            keyEquivalent: ""
        )
        autostart.target = self
        autostart.state = autostartEnabled() ? .on : .off
        menu.addItem(autostart)

        menu.addItem(.separator())
        menu.addItem(action("Pokaż plik z historią", #selector(revealCSV)))
        menu.addItem(action("Odśwież", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(action("Zakończ", #selector(quit)))

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func autostartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPath)
    }

    @objc private func toggleAutostart() {
        if autostartEnabled() {
            runLaunchctl(["unload", agentPath])
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(agentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>\(Bundle.main.bundlePath)</string>
                </array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: agentPath, atomically: true, encoding: .utf8)
            runLaunchctl(["load", agentPath])
        }

        refresh()
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
    }

    @objc private func revealCSV() {
        let path = NSString(string: "~/.vpn-sessions.csv").expandingTildeInPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

Note on `ProgramArguments`: the path comes from `Bundle.main.bundlePath`, not from a literal — the app may live somewhere other than `~/Applications`, and a launchd plist does not expand `~`.

- [ ] **Step 2: Write `Sources/VPNTime/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Build and confirm it compiles**

```bash
cd ~/Projects/vpn-time && swift build -c release 2>&1 | tail -20
ls -la .build/release/VPNTime
```

Expected: the build has no errors, the binary exists.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTime
git commit -m "feat: rebuild the status bar UI on top of VPNTimeCore"
```

---

## Task 9: `Info.plist`, `build.sh` and bundle assembly

**Files:**
- Create: `~/Projects/vpn-time/bundle/Info.plist`
- Create: `~/Projects/vpn-time/build.sh`

**Interfaces:**
- Consumes: the `VPNTime` target from Task 8.
- Produces: `build/VPN Time.app` — a complete, ad-hoc signed bundle; used by `install.sh` in Task 11.

- [ ] **Step 1: Write `bundle/Info.plist` (a copy of the original, unchanged)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VPN Time</string>
    <key>CFBundleDisplayName</key>
    <string>VPN Time</string>
    <key>CFBundleIdentifier</key>
    <string>com.redge.vpntimebar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>vpntime</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Write `build.sh`**

```bash
#!/bin/bash
# Builds the release binary and assembles the ad-hoc signed .app bundle in build/.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/VPN Time.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp .build/release/VPNTime "$APP/Contents/MacOS/vpntime"

codesign --force --deep -s - "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|flags'

echo "built: $APP"
```

- [ ] **Step 3: Build and verify the bundle**

```bash
chmod +x ~/Projects/vpn-time/build.sh
~/Projects/vpn-time/build.sh
```

Expected: `Identifier=com.redge.vpntimebar`, `flags=0x2(adhoc)`, `built: build/VPN Time.app`.

- [ ] **Step 4: Smoke test without touching the production installation**

Run **the binary directly**, not via `open` — `open` on the same bundle id only activates the old instance instead of starting a new one. Remember the PID: `kill %1` will not work, because the plan executor's shell has no job control.

```bash
OLD_PID="$(pgrep -x vpntime | head -1)"
"$HOME/Projects/vpn-time/build/VPN Time.app/Contents/MacOS/vpntime" &
NEW_PID=$!
sleep 3
pgrep -x vpntime | wc -l
echo "old=$OLD_PID new=$NEW_PID"
```

Expected: `2` (two padlocks in the menu bar).

**Do not click "Uruchamiaj przy logowaniu" (Launch at login) during this test** — `Bundle.main.bundlePath` would then write a plist pointing at `build/` instead of the installed app.

Compare the menus of both instances automatically instead of eyeballing them. With two processes of the same name, `process "vpntime"` is ambiguous, so we address them by PID:

```bash
read_menu_of() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
    set mb to menu bar item 1 of menu bar 1
    set out to \"\"
    repeat with mi in (every menu item of menu 1 of mb)
      set nm to name of mi
      if nm is missing value then
        set out to out & \"SEP\" & linefeed
      else
        set out to out & nm & linefeed
      end if
    end repeat
    return out
  end tell"
}

diff <(read_menu_of "$OLD_PID") <(read_menu_of "$NEW_PID") && echo "PARITY OK"
```

Expected: `PARITY OK`. The only acceptable difference is the minute counter in the buckets when a full minute ticked over between the two reads — in that case repeat the `diff`.

Kill **only** the new instance:

```bash
kill "$NEW_PID"
sleep 1
pgrep -x vpntime | wc -l
```

Expected: `1`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add bundle build.sh
git commit -m "build: assemble and ad-hoc sign the app bundle"
```

---

## Task 10: Bash scripts into the repo + their tests

**Files:**
- Create: `~/Projects/vpn-time/scripts/vpn-track.sh` (from `~/.local/bin/vpn-track.sh` + injectable dependencies)
- Create: `~/Projects/vpn-time/scripts/vpn-report.sh` (a 1:1 copy of `~/.local/bin/vpn-report.sh`)
- Create: `~/Projects/vpn-time/test/test-vpn-track.sh`
- Create: `~/Projects/vpn-time/test/test-vpn-report.sh`
- Create: `~/Projects/vpn-time/test/run-tests.sh`

**Interfaces:**
- Consumes: nothing from Swift.
- Produces: scripts installed by `install.sh` into `~/.local/bin/`.

- [ ] **Step 1: Copy the scripts into the repo unchanged and commit them as a baseline**

```bash
cd ~/Projects/vpn-time
mkdir -p scripts test
cp ~/.local/bin/vpn-track.sh scripts/vpn-track.sh
cp ~/.local/bin/vpn-report.sh scripts/vpn-report.sh
chmod +x scripts/*.sh
git add scripts
git commit -m "chore: vendor the tracker shell scripts verbatim"
```

The separate commit matters: the next diff shows exactly what changed relative to the working original.

- [ ] **Step 2: Write the `vpn-report.sh` test (red first — the file does not exist yet)**

File `test/test-vpn-report.sh`:

```bash
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
```

The arithmetic behind these values (seconds truncated down, `%-14s` provides the gap between columns): 839 + 31399 = 32238 s = 8 h 57 m 18 s → `8h 57m`; 3600 s → `1h 00m`; 32238 + 3600 = 35838 s = 9 h 57 m 18 s → `9h 57m`.

- [ ] **Step 3: Run the `vpn-report.sh` test and confirm it passes**

```bash
chmod +x ~/Projects/vpn-time/test/test-vpn-report.sh
~/Projects/vpn-time/test/test-vpn-report.sh
```

Expected: only `ok:` lines, exit code 0. `vpn-report.sh` needed no changes — it reads only `$HOME`.

- [ ] **Step 4: Add injectable dependencies to `scripts/vpn-track.sh`**

Change exactly two lines:

```bash
LOGDIR="${VPN_TRACK_LOGDIR:-/Library/Application Support/Tunnelblick/Logs}"
```

and

```bash
running_cmd="$(${VPN_TRACK_PS_CMD:-ps -axww -o command=} | grep 'Tunnelblick.app/Contents/Resources/openvpn' | grep -v grep | head -1)"
```

The rest of the script stays unchanged.

- [ ] **Step 5: Write the `vpn-track.sh` test**

File `test/test-vpn-track.sh`:

```bash
#!/bin/bash
# Tests vpn-track.sh state transitions with a faked ps and Tunnelblick log dir.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"

  if [ "$actual" = "$expected" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label — expected [$expected], got [$actual]"
    fail=1
  fi
}

setup() {
  HOME="$(mktemp -d)"
  export HOME
  VPN_TRACK_LOGDIR="$HOME/logs"
  export VPN_TRACK_LOGDIR
  mkdir -p "$VPN_TRACK_LOGDIR"
}

fake_connected() {
  export VPN_TRACK_PS_CMD="echo /Applications/Tunnelblick.app/Contents/Resources/openvpn --config /Library/Application Support/Tunnelblick/Shared/Office_VPN.tblk/Contents/Resources/config.ovpn"
}

fake_disconnected() {
  export VPN_TRACK_PS_CMD="true"
}

echo "connecting writes the state file"
setup
fake_connected
printf '%s Mon Jul  8 07:27:37 2026 OpenVPN starting\n' "$(( $(date +%s) - 3600 ))" \
  > "$VPN_TRACK_LOGDIR/a.openvpn.log"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.state" ] && echo yes || echo no)" "yes" "state file created"
assert_eq "$(cut -f2 "$HOME/.vpn-sessions.state")" "Office_VPN" "config name parsed from the tblk path"
assert_eq "$([ -f "$HOME/.vpn-sessions.csv" ] && echo yes || echo no)" "no" "no CSV row while still connected"

echo "staying connected does not duplicate the state"
before="$(cat "$HOME/.vpn-sessions.state")"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(cat "$HOME/.vpn-sessions.state")" "$before" "state file untouched"

echo "disconnecting appends a CSV row and clears the state"
fake_disconnected
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$([ -f "$HOME/.vpn-sessions.state" ] && echo yes || echo no)" "no" "state file removed"
assert_eq "$(head -1 "$HOME/.vpn-sessions.csv")" "start_iso,end_iso,duration_s,config" "CSV header written"
assert_eq "$(wc -l < "$HOME/.vpn-sessions.csv" | tr -d ' ')" "2" "one data row"
assert_eq "$(tail -1 "$HOME/.vpn-sessions.csv" | cut -d, -f4)" "Office_VPN" "config recorded"

duration="$(tail -1 "$HOME/.vpn-sessions.csv" | cut -d, -f3)"
assert_eq "$([ "$duration" -ge 3595 ] && [ "$duration" -le 3605 ] && echo ok || echo "$duration")" "ok" \
  "duration taken from the openvpn log start (~3600 s)"

echo "disconnecting while already disconnected is a no-op"
rows_before="$(wc -l < "$HOME/.vpn-sessions.csv")"
bash "$ROOT/scripts/vpn-track.sh"
assert_eq "$(wc -l < "$HOME/.vpn-sessions.csv")" "$rows_before" "no extra row"

exit "$fail"
```

- [ ] **Step 6: Run the `vpn-track.sh` test**

```bash
chmod +x ~/Projects/vpn-time/test/test-vpn-track.sh
~/Projects/vpn-time/test/test-vpn-track.sh
```

Expected: only `ok:`, exit code 0.

- [ ] **Step 7: Write `test/run-tests.sh`**

```bash
#!/bin/bash
# Runs the whole suite: Swift unit tests and the shell script tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0

echo "== swift test =="
(cd "$ROOT" && swift test) || status=1

for t in "$ROOT"/test/test-*.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || status=1
done

if [ "$status" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi

exit "$status"
```

- [ ] **Step 8: Run the whole suite**

```bash
chmod +x ~/Projects/vpn-time/test/run-tests.sh
~/Projects/vpn-time/test/run-tests.sh
```

Expected: `ALL TESTS PASSED`.

- [ ] **Step 9: Commit**

```bash
cd ~/Projects/vpn-time
git add scripts test
git commit -m "test: cover the tracker and report scripts

vpn-track.sh gains VPN_TRACK_LOGDIR and VPN_TRACK_PS_CMD overrides so the
poller can run against a fake process list and log directory."
```

---

## Task 11: launchd templates and `install.sh`

**Files:**
- Create: `~/Projects/vpn-time/launchd/com.redge.vpntrack.plist.template`
- Create: `~/Projects/vpn-time/launchd/com.redge.vpntimebar.plist.template`
- Create: `~/Projects/vpn-time/install.sh`

**Interfaces:**
- Consumes: `build/VPN Time.app` (Task 9), `scripts/*.sh` (Task 10).
- Produces: `install.sh` used in Task 12.

- [ ] **Step 1: Write `launchd/com.redge.vpntrack.plist.template`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.redge.vpntrack</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__HOME__/.local/bin/vpn-track.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>__HOME__/.local/bin/vpn-track.err</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `launchd/com.redge.vpntimebar.plist.template`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.redge.vpntimebar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>__HOME__/Applications/VPN Time.app</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
```

`ProgramArguments` uses `/usr/bin/open`, not the binary directly — this way the job exits immediately, the app lives detached as `application.com.redge.vpntimebar…`, and the "Uruchamiaj przy logowaniu" toggle can load/unload the agent without killing the running app. There is no `KeepAlive` here.

- [ ] **Step 3: Write `install.sh`**

```bash
#!/bin/bash
# Installs the tracker scripts, the app bundle and the launchd agents.
# Idempotent. Never touches ~/.vpn-sessions.csv beyond making a backup.
set -euo pipefail

cd "$(dirname "$0")"

STAMP="$(date +%Y-%m-%d-%H%M%S)"
APP_SRC="build/VPN Time.app"
APP_DST="$HOME/Applications/VPN Time.app"
AGENTS="$HOME/Library/LaunchAgents"

if [ ! -d "$APP_SRC" ]; then
  echo "error: $APP_SRC missing — run ./build.sh first" >&2
  exit 1
fi

echo "== backing up session data =="
for f in "$HOME/.vpn-sessions.csv" "$HOME/.vpn-sessions.state"; do
  if [ -f "$f" ]; then
    cp "$f" "$f.bak-$STAMP"
    echo "  $f -> $f.bak-$STAMP"
  fi
done

echo "== installing scripts =="
mkdir -p "$HOME/.local/bin"
install -m 755 scripts/vpn-track.sh "$HOME/.local/bin/vpn-track.sh"
install -m 755 scripts/vpn-report.sh "$HOME/.local/bin/vpn-report.sh"

echo "== rendering launchd agents =="
mkdir -p "$AGENTS"
for label in com.redge.vpntrack com.redge.vpntimebar; do
  sed "s|__HOME__|$HOME|g" "launchd/$label.plist.template" > "$AGENTS/$label.plist"
  echo "  $AGENTS/$label.plist"
done

echo "== swapping the app bundle =="
launchctl unload "$AGENTS/com.redge.vpntimebar.plist" 2>/dev/null || true
pkill -x vpntime 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "== loading agents =="
launchctl load "$AGENTS/com.redge.vpntimebar.plist"
launchctl unload "$AGENTS/com.redge.vpntrack.plist" 2>/dev/null || true
launchctl load "$AGENTS/com.redge.vpntrack.plist"

echo "== done =="
launchctl list | grep -E 'com\.redge\.vpn' || true
```

- [ ] **Step 4: Check plist rendering without installing**

```bash
cd ~/Projects/vpn-time
sed "s|__HOME__|$HOME|g" launchd/com.redge.vpntrack.plist.template | diff - ~/Library/LaunchAgents/com.redge.vpntrack.plist && echo "vpntrack: identyczny"
sed "s|__HOME__|$HOME|g" launchd/com.redge.vpntimebar.plist.template | diff - ~/Library/LaunchAgents/com.redge.vpntimebar.plist && echo "vpntimebar: identyczny"
```

Expected: both print `identyczny` (identical). If `diff` shows anything, we fix the **template** so that it is byte-for-byte the same as the working plist.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
chmod +x install.sh
git add launchd install.sh
git commit -m "build: add launchd templates and an idempotent installer"
```

---

## Task 12: Cutover — replacing the working installation

Up to this point the production installation was untouched. Now we replace it in a controlled order. `com.redge.vpntrack` is reloaded only at the very end, and only because the script gained new variables — the CSV data must not suffer.

**Files:** none new; running `install.sh` and `tools/verify-menu.sh`.

**Interfaces:**
- Consumes: everything from Tasks 9–11.
- Produces: `~/Applications/VPN Time.app` built from the repo, menu parity verified.

- [ ] **Step 1: Record the pre-swap state**

```bash
~/Projects/vpn-time/tools/verify-menu.sh
wc -l ~/.vpn-sessions.csv
md5 ~/.vpn-sessions.csv
cat ~/.vpn-sessions.state 2>/dev/null || echo "(VPN disconnected)"
```

Note down the line count, the MD5 checksum and the state — this is the baseline for Step 4.

- [ ] **Step 2: Full test suite before the swap**

```bash
~/Projects/vpn-time/test/run-tests.sh
```

Expected: `ALL TESTS PASSED`. If not — **stop**, the cutover does not happen.

- [ ] **Step 3: Build and install**

```bash
~/Projects/vpn-time/build.sh
~/Projects/vpn-time/install.sh
```

Expected: `launchctl list` shows `com.redge.vpntrack` and `com.redge.vpntimebar`.

- [ ] **Step 4: Verify parity and data integrity**

```bash
sleep 5
pgrep -x vpntime | wc -l
~/Projects/vpn-time/tools/verify-menu.sh
wc -l ~/.vpn-sessions.csv
md5 ~/.vpn-sessions.csv
```

Expected: exactly one `vpntime` process; `OK: menu matches the recovered layout (14 entries)`; the CSV line count and MD5 **unchanged** compared with Step 1 (unless the VPN disconnected in the meantime — then exactly one more line, and that is correct).

- [ ] **Step 5: Verify the autostart toggle**

In the menu bar menu click "Uruchamiaj przy logowaniu" (it gets unchecked), then once more (it gets checked). After each click:

```bash
ls -la ~/Library/LaunchAgents/com.redge.vpntimebar.plist 2>/dev/null || echo "(plist removed)"
pgrep -x vpntime | wc -l
```

Expected: the plist disappears and comes back, and the app **keeps running the whole time** (`1`). If the app dies on unload — the plist is wrong (`ProgramArguments` must point at `/usr/bin/open`, not at the binary).

- [ ] **Step 6: Verify "Pokaż plik z historią" (Show history file) and "Odśwież" (Refresh)**

Click both entries. Expected: Finder opens the home directory with `.vpn-sessions.csv` selected; "Odśwież" recalculates the menu without the icon flickering.

- [ ] **Step 7: Commit the verification state**

```bash
cd ~/Projects/vpn-time
git commit --allow-empty -m "chore: cut over to the rebuilt app bundle

Menu parity verified against the recovered layout; session CSV unchanged
across the swap; the autostart toggle loads and unloads the agent without
killing the running app."
```

---

## Task 13: README and memory update

**Files:**
- Create: `~/Projects/vpn-time/README.md`
- Modify: `~/.claude/projects/-Users-redge/memory/vpn-time-tracker.md`
- Modify: `~/.claude/projects/-Users-redge/memory/MEMORY.md`

**Interfaces:**
- Consumes: everything.
- Produces: documentation and a pointer from memory to the repo.

- [ ] **Step 1: Write `README.md`**

It must contain, in this order:
1. What it is for — Tunnelblick does not record cumulative time (the per-connection log is overwritten, the macOS unified log has ~2 days of retention).
2. Architecture — the poller as the data source (runs independently of the app), the app as a view reading the CSV + state file.
3. Components and their target paths (`~/.local/bin/vpn-track.sh`, `~/.local/bin/vpn-report.sh`, `~/Applications/VPN Time.app`, both launchd agents).
4. Installation: `./build.sh && ./install.sh`.
5. Tests: `./test/run-tests.sh` and `./tools/verify-menu.sh` (requires the Accessibility permission).
6. Aliases in `~/.zshrc` — **already exist** (lines 196–198), add them only on a fresh install on another machine:
   ```
   alias vpntime='~/.local/bin/vpn-report.sh'
   alias vpntime-week='~/.local/bin/vpn-report.sh week'
   alias vpntime-month='~/.local/bin/vpn-report.sh month'
   ```
7. Disabling: `launchctl unload ~/Library/LaunchAgents/com.redge.vpntimebar.plist` (menu bar) / `...com.redge.vpntrack.plist` (data collection).
8. Known limitations: history since 2026-07-08, session end accuracy ±30 s (polling interval), exact start taken from the openvpn log, a session counts entirely towards the day it started, the "od HH:mm" (since HH:mm) row does not show the date for multi-day sessions.
9. A "How this repo came to be" section — a link to `docs/recovered-api.md` and the plan.

- [ ] **Step 2: Update the memory note**

In `~/.claude/projects/-Users-redge/memory/vpn-time-tracker.md` replace the sentence "Źródło: build w scratchpad `vpnbuild/main.swift`" (Source: build in scratchpad …) with a pointer to the repo `~/Projects/vpn-time`, and add that the binary is built by `./build.sh` and installed by `./install.sh`. The rest of the note (architecture, autostart mechanics, limitations) stays unchanged — it is still accurate.

- [ ] **Step 3: Update `MEMORY.md`**

Change the hook for "VPN time tracker" so that it points to the repo:

```
- [VPN time tracker](vpn-time-tracker.md) — własny tracker czasu Tunnelblick VPN; źródła w ~/Projects/vpn-time (odtworzone 2026-09-15 z binarki)
```

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/vpn-time
git add README.md
git commit -m "docs: document the architecture, install flow and known limits"
git log --oneline
```

Expected: 15 commits, from `docs: recover VPN Time app spec…` to `docs: document…`.

---

## Task 14 (optional, outside the recreation scope): splitting sessions at midnight

Do not do this together with Tasks 1–13. It is a behaviour change, not a recreation — it should get its own decision and its own commit, so it can be reverted without touching parity.

Currently the session 2026-09-07 07:31 → 2026-09-09 18:31 (212380 s) counts entirely towards 7 September, which is why `Dziś` (Today) can show `0h 00m` even with an active VPN. If this were to change:
- extend `Totals.total` to split the interval `[start, start+duration)` at bucket boundaries,
- `vpn-report.sh` would need the same logic, otherwise the app and the CLI will start showing different numbers,
- the tests from Task 6 (`testMultiDaySessionCountsWhollyIntoItsStartDay`) would then have to be rewritten deliberately — their failure is the signal that the behaviour change is intended and not a regression.

---

## Order and checkpoints

| # | Task | Gate |
|---|---|---|
| 1 | Repo, evidence, backup | CSV backup exists, `git log` has 1 commit |
| 2 | Menu smoke test | **passes on the old binary** |
| 3 | SPM + Session/Bucket | `swift test` green (1) |
| 4 | VPNStore — CSV | `swift test` green (5) |
| 5 | VPNStore — state | `swift test` green (8) |
| 6 | Totals | `swift test` green (12) |
| 7 | TimeFormat | `swift test` green (15) |
| 8 | AppDelegate + main | `swift build -c release` passes |
| 9 | build.sh + bundle | two instances side by side look the same |
| 10 | Scripts + bash tests | `run-tests.sh` → `ALL TESTS PASSED` |
| 11 | launchd + install.sh | rendered plists `diff` to zero |
| 12 | Cutover | `verify-menu.sh` OK, CSV MD5 unchanged |
| 13 | README + memory | `git log` 15 commits |

Tasks 3–7 depend on each other sequentially (each builds on the types of the previous one). Task 10 is independent of 3–9 and can run in parallel. Task 2 must happen **while the old app still works** — after Task 12 there is nothing left to compare against.
