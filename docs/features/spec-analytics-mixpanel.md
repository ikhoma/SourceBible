# Spec — Analytics (Mixpanel) Integration

**Status:** Draft
**Date:** 2026-06-19
**Product decision:** [[PDR-Analytics-Mixpanel]] (Mixpanel у беті+проді, гейт на згоді, trust-first, North Star = MSS; свап на кастомну за free-tier лімітом)

---

## Goals

- Інструментувати багаті атомарні події, щоб у Mixpanel рахувати: engagement/retention, search behavior, feature adoption, **Meaningful Study Session (MSS)** — без нових білдів для зміни визначень.
- Аналітика **в беті і в проді**, анонімно (PreAuthIdentity), гейтнута на тумблері згоди (default ON); реліз з вимкненою згодою = `NoopAnalytics`. Mixpanel — тимчасово (free-tier), із заміною на власну реалізацію через абстракцію, коли ліміту перестане вистачати (D3).

## Non-goals

- Окремий remote kill-switch для аналітики (свап реалізації через абстракцію достатньо).
- Серверна аналітика / власний бекенд (V1.5+).
- A/B-експерименти, feature flags.
- Будь-який PII або текст нотаток.

## Architecture

### `AnalyticsService` (абстракція — один шар)

Усі виклики йдуть через протокол, ніяких `Mixpanel.track` по в'юхах (стиль як `TranslationProvider`, `UserDataStoreProtocol`).

```swift
protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent)
    func identify(distinctId: String)
    func flush()
}
```

- `AnalyticsEvent` — enum з асоційованими значеннями (typed events, без «магічних рядків» на місцях виклику). Маппінг enum → (name, props) в одному місці.
- **`MixpanelAnalytics`** — реальна реалізація (бета).
- **`NoopAnalytics`** — порожня реалізація для opt-out (тумблер згоди OFF) і як свап-таргет, поки не готова кастомна аналітика. Нуль мережі.
- Інʼєкція через Environment / DI; в'юхи/VM викликають `analytics.track(...)`.

### distinct_id

`identify(distinctId:)` ← **PreAuthIdentity** id ([[ADR-012-unified-user-data-layer]]). Анонімно, стабільно, без логіну → retention рахується, trust-first збережено.

### Гейтинг на згоді (бета + прод)

- **Джерело істини — тумблер «Share anonymous usage»** (`analyticsEnabled`, default ON), **не** build-флаг. ON → `MixpanelAnalytics`; OFF → `NoopAnalytics` (нуль мережі), без рестарту.
- Діє однаково в беті і в App Store-релізі (D3 ✅).
- Token — з `.xcconfig`/build setting, **не в git**.
- ⚠️ **Зміна від Slice 1:** код зараз гейтить `MixpanelAnalytics` через `#if BETA` (бета-only). Треба зняти — компілювати Mixpanel і в release, гейтити лише на тумблері згоди. Це **окремий крок реалізації** (Slice 1.5 / на старті Slice 2), не мовчки в межах іншого зрізу.
- Свап на кастомну аналітику = заміна `MixpanelAnalytics` на власну `AnalyticsService` за free-tier лімітом; remote kill-switch не потрібен.

### Тестування до TestFlight (DEBUG)

Щоб перевірити інтеграцію ще на симуляторі/девайсі, **без TestFlight**:

- **Init дозволено й у `#if DEBUG`** (на симуляторі немає TestFlight-receipt). Логіка: ініціалізувати якщо `TestFlight (sandboxReceipt)` **АБО** `DEBUG`. У release `DEBUG` нема → прод-гейтинг не порушено.
- **Окремий dev-токен** у Debug-конфізі (`.xcconfig`), відмінний від beta-токена — щоб тестові тапи **не засмічували** дані бети.
- **Debug-логи SDK** увімкнені в DEBUG → кожна відправлена подія видно в консолі Xcode.
- **`flush()`** після події в DEBUG, щоб слати негайно, не чекаючи батч.
- Перевірка: подія з'являється в **dev-проекті Mixpanel (Live/Events)** за секунди (фільтр по distinct_id).
- Точний синтаксис (logging-флаг, `flush`, init) — звірити в SDK-research.

