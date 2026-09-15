# VPN Time — odtworzenie źródeł i konsolidacja w repo (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Odtworzyć utracone źródła aplikacji menu bar „VPN Time" i zebrać cały tracker czasu VPN (apka Swift + dwa skrypty bash + dwa agenty launchd) w jedno wersjonowane repo `~/Projects/vpn-time`, nie przerywając działania obecnej instalacji ani nie tracąc historii w CSV.

**Architecture:** Repo SPM z rozdziałem na testowalny rdzeń bez AppKit (`VPNTimeCore`: parsowanie CSV/state, kubełki czasowe, formatowanie) i cienką warstwę UI (`VPNTime`: `AppDelegate` + `main.swift` na AppKit). Skrypty bash dostają wstrzykiwalne zależności (`VPN_TRACK_LOGDIR`, `VPN_TRACK_PS_CMD`) żeby dały się testować pod `HOME=$(mktemp -d)`. Ploty launchd trzymane jako szablony (launchd nie rozwija `~`), renderowane przez `install.sh`. Parytet z oryginałem weryfikuje zero-zależnościowy smoke test AppleScript, uruchamiany **najpierw na starej, działającej apce** — dopiero test, który przechodzi na oryginale, jest wiarygodny dla nowej binarki.

**Tech Stack:** Swift 6.3 toolchain / swift-tools-version 6.0 w trybie języka Swift 5, AppKit (`NSStatusItem`), XCTest, bash, launchd, `osascript`/System Events, `codesign` ad-hoc. Zero zależności zewnętrznych.

**Spec:** `docs/recovered-api.md` (tworzony w Zadaniu 1) — zapis śledztwa na binarce `~/Applications/VPN Time.app/Contents/MacOS/vpntime`. Pełna treść odzyskanej specyfikacji jest też wklejona niżej w „Odzyskana specyfikacja", żeby ten plan był samowystarczalny.

---

## Kontekst: dlaczego ten plan istnieje

Źródło `main.swift` powstało 8 lipca 2026 w efemerycznym scratchpadzie sesji i zostało skasowane razem z nim. Przetrwała wyłącznie skompilowana binarka (arm64, ad-hoc signed, bez debug info). Skrypty bash i ploty launchd przetrwały, bo leżą w `~/.local/bin` i `~/Library/LaunchAgents`.

Sprawdzono i wykluczono: `find`/Spotlight po całym `$HOME`, transkrypty `~/.claude/projects/**` (sesja `1010cebb-…` już nie istnieje), `dwarfdump` (brak debug info), Time Machine (`No machine directory found for host`).

**Cała specyfikacja poniżej została odzyskana empirycznie**, nie zgadnięta:
- nazwy typów i sygnatury — z demanglowanych symboli Swift (`nm -U` + `swift demangle`),
- długie literały UI — z sekcji `__TEXT` binarki,
- krótkie literały (≤15 bajtów, trzymane inline jako immediate) — przez odczytanie **żywego menu działającej apki** przez System Events,
- nazwy symboli SF, interwał timera i stałe AppKit — przez zdekodowanie immediate'ów z `otool -tV`.

---

## Global Constraints

Każde zadanie dziedziczy te wymagania.

- **Język:** proza planu, README i treść ticketów po polsku; **kod, komentarze w kodzie, nazwy branchy i commit messages po angielsku** (globalne `CLAUDE.md`).
- **Komentarze w kodzie są bardzo rzadkie.** Zamiast komentarza — nazwanie warunku, wyciągnięcie funkcji, nazwana stała. Uzasadnienia trafiają do README/commit message, nie inline.
- **Puste linie wokół `if`** — przed i po bloku `if`, ale nigdy bezpośrednio po `{` ani przed `}`.
- **Skill `dry-js-ts`** dotyczy JS/TS; tu nie ma JS/TS, ale jego zasady obowiązują w duchu: platforma przed zależnością, zero bibliotek zewnętrznych, typy wyprowadzane, nie przepisywane.
- **Zero zależności zewnętrznych.** Ani w Swift (`dependencies: []`), ani w testach bash (bez `bats`).
- **Nazwy odzyskane zachowujemy dosłownie:** `Session(start:duration:)`, `Bucket` (`Hashable`), `VPNStore.sessions() -> [Session]`, `VPNStore.activeSession() -> (Date, String)?`, `total(_:sessions:active:) -> Int` z zagnieżdżonym `inBucket(_:) -> Bool`, `AppDelegate.rebuildMenu(sessions:active:)`, `refresh()`, `toggleAutostart()`, `autostartEnabled() -> Bool`, `runLaunchctl(_: [String])`, `revealCSV()`, `quit()`, pole `agentLabel = "com.redge.vpntimebar"`, `csvPath`, `statePath`, `parser`, `statusItem`, `store`, `timer`, `calendar`.
- **Teksty UI po polsku, dosłownie** z listy w „Odzyskana specyfikacja". Żadnych przeredagowań, żadnych poprawek interpunkcji — nawet padding spacjami jest częścią kontraktu.
- **Cel platformy: macOS 13** (`platforms: [.macOS(.v13)]`, `-target arm64-apple-macos13.0`). Oryginał deklarował `LSMinimumSystemVersion 13.0` w `Info.plist`, ale binarka miała `VersionMin 26.0` — to była niespójność; ten plan ją naprawia świadomie.
- **Tryb języka Swift 5** (`swiftLanguageModes: [.v5]` przy `swift-tools-version: 6.0`). Oryginał był budowany gołym `swiftc` w trybie domyślnym; włączenie trybu 6 wciągnęłoby `NSStatusItem` i domknięcie `Timer`a w strict concurrency, co jest czystą stratą czasu przy odtwarzaniu.
- **Podpis:** ad-hoc, `codesign --force --deep -s - <bundle>`; `CFBundleIdentifier = com.redge.vpntimebar`, `CFBundleExecutable = vpntime`.
- **Nietykalne:** plik `~/.vpn-sessions.csv` i agent `com.redge.vpntrack`. Zbieranie danych nie może się zatrzymać ani zgubić rekordu na żadnym etapie.
- **Commity:** częste, jeden commit na zadanie (albo na krok, gdy zadanie jest długie); format `feat:` / `fix:` / `test:` / `docs:` / `chore:`.

