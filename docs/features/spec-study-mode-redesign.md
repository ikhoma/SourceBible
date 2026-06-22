# Study Mode Redesign — Spec

**Status:** Draft
**Author:** Ivan (+ агент)
**Date:** 2026-06-11
**Type:** Feature spec + Fable autonomous run brief
**Related:** `ADR-005-highlights-bookmarks-notes.md`, `ADR-010-bottomsheet-file-split.md`, `ADR-012-unified-user-data-layer.md`, `ADR-014-verse-text-view-cache-invalidation.md`, `spec-verse-sharing.md`, `HighlightColor.swift`

---

## 1. Проблема

Поточний verse bottom sheet працює на двох detent-ах — `.medium` і `.large` (`ReaderView.swift` → `.presentationDetents([.medium, .large], selection: $selectedDetent)`).

Болі:

1. **Контент vs фокус — конфлікт.** Щоб проскролити вертикальний контент Sheet (cross-refs, lexicon, commentaries), користувач мусить розгорнути його на `.large`. Але на `.large` обраний вірш виходить з поля зору (anchor стає `.center`, далі ховається під Sheet) — губиться зв'язок «текст вірша ↔ матеріал про нього».
2. **Хитка геометрія.** Зараз позиція вірша тримається через `safeAreaInset` + `verseSheetReservedHeight` + `scrollTo(anchor:)`. Це працює, але обраний вірш «плаває» залежно від detent, а фонова `ScrollView` лишається активною (треба gesture-blocking overlay, щоб гасити витік свайпів — `ReaderView.swift` рядки 190–213).
3. **Навігація розкидана.** Шеврони `<>` дублюються: у toolbar (chapter nav) і в шапці Sheet (verse/word nav, `VerseBottomSheetView.swift` рядки 107–129). Дії (highlight/note/bookmark/share) висять окремою `actionBar` знизу Sheet (рядки 215–263) і з'їдають вертикальний простір.

## 2. Бачення (Study Mode)

Один сфокусований режим читання-вивчення:

- Обраний вірш **закріплюється на 16 pt нижче toolbar** і лишається у фокусі.
- **Скрол рідера заблокований** — вірш не «втікає».
- **Sheet притискається знизу до вірша**: його верхня межа стоїть одразу під закріпленим віршем, а висота підлаштовується динамічно. Скролиться **тільки контент усередині Sheet**.
- **Вихід** — потягнути вниз ползунок (drag indicator) Sheet **або** натиснути кнопку **«Назад»** у toolbar.
- Кнопка **«Назад»** з'являється **мікроінтеракцією-морфінгом in-place** з пікера книги+перекладу (iOS 26).
- Toolbar-шеврони `<>` у цьому режимі **навігують між віршами** (таба «Вірш») або **між словами** (таба «Слово»).
- Шеврони в самому Sheet **прибираються** і замінюються **контекстним меню**; туди ж ховаються всі дії з нижньої `actionBar` (яку прибираємо).

Вайрфрейми — у прикріплених скріншотах 1–2; приклад вигляду хайлайтів — скріншот 3.

## 3. Цілі / Не-цілі

**Цілі**

- G1. Обраний вірш завжди у фокусі (фіксований 16 pt під toolbar), скрол рідера заблокований.
- G2. Sheet динамічної висоти, притиснутий під вірш; скролиться лише його внутрішній контент.
- G3. Єдина точка навігації по віршах/словах — toolbar-шеврони `<>`.
- G4. Дії (highlight/note/bookmark/share) консолідовані в одне контекстне меню в шапці Sheet; нижня `actionBar` видалена.
- G5. Мікроінтеракція морфінгу пікера ↔ «Назад» у стилі iOS 26.
- G6. Highlight-вибір кольору як список у контекстному меню: **Purple, Pink, Orange, Mint, Blue + None**.

**Не-цілі**

- N1. Зміна РОЗДІЛУ всередині Study Mode — **недоступна** (рішення продукту, див. §4 R6). Щоб змінити розділ, спершу вийти в рідер.
- N2. Cross-chapter навігація по віршах (на межі глави шеврон disabled — не перестрибує в наступну главу).
- N3. Зміна моделі даних highlights поза тим, що потрібно для нової палітри (§4 R8).
- N4. Перебудова контенту табів (Cross Refs / Translations / Lexicon / Commentaries / Word sub-tabs) — лишаються як є.
- N5. Зміна BD / `sourcebible.db` — не торкаємось.