### Згода (D2)

**Два елементи:**

1. **Одноразова нижня картка (bottom sheet)** при першому запуску — патерн «допоможи покращити», НЕ системний ATT-діалог і НЕ toast. Орієнтир: Meta AI «Share additional data», Transit «Want to help … improve service?».
   - Заголовок: «Допоможіть покращити Source Bible».
   - Рядок пояснення: збираємо **анонімну** статистику використання, щоб покращувати додаток; жодних особистих даних чи тексту нотаток/запитів; **рішення оборотне — тумблер у Меню**.
   - Дії: «Ділитися статистикою» (залита) / «Не ділитися» (текстова); лінк на privacy policy **вшитий у речення**, не окремим рядком.
   - Показується **один раз** (прапорець у user-data/AppStorage); «Не ділитися» → тумблер OFF.
2. **Тумблер у Settings «Share anonymous usage» (default ON)** з коротким описом поряд — постійне джерело правди, можна перемкнути будь-коли.

**Dismiss = відмова (amend 2026-08-03).** Свайп вниз або тап поза шітом без
явного вибору → тумблер OFF. Раніше закриття лишало зареєстрований дефолт
(`MixpanelAnalytics.isTestFlight`, PDR D4), тож у TestFlight «закрити не читаючи»
означало погодитись. Згода існує лише як affirmative action, однаково в усіх
збірках. Побічний ефект: тестер, що змахнув картку, вимикає собі аналітику —
свідомий розмін на користь однозначності; шлях назад у Меню.

**Чому не «Не зараз» (amend 2026-08-03).** Прапорець `analyticsConsentShown`
виставляється в момент ПОКАЗУ, тож картка більше не зʼявляється — «Не зараз»
де-факто означало «ніколи». Або текст, або поведінка мали змінитись; обрано
текст: питаємо один раз, повторних промтів про аналітику немає.

**Показ чекає на замір висоти (amend 2026-08-03).** Картка підстрибувала при
першій появі: презентувалась, потім змінювала висоту, а вміст переїжджав удруге.
Причина — **гонка** між `onAppear` кореневого в'ю (звідки йшов показ) і
`onGeometryChange` прихованої проби (звідки береться висота детента). Порядок між
ними не гарантований: виграє проба — детент одразу правильний; виграє `onAppear` —
шіт відкривається зі стартовими 300, далі детент стрибає на заміряні ~388, а
вміст, затиснутий у 300, розкладається наново. Звідси «то стрибає, то ні».

Показ тепер відбувається лише коли обидві умови зійшлись (`presentIfReady()`).
Заразом `analyticsConsentShown` виставляється РАЗОМ із показом, а не в `onAppear`:
інакше при невдалому заміру прапорець «спитали» стояв би, а спитати не встигли б.
Страхувальна гілка через 1 с показує картку з сідовою висотою — краще стрибок,
ніж мовчки не спитати згоду.

**Гейтинг init:** Mixpanel ініціалізується лише коли тумблер ON. OFF → SDK не стартує, події відкидаються (`NoopAnalytics`-поведінка). Перемикання в рантаймі поважається **без рестарту**.

Без блокуючого opt-in промту (немає цільової EU-бази, [[PDR-Analytics-Mixpanel]] D2).

### Swift 6 / iOS 26 (перевірити ПЕРЕД інтеграцією)

- Mixpanel SDK: перевірити `Sendable`/`@MainActor` анотації (постійний клас помилок у проекті). `AnalyticsService: Sendable` — реалізація має бути безпечна для виклику з будь-якого актора.
- SPM-пакет, версію й Swift 6 сумісність звірити web-research перед додаванням (правило проекту).

### Privacy

- `PrivacyInfo.xcprivacy` з декларацією зібраних типів (device identifiers, product interaction).
- Жодного raw-тексту нотаток/запитів (D1 — за рекомендацією не слати текст запиту).

## Event Taxonomy

> Іменування: `snake_case`. Спільні super-props: `translation`, `distinct_id` (auto), `app_version`, `is_beta`.
> **⚠️ Авторитетне джерело таксономії — [[ADR-022-analytics-event-collection-strategy]] + Slice 3 Work Order нижче.** Терміни (original / lexicon / concordance тощо) — у [[glossary]]. Розділ «Feature adoption (v1, СКАСОВАНО)» нижче лишено для історії.