---

## Odzyskana specyfikacja (źródło prawdy dla parytetu)

### Struktura projektu Swift (z symboli)

```
struct Session { let start: Date; let duration: Int }      // init(start:duration:)
enum Bucket: Hashable                                       // 3 przypadki: dziś / tydzień / miesiąc
final class VPNStore {
    private let csvPath: String                             // ~/.vpn-sessions.csv
    private let statePath: String                           // ~/.vpn-sessions.state
    private let parser: DateFormatter                       // inicjalizowany domknięciem
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
    //   ^ zawiera zagnieżdżone: func inBucket(_ date: Date) -> Bool
    private func autostartEnabled() -> Bool
    private func toggleAutostart()                          // @objc
    private func runLaunchctl(_: [String])
    private func revealCSV()                                // @objc
    private func quit()                                     // @objc
}
let app = NSApplication.shared                              // globalne `app` i `delegate`
let delegate = AppDelegate()                                //   => kod na poziomie main.swift
```

### Stałe AppKit (zdekodowane z `otool -tV`)

| Wywołanie | Wartość | Znaczenie |
|---|---|---|
| `setActivationPolicy:` | `1` | `.accessory` |
| `statusItemWithLength:` | `-1.0` | `NSStatusItem.variableLength` |
| `setImagePosition:` | `7` | `.imageLeading` |
| `scheduledTimerWithTimeInterval:repeats:block:` | `15.0`, `repeats = true` | odświeżanie co 15 s |

### Ikona i opis dostępności (zdekodowane z immediate'ów)

| Stan | `systemSymbolName` | `accessibilityDescription` |
|---|---|---|
| połączony | `lock.fill` | `VPN on` |
| rozłączony | `lock.open` | `VPN off` |

### Tytuł status itemu i tooltip

- tytuł połączony: `" %d:%02d"` z **czasem trwania aktywnej sesji** (zweryfikowane: `" 120:47"` przy sesji od 10.09 07:44, odczyt 15.09 ~08:31) — uwaga, to **nie** jest suma dzisiejsza,
- tytuł rozłączony: pusty (`""`),
- tooltip połączony: `"VPN aktywny: " + config`,
- tooltip rozłączony: `"VPN rozłączony"`.

### Menu — dosłowny zrzut z działającej apki (15.09.2026, VPN połączony)

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

Etykiety kubełków to **zaszyte literały z paddingiem**, nie wyrównanie liczone w kodzie (potwierdzone: `'Dziś:            '` leży w tablicy stringów binarki jako jeden 17-znakowy literał):

| Literał | Długość | Doklejana wartość |
|---|---|---|
| `"Dziś:            "` | 17 znaków (`Dziś:` + 12 spacji) | `hoursMinutes(...)` |
| `"Ten tydzień:  "` | 14 znaków (`Ten tydzień:` + 2 spacje) | `hoursMinutes(...)` |
| `"Ten miesiąc: "` | 13 znaków (`Ten miesiąc:` + 1 spacja) | `hoursMinutes(...)` |

Format wartości: `String(format: "%dh %02dm", h, m)`.

Wiersz stanu: `"● Połączony (" + config + ") od " + HH:mm(start)` albo `"○ Rozłączony"`.

### Semantyka kubełków (zweryfikowana empirycznie)

`inBucket` przyjmuje **jedną** datę — sesja należy w całości do kubełka swojego **początku**. Dowód z żywej apki z 15.09.2026 (wtorek):
- aktywna sesja trwa od 10.09 (poprzedni tydzień ISO), `Dziś: 0h 00m` i `Ten tydzień: 0h 00m`, ale `Ten miesiąc: 250h 48m` zawiera jej 120h 47m,
- rekord CSV `2026-09-07 07:31:22 → 2026-09-09 18:31:02` (212380 s) liczy się w całości do 7 września.

**Dzielenie sesji na północy jest poza zakresem.** To odtworzenie, nie przeprojektowanie.

### Format danych

`~/.vpn-sessions.csv` (nagłówek + wiersze, 70 linii na 15.09.2026):
```
start_iso,end_iso,duration_s,config
2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
```
`~/.vpn-sessions.state` (istnieje tylko gdy VPN aktywny): `epoch<TAB>config`.

Parser: `dateFormat = "yyyy-MM-dd HH:mm:ss"`, `locale = en_US_POSIX`, **`timeZone = .current`** — CSV pisze `date -r` w czasie lokalnym; parsowanie w UTC przesunęłoby każdą sesję o 2 h i rozjechało kubełek `Dziś` przy północy.