## 4. Вимоги

### R1. Вхід у Study Mode

- Тап по віршу (`vm.tapVerse(_:)`) → `vm.activeSheet = .verse`. **Study Mode == verse sheet відкритий.** Окремий прапорець не потрібен; усі гілки нижче вмикаються за умовою `vm.activeSheet == .verse`.
- При вході: обраний вірш позиціонується так, щоб його **верх був на 16 pt нижче нижньої межі nav bar**, після чого скрол рідера блокується.

### R2. Закріплений вірш + блокування скролу

- Рідерна `ScrollView` (`ReaderView.swift`): `.scrollDisabled(vm.activeSheet == .verse)`.
  - `scrollDisabled` глушить **жести користувача**, але програмний `proxy.scrollTo(...)` далі працює — це потрібно для chevron-навігації (R5), яка переставляє фокус на новий вірш, лишаючись у заблокованому стані.
- Позиціонування вірша: scrollTo обраного вірша з anchor так, щоб верх вірша опинився на `navBarBottom + 16`. Існуючий механізм `safeAreaInset` + `verseSheetReservedHeight` **замінюється** логікою динамічної висоти Sheet (R3): простір над Sheet = toolbar + 16 pt + сам вірш.
- Gesture-blocking overlay (`ReaderView.swift` рядки 190–213) **видаляється** — фоновий скрол заблокований через `scrollDisabled`, тож витоку свайпів немає. (Перевірити: `presentationBackgroundInteraction` теж більше не потрібен — див. R3.)

### R3. Динамічна висота Sheet (притиснутий під вірш)

- Замість `[.medium, .large]` — **один обчислений detent**: `presentationDetents([.height(studySheetHeight)])`.
- `studySheetHeight = containerHeight − navBarBottom − 16 − pinnedVerseHeight − gap`
  - `gap` ≈ 8 pt (візуальний відступ між низом вірша і верхом Sheet).
  - `pinnedVerseHeight` — виміряна висота рядка обраного вірша (`onGeometryChange` / `GeometryReader` на `VerseRowView`, коли `isSelected`). Зберігати у `@State` (або published у VM) і перераховувати `studySheetHeight` при зміні (зміна вірша через шеврон, зміна перекладу, зміна динамічного шрифту).
- `presentationDragIndicator(.visible)` — лишаємо; **тяг вниз = вихід** (dismiss → R7).
- `presentationBackgroundInteraction` — **прибрати** (фон заблокований; взаємодія з фоном у Study Mode не потрібна). Перевірити на iOS 18 fallback-гілці.
- `presentationSizing(.page)` — лишаємо для iOS 18+ гілки як зараз.

> **iOS 26 research-обов'язок (CLAUDE.md).** Перед кодом перевірити актуальний API для одно-detent sheet динамічної висоти: чи `.height()` з реактивним перерахунком стабільний, чи краще custom `PresentationDetent` з resolver-ом, що читає `context.maxDetentValue`. Перевірити поведінку drag-to-dismiss при єдиному detent (має лишитись лише «вниз = закрити», без проміжних позицій). Джерела: developer.apple.com, swiftwithmajid.com, createwithswift.com.

### R4. Кнопка «Назад» — морфінг in-place (iOS 26)

- Leading toolbar item зараз — `HStack { bookPicker; translationPicker }` (`ReaderView.swift` рядки 230–249).
- У Study Mode цей блок **морфиться in-place** в одну кнопку **«Назад»** (`chevron.backward` + лейбл) на тій самій позиції; при виході морфиться назад у пікери.
- Реалізація: `@Namespace` + `matchedGeometryEffect` (або iOS 26 toolbar morph API) між групою пікерів і кнопкою «Назад», анімовано пружиною на зміну `vm.activeSheet`.
- Тап «Назад» → вихід (R7).