### Session / engagement

| Event | Props | Коли |
|---|---|---|
| `app_opened` | — | foreground (cold start + повернення з фону; звідси DAU/WAU, retention) |
| `study_session_summary` | `duration_s`, `verses_opened`, `word_nav_count`, `verse_nav_count`, `searches_count`, `annotations_created`, + per-feature `<feature>_views_count` (×6) | кінець сесії (background, grace ~30с) |

> `word_nav_count` / `verse_nav_count` — шеврон-навігація між словами/віршами. `<feature>_views_count` — перегляди кожної з 6 фіч (ADR-022). Усе — лічильники в summary (НЕ події-на-тап), сигнал глибини без засмічення; годують MSS.

### Search behavior

| Event | Props | Коли |
|---|---|---|
| `search_committed` | `results_count`, `had_zero_results`, `translation`, `testament_filter` | коміт пошуку (tap підказки / Search CTA) |
| `search_result_opened` | `results_count`, `position` | тап результату → відкриття вірша |

> D1: **без** `query` raw-тексту. Якщо D1 зміниться — додається `query`.

### Feature adoption (ADR-022, варіант B — гранулярно)

Дискретна подія `feature_adopted_<feature>` фаєриться **раз/сесію** на першу взаємодію; деталь — лічильниками в `study_session_summary`. 6 фіч (1:1 з UI-поверхнями):

| Adoption-подія | Поверхня | Лічильник у summary |
|---|---|---|
| `feature_adopted_original` | список оригінальних слів (`OriginalWordsView`) | `original_views_count` |
| `feature_adopted_lexicon` | визначення слова Strong's (`WordMeaningView`) | `lexicon_views_count` |
| `feature_adopted_concordance` | вживання слова (`ConcordanceView`) | `concordance_views_count` |
| `feature_adopted_commentary` | коментар (`CommentaryDetailView`) | `commentary_views_count` |
| `feature_adopted_cross_reference` | cross-references | `cross_reference_views_count` |
| `feature_adopted_parallel_translation` | parallel translations | `parallel_translation_views_count` |

Перші три — воронка word-study (original → lexicon → concordance). Дискретні **поза** цією моделлю (бо рідкісні/цінні): `translation_switched(from,to)`, `note_created`, `highlight_created(color)`, `bookmark_created`. Деталі call-sites — у Slice 3 Work Order.

#### ~~Feature adoption (v1, СКАСОВАНО — лишено для історії)~~
> Початковий per-tap драфт (`original_opened`/`study_tab_switched`/`strongs_viewed`/`commentary_opened`/`crossref_opened`/`word_usage_opened`) **скасовано** на користь моделі ADR-022 вище — занадто великий обсяг подій.

### Відкладено (інструментувати, коли фічу доробимо в беті — зріз 4)

| Event | Чому відкладено |
|---|---|
| `verse_card_added` | картки віршів ще не реалізовано |
| `word_card_added` | картки слів ще не реалізовано |
| `folder_created` / `tag_added` | папки/теги: кнопка є, але **нефункціональний стаб** — інструментувати зламану кнопку немає сенсу |

## Meaningful Study Session (MSS) — рахується в Mixpanel

Додаток шле лише `study_session_summary` (лічильники). MSS — **Custom Event** у Mixpanel:

**Провізорна формула** (тюнабельна в Mixpanel без релізу; фінальні пороги — на реальних даних після Slice 3):

```
depthSignal = original_views_count + lexicon_views_count + concordance_views_count
            + commentary_views_count + cross_reference_views_count
            + parallel_translation_views_count
            + word_nav_count + annotations_created

MSS = study_session_summary WHERE
      duration_s >= 60          -- знижено зі 120: глибока сесія на 1 вірш теж MSS
  AND depthSignal >= 1          -- реальна дія глибини (verses_opened-гейт прибрано)
```