### Świadome odstępstwa od oryginału

1. `total(_:sessions:active:)` przenosi się z `AppDelegate` do `VPNTimeCore` (typ `Totals`) — sygnatura i nazwa bez zmian, zmienia się tylko miejsce zamieszkania, żeby dało się to przetestować bez AppKit.
2. `VPNStore.init` dostaje parametry `csvPath:`/`statePath:` z domyślnymi wartościami `~/...` — testy celują w katalog tymczasowy.
3. `Calendar(identifier: .iso8601)` zamiast `.current` — żeby tydzień w apce znaczył to samo co `%G-W%V` w `vpn-report.sh`.
4. Cel `macos13.0` (patrz Global Constraints).
5. `vpn-track.sh` dostaje `VPN_TRACK_LOGDIR` i `VPN_TRACK_PS_CMD` — bez tego testy skryptu są niewykonalne.

---

## File Structure

```
~/Projects/vpn-time/
├── .gitignore                          # .build/, build/, *.bak-*
├── README.md                           # architektura, instalacja, historia śledztwa
├── Package.swift                       # SPM: VPNTimeCore (lib) + VPNTime (exe)
├── Sources/
│   ├── VPNTimeCore/
│   │   ├── Session.swift               # struct Session
│   │   ├── Bucket.swift                # enum Bucket + Calendar.vpnTimeISO
│   │   ├── VPNStore.swift              # odczyt CSV + state file
│   │   ├── Totals.swift                # total(_:sessions:active:) + inBucket
│   │   └── TimeFormat.swift            # hoursMinutes(_:) i counter(_:)
│   └── VPNTime/
│       ├── AppDelegate.swift           # NSStatusItem, menu, timer, autostart
│       └── main.swift                  # globalne app/delegate, NSApp.run()
├── Tests/
│   └── VPNTimeCoreTests/
│       ├── VPNStoreTests.swift
│       ├── TotalsTests.swift
│       └── TimeFormatTests.swift
├── scripts/
│   ├── vpn-track.sh                    # poller (z wstrzykiwalnym LOGDIR/PS_CMD)
│   └── vpn-report.sh                   # raport CLI
├── test/
│   ├── run-tests.sh                    # uruchamia oba poniższe
│   ├── test-vpn-track.sh
│   └── test-vpn-report.sh
├── launchd/
│   ├── com.redge.vpntrack.plist.template
│   └── com.redge.vpntimebar.plist.template
├── bundle/
│   └── Info.plist
├── tools/
│   └── verify-menu.sh                  # smoke test parytetu menu przez System Events
├── build.sh                            # swift build + montaż .app + codesign
├── install.sh                          # backup, deploy, launchctl
└── docs/
    ├── recovered-api.md                # spec śledcza (Zadanie 1)
    ├── evidence/
    │   ├── menu-2026-09-15.txt
    │   ├── symbols-2026-09-15.txt
    │   └── strings-2026-09-15.txt
    └── superpowers/plans/2026-09-15-vpn-time-recreate.md
```

Podział `VPNTimeCore` / `VPNTime` jest podyktowany testowalnością: SPM nie testuje sensownie targetów wykonywalnych, a cała logika wartościowa (parsowanie, kubełki, formatowanie) nie potrzebuje AppKit. `AppDelegate` zostaje cienki i weryfikowany end-to-end przez `verify-menu.sh`.

---

## Zadanie 1: Repo, dowody śledcze i backup danych

Najpierw utrwalamy to, co odzyskane. Źródło zginęło raz przez efemeryczną lokalizację — pierwszy commit ma sprawić, żeby to się nie powtórzyło.

**Files:**
- Create: `~/Projects/vpn-time/.gitignore`
- Create: `~/Projects/vpn-time/docs/recovered-api.md`
- Create: `~/Projects/vpn-time/docs/evidence/menu-2026-09-15.txt`
- Create: `~/Projects/vpn-time/docs/evidence/symbols-2026-09-15.txt`
- Create: `~/Projects/vpn-time/docs/evidence/strings-2026-09-15.txt`
- Already present: `docs/superpowers/plans/2026-09-15-vpn-time-recreate.md`

**Interfaces:**
- Consumes: nic.
- Produces: repo git z gałęzią `main`; `docs/recovered-api.md` jako spec dla Zadań 2–8.

- [ ] **Step 1: Zabezpiecz dane produkcyjne (przed czymkolwiek innym)**

```bash
cp ~/.vpn-sessions.csv ~/.vpn-sessions.csv.bak-2026-09-15
cp ~/.vpn-sessions.state ~/.vpn-sessions.state.bak-2026-09-15 2>/dev/null || true
ls -la ~/.vpn-sessions.csv.bak-2026-09-15
```

Oczekiwane: plik backupu istnieje i ma ten sam rozmiar co oryginał.

- [ ] **Step 2: Zainicjuj repo**

```bash
cd ~/Projects/vpn-time
git init -b main
printf '%s\n' '.build/' 'build/' '*.bak-*' '.DS_Store' > .gitignore
```

- [ ] **Step 3: Zrzuć dowody z binarki do `docs/evidence/`**

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

Oczekiwane: `symbols-…txt` zawiera m.in. `vpntime.VPNStore.activeSession() -> (Foundation.Date, Swift.String)?`.

- [ ] **Step 4: Zrzuć żywe menu starej apki (dopóki działa)**

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