> **АМЕНДМЕНТ (ADR-024, 2026-06-21) — морфінг тепер ТРЬОХстановий.** Leading toolbar item морфиться між **трьома** станами замість двох: `пікери` (рідер) / **«Закрити»** (Sheet відкритий, cross-ref back-стек порожній) / **«‹ Назад»** (стек непорожній). «‹ Назад» зберігає поточний вигляд (`chevron.backward` + `studymode.back`); нова «Закрити» — без шеврона, дія `vm.activeSheet = nil`; «‹ Назад» — дія `vm.crossRefBack()` (крок по cross-ref історії). Ключ морф-анімації перевести з Bool (`vm.activeSheet == .verse`) на 3-станове значення, щоб морф спрацьовував і на Закрити ⇄ Назад. Деталі — ADR-024.

> **iOS 26 research-обов'язок.** Уточнити правильний API морфінгу toolbar-елементів під iOS 26 (matchedGeometry у toolbar vs `.toolbar` content transition vs `matchedTransitionSource`). Не додавати скляні фони вручну — iOS 26 застосовує glass через правильний placement/grouping (CLAUDE.md). iOS 18 fallback: простий fade/slide swap без matchedGeometry за `#available(iOS 26, *)`.

### R5. Toolbar-шеврони `<>` — verse/word навігація

Trailing `ToolbarItemGroup` (`ReaderView.swift` рядки 218–228) змінює призначення за станом:

- **`vm.activeSheet == nil` (рідер):** як зараз — `vm.prevChapter()` / `vm.nextChapter()`, disabled на межах глави.
- **`vm.activeSheet == .verse` + `bottomSheetMode == .verse`:** `vm.navigateToPreviousVerse()` / `vm.navigateToNextVerse()`.
  - Disabled: `vm.verses.first?.id == selectedVerse.id` (prev) / `vm.verses.last?.id == ...` (next). Без cross-chapter (N2).
- **`vm.activeSheet == .verse` + `bottomSheetMode == .word`:** `vm.navigateToPreviousWord()` / `vm.navigateToNextWord()`.
  - Disabled на першому/останньому елементі `vm.translationOrderedClickableWords`.
- Логіку `isPrevDisabled`/`isNextDisabled` (зараз у `VerseBottomSheetView.swift` рядки 133–149) **перенести/продублювати** у VM як обчислювані властивості (напр. `var navPrevDisabled: Bool`, `var navNextDisabled: Bool`), щоб toolbar і Sheet читали одне джерело правди. (Шеврони Sheet видаляються — R6 — тож фактично лишається один споживач, але винесення у VM прибирає дублювання.)
- При навігації по слову обране слово підсвічується у закріпленому вірші через існуючий `selectedSegment` (вже підтримано у `VerseRowView` / `VerseTextView`).

### R6. Sheet: прибрати шеврони + actionBar, додати контекстне меню

У `VerseBottomSheetView.swift`:

- **Видалити** `sheetHeader`-шеврони prev/next (`CapsuleNavGroupStyle`, рядки 107–129).
- **Видалити** нижню `actionBar` overlay (рядки 63–69, 215–273) повністю.
- У шапці Sheet (trailing, де були шеврони) додати **кнопку контекстного меню** — `ellipsis` у капсулі в стилі iOS 26.
- Меню (`Menu`) містить дії, що раніше були в `actionBar`:
  1. **Highlight** → підменю вибору кольору (R8).
  2. **Note** — `notesVM.openNewNote(...)` → відкрити `NoteEditorView` (логіка з рядків 235–238 без змін).
  3. **Bookmark** — `bookmarksVM.toggleBookmark(verseId:)` (toggle, показувати стан ✓/заповнену іконку).
  4. **Share** — `ShareLink` з `VerseShareFormatter.format(...)` (без змін до формату, див. `spec-verse-sharing.md`; пункт P1 цього spec — share у контекстному меню — тут і реалізується).
- Шапка Sheet лишає заголовок (референс вірша / текст слова) як зараз (рядки 89–103).

### R7. Вихід зі Study Mode

Два шляхи, обидва ведуть в один код виходу:

- **Drag-to-dismiss** ползунка Sheet вниз.
- **Кнопка «Назад»** у toolbar.

Код виходу: `vm.activeSheet = nil` → `onDismiss` (вже є: `vm.clearWordSelection()`); прибрати `selectedDetent = .medium` (detent більше немає). Рідер: `scrollDisabled` знімається, скрол розблоковано, вірш лишається на місці. Toolbar: морфінг «Назад» → пікери (R4).

