# Karty procesów i RAM z ikonami aplikacji

Data: 2026-08-26
Status: zatwierdzone przez użytkownika

## Cel

Przebudować prezentację sekcji `Procesy` i `RAM` w pływającym panelu ThermoBar
na czytelny układ inspirowany referencją użytkownika: mocny nagłówek z bieżącą
metryką systemową, separator oraz pojedyncze wiersze z ikoną aplikacji, nazwą,
wartościami i przyciskiem otwierającym Monitor aktywności.

Zmiana dotyczy prezentacji i danych potrzebnych do rozpoznawania ikon. Nie zmienia
rankingu procesów, agregacji pamięci, częstotliwości pomiarów ani limitu pięciu
pozycji w każdej sekcji.

## Wygląd i zachowanie

Obie sekcje korzystają z tego samego wzorca:

- pogrubiony tytuł po lewej i bieżące użycie całego systemu po prawej;
- cienki separator pod nagłówkiem;
- maksymalnie pięć równych, jednowierszowych pozycji;
- ikona aplikacji lub pliku wykonywalnego o rozmiarze około 22–24 punktów;
- nazwa skracana z ogona, z pełną nazwą w podpowiedzi;
- wartości liczbowe wyrównane do prawej i zapisane cyframi tablicowymi;
- przycisk z symbolem `arrow.up.right.square` po prawej stronie.

Sekcja `Procesy` pokazuje w nagłówku `CPU <wartość> · GPU <wartość>`. Jej
wiersze zachowują dwie osobne kolumny CPU i GPU. Brak wiarygodnego odczytu GPU
nadal jest oznaczany przez `—`.

Sekcja `RAM` pokazuje w nagłówku procent zajętej pamięci systemowej. Każdy
wiersz ma jedną kolumnę sformatowanej pamięci.

Widoczne numery rankingu `1–5` znikają. Kolejność wierszy nadal jednoznacznie
reprezentuje ranking. Nazwa ani ikona nie są elementami interaktywnymi.

Kliknięcie przycisku w dowolnym wierszu jedynie uruchamia systemowy Monitor
aktywności. ThermoBar nie próbuje zaznaczać procesu ani przekazywać PID, ponieważ
Monitor aktywności nie udostępnia stabilnego publicznego interfejsu do takiego
sterowania.

## Dane i granice modułów

`ThermoBarCore` pozostaje niezależny od AppKit i nie przenosi obiektów `NSImage`.
Czytnik procesów rozszerza zweryfikowaną tożsamość procesu o opcjonalną lokalną
ścieżkę służącą wyłącznie do rozpoznania ikony:

- dla procesu wewnątrz pakietu `.app` jest to ścieżka zewnętrznego pakietu
  aplikacji, którego nazwa już dziś definiuje grupę RAM;
- dla samodzielnego programu jest to znormalizowana ścieżka pliku wykonywalnego;
- dla tożsamości awaryjnej opartej wyłącznie na krótkiej nazwie ścieżka jest
  nieobecna.

Ścieżka pochodzi z tego samego podwójnego odczytu tożsamości, który chroni przed
podmianą PID podczas próbkowania. Kalkulator przekazuje ją do wpisów CPU/GPU i
RAM bez wykonywania operacji na plikach. Wszystkie rekordy tej samej grupy RAM
muszą wskazywać tę samą tożsamość ikony; konflikt unieważnia odczyt grupy zamiast
wybierać przypadkową ikonę.

W celu zachowania zgodności źródłowej publiczne inicjalizatory wpisów otrzymują
opcjonalną ścieżkę z domyślną wartością `nil`. Ranking, sortowanie, wartości i
limity pozostają niezmienione.

## Rozpoznawanie ikon

Warstwa aplikacji ThermoBar zamienia ścieżkę na ikonę przez `NSWorkspace`.
Odpowiedzialność jest zamknięta w małym dostawcy ikon wstrzykiwanym do widoku.
Dostawca buforuje wynik według ścieżki, aby cykliczne odświeżenia pomiarów nie
powodowały kolejnych odczytów z dysku.