Oczekiwane: 14 pozycji menu, zaczynając od `[Czas na VPN]`.

Jeżeli `osascript` zwróci `-1719` albo błąd uprawnień: w Ustawieniach → Prywatność i ochrona → Dostępność dodaj terminal/Claude Code. Bez tego Zadanie 2 i 12 nie mają jak zweryfikować parytetu.

- [ ] **Step 5: Napisz `docs/recovered-api.md`**

Przepisz do niego sekcję „Odzyskana specyfikacja" z tego planu w całości (tabele stałych, ikon, menu, semantyka kubełków, format danych, odstępstwa) i dopisz nagłówek opisujący metodę odzyskania oraz datę. To jest spec — Zadania 2–8 się do niego odwołują.

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

## Zadanie 2: Smoke test parytetu menu, zwalidowany na oryginale

Ten test powstaje **zanim** pojawi się jakikolwiek nowy kod, i musi przejść na **starej** binarce. Test, który nigdy nie zaświecił się na zielono na znanym-dobrym systemie, nic nie dowodzi.

**Files:**
- Create: `~/Projects/vpn-time/tools/verify-menu.sh`

**Interfaces:**
- Consumes: `docs/evidence/menu-2026-09-15.txt` (kształt odniesienia).
- Produces: `tools/verify-menu.sh` — używane w Zadaniu 12 (cutover) jako bramka akceptacji.

- [ ] **Step 1: Napisz `tools/verify-menu.sh`**

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

- [ ] **Step 2: Uruchom go na STAREJ, działającej apce**

```bash
chmod +x ~/Projects/vpn-time/tools/verify-menu.sh
~/Projects/vpn-time/tools/verify-menu.sh
```

Oczekiwane: `OK: menu matches the recovered layout (14 entries)`.

Jeśli test nie przechodzi na oryginale — **napraw test, nie oryginał.** Wzorce mają opisywać rzeczywistość, nie życzenia.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/vpn-time
git add tools/verify-menu.sh
git commit -m "test: add menu parity smoke test, validated against the original binary"
```

---

## Zadanie 3: Szkielet SPM + `Session` i `Bucket`

**Files:**
- Create: `~/Projects/vpn-time/Package.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Session.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Bucket.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TotalsTests.swift` (na razie tylko test kalendarza)

**Interfaces:**
- Consumes: spec z Zadania 1.
- Produces: `Session(start: Date, duration: Int)` z polami `start`/`duration`; `enum Bucket: Hashable { case today, week, month }`; `Calendar.vpnTimeISO`.

- [ ] **Step 1: Napisz `Package.swift`**

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

- [ ] **Step 2: Napisz test kalendarza (najpierw czerwony)**

Plik `Tests/VPNTimeCoreTests/TotalsTests.swift`:

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

- [ ] **Step 3: Uruchom test i potwierdź, że nie kompiluje**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: błąd kompilacji — `cannot find 'Calendar.vpnTimeISO'` / brak modułu.

- [ ] **Step 4: Napisz `Sources/VPNTimeCore/Session.swift`**

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

- [ ] **Step 5: Napisz `Sources/VPNTimeCore/Bucket.swift`**

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

- [ ] **Step 6: Uruchom test i potwierdź, że przechodzi**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `Executed 1 test, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/vpn-time
git add Package.swift Sources/VPNTimeCore Tests
git commit -m "feat: add SPM skeleton with Session and Bucket"
```

---

## Zadanie 4: `VPNStore` — parsowanie CSV

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/VPNStore.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/VPNStoreTests.swift`

**Interfaces:**
- Consumes: `Session` z Zadania 3.
- Produces: `VPNStore(csvPath:statePath:)`, `sessions() -> [Session]`, `activeSession() -> (Date, String)?`.

- [ ] **Step 1: Napisz testy parsowania CSV (najpierw czerwone)**

Plik `Tests/VPNTimeCoreTests/VPNStoreTests.swift`:

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

`Session` celowo nie jest `Equatable` (oryginał też nie był), dlatego pusty wynik sprawdzamy przez `isEmpty`, a nie przez porównanie z `[]`.

- [ ] **Step 2: Uruchom testy i potwierdź, że nie kompilują**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `cannot find 'VPNStore' in scope`.

- [ ] **Step 3: Napisz `Sources/VPNTimeCore/VPNStore.swift`**

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

- [ ] **Step 4: Uruchom testy i potwierdź, że przechodzą**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/VPNStore.swift Tests/VPNTimeCoreTests/VPNStoreTests.swift
git commit -m "feat: parse the session CSV in VPNStore"
```

---

## Zadanie 5: `VPNStore.activeSession()` — plik stanu

**Files:**
- Modify: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/VPNStoreTests.swift`

**Interfaces:**
- Consumes: `VPNStore` z Zadania 4 (implementacja `activeSession()` już tam jest).
- Produces: potwierdzony kontrakt `(Date, String)?`.

- [ ] **Step 1: Dopisz testy pliku stanu**

Dodaj do `VPNStoreTests`:

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