> **АМЕНДМЕНТ (ADR-024, 2026-06-21).** Вихід (свайп-вниз / «Закрити») доступний лише коли cross-ref back-стек **порожній** — інакше leading-кнопка показує «‹ Назад» і робить крок назад по стеку, а не закриває Sheet (свайп-вниз закриває завжди). `onDismiss` додатково очищає `crossRefBackStack`. Деталі — ADR-024.

### R8. Highlight: нова палітра як список у меню

- Підменю Highlight рендериться як список (скріншот 3): **None** зверху, розділювач, далі кольорові пункти з точкою + ✓ на активному.
- Палітра: **Purple, Pink, Orange, Mint, Blue**.
- Реалізація вибору: `Menu` з вкладеним `Picker(selection:)` (None + 5 кольорів) — iOS рендерить Picker у меню саме як checklist зі скріншота; або вкладений `Menu` з `Button`-ами + ✓. Перевагу — `Picker` (нативний вигляд зі скріншота).
- `None` = прибрати highlight (`vm.removeHighlight(for:)`); колір = `vm.setHighlightColor(_:for:)`.

**Зміна моделі `HighlightColor` (увага — user-data інваріант):**

- Зараз `enum HighlightColor { yellow, green, blue, pink }` (`HighlightColor.swift`). Highlights зберігаються як рядок кольору в user DB (GRDB, ADR-005/012).
- Треба: додати `purple`, `orange`, `mint`; лишити `blue`, `pink`.
- `yellow`, `green` — **не видаляти з enum** (інакше зламаються вже збережені у користувача highlights). Лишити їх для коректного **рендеру legacy-значень**, але **не показувати** в новому picker-і (picker експонує лише 5 нових). Тобто: `HighlightColor.allCases` для рендеру ≠ `HighlightColor.pickerCases` для UI вибору.
- Додати `color`/`uiColor`/`label` (+ localized keys `highlight.color.purple|orange|mint`) для нових кейсів.
- **Жодної міграції збережених даних** — лише розширення enum (інваріант: не ламати user data без міграції).

## 5. Стани та переходи

```
[Reader]  --tapVerse-->  [Study Mode: Verse tab]
   ^                          |   |  \
   |  Back / drag-down        |   |   \-- mode tab → [Study Mode: Word tab]
   +--------------------------+   |
                                  |  toolbar < >  → prev/next verse (locked reader re-anchors)
[Study Mode: Word tab]
   |  toolbar < >  → prev/next word (selectedSegment highlight у вірші)
   |  Back / drag-down → [Reader]
```

- Toolbar leading: `[Book ▾][Translation ▾]` ⇄ (morph) ⇄ `[Закрити]` ⇄ (morph) ⇄ `[‹ Назад]` (3 стани — ADR-024).
- Toolbar trailing `< >`: chapter nav (Reader) ⇄ verse/word nav (Study Mode).

## 6. Edge cases

1. **Дуже довгий вірш** (висота > ~35% контейнера): закріплена зона з'їдає Sheet. Обмежити `pinnedVerseHeight` стелею (напр. `0.35 * containerHeight`); понад стелю — сам текст вірша скролиться внутрішньо, Sheet не стискається менше за мінімум (напр. ≥ 30% екрана).
2. **Перший/останній вірш глави:** відповідний toolbar-шеврон disabled (N2). Перехід у наступну главу — лише через вихід (N1/R6 продукт-рішення).
3. **Перемикання Verse↔Word у Study Mode:** при вході у Word — `vm.autoSelectFirstWordIfNeeded()` (вже є); закріплений вірш не змінюється, додається підсвітка слова.
4. **Зміна перекладу/Dynamic Type у Study Mode:** `pinnedVerseHeight` міняється → перерахувати `studySheetHeight` (R3).
5. **Legacy highlight (`yellow`/`green`) на закріпленому вірші:** рендериться коректно, у picker-і — без галочки на жодному з 5 нових (бо активний колір не в `pickerCases`); вибір нового кольору перезаписує.
6. **iOS 18 fallback:** морфінг → простий swap; динамічна висота — перевірити `.height()` на iOS 18; drag-to-dismiss поведінка.
7. **VoiceOver / accessibility:** «Назад» має лейбл; шеврони — динамічний лейбл («Наступний вірш» / «Наступне слово»); пункти меню — стандартні.