Brak ścieżki, nieistniejący plik lub błąd rozpoznania nie ukrywa wiersza. Widok
pokazuje wtedy neutralny symbol systemowy dla pliku wykonywalnego. Procesy
pomocnicze, takie jak przeglądarkowe helpery, używają ikony zewnętrznej aplikacji,
ale zachowują własną nazwę procesu w sekcji `Procesy`.

## Metryki nagłówków

`ThermoBarPresentation` pozostaje jedynym miejscem formatowania bieżących metryk
systemowych. Przekazuje do listy gotowe wartości CPU, GPU i procent RAM; widok
nie przelicza ponownie danych ze snapshotu.

Gdy metryka jest niedostępna lub snapshot nieaktualny, odpowiednia wartość w
nagłówku ma postać `—`. Stany `pomiar` i `niedostępne` sekcji zachowują istniejące
teksty zastępcze pod nagłówkiem.

## Otwieranie Monitora aktywności

Mały serwis w warstwie aplikacji otwiera znaną systemową lokalizację Monitora
aktywności przez `NSWorkspace`. Funkcja nie uruchamia podprocesu, nie używa
powłoki i nie dodaje nowych uprawnień. Akcja jest wstrzykiwana do
`ResourceConsumerList`, dzięki czemu zachowanie przycisku można sprawdzić bez
uruchamiania zewnętrznej aplikacji w testach.

Wszystkie przyciski wykonują tę samą akcję. Niepowodzenie systemowego wywołania
nie wpływa na pomiary ani stan listy.

## Dostępność i układ adaptacyjny

- Ikony są dekoracyjne i ukryte przed VoiceOver.
- Wiersz zachowuje połączoną etykietę zawierającą nazwę, pozycję rankingu i
  wartości, mimo że numer rankingu nie jest widoczny.
- Przycisk ma osobny fokus klawiatury, podpowiedź oraz etykietę
  `Otwórz Monitor aktywności — <nazwa>`.
- Kolumny liczbowe i ikona skalują się z tekstem w granicach pozwalających
  zachować jedną linię przy panelu szerokości 260 punktów.
- Skracana jest wyłącznie nazwa procesu lub aplikacji; wartości i przycisk nie
  mogą się zawijać ani znikać.
- Istniejący tryb zwiększonego kontrastu i ograniczenia ruchu pozostaje
  respektowany; zmiana nie dodaje animacji.

## Weryfikacja

Testy rdzenia obejmą:

- ścieżkę zewnętrznego pakietu dla procesu pomocniczego w zagnieżdżonym `.app`;
- ścieżkę samodzielnego programu oraz brak ścieżki w tożsamości awaryjnej;
- przenoszenie ścieżki do wpisów procesów i agregatów RAM;
- odrzucenie sprzecznych tożsamości ikony w jednej grupie;
- brak zmian w rankingu, agregacji i limicie pięciu pozycji.

Testy aplikacji obejmą:

- format nagłówków CPU/GPU i RAM, w tym wartości niedostępne;
- zachowanie etykiet dostępności po usunięciu widocznych numerów;
- wywołanie jednej wstrzykniętej akcji przez przyciski obu sekcji;
- stabilny układ wartości, ikon i akcji przy szerokości panelu 260 punktów;
- awaryjną ikonę dla brakującej lub nierozpoznanej ścieżki.

Końcowa weryfikacja obejmie pełne `swift test`, release build, istniejący audyt
bezpieczeństwa oraz wizualne sprawdzenie zbudowanej aplikacji z obiema sekcjami
widocznymi.

## Poza zakresem

- zwiększenie limitu z pięciu do sześciu wierszy;
- zmiana algorytmu rankingu CPU/GPU albo agregacji RAM;
- wybieranie lub filtrowanie konkretnego PID w Monitorze aktywności;
- menu kontekstowe, zamykanie procesów lub sterowanie ich priorytetem;
- sieć, telemetria, nowe zależności i dodatkowe uprawnienia.