- [ ] **Step 2: Uruchom testy**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `Executed 8 tests, with 0 failures`. Jeśli któryś pada — poprawiamy `activeSession()`, nie test.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/vpn-time
git add Tests/VPNTimeCoreTests/VPNStoreTests.swift
git commit -m "test: cover the active-session state file contract"
```

---

## Zadanie 6: `Totals` — sumowanie po kubełkach

Najważniejsze zadanie pod względem parytetu. Semantyka „sesja należy do kubełka swojego początku" jest nieoczywista i została potwierdzona na żywym systemie — testy muszą ją zamrozić.

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/Totals.swift`
- Modify: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TotalsTests.swift`

**Interfaces:**
- Consumes: `Session`, `Bucket`, `Calendar.vpnTimeISO`.
- Produces: `Totals(calendar:now:)` i `total(_ bucket: Bucket, sessions: [Session], active: (Date, String)?) -> Int`.

- [ ] **Step 1: Dopisz testy kubełków (najpierw czerwone)**

Dodaj do `TotalsTests`:

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

- [ ] **Step 2: Uruchom testy i potwierdź, że nie kompilują**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `cannot find 'Totals' in scope`.

- [ ] **Step 3: Napisz `Sources/VPNTimeCore/Totals.swift`**

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

- [ ] **Step 4: Uruchom testy i potwierdź, że przechodzą**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/Totals.swift Tests/VPNTimeCoreTests/TotalsTests.swift
git commit -m "feat: bucket session totals by the day the session started"
```

---

## Zadanie 7: Formatowanie czasu

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTimeCore/TimeFormat.swift`
- Test: `~/Projects/vpn-time/Tests/VPNTimeCoreTests/TimeFormatTests.swift`

**Interfaces:**
- Consumes: nic.
- Produces: `hoursMinutes(_ seconds: Int) -> String` („`250h 48m`"), `counter(_ seconds: Int) -> String` („` 120:47`", z wiodącą spacją).

- [ ] **Step 1: Napisz testy (najpierw czerwone)**

Plik `Tests/VPNTimeCoreTests/TimeFormatTests.swift`:

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

- [ ] **Step 2: Uruchom testy i potwierdź, że nie kompilują**

```bash
cd ~/Projects/vpn-time && swift test --filter TimeFormatTests 2>&1 | tail -20
```

Oczekiwane: `cannot find 'hoursMinutes' in scope`.

- [ ] **Step 3: Napisz `Sources/VPNTimeCore/TimeFormat.swift`**

```swift
import Foundation

public func hoursMinutes(_ seconds: Int) -> String {
    String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
}

public func counter(_ seconds: Int) -> String {
    String(format: " %d:%02d", seconds / 3600, (seconds % 3600) / 60)
}
```

- [ ] **Step 4: Uruchom testy i potwierdź, że przechodzą**

```bash
cd ~/Projects/vpn-time && swift test 2>&1 | tail -20
```

Oczekiwane: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTimeCore/TimeFormat.swift Tests/VPNTimeCoreTests/TimeFormatTests.swift
git commit -m "feat: format bucket totals and the status bar counter"
```

---

## Zadanie 8: `AppDelegate` i `main.swift`

Warstwa AppKit. Nie ma tu testów jednostkowych — weryfikacją jest `tools/verify-menu.sh` w Zadaniu 12.

**Files:**
- Create: `~/Projects/vpn-time/Sources/VPNTime/AppDelegate.swift`
- Create: `~/Projects/vpn-time/Sources/VPNTime/main.swift`

**Interfaces:**
- Consumes: `VPNStore`, `Totals`, `Bucket`, `hoursMinutes(_:)`, `counter(_:)`.
- Produces: wykonywalny target `VPNTime` (binarka `.build/release/VPNTime`).

- [ ] **Step 1: Napisz `Sources/VPNTime/AppDelegate.swift`**

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

Uwaga do `ProgramArguments`: ścieżka bierze się z `Bundle.main.bundlePath`, nie z literału — apka może stać gdzie indziej niż `~/Applications`, a plist launchd nie rozwija `~`.

- [ ] **Step 2: Napisz `Sources/VPNTime/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Zbuduj i potwierdź, że kompiluje**

```bash
cd ~/Projects/vpn-time && swift build -c release 2>&1 | tail -20
ls -la .build/release/VPNTime
```

Oczekiwane: build bez błędów, binarka istnieje.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/vpn-time
git add Sources/VPNTime
git commit -m "feat: rebuild the status bar UI on top of VPNTimeCore"
```

---

## Zadanie 9: `Info.plist`, `build.sh` i montaż bundla

**Files:**
- Create: `~/Projects/vpn-time/bundle/Info.plist`
- Create: `~/Projects/vpn-time/build.sh`

**Interfaces:**
- Consumes: target `VPNTime` z Zadania 8.
- Produces: `build/VPN Time.app` — kompletny, podpisany ad-hoc bundle; używany przez `install.sh` w Zadaniu 11.

- [ ] **Step 1: Napisz `bundle/Info.plist` (kopia oryginału, bez zmian)**

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

- [ ] **Step 2: Napisz `build.sh`**

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

- [ ] **Step 3: Zbuduj i zweryfikuj bundle**

```bash
chmod +x ~/Projects/vpn-time/build.sh
~/Projects/vpn-time/build.sh
```

Oczekiwane: `Identifier=com.redge.vpntimebar`, `flags=0x2(adhoc)`, `built: build/VPN Time.app`.

- [ ] **Step 4: Smoke test bez ruszania instalacji produkcyjnej**

Uruchom **binarkę wprost**, nie przez `open` — `open` tego samego bundle id tylko aktywuje starą instancję zamiast wystartować nową. Zapamiętaj PID: `kill %1` nie zadziała, bo powłoka wykonawcy planu nie ma kontroli zadań.

