# SourceBible — контекст для агента

## ⛔ НЕ ЗМІНЮВАТИ КОД БЕЗ ЯВНОГО ПРОХАННЯ

**Ніколи не редагуй Swift файли, скрипти або базу без того щоб користувач явно попросив це зробити.**
Аналіз, діагностика, пояснення — OK. Зміна файлів — тільки після "зроби це" або "виправ це".
Це правило введено після того як агент кілька разів ламав код без дозволу.

## 🤖 Autonomous mode (Fable / великі scoped-таски)

Цей режим **не скасовує** правило вище — він **замінює** мʼяке «питай перед кожною правкою» на «дозвіл наданий наперед на чітко окреслений обсяг, ревʼю по фінальному diff». Вмикається **тільки** коли користувач явно сказав «віддаю це в автономний режим / Fable» **і** дав spec.

**Умови входу (всі обовʼязкові):**
- Є явна команда на автономний прогін + посилання на затверджений `spec`/`plan`/`ADR` у `docs/`.
- Визначений **scope**: які файли/таблиці можна чіпати, що — ні.
- Визначені **acceptance criteria** (що означає «готово»).

**Огорожа (всередині неї — свобода без покрокового підтвердження):**
- Працювати **тільки в окремій git-гілці або worktree**, ніколи не в main/робочій гілці напряму.
- Не виходити за межі `scope`. Якщо завдання вимагає вийти — **зупинитись і спитати**, не розширювати самовільно.
- Перед статусом «готово»: код **збирається**, тести проходять, і підготовлено **повний diff** + короткий звіт змін для ревʼю.
- Нові архітектурні рішення всередині прогону → фіксувати як ADR/amendment і **позначити в звіті** (рішення все одно потребує підпису користувача пост-фактум).

**⛔ Жорсткі інваріанти — діють ЗАВЖДИ, автономний режим їх НЕ послаблює:**
- Усі ⛔-заборони з розділів «База даних» і «Xcode» нижче (не читати/ламати `sourcebible.db` у Linux-sandbox, не запускати `.recover` на робочій базі, тощо).
- Swift 6 strict concurrency + iOS 26 research перед UI-кодом.
- Python скрипти — під Python 3.9.
- Build має проходити; не лишати код у стані, що не компілюється.
- **Жодних незворотних дій** (видалення/перезапис бази, force-push, зміна схеми user-data без міграції) без окремого явного дозволу — навіть в автономному режимі.

**Вихід з режиму:** автономний прогін завершується видачею diff на ревʼю. Merge у робочу гілку робить користувач (або агент — лише після явного «мерджимо»).

## 📋 Docs & знання проекту

### При ініціалізації кожного чату
**Завжди читай `docs/INDEX.md` першим.** Там однорядкові summary всіх ADR, spec і product decision файлів.  
Не читай всі docs підряд — завантажуй конкретний файл тільки коли задача до нього відноситься.

### Коли завантажувати повний документ
- Задача торкається архітектурного рішення → читай відповідний ADR з `docs/architecture/`
- Задача торкається фічі в розробці → читай відповідний spec з `docs/features/`
- Задача суперечить відомому рішенню → читай той документ і поясни конфлікт перед тим як діяти

### Структура `docs/`
```
docs/
├── INDEX.md                  ← читати завжди при старті
├── architecture/             ← ADR файли (Architecture Decision Records)
├── features/                 ← spec і implementation plan для кожної фічі
├── product decisions/        ← PDR файли (Product Decision Records)
└── *.md                      ← reference документація (db_build, system designs)
```

### Правила для нових документів
- **Новий ADR** → `docs/architecture/ADR-NNN-короткий-опис.md` (NNN = наступний номер)
- **Новий spec або plan** → `docs/features/spec-назва-фічі.md` або `plan-назва-фічі.md`
- **Product decision** → `docs/product decisions/PDR-назва.md`
- Після створення документа **завжди додавай рядок в `docs/INDEX.md`**
- Не зберігай spec/ADR/plan поза `docs/` — єдине місце для проектної документації

### Конфлікти рішень
Якщо нова задача суперечить прийнятому ADR або spec — **не виконуй мовчки**.  
Назви конфлікт явно, поясни що змінилось, і запропонуй або оновити документ, або змінити підхід.

---

## 🔍 iOS 26 API — обов'язковий research перед реалізацією

**Перед тим як писати будь-який UI код для iOS 26 — спочатку research, потім код.**

