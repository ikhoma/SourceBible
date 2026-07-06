# Reader Resume Position — Design & Spec

**Status:** Draft (proposed 2026-07-02)
**Type:** Feature spec (UX fix) + persistence decision
**Scope:** `ReaderViewModel`, `ReaderView`, `MenuView`, `@AppStorage` keys. **No changes to `sourcebible.db` schema.** Optional GRDB `user_data.db` migration only if Phase 2 (sync) is taken.

---

## 1. Проблема

Додаток **завжди** відкривається на Буття 1:1. `ReaderViewModel.init()` жорстко ставить
`currentBook = GEN`, `currentChapter = 1` і викликає `loadChapter()`. Після кожного
перезапуску (cold launch, або SwiftUI пересоздання VM) прочитане місце губиться —
користувач щоразу гортає назад туди, де читав.

Що вже персиститься сьогодні: тільки `defaultTranslationId` через `UserDefaults`
(відновлюється в тому ж `init` Task-у). Книга, глава і скрол — ні.

## 2. Цілі / Non-goals

**Цілі**
- Після перезапуску відкривати **останню книгу + главу + позицію скролу** (за замовчуванням).
- Пункт у Меню: вибір поведінки при старті — **«Продовжити з місця»** або **«Остання закладка»**.
- Відновлення стійке до зміни розміру шрифту / повороту / зміни перекладу
  (зберігаємо **верхній видимий вірш**, не піксельний офсет).

**Non-goals (поза цим спринтом)**
- Синхронізація позиції між пристроями (можливий Phase 2, див. §9).
- Історія/стек нещодавно прочитаного (тільки одна остання позиція).
- Персист скролу всередині Study Mode / bottom sheet.
- Персист вибраного вірша або відкритого sheet (відновлюємо тільки reading position).

## 3. Рішення користувача (з елісітації 2026-07-02)

| Питання | Рішення |
|---|---|
| Поведінка за замовчуванням | **Continue where I left off** |
| Пункти Меню | **Continue where I left off** + **Last bookmark** (без «Always Genesis») |
| Що таке «остання закладка» | **Most recently created** bookmark |
| Точність скролу | **Top-visible verse** (стійко до relayout) |

## 4. Модель даних

### 4.1 Що зберігаємо

Reading position — **один** запис (не список), 4 поля:

| Поле | Тип | Приклад | Нотатки |
|---|---|---|---|
| `bookId` | String | `"ROM"` | канонічний ID книги (не назва) |
| `chapter` | Int | `5` | |
| `verseAnchorId` | String | `"ROM\|5\|1"` | compound ID верхнього видимого вірша |
| `translationId` | String | `"KJV"` | уже є як `defaultTranslationId`, дублювати не треба |

`verseScrollAnchorId` — це **джерело істини для скролу**. `bookId`/`chapter` дублюють
його для швидкого читання без парсингу (і як fallback, якщо вірш зник — див. §7).

### 4.2 Де зберігаємо — рішення

**Рекомендація: `UserDefaults` через `@AppStorage`** (як `defaultTranslationId`).

Обґрунтування:
- Один запис, невеликий, часто перезаписується — ідеально для `UserDefaults`.
- Не user-authored контент (на відміну від highlights/notes/bookmarks у GRDB).
- Нульова вартість міграції, збігається з наявним патерном налаштувань.
- Втрата цього значення нефатальна (просто відкриється Буття) — durability GRDB зайва.

**Це НЕ evictable-кеш.** `UserDefaults` = plist у контейнері застосунку: переживає
relaunch, ребут, оновлення OS/застосунку; система НЕ витісняє його під тиском пам'яті
(на відміну від `Caches/`); очищується лише при видаленні застосунку. Для «останньої
позиції» цього достатньо.

Trade-off: `UserDefaults` **не синкається** через наявний `SyncEngine` (він працює на
`user_data.db`). Якщо пізніше знадобиться «продовжити на іншому пристрої» —
Phase 2 переносить position у GRDB-таблицю (§9). Абстракція `ReadingPositionStore`
(§6.1) робить цей своп локальним.

**Нові ключі `@AppStorage`:**

```
"launchBehavior"          : String   // "resume" | "lastBookmark"   (default "resume")
"lastReadBookId"          : String   // default ""  ← sentinel: порожньо = стану ще нема
"lastReadChapter"         : Int      // default 1
"lastReadVerseAnchorId"   : String   // default ""  (порожньо → скрол на верх глави)
```

`translationId` НЕ додаємо — використовуємо наявний `defaultTranslationId`.

**Детекція першого старту:** `load()` повертає `nil` коли `lastReadBookId == ""`
(sentinel) — це надійно відрізняє «стану ще нема» (clean install / ніколи не читав)
від реального читання Буття. Nil → gоворить `init` впасти в `GEN 1:1` (§6.2).
Default `"GEN"` тут був би багом: «немає стану» стало б невідрізнити від «читав Буття».