## 7. Acceptance criteria

- AC1. Тап по віршу закріплює його верх на 16 pt під toolbar; рідер не скролиться жестом.
- AC2. Sheet відкривається висотою, що лишає над собою лише toolbar + 16 pt + вірш + ~8 pt gap; внутрішній контент Sheet скролиться.
- AC3. Toolbar `<>` у табі «Вірш» гортають вірші (re-anchor на новий вірш, рідер лишається locked); у табі «Слово» — слова, з підсвіткою `selectedSegment`. На межах — disabled, без cross-chapter.
- AC4. Шеврони в шапці Sheet і нижня `actionBar` відсутні; усі 4 дії доступні з контекстного меню в шапці.
- AC5. Highlight-підменю показує None + Purple/Pink/Orange/Mint/Blue з ✓ на активному; вибір застосовується миттєво; None знімає highlight.
- AC6. Кнопка «Назад» морфиться in-place з пікера книги+перекладу і назад; тап «Назад» і тяг-вниз обидва повертають у рідер з розблокованим скролом.
- AC6.1 (ADR-024). Leading toolbar морфиться між 3 станами (пікер/Закрити/Назад). При багаторівневому cross-ref переході «‹ Назад» крокує назад по точках входу до кореня; у корені кнопка = «Закрити». Свайп-вниз закриває Sheet з будь-якого рівня й очищає стек.
- AC7. Вже збережені highlights (включно з legacy `yellow`/`green`) відображаються коректно після оновлення палітри; жодних втрат даних.
- AC8. Build проходить (Swift 6 strict concurrency, iOS 26 SDK); iOS 26-only API — за `#available(iOS 26, *)` з iOS 18 fallback.

## 8. Орієнтовні зони змін (для оцінки)

- `SourceBible/Views/Reader/ReaderView.swift` — toolbar (морф «Назад», retarget шевронів), презентація Sheet (single `.height` detent, scroll lock, вимір висоти вірша, видалення gesture-overlay).
- `SourceBible/Views/BottomSheet/VerseBottomSheetView.swift` — видалити header-шеврони + `actionBar`, додати контекстне меню (highlight picker / note / bookmark / share).
- `SourceBible/ViewModels/ReaderViewModel.swift` — `navPrevDisabled`/`navNextDisabled`, можливо published `pinnedVerseHeight` / `studySheetHeight` helper.
- `SourceBible/Models/HighlightColor.swift` — нові кейси `purple/orange/mint`, `pickerCases`, кольори/лейбли.
- `*.xcstrings` — рядки: `studymode.back`, `highlight.color.purple|orange|mint`, accessibility-лейбли шевронів.
- (Можливо) новий малий view для контекстного меню / color picker, якщо `VerseBottomSheetView` розростається — узгодити з ADR-010 (модульний split).

---

## 9. Fable — autonomous run brief

> Активувати автономний режим (CLAUDE.md → «Autonomous mode») **тільки** після явної команди «віддаю в Fable» з посиланням на цей spec.

**Умови входу:** ця команда + цей `spec` затверджено + scope і acceptance нижче.

**Scope — можна чіпати:**

- `SourceBible/Views/Reader/ReaderView.swift`
- `SourceBible/Views/BottomSheet/VerseBottomSheetView.swift`
- `SourceBible/ViewModels/ReaderViewModel.swift`
- `SourceBible/Models/HighlightColor.swift`
- `SourceBible/**/*.xcstrings` (лише додавання нових ключів)
- За потреби — новий файл view у `SourceBible/Views/BottomSheet/` (узгоджено з ADR-010).

**Scope — НЕ чіпати:**

- `scripts/**`, `build_db.py`, `build_verse_map.py`, `sourcebible.db`, схему БД, GRDB-схему user-data.
- Контент-логіку табів (cross-refs/lexicon/commentaries/word usage), пошук, локалізаційний рушій.
- `IPHONEOS_DEPLOYMENT_TARGET` (лишається як є; нове iOS 26 API — за `#available`).

**Огорожа:**

- Працювати **в окремій git-гілці** (напр. `feature/study-mode-redesign`), не в робочій напряму.
- iOS 26 UI-код — **спершу research** (R3/R4 research-блоки), потім код.
- Перед статусом «готово»: build проходить, підготовлено **повний diff** + короткий звіт.
- Вийти за scope → **зупинитись і спитати**, не розширювати самовільно.