Це правило введено після того як неправильне використання `HStack` + `ToolbarItem` замість `ToolbarItemGroup` призвело до годин боротьби з розмірами та відступами кнопок — тоді як правильний API вирішив проблему одним рядком.

### Обов'язковий порядок
1. **Search first.** Використовуй WebSearch щоб знайти правильний iOS 26 API для задачі. Запитуй конкретно: назву компонента, відомі проблеми, офіційні приклади.
2. **Перевір документацію.** Зайди на `developer.apple.com` або `createwithswift.com`, `swiftwithmajid.com` — там є актуальні приклади для iOS 26.
3. **Тільки після цього — пиши код.** Не гадай як має працювати API — перевір.

### Конкретні уроки
- **Button groups у toolbar** → використовуй `ToolbarItemGroup`, НЕ `HStack` всередині `ToolbarItem`. `ToolbarItemGroup` автоматично застосовує glass capsule, правильні відступи і розміри.
- **Liquid Glass** → не додавай `.background(.thinMaterial)` або `.glassEffect()` вручну до toolbar кнопок — iOS 26 застосовує glass автоматично через правильний placement і grouping.
- **Corner radius** → ⛔ не встановлюй `.presentationCornerRadius()` або `.cornerRadius()` / `.clipShape(.rect(cornerRadius:))` якщо це не запитано явно. iOS 26 застосовує правильний радіус автоматично (floating sheets — радіус екрана пристрою, кнопки — system capsule тощо). Хардкодний радіус руйнує системну консистентність.
- **HIG / iOS 26 UI Kit** → завжди використовуй стандартні системні компоненти та стилі: `.buttonStyle(.borderedProminent)` + `.controlSize(.large)` для primary actions, `List` зі стандартними row styles для налаштувань, нативні `Toggle`, `Label`, `Form` тощо. Не винаходь власні компоненти якщо є системний еквівалент — він автоматично отримує Liquid Glass, Dynamic Type, accessibility і правильні відступи за HIG.
- Якщо щось не виглядає правильно після першої спроби — **це сигнал що використовується неправильний API**, а не що потрібно більше хаків з padding/frame.

---

iOS Bible app (SwiftUI, SQLite без ORM). Оригінальні мови (Macula Hebrew/Greek) + переклади + Strong's лексикон.

## Архітектура

- **`SourceBible/Resources/sourcebible.db`** — SQLite база що бандлиться в app
- **`scripts/build_db.py`** — збирає базу з нуля (~10 хв)
- **`build_verse_map.py`** — окремий скрипт, додає verse_map після build_db.py
- **`docs/db_build.md`** — повна документація збірки з відомими помилками

Ключові таблиці: `word` (Macula слова, MT нумерація), `verse` (тексти перекладів), `strongs` (лексикон), `verse_map` (маппінг нумерації), `cross_reference`, `translation`, `book`.

## 🎯 iOS deployment target — обов'язкове правило

**Мінімальна версія: iOS 18.** `IPHONEOS_DEPLOYMENT_TARGET` буде змінено з `26.4` → `18.0` в окремому спринті після завершення поточних фіч.

**До того часу:** не пиши iOS 26-exclusive API без `#available(iOS 26, *)` guard і iOS 18 fallback.

```swift
// ✅ Правильно
if #available(iOS 26, *) {
    // iOS 26 enhanced experience
} else {
    // iOS 18 fallback
}

// ❌ Неправильно — вільне використання iOS 26-only API без guard
someIOS26OnlyAPI()
```

Раніше відомі iOS 26-only діри — **закрито** (compiler-oracle аудит 2026-07-06, Phase A, target=18.0 → 0 unguarded викликів, див. `docs/features/plan-ios18-compat.md`):
- `TabView` value-based tab selection — ✅ покрито iOS 18 split у `ContentView.swift` (legacy fallback); компілятор на 18.0 підтвердив.
- `LocalizedBundle` — це SDK-concurrency (`Bundle` `@MainActor` в iOS 26 SDK), **не** runtime-availability; вирішено через `nonisolated`. Зниження target його не чіпає.

Стан: під target=18.0 кодова база компілюється чисто (Debug+Release+Archive). Лишається на Phase B (окремий спринт): власне flip target 26.4→18.0 + повний iOS 18 runtime/візуальний QA.

Swift 6 strict concurrency — це налаштування компілятора, не залежить від deployment target. Залишається без змін.

---

## ⚡ Swift 6 / iOS 26 SDK — обов'язкові правила

Проект компілюється з **Swift 6 strict concurrency** під iOS 26 SDK. Ці правила усувають цілі класи помилок.

