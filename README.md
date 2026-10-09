# VPN Time

Tracker czasu spędzonego na VPN-ie (Tunnelblick) dla macOS: ikona w pasku menu
z licznikiem bieżącej sesji i sumami dziś / ten tydzień / ten miesiąc, plus
raport w terminalu.

Powstał, bo Tunnelblick nie zapisuje sumarycznego czasu — log pojedynczego
połączenia jest nadpisywany przy kolejnym, a unified log macOS ma retencję
rzędu dwóch dni. Nie ma więc skąd odczytać „ile godzin byłem na VPN-ie w tym
miesiącu".

## Architektura

Dwa niezależne byty:

- **Poller** (`vpn-track.sh`, launchd co 30 s) — jedyne źródło surowych danych.
  Sprawdza, czy żyje proces openvpn Tunnelblicka; przy połączeniu zapisuje
  `~/.vpn-sessions.state`, przy rozłączeniu dopisuje wiersz do
  `~/.vpn-sessions.csv`. Przy okazji notuje ciągi aktywności przy komputerze
  (`~/.vpn-activity.*`). Działa niezależnie od tego, czy apka jest uruchomiona.
- **Widok** (`VPN Time.app`) — czyta te pliki co 15 s. Sam zapisuje tylko plist
  autostartu i historię początków pracy (`~/.vpn-workdays.csv`). Zamknięcie apki
  nie przerywa zbierania danych.

Rdzeń logiki (`VPNTimeCore`) jest oddzielony od AppKit, żeby dał się testować
jednostkowo; `AppDelegate` jest cienki i weryfikowany end-to-end.

## Komponenty i ścieżki docelowe

| Element | Ścieżka |
|---|---|
| Apka | `~/Applications/VPN Time.app` |
| Poller | `~/.local/bin/vpn-track.sh` |
| Raport CLI | `~/.local/bin/vpn-report.sh` |
| Agent pollera | `~/Library/LaunchAgents/com.redge.vpntrack.plist` |
| Agent apki | `~/Library/LaunchAgents/com.redge.vpntimebar.plist` |
| Dane | `~/.vpn-sessions.csv`, `~/.vpn-sessions.state` |
| Aktywność | `~/.vpn-activity.csv` (zamknięte ciągi), `~/.vpn-activity.state` (bieżący) |
| Dni pracy | `~/.vpn-workdays.csv` (`date,start_iso,end_iso,source`) |

## Instalacja

```bash
./build.sh && ./install.sh
```

`install.sh` jest idempotentny i przed każdą podmianą robi kopię danych sesji.
Po instalacji apka wstaje z opóźnieniem do ~10 s — LaunchServices ocenia świeżo
skopiowany, podpisany ad-hoc bundle.

## Testy

```bash
./test/run-tests.sh      # testy jednostkowe Swift + testy obu skryptów bash
./tools/verify-menu.sh   # zgodność menu działającej apki ze specyfikacją
```

`verify-menu.sh` czyta menu przez System Events, więc wymaga uprawnienia
**Dostępność** dla terminala, z którego jest uruchamiany.

## Początek pracy

Pod stanem połączenia menu pokazuje wiersz `Praca od 08:12 (aktywność) · 6h 05m`,
czyli kiedy zaczął się dzień pracy i ile czasu od tego minęło. Licznik to czas
brutto od startu, przerwy nie są odejmowane.

Jak apka wykrywa start:

- Poller co 30 s czyta czas bezczynności klawiatury i myszy (`HIDIdleTime`).
  Aktywność w ostatniej minucie przedłuża bieżący **ciąg aktywności**. Przerwa
  dłuższa niż **30 min** (także uśpienie Maca) zamyka ciąg i zaczyna nowy.
- Startem jest **początek ciągu, w którym nastąpiło pierwsze dzisiejsze
  połączenie VPN**. Rzut oka na laptopa o 7:00 nie liczy się, jeśli właściwa
  praca ruszyła o 8:40, a VPN o 8:45 — start to 8:40.
- Gdy dziś nie było jeszcze VPN-a, pokazany jest pierwszy ciąg aktywności z
  dopiskiem `(bez VPN)`, jako start wstępny.
