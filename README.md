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

- **Poller** (`vpn-track.sh`, launchd co 30 s) — jedyne źródło danych. Sprawdza,
  czy żyje proces openvpn Tunnelblicka; przy połączeniu zapisuje
  `~/.vpn-sessions.state`, przy rozłączeniu dopisuje wiersz do
  `~/.vpn-sessions.csv`. Działa niezależnie od tego, czy apka jest uruchomiona.
- **Widok** (`VPN Time.app`) — czyta CSV i plik stanu co 15 s. Nic nie zapisuje
  poza plistem autostartu. Zamknięcie apki nie przerywa zbierania danych.

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

## Koniec pracy

W menu, pod przełącznikiem autostartu, siedzi pozycja **Koniec pracy**.
Kliknięcie otwiera panel z pickerem godziny — dowolna godzina i minuta, do
wpisania z klawiatury albo wyklikania strzałkami, Enter zatwierdza. Po ustawieniu
apka zamyka Tunnelblicka, gdy ta godzina nadejdzie — co rozłącza VPN i domyka
sesję w CSV. Przycisk `Wyłącz` kasuje ustawienie.

Trzy rzeczy warto wiedzieć:

- Zamknięcie odpala się **tylko przy aktywnej sesji VPN**. Ustawiona godzina
  przy rozłączonym VPN-ie nic nie robi; nie zamknie też Tunnelblicka, jeśli
  połączysz się ponownie po godzinie końca pracy.
- Odpala się **raz dziennie**. Data ostatniego odpalenia siedzi w preferencjach,
  więc restart apki wieczorem nie wywoła zamknięcia drugi raz.
- Wybranie godziny, która **dziś już minęła**, nie zamyka niczego natychmiast —
  ustawienie wchodzi w życie od następnego dnia.

Dokładność to ±15 s (interwał timera apki). Wynik każdej próby zamknięcia ląduje
w `~/Library/Logs/VPNTime.log`.

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

Cztery rzeczy w tym repo **nie** pochodzą z oryginału i są świadomymi zmianami:
ikona aplikacji (oryginał jej nie miał), własny glif w pasku menu zamiast
systemowych symboli `lock.fill` / `lock.open`, funkcja „Koniec pracy" (nowa
pozycja menu, przez co `verify-menu.sh` sprawdza teraz 15 pozycji zamiast 14 —
zgodność z odzyskanym layoutem dowodzą dalej pozycje 1–9) oraz same skrypty
bash, które nie przetrwały w żadnej kopii i zostały odtworzone z kontraktów
zamrożonych w testach.