## 5. Захоплення позиції (capture)

`lastReadVerseAnchorId` має **два джерела**, залежно від режиму:

| Режим | Джерело якоря | Чому |
|---|---|---|
| **Study Mode відкритий** (`activeSheet == .verse`) | `selectedVerse.id` | вірш у фокусі — найосмисленіша точка повернення; scroll заблоковано (`scrollDisabled`), тож scroll-tracker тут не джерело |
| **Reading (sheet закритий)** | верхній видимий вірш | природна позиція читання |

Тобто capture-guard — **не** «не писати під час Study Mode» (це була помилка), а
«у Study Mode писати `selectedVerse.id`, у reading — top-visible». `tapVerse` та
`navigateToVerse` уже мають `selectedVerse` — достатньо в них (і при chevron/cross-ref
навігації) викликати `vm.recordReadingPosition(verseId: selectedVerse.id)`.

### 5.1 Top-visible verse у reading-режимі — ІМПЛЕМЕНТОВАНО

**Обраний підхід: `scrollPosition(id:anchor:)` + `scrollTargetLayout()`, read-only.**

Reader — звичайний `VStack` (НЕ `LazyVStack`). Ключове спостереження, що зняло
початкове побоювання: `scrollTargetLayout()` **без** `scrollTargetBehavior` НЕ додає
snapping — він лише маркує рядки як scroll-таргети, тож feel скролу не змінюється і
ADR-021 (pin-позиціювання) не зачеплено. Binding використовується **тільки на читання**
(`onChange`), ніколи не задає скрол програмно → не конфліктує зі StudyPin / `proxy.scrollTo`.

```swift
// VStack: .scrollTargetLayout()
// ScrollView: .scrollPosition(id: $topVisibleVerseID, anchor: .top)
.onChange(of: topVisibleVerseID) { _, id in
    guard !sheetOpen, let id else { return }   // Study Mode → анкор = selectedVerse
    vm.noteReadingAnchor(id)
}
```

Обкладинка/заголовок не мають `.id()` → binding репортить `nil` для них, ми ігноруємо.

**Статус верифікації (2026-07-02, iPhone 17 / iOS 26 sim):**
- ✅ **Restore** підтверджено: launch-arg інжект `JHN|3|16` → застосунок відкрив John 3,
  скрол рівно на в.16 (не Genesis, не в.1). Book/chapter + scroll-to-anchor працюють.
- ⏳ **Capture під час ручного скролу** (чи `scrollPosition(id:)` стабільно репортить
  top verse на non-lazy VStack) — потребує тесту жестами на пристрої/симі. Якщо
  виявиться нестабільним → fallback нижче.

**Fallback (якщо capture нестабільний):** `onScrollGeometryChange(for:){ $0.contentOffset.y }`
(iOS 18) + кумулятивні висоти з наявного height-store; або per-row frame через
named coordinate space + `PreferenceKey`. Обидва не потребують Lazy.

Nil/невизначено (коли зверху обкладинка/заголовок) — **ігноруємо**, тримаємо останній
відомий вірш; fallback `bookId/chapter` усе одно приведе на початок глави.

### 5.2 Коли писати

- Reading-режим: debounce ~300 ms (не писати на кожен кадр скролу).
- Study Mode: одразу при зміні `selectedVerse` (tap / chevron / cross-ref / navigateToVerse).
- `scenePhase == .background` / `.inactive` — форсований flush останнього значення
  (гарантія на випадок kill без наступного onChange).
- Кожна навігація що змінює главу (`loadChapter`, `navigateToVerse`, chevrons,
  edge-swipe) оновлює `bookId/chapter` одразу.

⚠️ **Взаємодія з наявними механізмами (критично — саме той клас багів, від якого
застерігає CLAUDE.md):**
- Capture **read-only**: не використовуємо жоден capture-binding для програмного
  скролу — щоб не конфліктувати з `StudyPinView` (contentOffset) і `proxy.scrollTo(...)`.
- `.id("\(book)-\(chapter)")` на ScrollView скидає скрол при зміні глави — залишаємо
  як є; відновлення (§6) працює ПІСЛЯ того як нова identity змонтована.

## 6. Відновлення (restore)

### 6.1 Абстракція

```swift
protocol ReadingPositionStore {
    var launchBehavior: LaunchBehavior { get set }   // .resume | .lastBookmark
    func load() -> ReadingPosition?
    func save(_ position: ReadingPosition)
}
struct ReadingPosition { let bookId: String; let chapter: Int; let verseAnchorId: String? }
enum LaunchBehavior: String { case resume, lastBookmark }
```

MVP-реалізація `UserDefaultsReadingPositionStore` читає/пише ключі §4.2. Це точка
свопу на GRDB у Phase 2.