- Źródło w nawiasie: `aktywność` (ciąg zaczął się przed VPN-em), `VPN` (brak
  wcześniejszej aktywności), `ręcznie`.

Przełącznik **Wykrywaj początek pracy** w menu wyłącza wykrywanie. Wtedy liczy
się tylko ręczna wartość, a bez niej menu pokazuje `Praca: nie wykryto`.

## Formularz „Czas pracy”

Pozycje **Początek pracy** i **Koniec pracy** w menu otwierają jedno okno.

Górna część dotyczy **dzisiaj**:

- początek: `Automatycznie` (z podglądem, co zostało wykryte) albo `Ręcznie` z
  godziną. Ręczna wartość obowiązuje **tylko tego dnia**; następnego dnia start
  znów jest wykrywany;
- przełącznik wykrywania;
- koniec: `Wyłączony`, `O godzinie` albo `Po … od początku pracy`;
- podgląd na żywo, np. `Dziś: 08:00 → 16:00 (8h 00m)`.

`Zapisz` zatwierdza wszystko naraz. Jeśli koniec według nowych ustawień już
minął, nic nie zamyka się od razu. Zapis bez zmiany reguły końca nie odpali go
drugi raz tego samego dnia.

Dolna część to **dni pracy** z `~/.vpn-workdays.csv`, łącznie z dzisiejszym
(wiersz `dziś`). Kliknięcie wiersza ładuje dzień do edycji. Data, godzina `od`
i `do`, potem `Zapisz dzień`; wybranie daty, której nie ma w tabeli, dodaje
nowy dzień. `Usuń dzień` kasuje wiersz. Poprawione minione dni mają źródło
`poprawiony` i apka już ich nie nadpisuje.

Dzisiejszy wiersz powstaje z ustawień: start jak w menu, koniec według reguły
końca pracy (np. start + 11 h). Zapis dzisiejszego dnia w tabeli ustawia
ręczny początek na dziś i zapamiętuje podany koniec. Ten koniec trafia tylko do
historii; o zamknięciu Tunnelblicka dalej decyduje reguła. Kolejne `Zapisz` w
górnej części wraca do końca z reguły. Dzisiejszego wiersza nie da się usunąć —
służy do tego `Automatycznie`.

Historia ma kolumny `date,start_iso,end_iso,source`; starsze pliki bez kolumny
końca są czytane dalej. Po uruchomieniu apka uzupełnia brakujące minione dni:
start według reguły wykrywania, koniec jako koniec ostatniej sesji VPN tego dnia.
Dni bez VPN-a nie trafiają do historii. `vpn-report.sh` (widok dni) dopisuje je
do wiersza: `2026-10-02     7h 40m   start 08:12  koniec 16:30`.

## Koniec pracy

Koniec pracy ustawia się w formularzu „Czas pracy”. **O godzinie** to dowolna
godzina i minuta. **Po … od początku pracy** to np. `08:00`, czyli 8 h od
wykrytego lub ręcznie ustawionego startu. Gdy ten moment nadejdzie, apka rozłącza
VPN i zamyka Tunnelblicka, co domyka sesję w CSV.

Trzy rzeczy warto wiedzieć:

- Zamknięcie odpala się **tylko przy aktywnej sesji VPN**. Ustawiona godzina
  przy rozłączonym VPN-ie nic nie robi; nie zamknie też Tunnelblicka, jeśli
  połączysz się ponownie po godzinie końca pracy.
- Odpala się **raz dziennie**. Data ostatniego odpalenia siedzi w preferencjach,
  więc restart apki wieczorem nie wywoła zamknięcia drugi raz.
- Wybranie godziny, która **dziś już minęła**, nie zamyka niczego natychmiast —
  ustawienie wchodzi w życie od następnego dnia. To samo dotyczy ręcznej zmiany
  początku pracy, po której termin „start + N h” okazuje się już miniony.
- W trybie „po czasie” bez znanego startu nic się nie odpala. Gdy koniec już raz
  odpalił danego dnia, późniejsze przesunięcie startu nie odpali go ponownie.

Dokładność to ±15 s (interwał timera apki). Wynik każdej próby zamknięcia ląduje
w `~/Library/Logs/VPNTime.log`.

## Aktualizacje