### Bundle subclasses
**Bundle отримав `@MainActor` в iOS 26 SDK.** Будь-який `Bundle` subclass успадковує `@MainActor`.
→ Всі overrides + static methods, що мають бути доступні з non-main-actor контексту, **обов'язково** маркувати `nonisolated`.
→ Мutaбельний стан виносити у **file-private globals** з `nonisolated(unsafe) var`, НЕ як `static var` на класі (статичні члени класу успадковують `@MainActor` inference).
→ `let` константи Sendable-типів (`NSLock`, etc.) у тому ж файлі — **також потребують `nonisolated(unsafe)`**, бо `@MainActor` inference поширюється на file-scope globals. Компілятор може видавати warning "unnecessary" — ігнорувати, без анотації буде error.

```swift
// ✅ Правильно
// swiftlint:disable:next nonisolated_unsafe
private nonisolated(unsafe) let _lock = NSLock()   // let Sendable — теж потребує анотації!
// swiftlint:disable:next nonisolated_unsafe
private nonisolated(unsafe) var _state: String = ""

final class MyBundle: Bundle, @unchecked Sendable {
    nonisolated override func localizedString(...) -> String { ... }
    nonisolated static func activate(...) { ... }
}

// ❌ Неправильно — static var на класі → @MainActor inference cascade
final class MyBundle: Bundle {
    private static var _state = ""   // ← заразить весь клас
}

// ❌ Неправильно — let без nonisolated(unsafe) в файлі з Bundle subclass
// Компілятор видає warning "unnecessary" — але це помилкове попередження.
// Без анотації: "Main actor-isolated let cannot be referenced from nonisolated context"
private let _lock = NSLock()
```

### Closures з @escaping та instance methods
**Swift 6:** виклик instance method всередині `@escaping` closure вимагає явного `self.`.
→ Якщо метод не використовує `self` state → **винести у file-level func**. Це чистіше і не потребує `self.` capture.

```swift
// ✅ Правильно — file-level func, no self capture needed
private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// ❌ Неправильно — instance method в @escaping closure без self.
class Store {
    func nowMs() -> Int64 { ... }
    func write() { db.write { nowMs() } }  // ← Swift 6 error
}
```

### Visibility та private types
**Swift 6:** property не може бути більш видима, ніж її тип.
→ Якщо клас або struct є `private` — всі properties теж `private`.
→ Якщо property посилається на `private` тип → або зробити property/клас `private`/`fileprivate`, або використати протокол як тип (`(any UITextViewDelegate)?` замість `PrivateCoordinator?`).

### UIViewControllerRepresentable для клавіатури в sheets
**Замість `UIViewRepresentable` + `DispatchQueue.asyncAfter` для `becomeFirstResponder()`.**
→ Завжди використовувати `UIViewControllerRepresentable` + `viewDidAppear()` — гарантований момент після sheet-анімації.

---

## ⛔ ЗАБОРОНИ — не повторювати ці помилки

### База даних

**⛔ Не читати `sourcebible.db` через Python у Linux sandbox або bash.**
APFS sparse file — 24MB фізично / ~149MB логічно. Linux читає sparse holes як нулі → SQLite error 11 (SQLITE_CORRUPT). Будь-який `sqlite3.connect()` у sandbox падає з "database disk image is malformed".
→ Всі Python скрипти для DB запускати **тільки на Mac** (`~/Projects/SourceBible/`).

**⛔ Не запускати `.recover` на робочій базі.**
`.recover` витягує тільки некорумповані сторінки. Sparse сторінки (де живуть `verse` і `strongs`) не відновлюються → база після `.recover` втрачає ці таблиці. Зламали робочу базу саме так.

**⛔ `build_db.py` не будує `verse_map`.**
Це окремий скрипт. Завжди запускати після build_db.py:
```bash
python3 build_verse_map.py sourcebible.db
```
Без verse_map "Оригінал" показує слова не того вірша у 459 розділах.

**⛔ Не брати xlit sub-entry від базового Strong's номера.**
H871a (прийменник בְּ) і H871 (місто Атарот) — абсолютно різні слова. Strip suffix для xlit = неправильний xlit. Fallback H835a→H835 безпечний тільки якщо `original[0]` збігається.