### 6.2 Потік у `ReaderViewModel.init()`

Зараз `init` async-Task: вантажить `allBooks`, `availableTranslations`, ставить
`currentTranslation` з `defaultTranslationId`, тоді **жорстко** `GEN`, тоді `loadChapter()`.

Змінюємо тільки блок вибору книги/глави:

```swift
// (після завантаження allBooks/translations)
let target: (bookId: String, chapter: Int, anchor: String?)
switch positionStore.launchBehavior {
case .resume:
    if let p = positionStore.load() { target = (p.bookId, p.chapter, p.verseAnchorId) }
    else { target = ("GEN", 1, nil) }               // перший запуск
case .lastBookmark:
    if let b = store.bookmarks().first,             // §6.3 — most-recently-created
       let vid = b.verseIds.first,
       let parsed = parseVerseId(vid) { target = (parsed.bookId, parsed.chapter, vid) }
    else if let p = positionStore.load() { target = (p.bookId, p.chapter, p.verseAnchorId) }
    else { target = ("GEN", 1, nil) }               // немає закладок → resume/Genesis
}
self.currentBook = allBooks.first { $0.id == target.bookId } ?? allBooks.first ?? currentBook
self.currentChapter = max(1, min(target.chapter, currentBook.chapterCount))  // clamp, §7
self.pendingRestoreAnchorId = target.anchor
self.loadChapter()
```

`pendingRestoreAnchorId` — новий `@Published var pendingRestoreAnchorId: String?`.
`ReaderView` спостерігає його і після рендеру віршів робить **один** `scrollTo(anchor)`:

```swift
.onChange(of: vm.verses.map(\.id)) { _, _ in
    guard let anchor = vm.pendingRestoreAnchorId,
          vm.verses.contains(where: { $0.id == anchor }) else { return }
    DispatchQueue.main.async {
        proxy.scrollTo(anchor, anchor: .top)   // без анімації — миттєве відновлення
        vm.pendingRestoreAnchorId = nil
    }
}
```

Використовуємо наявний `ScrollViewReader.proxy` — restore розв'язаний від
capture-binding. Якщо `anchor == nil` або вірш відсутній — скрол лишається на верху
глави (природний fallback).

### 6.3 «Остання закладка» = most-recently-created

`store.bookmarks()` повертає `[BookmarkWithVerses]`. Треба гарантувати сортування
за створенням DESC. Перевірити, що `Bookmark` має `createdAt` і що `bookmarks()`
сортує (або відсортувати у VM). Перший елемент → його перший `verseId` → позиція.
Якщо закладок нема — тихо падаємо в `resume` (а тоді в Genesis).

## 7. Edge cases

| Випадок | Поведінка |
|---|---|
| Перший запуск (нема position) | Буття 1:1, скрол зверху |
| Збережена книга зникла з БД | fallback `allBooks.first` → Genesis |
| `chapter` > `chapterCount` (напр. БД оновилась) | clamp до `chapterCount` |
| `verseAnchorId` відсутній у главі (versemap/numbering змінився) | скрол на верх глави, без краху |
| Збережений переклад видалено | наявна логіка вже падає в `defaultTranslation` |
| `launchBehavior = lastBookmark`, але закладок нема | resume → Genesis |
| Study Mode був відкритий при kill | якір = `selectedVerse.id` (§5); relaunch скролить на цей вірш, sheet НЕ відновлюємо |
| Псалми зі зсувом нумерації (verse_map) | `verseAnchorId` — це translation-verse compound ID (те, що в `verses`), тож збігається 1:1 з відрендереними рядками; Macula-offset не залучений |

## 8. UI — Меню

Нова секція у `MenuView` (`Form`), між «Переклад» і «Додаток», патерн наявного
`NavigationLink` + `LabeledContent`:

```
Section("menu.section.reading") {
    NavigationLink {
        LaunchBehaviorPickerView(selected: $launchBehavior)   // новий, за зразком DefaultTranslationPickerView
    } label: {
        LabeledContent("menu.launch_behavior", value: launchBehaviorLabel)
    }
}
```

`LaunchBehaviorPickerView` — `List` з двома рядками (checkmark на вибраному), як
`DefaultTranslationPickerView`. Рядки:
- `menu.launch.resume` → «Продовжити з місця» / "Continue reading"
- `menu.launch.last_bookmark` → «Остання закладка» / "Last bookmark"

**Нові рядки локалізації** (EN + UK, `.xcstrings`):
`menu.section.reading`, `menu.launch_behavior`, `menu.launch.resume`,
`menu.launch.last_bookmark`. UX-copy фіналізувати через `design:ux-copy`.

## 9. iOS 18 сумісність

- `GeometryReader` + `.coordinateSpace(name:)` + `PreferenceKey` (B1) — доступні на
  всіх цілях, `#available` не потрібен.
