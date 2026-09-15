# VPN Time — odzyskana specyfikacja API

**Status:** źródło prawdy dla odtworzenia aplikacji.

**Skąd to pochodzi.** Źródła `main.swift` powstały 2026-07-08 w efemerycznym scratchpadzie
sesji i zostały skasowane razem z nim. Specyfikację poniżej odzyskano empirycznie z
działającej instalacji na **innej maszynie** (użytkownik `redge`):

- nazwy typów i sygnatury — z demanglowanych symboli Swift (`nm -U` + `swift demangle`),
- długie literały UI — z sekcji `__TEXT` binarki,
- krótkie literały (≤15 bajtów, trzymane inline jako immediate) — przez odczytanie żywego
  menu działającej apki przez System Events,
- nazwy symboli SF, interwał timera i stałe AppKit — przez zdekodowanie immediate'ów
  z `otool -tV`.

**Uwaga dla czytelnika.** Na maszynie, na której odtworzono kod (`bartlomiejzimny`,
2026-09-15), oryginalna binarka **nie istnieje**. Nie ma więc `docs/evidence/` ani
możliwości ponownego zrzutu — ten dokument cytuje plan odtworzeniowy
(`docs/superpowers/plans/2026-09-15-vpn-time-recreate.md`), a nie binarkę.

> **Uwaga o aktualności (2026-09-15):** poniższy zrzut menu opisuje **oryginał**.
> Działająca apka ma o jedną pozycję więcej — `Koniec pracy: …` zaraz po
> `Uruchamiaj przy logowaniu` — dodaną na życzenie użytkownika już po
> odtworzeniu. Pozycje 1–9 pozostają bez zmian.

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