- `<feature>_views_count` інкрементується через `SessionTracker.recordFeatureUse(_:)`; шеврон-навігація — `word_nav_count` / `verse_nav_count`.
- North Star дашборд: % сесій що MSS; % WAU з ≥1 MSS/тиждень.
- Окрема воронка adoption: `feature_adopted_original` → `_lexicon` → `_concordance`.
- Adoption-флоу — **воронки** (open → search → open verse → annotate), окремо від MSS.

## Acceptance Criteria

- [ ] Події летять у Mixpanel у беті і в проді, коли згода ON; згода OFF (бета чи реліз) → `NoopAnalytics`, жодного мережевого виклику.
- [ ] Тумблер «Share anonymous usage» (default ON) керує init SDK; вимкнено → жодних подій, без рестарту.
- [ ] Одноразова нижня картка показується рівно раз; «Не зараз» → тумблер OFF; є тумблер+опис у Settings.
- [ ] distinct_id = PreAuthIdentity; нема PII; нема raw-тексту запиту (D1).
- [ ] `study_session_summary` шлеться рівно раз на сесію з коректними лічильниками.
- [ ] `PrivacyInfo.xcprivacy` присутній; token не в git.
- [ ] DEBUG-білд (симулятор): Mixpanel ініціалізується з dev-токеном, подія видно в Mixpanel Live за секунди; release не зачеплено.
- [ ] Build проходить; Swift 6 strict concurrency без помилок.
- [ ] У Mixpanel можна зібрати: retention D1/D7/D30, топ/zero-result пошук, adoption кожної фічі, MSS-дашборд.

## Open Items / Dependencies

- **D1/D2/D3** з [[PDR-Analytics-Mixpanel]] — підпис перед реалізацією.
- Mixpanel Swift SDK: версія + Swift 6 перевірка (web-research).
- Залежить від PreAuthIdentity API ([[ADR-012-unified-user-data-layer]]).
- Відкладені події (`verse_card_added`, `word_card_added`, `folder_created`, `tag_added`) — інструментувати разом із фічею карток/папок Нотаток (зріз 4, у беті).
- **v1.5 (за потреби):** перехід `MixpanelAnalytics` → `NoopAnalytics`, **якщо в цьому буде сенс** (напр. наближення до Free-cap). Це **просто свап реалізації** через наявну абстракцію — окремий remote kill-switch НЕ потрібен. Free-план не білить і щомісяця знову дає 1M, тож зараз нічого спеціального не робимо (абстракція вже це дозволяє).

## Implementation Slices (черговість; виконує Opus інтерактивно на `work`, не автономний Fable)

1. **Каркас:** `AnalyticsService` + `MixpanelAnalytics` + `NoopAnalytics`, гейтинг (BETA/TestFlight **+ DEBUG для тестів**), distinct_id, картка+тумблер згоди, `PrivacyInfo.xcprivacy`, token через xcconfig (окремі dev/beta токени). (Acceptance: події видно в Mixpanel Live з DEBUG-білда; no-op у release.)
2. **Engagement + Search:** `app_opened`, `study_session_summary` (вкл. `word_nav_count`/`verse_nav_count`), `search_committed`, `search_result_opened`.
3. **Feature adoption (ADR-022, варіант B):** `feature_adopted_*` (×6: original/lexicon/concordance/commentary/cross_reference/parallel_translation) раз/сесію + `<feature>_views_count` у summary; дискретні `translation_switched`, `note_created`, `highlight_created`, `bookmark_created`. Деталі — Slice 3 Work Order.
4. **Нові Нотатки:** `verse_card_added`/`word_card_added`/`folder_created`/`tag_added` — разом із фічею карток/папок.

## Slice 1 — Work Order (каркас аналітики)

**Виконавець:** Opus (Fable недоступна), інтерактивно — правки після «давай», diff на ревʼю. Не autonomous-unattended.

**Гілка:** на `work` (окрема гілка/worktree не потрібна — рішення Ivan). Гейт = повний diff на ревʼю **перед** FF-мерджем `work → main`.

**Перший крок (ОБОВʼЯЗКОВО, до коду):** web-research актуального Mixpanel Swift SDK — SPM URL, остання версія, **Swift 6 strict concurrency** сумісність (`@MainActor`/`Sendable`), iOS 18 min. Зафіксувати в звіті. Якщо SDK не Swift-6-ready → **зупинитись і спитати**, не хакати.