**⛔ При зміні `_parse_stepbible_file()` — перевіряти regex `data_re` для TBESH suffixed IDs.**
Баг виявлено у червні 2026: regex `r'^[HG]\d{4,5}\t'` мовчки скіпає 1 424 рядки TBESH де `eStrong#` = `H1471a`, `H6213a`, `H6743b` тощо. Для ~542 Strong's IDs у TBESH взагалі немає bare-number рядка — тільки suffixed. Результат: `short_def`/`long_def` = NULL для цих слів (наприклад H1471 גּוֹי, H6213 עָשָׂה, H5034 נָבֵל).

Правильний regex: `r'^[HG]\d{4,5}[a-z]?\t'` — дозволяє опціональний суфікс. Плюс треба propagate дані suffixed-row → базовий ID (H1471a → H1471).

Деталі і код виправлення: `docs/db_build.md` → розділ "TBESH suffixed eStrong# entries".

### Xcode

**⛔ Після зміни DB завжди робити Clean Build Folder (⇧⌘K).**
Xcode кешує старий `sourcebible.db`. Без Clean — код бачить стару схему.

**⛔ `#Preview` зі sample-даними завжди під `#if DEBUG … #endif`.**
Sample-дані (`BibleVerse.sampleVerses`, `BibleVerse.sampleBooks`, `StrongsEntry.sample` тощо) оголошені під `#if DEBUG`. Макрос `#Preview` НЕ загортається в `#if DEBUG` автоматично — його вміст тайп-чекається і компілюється в Release. Тому превʼю, що посилається на DEBUG-only sample, **компілюється в Debug, але валить `Product > Archive` (Release)** з `'BibleVerse' has no member 'sampleVerses'` (+ каскад `Generic parameter 'C' could not be inferred` для `ForEach`).
→ Будь-який `#Preview`, що споживає sample-дані, обгортати:
```swift
#if DEBUG
#Preview { ... BibleVerse.sampleVerses ... }
#endif
```
Не видно при звичайному ⌘B/⌘R (Debug) — перевіряти тільки через Archive або Release-білд.

**⛔ Python скрипти писати для Python 3.9.**
Mac має Python 3.9 за замовчуванням. Не використовувати синтаксис 3.10+:
- `str | None` → `Optional[str]` (з `from typing import Optional`)
- `list[str]` як тип параметра → `List[str]` або просто `list`
- `dict[str, X]` як тип параметра → `Dict[str, X]` або просто `dict`

## Повний цикл збірки DB

```bash
cd ~/Projects/SourceBible
python3 scripts/build_db.py                      # ~10 хв
python3 build_verse_map.py sourcebible.db        # ~1 хв, 7292 рядки
python3 scripts/import_commentaries.py sourcebible.db  # ~2 хв, 36 071 вірші (Calvin + Henry + Spurgeon + Owen)
python3 scripts/process_glosses.py sourcebible.db      # синтез глос
cp sourcebible.db SourceBible/Resources/sourcebible.db
# Xcode: ⇧⌘K → Run
```

## Що реалізовано (не реалізовувати повторно)

| Компонент | Файл | Статус |
|-----------|------|--------|
| verse_map + findBestMaculaVerse (3 рівні) | `ReaderViewModel.swift` | ✅ |
| findMaculaVerse() DB lookup | `DatabaseService.swift` | ✅ |
| MorphologyDecoder case "S" (займ. суф.) | `WordTabContent.swift` | ✅ |
| Header xlit: Macula ctx > xlitSimple > transliteration | `WordTabContent.swift` | ✅ |
| Sub-entry xlit fix (H871a, H1886d, H2050b) | `build_db.py` → verify_xlit_integrity | ✅ |

## Схема word table (важливо — не плутати колонки)

```sql
word(id, book_id, chapter, verse, position, surface, lemma,
     strongs_id, morph, gloss, language, xlit,
     gloss_macula,   -- ← не gloss! перейменовано
     syntax_role, greek, greek_strong,
     after_char,     -- trailing char from Macula XML (maqaf ־, sof pasuq ׃)
     lexical_class,  -- Macula TSV `class` field
     slot,           -- Macula !N group position (multiple tokens share same slot = 1 display word)
     xlit_slot)      -- BibleHub combined per-slot translit (ADR-020)
```
`gloss_macula` — стара назва була `gloss`, перейменована. Якщо код падає з "no such column: w.gloss_macula" — база стара, потрібна перезбірка.

## verse_map — зсув нумерації псалмів

459 розділів де KJV/RST нумерація відрізняється від MT (Macula). Псалми: заголовок = вірш 1 в MT, але KJV/RST його не рахують. Деталі: `docs/db_build.md` → розділ verse_map.

Очікуваний розмір: **7 292 рядки**, 459 розділів. Якщо менше — щось пішло не так.
