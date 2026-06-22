# ADR-024 — Cross-Reference Back-Stack Navigation

**Status:** Proposed (2026-06-21)
**Amends:** `spec-study-mode-redesign.md` (R4 — leading toolbar морфінг; R7 — вихід зі Study Mode)
**Related:** ADR-005 (AppNavigationRouter — cross-tab навігація), ADR-021 (Study Mode pinning/sizing)

---

## Контекст

У рідері можна перейти з cross-ref на цільовий вірш — зручно подивитися вірш у контексті. Зараз:

- Cross-ref тап (`VerseTabContent.swift`, ~р.183) → `router.requestNavigation(to:)` → `ContentView.onChange` → `vm.navigateToVerse(id:)` → **замінює** `selectedVerse` цільовим. Історія переходів ніде не зберігається.
- Єдина кнопка виходу — **«‹ Назад»** у leading toolbar (`ReaderView.backButton`, ~р.395): `vm.activeSheet = nil` → закриває Sheet і знімає виділення вірша. `onDismiss` чистить `clearWordSelection()`.
- Trailing `‹ ›` чеврони (R5) — навігація **між сусідніми віршами в межах глави** (`navigateToPreviousVerse`/`navigateToNextVerse`), не через `navigateToVerse`.

Проблема: перехід по cross-ref може бути багаторівневим (A → B → C → …), а повернутися до точки входу неможливо — тільки повністю закрити Sheet (свайп-вниз або «Назад»). Семантика «Назад» перевантажена: вона і «закрити», і єдиний спосіб вийти.

## Рішення

Ввести **cross-ref back-stack** у `ReaderViewModel` і **розщепити** кнопку leading toolbar на дві семантики:

- **«Закрити»** (без шеврона) — закриває Sheet, деактивує вірш. Це поточна дія «‹ Назад», просто перейменована й без шеврона.
- **«‹ Назад»** (вигляд **незмінний** — `chevron.backward` + лейбл `studymode.back`, `.headline`) — крок назад по back-стеку до вірша, з якого зробили cross-ref перехід. Майже завжди це зміна книги/глави (на відміну від `‹ ›` чевронів, що ходять у межах однієї глави).

### Дані (нове в `ReaderViewModel`)

```
@Published private(set) var crossRefBackStack: [String] = []  // verseId-и, З ЯКИХ стрибнули; топ = останній
var canCrossRefBack: Bool { !crossRefBackStack.isEmpty }
```

Стек — session-scoped до відкритого Sheet; очищається при закритті.

### Джерело переходу керує стеком

`navigateToVerse(id:source:)` отримує параметр-enum:

| `source`     | Хто викликає                                            | Дія зі стеком                              |
|--------------|---------------------------------------------------------|--------------------------------------------|
| `.fresh` (default) | `tapVerse`, пошук, закладки, нотатки, `pendingVerseId` | **очистити** стек (нова точка входу)        |
| `.crossRef`  | тап по cross-ref у відкритому Sheet                     | **push** поточного `selectedVerse.id`, потім перехід |
| `.back`      | кнопка «‹ Назад»                                         | без push/clear (стек уже спопнутий викликачем) |

Cross-ref тап викликає новий метод `followCrossReference(to:)` **напряму на VM**, а не через `router`:

```
func followCrossReference(to verseId: String) {
    navigateToVerse(id: verseId, source: .crossRef)
}

func crossRefBack() {
    guard let previous = crossRefBackStack.popLast() else { return }
    navigateToVerse(id: previous, source: .back)
}
```

Router-хоп (`requestNavigation`) лишається **тільки** для cross-tab входів (пошук, закладки, нотатки з інших табів). Cross-ref завжди в межах активного рідера, тож проміжний хоп через інший таб не потрібен; зміну книги/глави `navigateToVerse` робить і так.

> **Push — у success-гілці** `navigateToVerse` (де `verses.first(where:)` знайшов цільовий вірш), щоб невдалий перехід не лишив «сирий» origin у стеку.

### Leading toolbar — три стани (амендить R4)

Поточний морфінг **пікер ⇄ «Назад»** стає **трьохстановим**, зберігаючи ту саму in-place morph-трансформацію (content swap + `.blurReplace`, пружина — рішення A1 у spec):