Na dole menu jest wiersz `Wersja 1.3.0` i pozycja **Sprawdź aktualizacje…**.
Apka pyta GitHuba o najnowsze wydanie (`jash90/vpn-time`, endpoint
`releases/latest`). Ręczne sprawdzenie kończy się zawsze oknem: „masz najnowszą
wersję", błąd albo propozycja instalacji z notatkami wydania. Oprócz tego raz na
24 h apka sprawdza po cichu; gdy coś znajdzie, pozycja zmienia się na
`Zainstaluj aktualizację v1.4.0…`. Bez kliknięcia nic się nie instaluje.

Instalacja:

1. Pobranie `VPN-Time-<tag>.zip` z wydania.
2. Porównanie SHA-256 archiwum z sumą, którą GitHub publikuje przy pliku.
   Wydanie bez tej sumy w ogóle nie jest proponowane.
3. Rozpakowanie i sprawdzenie podpisu: Developer ID zespołu `H2X8YGN869`,
   identyfikator `com.redge.vpntimebar`.
4. Wersja w pobranym `Info.plist` musi być wyższa od bieżącej.
5. Apka uruchamia `update-helper.sh` (ze swojego bundla) i się zamyka. Helper
   czeka na jej koniec, podmienia bundle (stary trafia na bok i wraca, jeśli
   podmiana się nie uda), instaluje `vpn-track.sh` i `vpn-report.sh` z nowego
   bundla do `~/.local/bin`, przeładowuje agenta pollera i uruchamia apkę.

Każdy krok ląduje w `~/Library/Logs/VPNTime.log`. Aktualizacja działa tylko
tam, gdzie apka może pisać do folderu nadrzędnego (domyślnie `~/Applications`).

`release.sh` odmawia wydania, gdy tag nie zgadza się z
`CFBundleShortVersionString` w `bundle/Info.plist`.

## Aliasy

```
alias vpntime='~/.local/bin/vpn-report.sh'
alias vpntime-week='~/.local/bin/vpn-report.sh week'
alias vpntime-month='~/.local/bin/vpn-report.sh month'
```

## Wyłączanie

```bash
launchctl unload ~/Library/LaunchAgents/com.redge.vpntimebar.plist  # sam pasek
launchctl unload ~/Library/LaunchAgents/com.redge.vpntrack.plist    # zbieranie danych
```

## Znane ograniczenia

- Dokładność końca sesji ±30 s (interwał pollingu). Początek jest dokładny —
  bierze się z logu openvpn, nie z momentu odpytania.
- **Sesja liczy się w całości do kubełka swojego początku.** Sesja rozpoczęta
  w poniedziałek i trwająca do środy w całości ląduje w poniedziałku, więc
  `Dziś` potrafi pokazywać `0h 00m` mimo aktywnego VPN-a. To zachowanie
  oryginału, zamrożone testami, a nie błąd.
- Wiersz „od HH:mm" nie pokazuje daty, więc przy sesjach wielodniowych sama
  godzina bywa myląca.
- Tydzień liczony po ISO (od poniedziałku), spójnie z `%G-W%V` w raporcie CLI.

## Jak powstało to repo

Źródła `main.swift` zginęły 2026-07-08 razem z efemerycznym scratchpadem sesji.
Specyfikację odtworzono empirycznie z działającej binarki na innej maszynie —
demanglowane symbole Swift, literały z sekcji `__TEXT`, zrzut żywego menu przez
System Events, stałe AppKit zdekodowane z `otool -tV`. Zapis tego śledztwa:
[`docs/recovered-api.md`](docs/recovered-api.md), pełny plan odtworzenia:
[`docs/superpowers/plans/`](docs/superpowers/plans/).

Pięć rzeczy w tym repo **nie** pochodzi z oryginału i są świadomymi zmianami:
ikona aplikacji (oryginał jej nie miał), własny glif w pasku menu zamiast
systemowych symboli `lock.fill` / `lock.open`, funkcja „Koniec pracy", funkcja
„Początek pracy" (razem cztery nowe pozycje menu, przez co `verify-menu.sh`
sprawdza teraz 18 pozycji zamiast 14) oraz same skrypty bash, które nie
przetrwały w żadnej kopii i zostały odtworzone z kontraktów zamrożonych w
testach.