- `onScrollGeometryChange` (B2 fallback) — iOS 18+; для reader OK (ціль iOS 18).
- `scrollPosition(id:)` / `scrollTargetLayout()` — свідомо **не** використовуємо
  (потребують Lazy-контейнера; reader на звичайному `VStack`, див. §5.1).
- Перед реалізацією — **research-first** (правило CLAUDE.md): спайк B1 на iOS 18
  симуляторі — переконатися, що preference-редукція по рядках не дає помітного
  оверхеду скролу і коректно визначає верхній вірш при covers-on/covers-off.

## 10. Trade-offs

- **UserDefaults vs GRDB:** обрано UserDefaults (простота, патерн). Ціна — нема синку;
  усунено абстракцією `ReadingPositionStore`.
- **Top-visible verse vs pixel offset:** обрано вірш (стійкість до relayout). Ціна —
  скрол відновлюється «до початку рядка вірша», не до піксельної позиції всередині
  довгого вірша. Прийнятно для читання.
- **Restore через proxy.scrollTo vs scrollPosition binding:** обрано `scrollTo`
  (розв'язка з capture, переюз наявного `ScrollViewReader`, без конфлікту зі
  StudyPin). Ціна — потрібен `pendingRestoreAnchorId` + onChange-хук.
- **B1 (per-row frame) vs LazyVStack+scrollPosition:** обрано B1 — reader на
  звичайному `VStack`, а Lazy-перехід ризикує регресією StudyPin/per-row геометрії
  (ADR-021). Ціна — preference-редукція по рядках (легкий оверхед скролу; спайк у §9).
- **Study Mode якір = selectedVerse:** у Study Mode scroll заблоковано, тож якорем є
  вірш у фокусі — це і найосмисленіша, і єдина коректна точка повернення.
- **Одна позиція vs історія:** одна (простота). Історія — окремий майбутній feature.

## 11. Фази

**Phase 1 (цей спринт) — core resume**
1. `ReadingPositionStore` + `UserDefaultsReadingPositionStore` + `@AppStorage` ключі.
2. Capture: (a) reading — per-row frame (B1) + debounce; (b) Study Mode — `selectedVerse.id` при tap/chevron/cross-ref/navigateToVerse; + scenePhase flush.
3. Restore: `pendingRestoreAnchorId` + гілка в `init` + onChange-scroll у `ReaderView`.
4. Menu: секція «Reading» + `LaunchBehaviorPickerView` + локалізація.
5. `lastBookmark` гілка (most-recently-created).

**Phase 2 (опційно, пізніше) — sync**
- Перенести position у GRDB-таблицю `reading_position` (sync-ready, як ADR-012),
  свопнути реалізацію `ReadingPositionStore`. Тільки якщо з'явиться крос-девайс вимога.

## 12. Acceptance criteria

- [ ] Читаю Рим 5, гортаю до в.12, kill+relaunch → відкривається Рим 5, скрол на в.12 (±1 рядок).
- [ ] Перший запуск (clean install) → Буття 1:1.
- [ ] Меню → «Остання закладка» + kill+relaunch → відкривається most-recently-created закладка.
- [ ] «Остання закладка» без жодної закладки → Буття 1:1 (без краху).
- [ ] Зміна розміру шрифту (Dynamic Type) між сесіями → той самий вірш зверху, не збитий офсет.
- [ ] Study Mode відкритий при kill → relaunch показує reading position, sheet закритий.
- [ ] Збережена глава > chapterCount (симуляція) → clamp, без краху.
- [ ] Build проходить (Debug + **Archive/Release** — перевірити `#Preview` під `#if DEBUG`).
- [ ] Swift 6 strict concurrency — без нових warning'ів.

## 13. Тест-план

- Unit: `UserDefaultsReadingPositionStore` load/save round-trip; clamp-логіка; parseVerseId; fallback-ланцюг lastBookmark→resume→Genesis.
- UI/manual: матриця acceptance §12 на iOS 18 симуляторі (мін. ціль) + iOS 26.
- Regression: Study Mode pin-скрол, chevron-навігація, edge-swipe paging, cross-ref back-stack (ADR-024) — переконатися, що per-row frame capture (B1) не ламає геометрію і що Study-Mode якір коректно = `selectedVerse.id`.
- Acceptance додатково: у Study Mode на Рим 5:12 kill+relaunch → відкривається Рим 5 зі скролом на в.12.

## 14. Дотичні документи

- ADR-012 (unified user data layer) — куди піде position у Phase 2.
- ADR-021 (Study Mode scroll) — не регресувати pin/contentOffset механіку.
- ADR-024 (cross-ref back-stack) — навігація, яку capture-guard не має чіпати.
- PDR-Page-Turn-Gesture-Zone — edge-swipe оновлює bookId/chapter.