**Scope IN (тільки це):**
- `AnalyticsService` protocol + `AnalyticsEvent` enum (маппінг enum → name/props в одному місці).
- `MixpanelAnalytics` (бета) + `NoopAnalytics` (release / opt-out).
- Інʼєкція через Environment/DI. **Крапки виклику подій поки НЕ інструментувати** (зрізи 2–4).
- Гейтинг: `#if BETA` + TestFlight-перевірка; токен через `.xcconfig` (не в git).
- Згода: одноразова нижня картка + тумблер Settings «Share anonymous usage» (default ON); init гейтиться на тумблері, без рестарту.
- `distinct_id` = PreAuthIdentity ([[ADR-012-unified-user-data-layer]]).
- `PrivacyInfo.xcprivacy` з деклараціями зібраних типів.
- SPM-залежність Mixpanel.

**Scope OUT (не чіпати):**
- Конкретні event-виклики в Reader/Search/Notes (зрізи 2–4).
- Логіка сесій / `study_session_summary` (зріз 2).
- Будь-яка зміна `sourcebible.db`, схеми user-data, GRDB.
- UI поза карткою згоди + рядком у Settings.

**Acceptance criteria:**
- Build проходить (iOS 18 min); Swift 6 strict concurrency без помилок.
- BETA-білд: ініціалізує Mixpanel при тумблері ON і шле тестову подію; release-білд = `NoopAnalytics`, нуль мережі.
- Тумблер керує init без рестарту; картка показується раз; «Не зараз» → OFF.
- Токен не в git; `PrivacyInfo.xcprivacy` присутній.
- Повний diff + короткий звіт (включно з результатом SDK-research).

**Hard invariants (завжди чинні):** усі ⛔ з CLAUDE.md (не читати/ламати `sourcebible.db` у Linux-sandbox, жодних незворотних дій без дозволу, build має проходити). iOS 26-only API — лише з `#available` + iOS 18 fallback.

**Exit:** diff + звіт на ревʼю Ivan. FF-мердж `work → main` і push origin — після підпису Ivan.

---

## Slice 2 — Work Order (Engagement + Search)

**Виконавець:** прості call-site події — може дешевша модель строго за цим чеклистом; `SessionTracker` (stateful) — за дизайном нижче, фінальний diff ревʼю Opus + Ivan.

**Гілка:** `work` (як Slice 1). Гейт = повний diff на ревʼю перед FF-мерджем.

**Передумова:** Slice 1 змерджено; канал підтверджено (DEBUG-білд → подія видно в Mixpanel за секунди). Інʼєкція вже є: `.environment(\.analytics, analytics)`; у в'юшках читати `@Environment(\.analytics) private var analytics`.

### Scope IN (тільки це)
Чотири події зрізу + інфраструктура сесії:

| Подія | Файл / точка виклику | Props | Тригер |
|---|---|---|---|
| `app_opened` | `SourceBibleApp.swift` — `@Environment(\.scenePhase)` обсервер на сцені, перехід → `.active`. **Прибрати TEMP-виклик з `init()`.** | — | foreground (cold start + повернення з фону) |
| `search_committed` | `SearchViewModel.search(query:translation:)` — **після** того як `results` заповнені (не на старті async-таски) | `results_count`, `had_zero_results` (=`results.isEmpty`), `translation`, `testament_filter` (з фільтра, `nil`=all) | коміт пошуку |
| `search_result_opened` | `SearchView.swift` — у замиканні тапу результату, що штовхає `ReaderView` | `results_count`, `position` (0-based індекс у `results`) | тап результату → відкриття вірша |
| `study_session_summary` | `SessionTracker.flush()` (див. нижче) | `duration_s`, `verses_read`, `study_tool_opens`, `word_nav_count`, `verse_nav_count`, `annotations_created`, `searches` | кінець сесії (background, grace ~30с) |