| Стан                                  | Контент leading toolbar           | Дія                       |
|---------------------------------------|-----------------------------------|---------------------------|
| Sheet закритий (рідер)                | `[Book ▾][Translation ▾]` пікери  | відкрити пікери           |
| Sheet відкритий, `crossRefBackStack` порожній | **«Закрити»** (без шеврона)    | `vm.activeSheet = nil`    |
| Sheet відкритий, `crossRefBackStack` непорожній | **«‹ Назад»** (як зараз)      | `vm.crossRefBack()`       |

Анімацію морфінгу треба перевести з ключа-Bool (`vm.activeSheet == .verse`) на 3-станове значення (напр. enum або композит `"\(activeSheet)-\(canCrossRefBack)"`), щоб морф спрацьовував і на переході **Закрити ⇄ Назад** усередині відкритого Sheet.

### Вихід зі Study Mode (амендить R7)

Шляхи виходу без змін: **свайп-вниз** ползунка або кнопка **«Закрити»** (коли стек порожній). Обидва: `vm.activeSheet = nil`. `onDismiss` додатково **очищає `crossRefBackStack`** (наступний вхід — чистий), окрім наявного `clearWordSelection()`.

## Потік

```
Рідер
  │ тап вірш A            (.fresh → стек [])
  ▼
[Sheet: A]   leading = «Закрити»
  │ cross-ref → B         (push A → [A])
  ▼
[Sheet: B]   leading = «‹ Назад»
  │ cross-ref → C         (push B → [A,B])
  ▼
[Sheet: C]   leading = «‹ Назад»
  │ «‹ Назад» (pop B → [A])
  ▼
[Sheet: B]   leading = «‹ Назад»
  │ «‹ Назад» (pop A → [])
  ▼
[Sheet: A]   leading = «Закрити»
  │ «Закрити» / свайп-вниз → закрити, стек очищено
  ▼
Рідер
```

## Граничні випадки / правила

- **`‹ ›` чеврони vs стек:** чеврони ходять між віршами в межах глави й **НЕ чіпають** `crossRefBackStack`. Якщо юзер прийшов A→B по cross-ref, а тоді чевронами перейшов B→B+1, кнопка «‹ Назад» усе одно повертає до A. Чеврони = браузинг у межах тієї ж точки входу; «‹ Назад» = крок по cross-ref історії. (Підтверджено користувачем 2026-06-21.)
- **Цикли** (A→B→A) працюють самі — це лінійна історія, дедуп не потрібен.
- Опц. guard: не пушити, якщо `target == current` (cross-ref сам на себе).
- **Аналітика:** на `.back` пропускати `sessionTracker.incVersesOpened(...)` — вірш уже порахований як unique read при першому відкритті; повернення не має його дублювати.
- **Word/Verse таби** ортогональні стеку — він на рівні вірша, не режиму.

## Обсяг імплементації (малий; без БД/схеми)

- `ReaderViewModel.swift`: `crossRefBackStack`, `canCrossRefBack`, `source`-параметр у `navigateToVerse`, `followCrossReference(to:)`, `crossRefBack()`; очистка стеку в `onDismiss`-шляху (+~25 рядків).
- `ReaderView.swift`: `backButton` → трьохстанова гілка (Закрити/Назад); ключ морф-анімації на 3 стани.
- `VerseTabContent.swift`: cross-ref тап → `vm.followCrossReference(to:)` замість `router.requestNavigation(...)`.
- Рядок `studymode.close` («Закрити») у `Localizable.xcstrings` (UK+EN). `studymode.back` лишається.

## Trade-offs

- **(+)** Зрозуміла, передбачувана навігація вглиб і назад; розвантажена семантика кнопки.
- **(+)** Мінімальна зміна — без нового координатора навігації, без зміни моделі/схеми.
- **(−)** Cross-ref обходить `router` → дві різні точки входу в `navigateToVerse` (in-Reader пряма vs cross-tab через router). Прийнятно: router і був лише про cross-tab перемикання.
- **(−)** Стек тримає лише `verseId` (не позицію скролу/режим) — повернення завжди відкриває цільовий вірш на Verse-табі зверху. Достатньо для MVP; за потреби пізніше зберігати багатший snapshot.

## Що переглянути з ростом

- Якщо знадобиться **forward**-навігація («вперед» після «назад») — стек → курсор-у-масиві.
- Якщо повернення має відновлювати режим (Word) / pill / позицію — зберігати в стеку snapshot замість голого `verseId`.
