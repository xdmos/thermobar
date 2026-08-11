# ThermoBar

ThermoBar to lekka aplikacja menu bar dla macOS, która pokazuje bieżące
obciążenie i stan termiczny Maca. Działa lokalnie, nie wysyła telemetrii i nie
wymaga konta ani połączenia z Internetem.

## Funkcje

- pływający panel oraz menu bar;
- użycie CPU, GPU i pamięci RAM;
- średnie temperatury CPU i GPU oraz najgorętszy punkt układu;
- prędkość aktualnie najszybszego wentylatora w RPM;
- systemowy stan termiczny macOS;
- opcjonalne lokalne powiadomienia o poważnym i krytycznym stanie termicznym;
- opcjonalne uruchamianie przy logowaniu;
- adaptacyjne próbkowanie zależne od widoczności panelu i uśpienia Maca.

ThermoBar jedynie odczytuje dane. Nie zmienia prędkości wentylatorów i nie
zapisuje wartości do AppleSMC.

## Wymagania

- macOS 27.0 lub nowszy;
- Xcode z toolchainem Swift 6.2;
- Apple Silicon.

Pełny odczyt prywatnych czujników jest obecnie zweryfikowany wyłącznie dla
`Mac17,9` z kompilacją macOS `26A5388g`. Na innym modelu lub po aktualizacji
systemu ThermoBar celowo wyłączy niezweryfikowane temperatury, GPU i RPM zamiast
zgadywać klucze czujników. Publiczne metryki CPU, RAM i stan termiczny macOS
pozostają dostępne.

## Instalacja ze źródeł

```bash
git clone https://github.com/xdmos/thermobar.git
cd thermobar
./Scripts/build-app.sh
ditto build/ThermoBar.app /Applications/ThermoBar.app
open /Applications/ThermoBar.app
```

Skrypt tworzy lokalnie podpisany pakiet `build/ThermoBar.app`. Po uruchomieniu
ikona ThermoBar pojawi się w menu barze. Panel można pokazywać i ukrywać z menu
aplikacji.

Powiadomienia wymagają zgody macOS. Włączenie uruchamiania przy logowaniu może
wymagać potwierdzenia w **Ustawienia systemowe → Ogólne → Elementy logowania i
rozszerzenia**.

## Prywatność i bezpieczeństwo

- brak zależności zewnętrznych SwiftPM;
- brak sieci, telemetrii i analityki;
- brak subprocessów, XPC i helpera uprzywilejowanego;
- puste entitlements;
- AppleSMC jest używane wyłącznie do odczytu z dokładnej listy kluczy dla
  obsługiwanego modelu i kompilacji systemu;
- ustawienia aplikacji są przechowywane lokalnie w `UserDefaults`.

## Testy

Podstawowy zestaw testów:

```bash
swift test -Xswiftc -strict-concurrency=complete
```

Dodatkowe bramki jakości:

```bash
swift test --sanitize=thread -Xswiftc -strict-concurrency=complete
THERMOBAR_RUN_LIVE_SENSORS=1 swift test --filter Live
THERMOBAR_RUN_PERFORMANCE=1 swift test -c release --filter SensorReadPerformanceTests
./Scripts/build-app.sh
./Scripts/verify-security.sh build/ThermoBar.app
```

Testy `Live` i pomiar wydajności są przeznaczone dla dokładnie obsługiwanego
modelu i kompilacji systemu.

## Informacje o kodzie zewnętrznym

Projekt nie ma zależności wykonywalnych innych firm. Informacje o źródle wiedzy
dotyczącej układu ABI AppleSMC znajdują się w
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