### `SessionTracker` — дизайн (stateful компонент)
- **Новий файл:** `SourceBible/Services/Analytics/SessionTracker.swift`. `@MainActor final class SessionTracker: ObservableObject` (UI-керований стан; не `Sendable`-проблема, бо живе на main).
- **Залежність:** ін'єктується `any AnalyticsService` через init (не лізти в `Mixpanel` напряму — лишаємось за абстракцією).
- **Стан сесії:** `startedAt: Date?` + лічильники (`versesRead`, `studyToolOpens`, `wordNavCount`, `verseNavCount`, `annotationsCreated`, `searches`) = Int, всі приватні.
- **API (public, всі `@MainActor`):**
  - `begin()` — старт сесії, якщо ще не активна (викликається на `app_opened`/перший foreground).
  - `incVersesRead()`, `incWordNav()`, `incVerseNav()`, `incStudyToolOpen()`, `incAnnotation()`, `incSearch()` — інкременти.
  - `flush()` — якщо сесія активна: зібрати `study_session_summary` з `duration_s = now - startedAt`, `analytics.track(...)`, скинути стан. No-op якщо сесії нема.
- **Життєвий цикл (у `SourceBibleApp`/`ContentView` через `scenePhase`):**
  - `.active` → `analytics.track(.appOpened)` + `tracker.begin()`. Якщо повернення в межах grace (~30с після background) — **не** новий `begin()`, продовжити поточну сесію (зберігати `backgroundedAt`, скасувати pending-flush).
  - `.background` → запланувати flush через ~30с (grace). Якщо не повернулись — `tracker.flush()`.
  - ⚠️ **Amendment (precaution, NOT yet empirically verified):** flush у фоні варто обгорнути в `UIApplication.beginBackgroundTask` (+`endBackgroundTask` через defer), бо на реальному пристрої iOS присипляє апку за кілька секунд і `Task.sleep(30с)` може не доспрацювати. Це профілактика за відомою поведінкою iOS, а не фікс спостереженого збою — сценарій background+grace ще треба прокликати й підтвердити через MCP.
- **Інʼєкція:** створити в `SourceBibleApp.init` поряд з `analytics`, прокинути в Environment (`@Environment(\.sessionTracker)` або `@EnvironmentObject`), щоб ReaderViewModel/в'юшки інкрементили.

### Точки інкременту лічильників (Slice 2 scope)
- `verses_read` → `ReaderViewModel`: `navigateToVerse(id:)`, `navigateToNextVerse()`, `navigateToPreviousVerse()`, `tapVerse(_:)`, зміна глави (`nextChapter`/`prevChapter`). Рахувати **унікальні** відкриті вірші за сесію (Set verseId), не кожен скрол.
- `word_nav_count` → `navigateToNextWord()` / `navigateToPreviousWord()`.
- `verse_nav_count` → `navigateToNextVerse()` / `navigateToPreviousVerse()` (шеврон у Bottom Sheet).
- `searches` → інкремент разом з `search_committed`.

### Крос-зрізова залежність (важливо — НЕ інструментувати тут)
- `study_tool_opens` інкрементиться на `original_opened`/`study_tab_switched`/`strongs_viewed`/`commentary_opened`/`crossref_opened`/`word_usage_opened` — **це Slice 3**. Тут лише визначити `incStudyToolOpen()`; виклики додасть Slice 3.
- `annotations_created` — на `note_created`/`highlight_created`/`bookmark_created` — **Slice 3**. Тут лише `incAnnotation()`.
- Тобто `study_session_summary` у Slice 2 шлеться з реальними `verses_read`/`word_nav`/`verse_nav`/`searches`, а `study_tool_opens`/`annotations_created` поки 0 — заповняться, коли Slice 3 додасть свої виклики.

### Scope OUT (не чіпати)
- Feature-adoption події (Slice 3) і будь-які виклики `incStudyToolOpen()`/`incAnnotation()`.
- Картки/папки/теги (Slice 4).
- `sourcebible.db`, схема user-data, GRDB, ReaderViewModel-логіка поза інкрементами.

### Acceptance criteria
- Build проходить (iOS 18 min); Swift 6 strict concurrency без помилок (SessionTracker `@MainActor`; `track()` через абстракцію).
- DEBUG-білд: `app_opened` при кожному foreground; `search_committed`/`search_result_opened` з коректними props видно в Mixpanel за секунди.
- `study_session_summary` шлеться **рівно раз на сесію** на background+grace, з коректними `duration_s`, `verses_read`, `word_nav_count`, `verse_nav_count`, `searches` (інші лічильники = 0 до Slice 3).
- Повернення в межах grace не плодить нову сесію / дубль summary.
- Згода OFF (включно з release-білдом) → `NoopAnalytics`, нуль мережі; ON → події летять (бета і прод).
- TEMP `track(.appOpened)` з `init()` прибрано.
- Повний diff + короткий звіт.

