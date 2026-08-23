# Lista procesów CPU/GPU

Data: 2026-08-23  
Status: zatwierdzone przez użytkownika

## Cel

Zastąpić mylące sortowanie listy `CPU/GPU` po GPU widokiem podobnym do
aplikacji Stats: pięć najbardziej obciążających CPU procesów oraz ich dostępne
użycie GPU na tym samym wierszu.

## Zachowanie

- Sekcja nosi tytuł **Procesy**.
- Pokazuje od jednej do pięciu pozycji, posortowanych malejąco po użyciu CPU.
- Każda pozycja jest pojedynczym wierszem: numer, nazwa procesu oraz
  `CPU <wartość> · GPU <wartość>`.
- Gdy dla procesu nie ma wiarygodnego licznika Metal GPU, UI pokazuje
  `GPU —`; brak ten nie wpływa na kolejność.
- Wartości CPU zachowują dotychczasową semantykę w stylu Activity Monitor:
  jeden proces wielowątkowy może przekroczyć 100%.
- Sekcja RAM oraz jej opcja widoczności nie zmieniają się.
- Stan pierwszego pomiaru i błąd odczytu nadal korzystają z obecnych tekstów
  zastępczych.

## Implementacja

1. W `ResourceConsumerCalculator` sortować wiersze wyłącznie według CPU i
   ograniczać wynik do pięciu.
2. W `ResourceConsumerList` usunąć dwuwierszowy układ procesów, zmienić tytuł
   na `Procesy` i renderować CPU oraz GPU jako pojedynczą wartość po prawej.
3. Zaktualizować katalog polski i angielski oraz testy kalkulatora i prezentacji.

## Weryfikacja

- Test sortowania: wyższe CPU zawsze wygrywa nad wyższym GPU.
- Test limitu: wynik zawiera najwyżej pięć pozycji.
- Test prezentacji: CPU i GPU są na tym samym wierszu, a brak GPU pokazuje
  znak `—`.
- Uruchomić odpowiednie testy pakietu oraz pełne `swift test`.
