# ADR-037: Commentary Text Selection — Share & Add-to-Note with Attribution

**Status:** Proposed
**Date:** 2026-08-27
**Deciders:** Ivan
**Related:** [[ADR-012-unified-user-data-layer]] (`NoteBlockType.quote` / `QuoteBlockContent` — schema-ready since ADR-012, no UI consumer until this ADR), [[ADR-014-verse-text-view-cache-invalidation]] (precedent `UIViewRepresentable`+`UITextView` architecture), `spec-verse-sharing.md` / `VerseShareFormatter` (attribution-string precedent), `commentary-system-design.md` (`comments`/`comment_verses` schema), [[ADR-027-modular-commentary-modules]] (future source curation — explicitly NOT this ADR's scope)

---

> ### 🔁 Амендмент 2026-08-27 — adversarial architecture review
>
> Первинна редакція цього ADR (та сама сесія, кілька годин раніше) пройшла ворожий
> перегляд із перевіркою кожного твердження проти живого коду, живої бази й актуальної
> документації Apple. Чотири речі виявились хибними або недовизначеними і **виправлені
> нижче в тексті**:
>
> 1. **Не той API.** `buildMenu(with:)` + `builder.remove(menu: .share)` — не задокументований
>    шлях до меню виділення тексту `UITextView`. Правильний — `UITextViewDelegate`
>    `textView(_:editMenuForTextIn:suggestedActions:)`. Розділ «Рішення §2» переписаний.
> 2. **Не той масштаб.** «Найбільша секція ≈231k символів (Owen Heb 1:1-2)» — заміряно
>    хибно. Реальний максимум — **Calvin Ps 150:6 = 329 343 символи / 3 293 абзаци**;
>    Owen Heb 1:1-2 лише **пʼятий** за розміром. Це знімає варіант «один нескролящий
>    `UITextView` всередині SwiftUI `ScrollView`». Розділ «Рішення §1» переписаний.
> 3. **Дірка в happy path.** `NoteEditorView` і `NoteCardView` **не вміють рендерити
>    `.quote`-блок** — вони фільтрують блоки по `.verse` і `.text`. За первинним планом
>    користувач додав би цитату в нотатку й побачив порожній редактор. Новий розділ
>    «Рішення §5» + Action Item.
> 4. **Атрибуція вже локалізована.** `Theologian.shortName` — це `NSLocalizedString`,
>    а не англійський літерал; share-рядок піде мовою застосунку. Зафіксовано у §3.
>
> Підтверджено як правильне й лишено без змін: «пастка з капіталізацією» (§4), відмова
> від SwiftUI `.textSelection` (Option B), патерн `openNewNote` без `isEditorPresented`.

---

## Контекст

Зараз тіло коментаря рендериться через `CommentaryTextView` (`SourceBible/Views/BottomSheet/VerseTabContent.swift`): звичайний SwiftUI `Text`, розбитий по `"\n\n"` на параграфи в `LazyVStack`. Розбивка — вимушена: SwiftUI `Text` мовчки не рендерить дуже довгі рядки. `.textSelection` ніде не увімкнено — користувач **не може** виділити чи скопіювати жодного слова з коментаря сьогодні.

Продуктовий запит: довгий тап має виділяти текст нативно (як в Apple Books — системні повзунки/лупа + системне контекстне меню), і з виділення має бути шлях дістати цитату з правильною атрибуцією (богослов + посилання на вірш) — або назовні (Share), або в застосунок (Нотатка).

### Реальний масштаб тексту — заміряно, не з памʼяті

⚠️ Первинна редакція ADR оперувала числом «≈231 000 символів (Owen Heb 1:1-2)» як найгіршим випадком. **Заміряно 2026-08-27** (read-only `sqlite3` через міст, `SourceBible/Resources/sourcebible.db`, таблиця `comments`):

| Джерело | Секцій | Найдовша секція | Середня |
|---|---:|---:|---:|
| Calvin | 13 342 | **329 343** | 3 248 |
| Owen | 180 | 282 947 | 44 527 |
| Henry | 2 653 | 76 587 | 12 004 |
| Spurgeon | 2 251 | 7 419 | 1 423 |

Топ-5 за розміром: `Calvin PSA 150:6` — **329 343** символи / **3 293 абзаци**; `Calvin EZK 21:1` — 303 119; `Owen HEB 3:7-11` — 282 947; `Calvin DAN 12:13` — 265 021; `Owen HEB 1:1-2` — 231 237. Усього **34 секції понад 100k** символів і **7 понад 200k** з 18 426.

Тобто: найгірший випадок на **43% більший** за той, що припускав ADR, це **Calvin, а не Owen**, і таких секцій не одна-дві, а десятки. Секція `PSA 150:6` привʼязана рівно до одного вірша в `comment_verses` — це **досяжний одним тапом** екран, не теоретичний край.

📌 **Побічне спостереження (поза обсягом):** усі найбільші Calvin-секції сидять на *останньому* вірші книги або глави (`PSA 150:6`, `EZK 21:1`, `DAN 12:13`, `HEB 13:24`, `JOS 24:32`). Це має вигляд артефакту імпорту — «хвіст» тексту книги, приліплений до останньої секції. Не чіпаємо тут; належить до майбутнього ADR про курацію джерел (п. 2 «поза обсягом» нижче), але варте окремого заміру.

### Дослідження API — виправлено після перевірки документації

**Первинне твердження ADR:** «єдиний спосіб додати власні дії — підклас `UITextView`, що перевизначає `buildMenu(with:)`; `builder.remove(menu: .share)` прибирає системний Share».

**Що показала перевірка живої документації Apple (2026-08-27):**

- ✅ SwiftUI `.textSelection(.enabled)` справді не дає гачка ні на буфер обміну, ні на власні пункти меню. Це підтверджено, Option B лишається відхиленим.
- ✅ `UIMenu.Identifier.share` **існує** (задокументовано, «The Share menu», у групі *Edit menus*) — назва ідентифікатора в первинному ADR не вигадана.
- ❌ **Але `buildMenu(with:)` — не той шлях.** Документація `UIResponder.buildMenu(with:)` прямо каже, що місце оверрайду визначає, *яку систему меню* править builder: app delegate → `UIMenuSystem.main` (menu bar, Mac Catalyst), view controller → `UIMenuSystem.context`. Про edit menu виділення тексту в `UITextView` там немає нічого, а оверрайд на самому `UITextView` (не на VC) — undocumented territory.
- ✅ **Задокументований і санкціонований гачок — `UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)`** (iOS 16+). Він отримує `range` виділення й масив `suggestedActions` від системи, повертає власний `UIMenu` (або `nil` = дефолт). Приклад у самій документації Apple додає до меню виділення «Highlight» і «Add Bookmark» — буквально наш кейс.
- ⚠️ **Сигнал на майбутнє:** сторінка цього методу показує availability `iOS 16.0 – 27.0`, тобто його **депрекують в iOS 27**. Для нашого мінімуму (iOS 18) та SDK (iOS 26) він чинний і правильний, але це вже другий незалежний привід тримати Option C живим як запасний (див. Наслідки).
- ⚠️ **Видалення системного Share** через `builder.remove(menu:)` більше не застосовне (ми не в `buildMenu`). Замість цього — **фільтрація `suggestedActions`** перед складанням власного `UIMenu`. Це не задокументовано як контракт: якщо системний Share прийде не як `UIMenu(identifier: .share)`, а як `UIAction`, фільтр мовчки не спрацює. Деградація мʼяка (два схожі пункти замість одного), не крах — але це **обовʼязковий пункт QA на пристрої**, а не припущення.

### Прецедент у проєкті — і межі його дії

У проєкті вже є архітектура «`UIViewRepresentable` + підклас `UITextView`» — `VerseTextView.swift` (`HighlightableTextView`), включно з `isScrollEnabled = false`, щоб батьківський SwiftUI `ScrollView` керував скролом (ADR-014 регулює інвалідацію кешу через `.id()`).

**Але прецедент не покриває цю задачу двічі:**

1. Довгий тап у `VerseTextView` зайнятий під word-lookup (`onWordTap`), а `isSelectable = false`. Тобто це **не доказ**, що *режим виділення* `UITextView` уживається в тому самому типі батьківського `ScrollView`.
2. `VerseTextView` рендерить **один вірш** (сотні символів). Коментарна секція — до 329k. Масштаб інший на три порядки.

**Перевірка ризику «нескролящий `UITextView` всередині `ScrollView` + виділення» (дослідження 2026-08-27):**

- `UITextView` **сам є `UIScrollView`**. Вкладення його в інший скрол-в'ю — відома проблемна конфігурація: на форумах Apple є звіт саме про цю комбінацію (`isScrollEnabled = false` + зовнішній `UIScrollView` + виділення тексту), де зовнішній скрол стрибає при взятті виділення; рекомендація в треді — не вкладати.
- `isScrollEnabled = false` **вимикає ліниву верстку**: щоб віддати `intrinsicContentSize`/`sizeThatFits`, TextKit має розкласти **весь** документ синхронно на main thread. Для 329k символів це не «можливо повільно», це гарантований фриз.
- Висота такої в'юшки для 329k символів — порядку **150 000+ pt** (≈450 000 px на 3x). Це далеко за межами того, що CoreAnimation тримає як один шар без тайлінгу й артефактів.
- Є звіти про **краш** `UITextView` при тапі по тексту вже від ~100k символів, і про різку деградацію TextKit 2 на великих документах.

Висновок: варіант «один нескролящий `UITextView` на секцію всередині SwiftUI `ScrollView`» — не «потребує QA», а **непрацездатний за конструкцією** на реальних даних. Рішення §1 переписане під це.

**Вже наявні шматки, які варто перевикористати:**

- `VerseShareFormatter` (`Services/VerseShareFormatter.swift`, вже реалізований): `format(verse:bookName:translationId:) → "\"{text}\"\n\n— {Book} {chapter}:{verse} ({translationId})"` — конвенція атрибуції через ем-дефіс уже прийнята продуктом.
- `NoteBlockType.quote` + `struct QuoteBlockContent { theologianId; verseId; text }` у `UserDataModels.swift` — **схема готова з ADR-012, але жоден UI досі не створює і не показує такий блок** (коментар у самому файлі: «MVP creates TextBlock and VerseBlock via UI. Others are schema-ready for v2»). Друга половина цього факту — «і не показує» — має свою ціну, див. §5.
- `NotesViewModel.openNewNote(attachedTo verse:translation:)` — готовий патерн «створити нотатку з прикріпленою сутністю + порожнім text-блоком, віддати `editingNote`, презентацію лишити виклику» — саме форму дзеркалимо для цитати.
- `CommentaryDetailView.detailTitle` уже обчислює `"{Book} {ch}:{verse} — {theologian.shortName}"` для navigation bar — та сама атрибуція, що потрібна Share/Note. Має стати єдиним джерелом цього рядка, а не перераховуватись у трьох місцях.
- `VerseBottomSheetView.ActiveEditor` — готовий патерн «один sheet-слот на в'ю» для презентації `NoteEditorView` поверх уже відкритого sheet-а.

**Свідомо поза обсягом цього ADR** (не забуте, а зафіксоване як окреме майбутнє рішення):

1. **Багата структурна розмітка коментарів** (тайтли/сабтайтли/цитати Писання блоком/клікабельні посилання на вірші). Реальна структура існує у вихідних файлах — Henry HTML і Spurgeon Markdown — але знищується на імпорті (`_strip_henry_html`/`_strip_spurgeon_md`). Відновлення потребує переписати `scripts/import_commentaries.py` по кожному джерелу + повний прогін `rebuild.sh` на Mac. Окремий майбутній ADR+spec.
2. **Курація джерел коментарів.** База зібрана з одного набору файлів, але `data/New/` містить альтернативні MyBible-модулі тих самих чотирьох авторів + два нові автори (Augustine, Edwards) + RU-варіанти. Іван уже порівнював два джерела Calvin і дійшов висновку, що потрібне власне змерджене джерело. Перетинається з відкритим питанням ADR-027 («власна канонічна схема vs MyBible-сумісна» + приклад діри Calvin Isaiah 49–66). Сюди ж — «хвостові» мегасекції на останньому вірші книги (див. вище). Окремий майбутній ADR/amendment до ADR-027.

---

## Рішення

**Замінити рендер тіла коментаря на один скролящий `UIViewRepresentable`-`UITextView` на всю площу sheet-а (не пораграфний `LazyVStack` з `Text` і не нескролящий `UITextView` всередині SwiftUI `ScrollView`), увімкнути нативне виділення, і додати два власні пункти в системне меню виділення через `UITextViewDelegate`: «Поділитися» та «Додати в нотатку».**

### 1. Один **скролящий** `UITextView` на секцію — він і є скрол-контейнер

Первинна редакція пропонувала `isScrollEnabled = false` всередині наявного SwiftUI `ScrollView`, за аналогією з `VerseTextView`. **Це відкинуто** — див. заміри й дослідження в Контексті: 329k символів, синхронна верстка всього документа заради `sizeThatFits`, в'юшка на 150k+ pt, вкладені скрол-в'ю під час виділення.

Натомість `CommentaryDetailView` **перестає бути SwiftUI `ScrollView`**:

```
NavigationStack
└── VStack(spacing: 0)
    ├── theologianHeader        // avatar + name/era/style + Divider — ЗАКРІПЛЕНИЙ
    └── SelectableCommentaryTextView(...)   // isScrollEnabled = TRUE, .frame(maxHeight: .infinity)
```

Що це дає одразу трьома ударами:

- **Ліниву верстку.** Скролящий `UITextView` — рідне середовище TextKit: розкладається viewport, а не весь документ. Ніякого `sizeThatFits` на 329k символів.
- **Нуль вкладених скролів.** Зникає весь клас ризику «зовнішній `ScrollView` бʼється з повзунками виділення» — його просто нема між чим і чим.
- **Крос-абзацне виділення.** Один `UIView` = одне виділення; тягнути через межу абзаців можна, як в Apple Books. Це і був первинний мотив відмовитись від пораграфної розбивки — він зберігається повністю.

`SelectableCommentaryTextView` (новий файл, `Views/BottomSheet/`):
- `UIViewRepresentable`, обгортає `UITextView` (підклас не потрібен — кастомізація меню йде через delegate, не через оверрайд).
- `isEditable = false`, `isSelectable = true`, **`isScrollEnabled = true`**.
- Вхід — `NSAttributedString`, побудований із `text.components(separatedBy: "\n\n")` через `NSMutableParagraphStyle.paragraphSpacingBefore`, щоб зберегти візуальний ритм, який зараз дає `LazyVStack(spacing: 12)`.
- Будувати `NSAttributedString` **один раз** і кешувати в `Coordinator` (як `VerseTextView.baseAttributedString`); присвоювати `attributedText` лише коли змінився `verseId`/`source`, інакше кожен `updateUIView` = повна верстка. На 3 293 абзацах ціна помилки тут — секунди.

✅ **Вирішено Іваном (2026-08-27):** шапка богослова — **двостанова, зі скрол-керованим колапсом**, не статично закріплена й не в `contentInset`.

- **Стан "expanded"** (при відкритті sheet-а, скрол = 0): повний вигляд — портрет 52pt, ім'я, ера · стиль, як зараз.
- **Стан "collapsed"** (після скролу тексту на поріг, напр. `> 60pt`): компактний рядок — маленький аватар (24pt) + ім'я, без ери/стилю; портрет і другий рядок згортаються.
- **Перехід — анімований**, керований прогресом скролу (0…1), а не бінарним перемиканням: opacity/scale великих елементів інтерполюються з offset-у, компактний рядок з'являється дзеркально. Той самий клас патерну, що collapsing-header у Mail/Reminders/Music — тільки шапка своя (не системний `navigationBarTitleDisplayMode`, бо вміст шапки кастомний).
- **Джерело офсету:** сам `SelectableCommentaryTextView` — він **є** `UIScrollView` (§1), тож `UIScrollViewDelegate.scrollViewDidScroll` у тому самому `Coordinator`, що вже реалізує `UITextViewDelegate` (§2), прокидає `contentOffset.y` назовні через замикання (`onScroll: (CGFloat) -> Void`) в `@State private var headerCollapseProgress: CGFloat` у `CommentaryDetailView`. Жодного окремого скрол-спостерігача — той самий делегат, що вже потрібен для меню виділення.
- Це **не** контраргумент проти §1 (скролящий `UITextView` як контейнер) — навпаки, робить закріплену шапку живою: `VStack` лишається (шапка зверху, текст на решту висоти), просто шапка сама перемальовується за `headerCollapseProgress`, а не є статичним `View`.

Обсяг ADR через це не змінюється якісно — просто §1 "закріплена шапка" стає "шапка з двома станами, керована офсетом того самого скролу". Деталі компактного/розгорнутого layout — на розсуд імплементації (SF Symbols розмір, spacing), не окреме архітектурне рішення.

### 2. Меню виділення — через `UITextViewDelegate`, не через `buildMenu`

```swift
// Задокументований Apple шлях для меню ВИДІЛЕННЯ в UITextView (iOS 16+).
// ⚠️ availability iOS 16.0–27.0 — метод депрекується в iOS 27; для нашого
// мінімуму (18) і SDK (26) чинний. Перевірити заміну перед стрибком на 27.
func textView(_ textView: UITextView,
              editMenuForTextIn range: NSRange,
              suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard range.length > 0 else { return nil }   // немає виділення — дефолтне меню

    // Прибираємо ГОЛИЙ системний Share (без атрибуції), щоб не мати двох
    // майже однакових пунктів. Форма системного елемента не є контрактом —
    // тому фільтр захищений з обох боків і мовчки нічого не ламає, якщо
    // Apple змінить представлення (найгірше — Share лишиться поруч).
    let kept = suggestedActions.filter { element in
        if let menu = element as? UIMenu   { return menu.identifier != .share }
        if let action = element as? UIAction { return action.identifier.rawValue != "share" }
        return true
    }

    // ⛔ NSLocalizedString/Text-шлях, НЕ String(localized:) — останній не проходить
    // крізь LocalizedBundle-swizzle (ADR-006, розділ «Локалізація» у CLAUDE.md).
    let share = UIAction(title: NSLocalizedString("action.share", comment: ""),
                         image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        self?.onShareRequested?(range)
    }
    let addToNote = UIAction(title: NSLocalizedString("commentary.menu.addToNote", comment: ""),
                             image: UIImage(systemName: "note.text")) { [weak self] _ in
        self?.onAddToNoteRequested?(range)
    }

    return UIMenu(children: kept + [UIMenu(options: .displayInline,
                                           children: [share, addToNote])])
}
```

**Чому прибираємо саме Share, а не додаємо четвертий пункт:** iOS сама додає «Share» у меню виділення — без атрибуції, голий рядок. Лишити його поруч із нашим «Поділитися» дало б два майже однакові пункти. Тому: **замінюємо** системний Share на свій (з атрибуцією), а Copy/Look Up/Translate/Search Web не чіпаємо взагалі — вони приходять у `suggestedActions` і йдуть далі без змін.

`Copy` лишається на 100% ванільним — просто виділений сирий текст. Атрибуція нікуди не губиться: сам Share Sheet, який відкриває наша дія «Поділитися», уже пропонує «Copy» серед своїх варіантів — і оскільки ми туди передаємо відформатований текст з атрибуцією, «скопіювати з атрибуцією» походить звідти, а не з підміни стандартного Copy (рішення Івана, обговорення цієї сесії).

**Деталі, що коштують компіляції або поведінки:**

- Діапазон беремо з параметра `range` делегата, **не** з `textView.selectedRange` у момент спрацювання `UIAction` — на момент виконання дії виділення може вже бути знято.
- Текст виділення — `(textView.text as NSString).substring(with: range)`. `NSRange` — UTF-16; `String.Index` тут не підходить, у Calvin/Owen є не-ASCII (єврейські/грецькі вставки, лапки, тире).
- Рядок «Поділитися» — **перевикористати наявний ключ `action.share`** (`Localizable.xcstrings` уже має EN «Share» / UK «Поділитись»). Новий ключ потрібен лише один: `commentary.menu.addToNote`.
- `onShareRequested` / `onAddToNoteRequested` — замикання, що йдуть із `UIViewRepresentable` у SwiftUI-батька (`CommentaryDetailView`), той самий патерн, що вже використовує `VerseTextView` для `onVerseTap`/`onWordTap`. Тримати їх на `Coordinator` (він і є delegate), не на в'юшці.

**Swift 6 strict concurrency — перевірено, чисто:**
- `UITextViewDelegate` оголошений `@MainActor`, `UITextView` — `@MainActor`, `UIViewRepresentable` — `@MainActor`. Отже `Coordinator`, що конформить делегату, MainActor-ізольований цілком.
- `UIActionHandler` = `(UIAction) -> Void` — **не** `@Sendable`. Замикання, написане інлайн у `@MainActor`-контексті, інферить `@MainActor` ізоляцію; жодного перетину акторів і жодної вимоги `Sendable` тут не виникає.
- Виклик замикань із `@escaping`-контексту вимагає явного `self.` (правило CLAUDE.md) — у сніпеті вище воно є через `self?.`.
- `Coordinator` **не робити `private`**: `makeCoordinator() -> Coordinator` вимагає, щоб тип був не менш видимий за сам `UIViewRepresentable` (правило видимості CLAUDE.md). `internal` всередині нового файлу — достатньо.
- Оверрайду `Bundle` тут немає → правила `nonisolated(unsafe)` не застосовні.

`CommentaryDetailView` — єдине місце, що знає атрибуцію (`detailTitle`) і володіє презентацією sheet-ів, тому саме він:
- на `onShareRequested` — формує рядок через `CommentaryQuoteShareFormatter` і показує share sheet (див. §3);
- на `onAddToNoteRequested` — викликає `notesViewModel.openNewNote(attachedToQuote:theologianId:verseId:)` і презентує `NoteEditorView` sheet-ом **поверх** уже відкритого commentary sheet-а (див. §5).

### 3. `CommentaryQuoteShareFormatter` (новий, дзеркалить `VerseShareFormatter`)

```swift
enum CommentaryQuoteShareFormatter {
    static func format(quote: String, theologianShortName: String, ref: String) -> String {
        "\u{201C}\(quote)\u{201D}\n\n— \(theologianShortName), \(ref)"
    }
}
```

`ref` — той самий рядок, що й `CommentaryDetailView.detailTitle` (без назви теолога всередині, вона йде окремим параметром) — обчислюється один раз, не парситься з виділеного тексту. Це і є відповідь на «а що робити з атрибуцією, коли в Calvin/Owen нема заголовка секції»: **атрибуція завжди береться з уже відомих координат секції (`bookId/startChapter/startVerse/endChapter/endVerse` + `source`), а не з вмісту виділення** — працює однаково для всіх чотирьох джерел незалежно від того, наскільки структурований їхній plain text.

⚠️ **`theologianShortName` — локалізований рядок**, а не англійський літерал: `Theologian.shortName` = `NSLocalizedString("theologian.\(id).short", value: id.capitalized, …)` (bug-028). Тобто в українському UI цитата поїде як «— Кальвін, Пс 1:3». Це очікувана й правильна поведінка (той самий рядок стоїть у навбарі), але зафіксувати варто: **share-текст залежить від мови застосунку**, і тест «поділився → отримав очікуваний рядок» має бути мовно-параметризований.

**Презентація share sheet.** У кодбейсі сьогодні **немає жодного `UIActivityViewController`** — єдиний share-шлях це SwiftUI `ShareLink` у `VerseBottomSheetView`. `ShareLink` тут не підходить: він кнопка, його не запустити програмно з `UIAction`. Два робочі шляхи:

- ✅ **Рекомендовано:** `.sheet(item: $shareText)` у `CommentaryDetailView` із тонким `UIViewControllerRepresentable`-обгортанням `UIActivityViewController`. Презентацією володіє SwiftUI-sheet, тому `popoverPresentationController` **не задіяний** і крах на iPad структурно неможливий.
- ⚠️ Прямий `present(_:animated:)` з UIKit — тоді на iPad `UIActivityViewController` за замовчуванням `.popover`, і **без** `popoverPresentationController.sourceView` + `sourceRect` це краш. Підтверджено, вимога чинна й у поточному SDK. Якщо йти цим шляхом — якорем брати `textView.firstRect(for:)` по діапазону виділення.

### 4. `NotesViewModel.openNewNote(attachedToQuote:)` — дзеркало наявного методу

```swift
/// Дзеркалить openNewNote(attachedTo verse:translation:).
/// ⛔ НЕ виставляє isEditorPresented — навмисно. Виклик володіє презентацією
/// сам (свій sheet-слот). Виставлення isEditorPresented тут підняло б
/// ОДНОЧАСНО sheet у NotesListView, і SwiftUI склав би нижній sheet —
/// це задокументована пастка в doc-коментарі сусіднього методу, не стиль.
@discardableResult
func openNewNote(attachedToQuote text: String, theologianId: String, verseId: String) -> NoteWithBlocks {
    let now = Date(); let noteId = UUID().uuidString
    let note = Note(id: noteId, userId: authService.userId, folderId: nil,
                     createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)

    let quoteContent = QuoteBlockContent(theologianId: theologianId, verseId: verseId, text: text)
    let quoteJSON = (try? JSONEncoder().encode(quoteContent))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let quoteBlock = NoteBlock(id: UUID().uuidString, noteId: noteId, position: 0,
                                type: .quote, verseId: verseId, strongsId: nil,
                                content: quoteJSON, createdAt: now, updatedAt: now)

    let textJSON = (try? JSONEncoder().encode(TextBlockContent(body: "")))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"body\":\"\"}"
    let textBlock = NoteBlock(id: UUID().uuidString, noteId: noteId, position: 1,
                               type: .text, verseId: nil, strongsId: nil,
                               content: textJSON, createdAt: now, updatedAt: now)

    let noteWithBlocks = NoteWithBlocks(note: note, blocks: [quoteBlock, textBlock], verseIds: [verseId])
    editingNote = noteWithBlocks
    return noteWithBlocks
}
```

Точно та сама форма, що й `openNewNote(attachedTo verse:translation:)` — нуль нового тертя в `store.saveNote`/`PreAuthIdentity` (той самий шлях, без логіну, уже працює для verse-нотаток).

`verseId` — це **тапнутий вірш** (`CommentaryDetailView.verseId`), а не початок секції. Так нотатка привʼязується до того місця, звідки користувач її взяв, і `note_verses` дає їй правильний якір у рідері. Секційний діапазон уже несе `ref` у самому тексті цитати.

⚠️ **Пастка з капіталізацією — перевірено, твердження ПРАВИЛЬНЕ:** у кодбейсі співіснують дві форми ідентичності теолога — `Theologian.id` (рядковий регістр, `"calvin"`, `StrongsModels.swift`) і `comments.source` у БД (капіталізований, `"Calvin"`; так пише `scripts/import_commentaries.py`, так читає `DatabaseService.loadCommentary(source: theologian.id.capitalized)` і так фільтрує `CommentariesView.visibleTheologians`). `QuoteBlockContent.theologianId` за doc-коментарем структури очікує **рядковий регістр** — тобто сюди йде `theologian.id`, **не** `theologian.id.capitalized`. Переплутати легко саме тому, що обидва варіанти виглядають валідними компільовано.

➕ **Побічно знайдено:** doc-коментар `QuoteBlockContent.theologianId` перелічує `"calvin" | "henry" | "spurgeon"` — **без Owen**, який у `Theologian.all` є з дня імпорту Owen. Коментар застарів. Виправити разом із цією фічею (однорядкова правка, але саме такі коментарі потім читають як контракт).

### 5. ⛔ `.quote`-блок ніде не рендериться — це діра в happy path, а не деталь

**Знайдено адверсарним ревʼю, первинна редакція ADR цього не бачила.** Перевірено в коді:

- `NoteEditorView.verseBlocks` = `blocks.filter { $0.type == .verse }` — рендерить **лише** `.verse`-картки плюс єдиний `.text`-блок. `.quote` не має жодної гілки.
- `NoteEditorView.navigationTitle` бере референс із першого `.verse`-блоку, інакше падає у загальний «Нотатка».
- `NoteCardView.verseText` так само шукає **тільки** `.verse`-блок; тіло картки — тільки `.text`.

Наслідок за первинним планом: користувач виділяє абзац Кальвіна → «Додати в нотатку» → **відкривається порожній редактор без жодного сліду цитати**. Збережеться воно правильно (`NoteEditorView.saveAndDismiss` копіює **всі** блоки й оновлює лише `.text`, тож `.quote` доживе до бази), але у списку нотаток картка теж буде майже порожня. Тобто фіча технічно працює й продуктово не існує.

**Рішення:** `.quote` отримує рендер **одночасно** з тим, як зʼявляється спосіб його створити — не окремою фазою:

- `NoteEditorView` — `QuoteContextCard` за прямою аналогією з наявним `VerseContextCard`: текст цитати + «— {shortName}, {ref}». Тап — навігація на `verseId` через `router.requestNavigation` (як у verse-картці).
- `NoteEditorView.navigationTitle` — врахувати `.quote` як джерело референсу, коли `.verse`-блоку немає.
- `NoteCardView` — гілка прев'ю для `.quote`, щоб картка в списку не була порожньою.

Це розширює обсяг фічі, але альтернатива — свідомо зашипити мертву кнопку.

---

## Options Considered

### Option A: нескролящий `UITextView` у SwiftUI `ScrollView` + `buildMenu(with:)` (обрано первинно — **відхилено після ревʼю**)

| Dimension | Assessment |
|---|---|
| Відповідність запиту | Повна на папері |
| Ризик платформи | **Блокуючий.** `isScrollEnabled=false` = синхронна верстка всього документа (до 329k символів) заради `sizeThatFits`; в'юшка на 150k+ pt; вкладені скрол-в'ю під час виділення — відома проблемна конфігурація |
| Коректність API | **Хибна.** `buildMenu(with:)` задокументований для main/context menu systems, не для edit menu виділення в `UITextView` |

**Відхилено.** Обидві опори варіанта не витримали перевірки.

### Option B: SwiftUI `.textSelection(.enabled)` без кастомних дій (відхилено)

| Dimension | Assessment |
|---|---|
| Складність | Мінімальна — один модифікатор |
| Відповідність запиту | Не відповідає — підтверджено, що немає гачка ні на буфер обміну, ні на власні пункти меню |

**Відхилено** — не дає ні Share з атрибуцією, ні Note. Технічно найдешевше, продуктово не рішення задачі.

### Option C: Виділення через `.textSelection`, а «Поділитися»/«Нотатка» — статичні кнопки під текстом (відхилено, лишається запасним)

| Dimension | Assessment |
|---|---|
| Складність | Низька |
| UX | Двокроковий (виділив → скроль/шукай кнопку) — не Apple Books |

**Відхилено як гірший UX**, але лишається запасним варіантом і тепер має **два** незалежні приводи існувати: (а) якщо фільтр `suggestedActions` виявиться крихким, (б) депрекація `editMenuForTextIn` в iOS 27.

### Option C′: пораграфні `UITextView` (по одному на абзац або на групу абзаців) — запасний, якщо D впаде

| Dimension | Assessment |
|---|---|
| Масштаб | Безпечний — кожна в'юшка маленька, `LazyVStack` лишається лінивим |
| Виділення | **Втрачається крос-абзацне** — виділення є властивістю одного `UIView` |

Тримати як відкат, якщо скролящий `UITextView` (D) дасть несподівані проблеми з layout всередині sheet-а. Ціна відкату — рівно та вимога, заради якої фіча й затівалась.

### Option D: **скролящий** `UITextView` на всю площу sheet-а + `UITextViewDelegate.editMenuForTextIn` (**обрано**)

| Dimension | Assessment |
|---|---|
| Відповідність запиту | Повна — нативні повзунки/лупа + власні пункти в системному меню, крос-абзацне виділення |
| Складність | Середня — новий `UIViewRepresentable` + перебудова layout `CommentaryDetailView` (шапка виходить зі скролу) |
| Ризик платформи | Низький — TextKit у рідному режимі (ліниво, viewport), нуль вкладених скролів, задокументований delegate API |
| Перевикористання | Максимальне — `VerseShareFormatter`-конвенція, `NoteBlockType.quote`, `openNewNote`-патерн, `detailTitle`, `ActiveEditor`-слот |

**Мінус:** шапка з портретом більше не прокручується (див. §1) — єдине, що потребує продуктового підпису.

---

## Наслідки

**Стає простіше:**
- `.quote`-блок ADR-012 нарешті отримує і **творця, і рендер** — жодної зміни схеми, тільки використання вже готового типу.
- Виділення+атрибуція працює однаково для Calvin/Henry/Spurgeon/Owen вже сьогодні, без чекання на переформатування бази (п. 1 «поза обсягом») — і коли те переформатування прийде, воно лягає на той самий `UITextView`, просто з багатшим `NSAttributedString`. Це крок уперед до майбутнього ADR, не вбік від нього.
- Зникає окремий клас багів «SwiftUI `Text` мовчки не рендерить довгий рядок» — TextKit не має цієї межі.

**Стає складніше:**
- Втрачається проста «один `Text` = один параграф» модель; регресія перевіряється вручну на найдовшій **виміряній** секції (`Calvin PSA 150:6`, 329 343 символи / 3 293 абзаци), не на тій, що здавалась найдовшою.
- `CommentaryDetailView` перестає бути SwiftUI-`ScrollView` — шапка закріплена.
- Обсяг фічі більший, ніж виглядало: `.quote` треба навчитись показувати у двох місцях (§5), інакше кнопка мертва.
- UIKit-кастомізація меню виділення — це якраз той UI-код, для якого CLAUDE.md вимагає **research iOS 26 API перед написанням коду**. Цей раунд research уже зроблено (документація Apple прочитана, не вгадана) — Фаза 5 має лише звірити сигнатуру з живим заголовком SDK у Xcode.

**Що переглянути з ростом:**
- **iOS 27.** `textView(_:editMenuForTextIn:suggestedActions:)` показаний в документації як `iOS 16.0 – 27.0`. Перед підняттям SDK до 27 — знайти заміну; якщо заміни немає, це тригер на Option C.
- Якщо фільтр `suggestedActions` перестане ловити системний Share — не «чинити фільтр», а прийняти два пункти або піти в Option C. Не будувати евристику на рядкових ідентифікаторах системних дій.
- Коли прийде ADR багатої розмітки (п. 1 «поза обсягом») — `SelectableCommentaryTextView` стає точкою, куди підключається розширений `NSAttributedString` (тайтли/цитати/tappable-посилання), а не переписується заново.

---

## Action Items

0. [x] **Вирішено Іваном:** шапка богослова — двостанова (expanded/collapsed), анімований перехід, керований `contentOffset.y` того самого `UITextView`-скролу (деталі — §1, оновлений блок "Вирішено Іваном"). `Coordinator` реалізує і `UITextViewDelegate` (§2), і `UIScrollViewDelegate` (`scrollViewDidScroll`), прокидає офсет через `onScroll` замикання.
1. [ ] **Research already done — verify, don't redo:** звірити з живим заголовком iOS 26 SDK у Xcode рівно три сигнатури: `UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)`, `UIMenu(options:children:)`, `UIMenu.Identifier.share`. Документація прочитана 2026-08-27; лишилось підтвердити компіляцією, а не пошуком.
2. [ ] Реалізувати `SelectableCommentaryTextView` — **скролящий** `UITextView` (`isScrollEnabled = true`), `NSAttributedString` зі збереженим міжабзацним інтервалом, кеш рядка в `Coordinator`. Перебудувати `CommentaryDetailView`: `VStack` = закріплена шапка + текст на решту висоти, замість `ScrollView`. Видалити `CommentaryTextView`.
3. [ ] Меню виділення через `editMenuForTextIn` (§2): фільтр Share захищений з обох боків (`UIMenu` і `UIAction`), діапазон беремо з параметра делегата, підрядок — через `NSString.substring(with:)`.
4. [ ] `CommentaryQuoteShareFormatter` + презентація share sheet **через SwiftUI `.sheet` з `UIViewControllerRepresentable`-обгорткою `UIActivityViewController`** (§3) — так iPad-popover взагалі не задіяний. Якщо все ж прямий `present()` — обовʼязково `popoverPresentationController.sourceView` + `sourceRect` (якір: `textView.firstRect(for:)`), інакше крах на iPad.
5. [ ] `NotesViewModel.openNewNote(attachedToQuote:theologianId:verseId:)` — з doc-коментарем про те, чому `isEditorPresented` НЕ виставляється. Передавати `theologian.id` (рядковий регістр!), не `.capitalized`. Заодно виправити застарілий doc-коментар `QuoteBlockContent.theologianId` (додати `owen`).
6. [x] **Підтверджено Іваном — входить в обсяг, у тому ж коміті, що й створення:** `QuoteContextCard` у `NoteEditorView` (аналог `VerseContextCard`), `.quote` як джерело `navigationTitle`, гілка прев'ю в `NoteCardView`. Без цього кроку кнопка технічно working, але відкриває користувачу порожній редактор — не приймається як прийнятний перший зріз.
7. [ ] Презентація `NoteEditorView` з `CommentaryDetailView`: власний `@State private var activeEditor: ActiveEditor?` слот (дзеркало `VerseBottomSheetView.ActiveEditor`), `.sheet(item:)`, явна ре-інʼєкція `.environmentObject(notesVM)` + `.environmentObject(router)` (як у `VerseBottomSheetView`), `.onDisappear { notesVM.refresh() }`. Це **третій** рівень sheet-стеку (рідер → Study Mode sheet → commentary sheet → note editor).
8. [ ] Локалізація: **один** новий ключ `commentary.menu.addToNote` (EN+UK) у `Localizable.xcstrings`; для «Поділитися» перевикористати наявний `action.share`. ⛔ `NSLocalizedString`/`Text`, не `String(localized:)` (ADR-006). Гейт: `python3 scripts/lint_localization.py`.
9. [ ] **QA на пристрої, обовʼязково:**
   - `Calvin PSA 150:6` (329 343 символи, 3 293 абзаци) — відкриття, скрол, виділення, без фризу й графічних артефактів. Це **новий** еталон найгіршого випадку; `Owen HEB 1:1-2` (231k) — вторинний.
   - неперервне перетягування виділення через межу абзаців;
   - `suggestedActions`-фільтр справді прибирає системний Share і **зберігає** Look Up / Translate / Search Web поруч із нашими пунктами;
   - Share sheet на **iPad** (обидва шляхи презентації, якщо обраний не рекомендований);
   - stacked-sheet: `NoteEditorView` поверх commentary sheet-а поверх Study Mode sheet-а — три рівні; перевірити, що нижні sheet-и не складаються і що після Save список нотаток оновлений;
   - нотатка з цитатою видно **і** в редакторі, **і** карткою в списку (§5);
   - share-рядок укр. та англ. мовою (`shortName` локалізований, §3).