**Жорсткі інваріанти (не послаблюються):**

- Не ламати збережені highlights — розширення `HighlightColor` без міграції/видалення legacy-кейсів (R8, AC7).
- Жодних незворотних дій (видалення/перезапис БД, force-push, зміна user-data схеми без міграції).
- Swift 6 strict concurrency; build має компілюватись на кожному кроці.
- Python (якщо знадобиться) — 3.9.

**Acceptance = §7 (AC1–AC8).** Нові архітектурні рішення під час прогону (напр. фінальний вибір detent-API чи окремий view для меню) → зафіксувати як ADR-amendment і позначити у звіті; підпис користувача — пост-фактум.

**Вихід із режиму:** прогін завершується diff-ом на рев'ю; merge у робочу гілку — за явним «мерджимо».

---

## 10. Implementation amendments (2026-06-11, гілка `feature/study-mode-redesign`)

> Рішення, прийняті під час імплементації в межах research-блоків R3/R4. Потребують підпису користувача пост-фактум.

**A1 — R4 морфінг: content swap + `.blurReplace`, без `matchedGeometryEffect`.**
Research: iOS 26 toolbar morph API (`matchedTransitionSource` + `navigationTransition`) призначений для переходів екран↔екран / sheet-із-кнопки, не для in-place заміни вмісту toolbar item. `matchedGeometryEffect` у toolbar ненадійний (обидва view співіснують під час transition → биті фрейми). Реалізовано: один `ToolbarItem`, вміст якого свапається `if/else` зі spring-анімацією + `.transition(.blurReplace)` (iOS 17+; fallback `.opacity`). На iOS 26 системна glass-капсула item-а зберігається і морфиться автоматично — ручного скла нема (відповідає CLAUDE.md).

**A2 — R3 detent: реактивний `.height(studySheetHeight)`.**
Research: одно-detent `.height()` з реактивним перерахунком стабільний на iOS 26; на iOS 16–18 відома вада — відкритий sheet може не зменшуватись при зміні висоти (записано в коментар коду; перевірити в compatibility-спринті). Зміни `pinnedVerseHeight` загорнуті у `withAnimation`. Вимір вірша — `onGeometryChange` на background обраного рядка; висота контейнера — `onGeometryChange` на кореневому ZStack.

**A3 — формула висоти. ВЕРИФІКОВАНО на девайсі (2026-06-11): припущення було хибним.**
`.height(x)` рахується від самого низу екрана ВКЛЮЧНО з bottom safe area → sheet стояв ~34 pt нижче, визирав наступний вірш. Виправлена формула: `studySheetHeight = containerHeight + bottomSafeAreaInset − topInset − cappedVerseHeight − 8`. Додатково: top inset зменшено 16 → 6 pt, бо рядок вірша має 10 pt внутрішнього padding — текст вірша тепер візуально на 16 pt під toolbar. Плюс re-anchor scrollTo через 0.4 s після відкриття (перший прохід може рахувати по застарілій геометрії).

**A4 — edge case 1 (довгий вірш) реалізовано частково.**
Cap `pinnedVerseHeight ≤ 0.35·container` і min sheet ≥ 0.30·container — є. Внутрішній скрол тексту самого вірша (понад стелю) — НЕ реалізовано: текст, що не вліз, частково перекривається sheet-ом. Окрема задача, якщо виявиться болем на реальних віршах.

**A8 — (fine-tune 2026-06-11, ітерації 2–3) живий resize detent: модифікатор ВСЕРЕДИНІ sheet + `selection:`.**
Два знайдені факти з девайса:
1. `safeAreaInset(spacing: nil)` додає системний default spacing (~16 pt) — вірш сидів нижче моку. Фікс: `spacing: 0`. ✅ верифіковано.
2. Closure контенту `.sheet(item:)` НЕ переобчислюється при зміні @State презентуючої view → аргументи presentation-модифікаторів, передані з ReaderView, заморожуються на момент відкриття (sheet застиг на висоті першого вірша). Фікс: геометрія перенесена у VM (`@Published pinnedVerseHeight`, `readerContainerHeight`, computed `studySheetHeight` + статичні `pinnedTopInset`/`sheetGap`), а `presentationDetents([.height(vm.studySheetHeight)], selection: $detent)` застосовується всередині `VerseBottomSheetView`, чиє body ререндериться від vm. Selection re-point у `onChange(of: vm.studySheetHeight)` — без selection вже відкритий sheet не рухається навіть при зміні набору detents.