```bash
OLD_PID="$(pgrep -x vpntime | head -1)"
"$HOME/Projects/vpn-time/build/VPN Time.app/Contents/MacOS/vpntime" &
NEW_PID=$!
sleep 3
pgrep -x vpntime | wc -l
echo "old=$OLD_PID new=$NEW_PID"
```

Oczekiwane: `2` (dwie kłódki w pasku menu).

**Nie klikaj „Uruchamiaj przy logowaniu" w trakcie tego testu** — `Bundle.main.bundlePath` zapisałby wtedy plist wskazujący na `build/` zamiast na zainstalowaną apkę.

Porównaj menu obu instancji automatycznie, zamiast oglądać je okiem. Przy dwóch procesach o tej samej nazwie `process "vpntime"` jest niejednoznaczne, więc adresujemy je po PID:

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

Oczekiwane: `PARITY OK`. Jedyna dopuszczalna różnica to licznik minut w kubełkach, gdy między dwoma odczytami przeskoczyła pełna minuta — powtórz wtedy `diff`.

Ubij **tylko** nową instancję:

```bash
kill "$NEW_PID"
sleep 1
pgrep -x vpntime | wc -l
```

Oczekiwane: `1`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
git add bundle build.sh
git commit -m "build: assemble and ad-hoc sign the app bundle"
```

---

## Zadanie 10: Skrypty bash do repo + ich testy

**Files:**
- Create: `~/Projects/vpn-time/scripts/vpn-track.sh` (z `~/.local/bin/vpn-track.sh` + wstrzykiwalne zależności)
- Create: `~/Projects/vpn-time/scripts/vpn-report.sh` (kopia 1:1 z `~/.local/bin/vpn-report.sh`)
- Create: `~/Projects/vpn-time/test/test-vpn-track.sh`
- Create: `~/Projects/vpn-time/test/test-vpn-report.sh`
- Create: `~/Projects/vpn-time/test/run-tests.sh`

**Interfaces:**
- Consumes: nic z Swift.
- Produces: skrypty instalowane przez `install.sh` do `~/.local/bin/`.

- [ ] **Step 1: Skopiuj skrypty do repo bez zmian i zacommituj jako punkt odniesienia**

```bash
cd ~/Projects/vpn-time
mkdir -p scripts test
cp ~/.local/bin/vpn-track.sh scripts/vpn-track.sh
cp ~/.local/bin/vpn-report.sh scripts/vpn-report.sh
chmod +x scripts/*.sh
git add scripts
git commit -m "chore: vendor the tracker shell scripts verbatim"
```

Osobny commit ma znaczenie: następny diff pokazuje dokładnie, co zmieniło się względem działającego oryginału.

- [ ] **Step 2: Napisz test `vpn-report.sh` (najpierw czerwony — plik jeszcze nie istnieje)**

Plik `test/test-vpn-report.sh`:

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

Arytmetyka za tymi wartościami (sekundy obcinane w dół, `%-14s` daje odstęp między kolumnami): 839 + 31399 = 32238 s = 8 h 57 m 18 s → `8h 57m`; 3600 s → `1h 00m`; 32238 + 3600 = 35838 s = 9 h 57 m 18 s → `9h 57m`.

- [ ] **Step 3: Uruchom test `vpn-report.sh` i potwierdź, że przechodzi**

```bash
chmod +x ~/Projects/vpn-time/test/test-vpn-report.sh
~/Projects/vpn-time/test/test-vpn-report.sh
```

Oczekiwane: same linie `ok:`, kod wyjścia 0. `vpn-report.sh` nie wymagał zmian — czyta wyłącznie `$HOME`.

- [ ] **Step 4: Dodaj wstrzykiwalne zależności do `scripts/vpn-track.sh`**

Zmień dokładnie dwie linie:

```bash
LOGDIR="${VPN_TRACK_LOGDIR:-/Library/Application Support/Tunnelblick/Logs}"
```

oraz

```bash
running_cmd="$(${VPN_TRACK_PS_CMD:-ps -axww -o command=} | grep 'Tunnelblick.app/Contents/Resources/openvpn' | grep -v grep | head -1)"
```

Reszta skryptu bez zmian.

- [ ] **Step 5: Napisz test `vpn-track.sh`**

Plik `test/test-vpn-track.sh`:

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

- [ ] **Step 6: Uruchom test `vpn-track.sh`**

```bash
chmod +x ~/Projects/vpn-time/test/test-vpn-track.sh
~/Projects/vpn-time/test/test-vpn-track.sh
```

Oczekiwane: same `ok:`, kod wyjścia 0.

- [ ] **Step 7: Napisz `test/run-tests.sh`**

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

- [ ] **Step 8: Uruchom całą suitę**

```bash
chmod +x ~/Projects/vpn-time/test/run-tests.sh
~/Projects/vpn-time/test/run-tests.sh
```

Oczekiwane: `ALL TESTS PASSED`.

- [ ] **Step 9: Commit**

```bash
cd ~/Projects/vpn-time
git add scripts test
git commit -m "test: cover the tracker and report scripts

vpn-track.sh gains VPN_TRACK_LOGDIR and VPN_TRACK_PS_CMD overrides so the
poller can run against a fake process list and log directory."
```

---

## Zadanie 11: Szablony launchd i `install.sh`

**Files:**
- Create: `~/Projects/vpn-time/launchd/com.redge.vpntrack.plist.template`
- Create: `~/Projects/vpn-time/launchd/com.redge.vpntimebar.plist.template`
- Create: `~/Projects/vpn-time/install.sh`

**Interfaces:**
- Consumes: `build/VPN Time.app` (Zadanie 9), `scripts/*.sh` (Zadanie 10).
- Produces: `install.sh` używany w Zadaniu 12.

- [ ] **Step 1: Napisz `launchd/com.redge.vpntrack.plist.template`**

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

- [ ] **Step 2: Napisz `launchd/com.redge.vpntimebar.plist.template`**

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

`ProgramArguments` używa `/usr/bin/open`, a nie binarki wprost — dzięki temu job kończy się natychmiast, apka żyje odłączona jako `application.com.redge.vpntimebar…`, a przełącznik „Uruchamiaj przy logowaniu" może load/unload agenta bez ubijania działającej apki. Nie ma tu `KeepAlive`.

- [ ] **Step 3: Napisz `install.sh`**

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

- [ ] **Step 4: Sprawdź renderowanie plistów bez instalowania**

```bash
cd ~/Projects/vpn-time
sed "s|__HOME__|$HOME|g" launchd/com.redge.vpntrack.plist.template | diff - ~/Library/LaunchAgents/com.redge.vpntrack.plist && echo "vpntrack: identyczny"
sed "s|__HOME__|$HOME|g" launchd/com.redge.vpntimebar.plist.template | diff - ~/Library/LaunchAgents/com.redge.vpntimebar.plist && echo "vpntimebar: identyczny"
```

Oczekiwane: oba `identyczny`. Jeśli `diff` coś pokaże, poprawiamy **szablon**, żeby był bajt w bajt taki jak działający plist.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/vpn-time
chmod +x install.sh
git add launchd install.sh
git commit -m "build: add launchd templates and an idempotent installer"
```

---

## Zadanie 12: Cutover — podmiana działającej instalacji

Do tego momentu produkcyjna instalacja była nietknięta. Teraz podmieniamy ją w kontrolowanej kolejności. `com.redge.vpntrack` przeładowujemy dopiero na końcu i tylko dlatego, że skrypt dostał nowe zmienne — dane w CSV nie mogą ucierpieć.

**Files:** brak nowych; wykonanie `install.sh` i `tools/verify-menu.sh`.

**Interfaces:**
- Consumes: wszystko z Zadań 9–11.
- Produces: `~/Applications/VPN Time.app` zbudowany z repo, zweryfikowany parytet menu.

- [ ] **Step 1: Zapisz stan sprzed podmiany**

```bash
~/Projects/vpn-time/tools/verify-menu.sh
wc -l ~/.vpn-sessions.csv
md5 ~/.vpn-sessions.csv
cat ~/.vpn-sessions.state 2>/dev/null || echo "(VPN disconnected)"
```

Zanotuj liczbę linii, sumę MD5 i stan — to punkt odniesienia dla Kroku 4.

- [ ] **Step 2: Pełna suita testów przed podmianą**

```bash
~/Projects/vpn-time/test/run-tests.sh
```

Oczekiwane: `ALL TESTS PASSED`. Jeżeli nie — **stop**, cutover się nie odbywa.

- [ ] **Step 3: Zbuduj i zainstaluj**

```bash
~/Projects/vpn-time/build.sh
~/Projects/vpn-time/install.sh
```

Oczekiwane: `launchctl list` pokazuje `com.redge.vpntrack` i `com.redge.vpntimebar`.

- [ ] **Step 4: Zweryfikuj parytet i nienaruszalność danych**

```bash
sleep 5
pgrep -x vpntime | wc -l
~/Projects/vpn-time/tools/verify-menu.sh
wc -l ~/.vpn-sessions.csv
md5 ~/.vpn-sessions.csv
```

Oczekiwane: dokładnie jeden proces `vpntime`; `OK: menu matches the recovered layout (14 entries)`; liczba linii i MD5 CSV **niezmienione** względem Kroku 1 (chyba że VPN rozłączył się w międzyczasie — wtedy dokładnie o jedną linię więcej i to jest poprawne).

- [ ] **Step 5: Zweryfikuj przełącznik autostartu**

W menu paska kliknij „Uruchamiaj przy logowaniu" (odznaczy się), potem jeszcze raz (zaznaczy). Po każdym kliknięciu:

```bash
ls -la ~/Library/LaunchAgents/com.redge.vpntimebar.plist 2>/dev/null || echo "(plist removed)"
pgrep -x vpntime | wc -l
```

Oczekiwane: plist znika i wraca, a apka **przez cały czas działa** (`1`). Jeśli apka ginie przy unload — plist jest zły (`ProgramArguments` musi wskazywać `/usr/bin/open`, nie binarkę).

- [ ] **Step 6: Zweryfikuj „Pokaż plik z historią" i „Odśwież"**

Kliknij obie pozycje. Oczekiwane: Finder otwiera katalog domowy z zaznaczonym `.vpn-sessions.csv`; „Odśwież" przelicza menu bez migotania ikony.

- [ ] **Step 7: Commit stanu weryfikacji**

```bash
cd ~/Projects/vpn-time
git commit --allow-empty -m "chore: cut over to the rebuilt app bundle

Menu parity verified against the recovered layout; session CSV unchanged
across the swap; the autostart toggle loads and unloads the agent without
killing the running app."
```

---

## Zadanie 13: README i aktualizacja pamięci

**Files:**
- Create: `~/Projects/vpn-time/README.md`
- Modify: `~/.claude/projects/-Users-redge/memory/vpn-time-tracker.md`
- Modify: `~/.claude/projects/-Users-redge/memory/MEMORY.md`

**Interfaces:**
- Consumes: całość.
- Produces: dokumentacja i wskaźnik z pamięci na repo.

- [ ] **Step 1: Napisz `README.md`**

Ma zawierać, w tej kolejności:
1. Po co to jest — Tunnelblick nie zapisuje sumarycznego czasu (log per-połączenie jest nadpisywany, unified log macOS ma retencję ~2 dni).
2. Architektura — poller jako źródło danych (działa niezależnie od apki), apka jako widok czytający CSV + plik stanu.
3. Komponenty i ich ścieżki docelowe (`~/.local/bin/vpn-track.sh`, `~/.local/bin/vpn-report.sh`, `~/Applications/VPN Time.app`, oba agenty launchd).
4. Instalacja: `./build.sh && ./install.sh`.
5. Testy: `./test/run-tests.sh` oraz `./tools/verify-menu.sh` (wymaga uprawnienia Dostępność).
6. Aliasy w `~/.zshrc` — **już istnieją** (linie 196–198), dopisz tylko przy świeżej instalacji na innej maszynie:
   ```
   alias vpntime='~/.local/bin/vpn-report.sh'
   alias vpntime-week='~/.local/bin/vpn-report.sh week'
   alias vpntime-month='~/.local/bin/vpn-report.sh month'
   ```
7. Wyłączanie: `launchctl unload ~/Library/LaunchAgents/com.redge.vpntimebar.plist` (pasek) / `...com.redge.vpntrack.plist` (zbieranie).
8. Znane ograniczenia: historia od 2026-07-08, dokładność końca sesji ±30 s (interwał pollingu), start dokładny z logu openvpn, sesja liczy się w całości do dnia swojego początku, wiersz „od HH:mm" nie pokazuje daty przy sesjach wielodniowych.
9. Sekcja „Jak powstało to repo" — link do `docs/recovered-api.md` i planu.

- [ ] **Step 2: Zaktualizuj notatkę pamięci**

W `~/.claude/projects/-Users-redge/memory/vpn-time-tracker.md` zamień zdanie „Źródło: build w scratchpad `vpnbuild/main.swift`" na wskazanie repo `~/Projects/vpn-time` i dopisz, że binarka jest budowana przez `./build.sh`, a instalowana przez `./install.sh`. Reszta notatki (architektura, mechanika autostartu, ograniczenia) zostaje bez zmian — jest nadal aktualna.

- [ ] **Step 3: Zaktualizuj `MEMORY.md`**

Zmień hook przy „VPN time tracker" tak, żeby wskazywał repo:

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

Oczekiwane: 15 commitów, od `docs: recover VPN Time app spec…` do `docs: document…`.

---

## Zadanie 14 (opcjonalne, poza zakresem odtworzenia): dzielenie sesji na północy

Nie wykonuj tego razem z Zadaniami 1–13. To zmiana zachowania, nie odtworzenie — powinna mieć własną decyzję i własny commit, żeby dało się ją cofnąć bez ruszania parytetu.

Obecnie sesja 2026-09-07 07:31 → 2026-09-09 18:31 (212380 s) liczy się w całości do 7 września, przez co `Dziś` potrafi pokazywać `0h 00m` mimo aktywnego VPN-a. Gdyby to miało się zmienić:
- rozszerzyć `Totals.total` o dzielenie przedziału `[start, start+duration)` po granicach kubełka,
- `vpn-report.sh` musiałby dostać tę samą logikę, inaczej apka i CLI zaczną pokazywać różne liczby,
- testy z Zadania 6 (`testMultiDaySessionCountsWhollyIntoItsStartDay`) trzeba wtedy świadomie przepisać — ich upadek jest sygnałem, że zmiana zachowania jest zamierzona, a nie regresją.

---

## Kolejność i punkty kontrolne

| # | Zadanie | Bramka |
|---|---|---|
| 1 | Repo, dowody, backup | backup CSV istnieje, `git log` ma 1 commit |
| 2 | Smoke test menu | **przechodzi na starej binarce** |
| 3 | SPM + Session/Bucket | `swift test` zielony (1) |
| 4 | VPNStore — CSV | `swift test` zielony (5) |
| 5 | VPNStore — state | `swift test` zielony (8) |
| 6 | Totals | `swift test` zielony (12) |
| 7 | TimeFormat | `swift test` zielony (15) |
| 8 | AppDelegate + main | `swift build -c release` przechodzi |
| 9 | build.sh + bundle | dwie instancje obok siebie wyglądają tak samo |
| 10 | Skrypty + testy bash | `run-tests.sh` → `ALL TESTS PASSED` |
| 11 | launchd + install.sh | wyrenderowane plisty `diff`-ują się do zera |
| 12 | Cutover | `verify-menu.sh` OK, MD5 CSV bez zmian |
| 13 | README + pamięć | `git log` 15 commitów |

Zadania 3–7 są od siebie zależne sekwencyjnie (każde buduje na typach poprzedniego). Zadanie 10 jest niezależne od 3–9 i może iść równolegle. Zadanie 2 musi się wydarzyć, **dopóki stara apka działa** — po Zadaniu 12 nie ma już do czego porównywać.