### Hard invariants (завжди чинні)
Усі ⛔ з CLAUDE.md; iOS 26-only API лише з `#available` + iOS 18 fallback; build має проходити.

**Exit:** diff + звіт на ревʼю Ivan. FF-мердж `work → main` — після підпису.

---

## Slice 3 — Work Order (Feature adoption + annotations) — модель [[ADR-022-analytics-event-collection-strategy]]

> **Перероблено під ADR-022:** замість дискретної події на кожен перегляд — **adoption-подія раз/сесію** + **лічильники в `study_session_summary`**. Це різко знижує обсяг (free-tier). Стара версія цього Work Order (per-tap `strongs_viewed` тощо) скасована.

**Виконавець:** call-site через `SessionTracker.recordX()` — може дешевша модель строго за чеклистом; фінальний diff ревʼю Opus + Ivan.

**Гілка:** `work` (Slice 2 уже в `main`; `work == main`). Гейт = повний diff перед FF-мерджем.

### A. Зміни в `AnalyticsEvent` (варіант B — гранулярно, 1:1 з UI-поверхнями)
- **Новий enum (6 фіч):** `enum AnalyticsFeature: String, CaseIterable { case original, lexicon, concordance, commentary; case crossReference = "cross_reference"; case parallelTranslation = "parallel_translation" }`. (`original` = список оригінальних слів; `lexicon` = визначення Strong's слова; `concordance` = вживання слова — див. [[glossary]].)
- **Один adoption-кейс:** `case featureAdopted(AnalyticsFeature)` → ім'я `feature_adopted_\(f.rawValue)`.
- **Розширити `studySessionSummary`**: фіксовані поля `duration_s`, `verses_opened`, `word_nav_count`, `verse_nav_count`, `searches_count`, `annotations_created` **+** per-feature `\(f.rawValue)_views_count` для кожного `AnalyticsFeature.allCases` (`original_views_count`, `lexicon_views_count`, `concordance_views_count`, `commentary_views_count`, `cross_reference_views_count`, `parallel_translation_views_count`).
- **Прибрати** дискретні per-tap кейси: `originalOpened`, `studyTabSwitched`, `strongsViewed`, `commentaryOpened`, `crossRefOpened`, `wordUsageOpened`.
- **Лишити дискретними:** `appOpened`, `searchCommitted`, `searchResultOpened`, `noteCreated`, `highlightCreated(color)`, `bookmarkCreated`, `translationSwitched(from,to)`.

### B. Зміни в `SessionTracker` (один generic метод)
- Стан: `featureCounts: [AnalyticsFeature: Int]` + `adopted: Set<AnalyticsFeature>` (обидва чистяться в `resetState()`); плюс `wordNav` (перейменований із `lexiconNav`), `verseNav`, `versesOpened` (Set), `searches`, `annotations`.
- **Один generic метод** (`@MainActor`, guard на активну сесію):
  ```swift
  func recordFeatureUse(_ f: AnalyticsFeature) {
      guard _startedAt != nil else { return }
      if adopted.insert(f).inserted { _analytics.track(.featureAdopted(f)) }
      featureCounts[f, default: 0] += 1
  }
  ```
- Навігаційні/інші інкременти: `incWordNav()`, `incVerseNav()`, `incVersesOpened(verseId:)`, `incSearch()`, `incAnnotation()`.
- `flush()` будує `study_session_summary`: фіксовані поля + цикл по `AnalyticsFeature.allCases` → `"\(f.rawValue)_views_count": featureCounts[f] ?? 0`.

### C. Точки виклику (роутимо через tracker, НЕ track напряму)
| Дія | Файл / тригер | Виклик |
|---|---|---|
| Список оригіналу (`OriginalWordsView`) | `VerseTabContent.swift` — пілюля `.original` | `tracker.recordFeatureUse(.original)` |
| Визначення слова / лексикон | `WordTabContent.swift` — `WordMeaningView` зʼявляється з `entry` (на appear, дедуп по `entry.id`) | `tracker.recordFeatureUse(.lexicon)` |
| Конкорданс (вживання слова) | `WordTabContent.swift` — `ConcordanceView` (суб-вкладка `.usage`) | `tracker.recordFeatureUse(.concordance)` |
| Шеврон-навігація слів | `ReaderViewModel.navigateToNext/PreviousWord` | `tracker.incWordNav()` |
| Коментар | `VerseTabContent.swift` — `CommentaryDetailView(theologian:)` | `tracker.recordFeatureUse(.commentary)` |
| Cross-references | `VerseTabContent.swift` — пілюля `.crossRefs` | `tracker.recordFeatureUse(.crossReference)` |
| Parallel translations | `VerseTabContent.swift` — пілюля `.translations` | `tracker.recordFeatureUse(.parallelTranslation)` |
| Зміна перекладу (дискретно) | `ReaderViewModel.selectTranslation` — `from` до присвоєння; фаєрити `translationSwitched(from,to)` лише якщо `from != to` | `analytics.track` (не tracker) |
| Нотатка / гайлайт / закладка (дискретно) | нова нотатка; no-highlight→highlighted; bookmark додано | `analytics.track(.note/​highlight/​bookmarkCreated)` + `tracker.incAnnotation()` |

> `study_tab_switched` (verse↔word) — **прибрано**: сигнал ловиться через `recordFeatureUse(.lexicon)` при появі meaning-в'юшки. `commentary.author` і `strongs_id` більше **не** шлються (свідомо, заради обсягу — ADR-022 Consequences); якщо треба author-breakdown — повернути `commentary_opened` дискретно. **Морфологія** (майбутнє) = новий case `AnalyticsFeature.morphology`, без іншого коду.

### D. Інʼєкція (де ще нема)
- `ReaderViewModel` — додати settable `var analytics` (sessionTracker уже є); прокинути в `ReaderView.task`. Потрібно для `translation_switched` і `highlight_created`.
- `NotesViewModel`, `BookmarksViewModel` — settable `analytics` + `sessionTracker` (дефолт `.noop`), прокинути через `.task`.
- Sub-в'юшки бот-шита (`WordMeaningView`, `ConcordanceView`, `CommentaryDetailView`, `CrossRefsView`, `TranslationsView`, `OriginalWordsView`) читають `@Environment(\.sessionTracker)` напряму.

### E. Дедуп / без інфляції
- `recordFeatureUse(.lexicon)` фаєрити **на appear** конкретного `entry.id`, не на кожен recompose (тримати останній відстріляний `entry.id`).
- adoption-події гарантовано раз/сесію через `adopted` Set.

### Scope OUT
- Cards/folders/tags (Slice 4). Зміна порогів MSS — у Mixpanel + PDR, не код. `sourcebible.db`/GRDB/схема user-data.

### Acceptance criteria
- Build (iOS 18 min), Swift 6 strict concurrency — без помилок.
- DEBUG-білд: `feature_adopted_*` летять **раз/сесію** на першу взаємодію; повторні перегляди в тій же сесії НЕ плодять adoption-подій (лише ростуть лічильники).
- `study_session_summary` містить ненульові `*_views_count` / `word_nav_count` / `annotations_created`, коли інструменти реально юзались.
- Жодних дублів adoption/лічильника на recompose.
- `translation_switched` не фаєриться на той самий переклад.
- Release з вимкненою згодою = `NoopAnalytics`, нуль мережі.
- Повний diff + короткий звіт.

### Hard invariants
Усі ⛔ з CLAUDE.md; iOS 26-only API лише з `#available` + iOS 18 fallback; build має проходити; білдити тільки через Xcode (не читати DB в Linux).

**Exit:** diff + звіт на ревʼю Ivan. FF-мердж `work → main` — після підпису.

---

## Related

[[PDR-Analytics-Mixpanel]] · [[PDR-Auth-Strategy]] · [[ADR-012-unified-user-data-layer]] · [[ADR-005-highlights-bookmarks-notes]]