**A9 — (fine-tune 2026-06-11, ітерація 4) custom detent через environment + вимір усіх рядків.**
Заміна set-а `[.height(old)] → [.height(new)]` для відкритого sheet виявилась no-op на девайсі навіть зсередини sheet-контенту. Робочий механізм: НЕЗМІННИЙ набір `[.custom(StudySheetDetent.self)]` + значення висоти через environment (`@Entry studySheetHeight`); система ре-резолвить `height(in:)` при оновленнях презентації — це штатний канал динаміки custom detent (прецедент: dynamicTypeSize-залежні detents оновлюються у відкритому sheet). Новий файл `Views/BottomSheet/StudySheetDetent.swift` (ADR-010). Додатково вимір вірша переведено на безумовний `onGeometryChange` на КОЖНОМУ рядку → `vm.verseRowHeights[id]`; `pinnedVerseHeight` — lookup. Це прибирає залежність від initial-callback умовно вставленого view при зміні selection (ймовірна друга причина застиглого sheet).

**A10 — (fine-tune 2026-06-11) dismiss тільки з не-скрольної зони.**
Вертикальний скрол контенту в табах у половині випадків тягнув увесь sheet (системний interactive dismiss при scroll-at-top). Фікс: `interactiveDismissDisabled(true)` + власний `DragGesture` (поріг 60 pt вниз) на верхньому не-скрольному блоці (шапка + mode tabs + pills). Вихід: drag по шапці, або кнопка «Назад». R7 уточнено.

**A11 — (2026-06-12) ФІНАЛЬНА архітектура геометрії sheet (підтверджено на девайсі, Gen 1:4–1:7).**
Підсумок усіх ітерацій R3. Робоча схема: (1) вимір — `onGeometryChange` на рядках рідера пише `frame(in:.global).maxY` ОБРАНОГО вірша у `vm.pinnedVerseGlobalBottom` (запис відкладений `Task`-ом — синхронні objectWillChange під час layout-пасу губляться); (2) `studySheetHeight = screenH − verseBottom − 8`, клемп 30–85% екрана — жодних припущень про navbar/container (ZStack-вимір контейнера розходився з реальним viewport на ~50 pt); (3) застосування — `StudySheetDetentApplier` (UIViewRepresentable всередині sheet) знаходить `UISheetPresentationController` через responder chain і виставляє `sheet.detents` напряму в `animateChanges` (заміна SwiftUI `.height`-set-а і навіть `invalidateDetents` для відкритого sheet — no-op); SwiftUI `[.custom(StudySheetDetent.self)]` + env лишаються для initial presentation. UIKit custom detent value = висота від самого низу екрана (виміряно). A2/A3/A8/A9 — історія шляху до цього рішення.

**A6 — (fine-tune 2026-06-11) затемнення фону прибрано.**
Системний dimming/shadow за sheet перекривав закріплений вірш. Повернуто `presentationBackgroundInteraction(.enabled)` — виключно щоб вимкнути dimming; фон лишається заблокованим через `scrollDisabled`, тож swipe-leak (причина старого gesture-overlay) не повертається.

**A7 — (fine-tune 2026-06-11) структура контекстного меню.**
Стандартний iOS 26 menu: зверху `ControlGroup` з 3 головними діями (Note / Bookmark / Share) — системний горизонтальний ряд icon+label; нижче — список хайлайтів окремою секцією (inline `Picker`: None + 5 кольорів). Вкладене підменю «Highlight» прибрано.

**A5 — highlight picker: `Picker` + `Section` всередині `Menu`.**
None у власній секції (розділювач — межа секцій), 5 кольорів з кольоровими крапками через `UIImage(...).withTintColor(_:renderingMode:.alwaysOriginal)` (template-символи UIMenu перефарбовує в монохром). Legacy yellow/green: selection не збігається з жодним tag → жодної ✓ (edge case 5 — як у spec).
