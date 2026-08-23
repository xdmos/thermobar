# Lista procesów CPU/GPU

Data: 2026-08-23  
Status: zatwierdzone przez użytkownika

Uwaga: 2026-08-23 użytkownik zatwierdził zmianę klucza rankingu z wyłącznie
CPU na `max(CPU, GPU)`; wcześniejsze sformułowania CPU-only zostały tym samym
zastąpione. Tego samego dnia użytkownik zatwierdził również podniesienie
limitu sekcji RAM z trzech do pięciu pozycji.

## Cel

Zastąpić mylące sortowanie listy `CPU/GPU` po GPU widokiem podobnym do
aplikacji Stats: pięć najbardziej obciążonych obliczeniowo procesów, gdzie
obciążenie jest równe `max(CPU, GPU)`, oraz ich dostępne użycie GPU na tym samym
wierszu.

## Zachowanie

- Sekcja nosi tytuł **Procesy**.
- Pokazuje od jednej do pięciu pojedynczych procesów (PID), posortowanych
  malejąco po `max(CPU, GPU)`. Nadal są to pojedyncze procesy, podobnie jak na
  liście „Top Processes” aplikacji Stats, lecz ranking celowo się od niej
  różni: proces obciążający wyłącznie GPU także trafia wysoko, ponieważ panel
  ma pokazywać największe obciążenie niezależnie od tego, która jednostka je
  ponosi.
- Remisy `max(CPU, GPU)` rozstrzygają kolejno: wyższe CPU, potem nazwa procesu
  przez istniejący `nameOrder` (porządek leksykograficzny scalarów Unicode), a
  na końcu niższy PID. Dzięki temu kolejność jest w pełni deterministyczna.
- `max(CPU, GPU)` decyduje również o składzie pięciu pozycji, nie tylko o ich
  kolejności: proces z niskim CPU i wysokim GPU może wyprzeć proces z wyższym
  CPU.
- Nazwa wiersza jest faktyczną nazwą wykonywalnego procesu (np. `Claude Helper`),
  a nie nazwą otaczającego pakietu aplikacji. Dzięki temu pomocnicze procesy
  są rozróżnialne tak jak w Stats.
- Każda pozycja jest pojedynczym wierszem: numer, nazwa procesu oraz dwie
  zarezerwowane kolumny liczbowe wyrównane do prawej — CPU i GPU. Nagłówki
  `CPU` i `GPU` stoją raz, w wierszu tytułu sekcji. Panel ma tylko 260 punktów
  szerokości, więc wartości nigdy się nie zawijają, a wiersze mają równą
  wysokość; skraca się wyłącznie nazwa procesu (z ogona, z pełną nazwą w
  podpowiedzi po najechaniu).
- Gdy dla procesu nie ma wiarygodnego licznika Metal GPU, kolumna GPU pokazuje
  `—`; brakujący licznik liczy się jako zero, więc taki proces jest oceniany na
  podstawie samego CPU i nie jest karany za brak licznika.
- Wartości CPU zachowują dotychczasową semantykę w stylu Activity Monitor:
  jeden proces wielowątkowy może przekroczyć 100%.
- Sekcja RAM nadal agreguje procesy należące do tej samej aplikacji, a jej
  opcja widoczności nie zmienia się. Pokazuje teraz do pięciu pozycji,
  dokładnie tak jak sekcja `Procesy`. Jest to nowsze ustalenie, które
  zastępuje limit trzech wierszy zapisany w
  `docs/superpowers/specs/2026-08-13-thermobar-top-consumers-design.md`. Jej
  wiersze wracają do układu z pierwotnej specyfikacji: jedna linia z wartością
  wyrównaną do prawej, spójna z kolumnami sekcji `Procesy`.
- Stan pierwszego pomiaru i błąd odczytu nadal korzystają z obecnych tekstów
  zastępczych.

## Implementacja

1. W `ResourceConsumerCalculator` zachować zgrupowaną ścieżkę RAM, natomiast
   z delty CPU/GPU tworzyć osobne wiersze per PID, sortowane wyłącznie według
   `max(CPU, GPU)` i ograniczone do pięciu.
   Modele wejściowe muszą przenosić oddzielnie nazwę procesu dla CPU/GPU oraz
   nazwę aplikacji i identyfikator grupy dla RAM.
2. W `ResourceConsumerList` usunąć dwuwierszowy układ procesów oraz RAM,
   zmienić tytuł na `Procesy` i renderować CPU oraz GPU jako dwie kolumny o
   stałej szerokości (skalowanej `@ScaledMetric` razem z Dynamic Type).
3. Zaktualizować katalog polski i angielski oraz testy kalkulatora i prezentacji.

## Weryfikacja

- Test sortowania: malejący `max(CPU, GPU)`, a przy remisie wyższe CPU,
  następnie `nameOrder` nazwy i niższy PID; kolejność jest deterministyczna.
- Test składu: proces z niskim CPU i wysokim GPU może wejść do pierwszej piątki
  i wyprzeć pozycję wybraną wcześniej wyłącznie po CPU.
- Test limitu: lista procesów i lista RAM zawierają każda najwyżej pięć
  pozycji.
- Test prezentacji: CPU i GPU są formatowane osobno, dla własnych kolumn tego
  samego wiersza, a brak GPU pokazuje znak `—`.
- Uruchomić odpowiednie testy pakietu oraz pełne `swift test`.
