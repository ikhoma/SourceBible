# Spec — Analytics (Mixpanel) Integration

**Status:** Draft
**Date:** 2026-06-19
**Product decision:** [[PDR-Analytics-Mixpanel]] (beta-only, trust-first, North Star = MSS)

---

## Goals

- Інструментувати багаті атомарні події, щоб у Mixpanel рахувати: engagement/retention, search behavior, feature adoption, **Meaningful Study Session (MSS)** — без нових білдів для зміни визначень.
- Зробити це **beta-only**, анонімно (PreAuthIdentity), і так, щоб у App Store-релізі аналітики не було.

## Non-goals

- Аналітика в проді (окремий майбутній PDR — D3).
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
- **`NoopAnalytics`** — порожня реалізація для App Store-релізу (D3 поки prod = no-op).
- Інʼєкція через Environment / DI; в'юхи/VM викликають `analytics.track(...)`.

### distinct_id

`identify(distinctId:)` ← **PreAuthIdentity** id ([[ADR-012-unified-user-data-layer]]). Анонімно, стабільно, без логіну → retention рахується, trust-first збережено.

### Гейтинг beta-only

- Компіляція: `#if BETA` навколо інстанціації `MixpanelAnalytics`; інакше `NoopAnalytics`.
- Рантайм-страховка: TestFlight-перевірка (`Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"`).
- Token — з `.xcconfig`/build setting, **не в git**.
- Результат: публічний реліз = `NoopAnalytics`, жодного мережевого виклику.

### Згода (D2)

**Два елементи:**

1. **Одноразова нижня картка (bottom sheet)** при першому запуску — патерн «допоможи покращити», НЕ системний ATT-діалог і НЕ toast. Орієнтир: Meta AI «Share additional data», Transit «Want to help … improve service?».
   - Заголовок: «Допоможи покращити SourceBible».
   - Рядок пояснення: збираємо **анонімну** статистику використання, щоб покращувати додаток; жодних особистих даних чи тексту нотаток/запитів.
   - Дії: «Добре» (primary) / «Не зараз» (secondary); лінк на privacy policy.
   - Показується **один раз** (прапорець у user-data/AppStorage); «Не зараз» → тумблер OFF.
2. **Тумблер у Settings «Share anonymous usage» (default ON)** з коротким описом поряд — постійне джерело правди, можна перемкнути будь-коли.

**Гейтинг init:** Mixpanel ініціалізується лише коли тумблер ON. OFF → SDK не стартує, події відкидаються (`NoopAnalytics`-поведінка). Перемикання в рантаймі поважається **без рестарту**.

Без блокуючого opt-in промту (немає цільової EU-бази, [[PDR-Analytics-Mixpanel]] D2).

### Swift 6 / iOS 26 (перевірити ПЕРЕД інтеграцією)

- Mixpanel SDK: перевірити `Sendable`/`@MainActor` анотації (постійний клас помилок у проекті). `AnalyticsService: Sendable` — реалізація має бути безпечна для виклику з будь-якого актора.
- SPM-пакет, версію й Swift 6 сумісність звірити web-research перед додаванням (правило проекту).

### Privacy

- `PrivacyInfo.xcprivacy` з декларацією зібраних типів (device identifiers, product interaction).
- Жодного raw-тексту нотаток/запитів (D1 — за рекомендацією не слати текст запиту).

## Event Taxonomy (v1)

> Іменування: `snake_case`. Спільні super-props: `translation`, `distinct_id` (auto), `app_version`, `is_beta`.

### Session / engagement

| Event | Props | Коли |
|---|---|---|
| `app_opened` | — | foreground (звідси DAU/WAU, retention D1/D7/D30) |
| `study_session_summary` | `duration_s`, `verses_read`, `study_tool_opens`, `word_nav_count`, `verse_nav_count`, `annotations_created`, `searches` | кінець сесії (background, grace ~30с) |

> `word_nav_count` / `verse_nav_count` — шеврон-навігація між словами/віршами при відкритому Bottom Sheet. Лічильники в summary (НЕ події-на-тап) — сигнал глибини без засмічення; годують MSS.

### Search behavior

| Event | Props | Коли |
|---|---|---|
| `search_committed` | `results_count`, `had_zero_results`, `translation`, `testament_filter` | коміт пошуку (tap підказки / Search CTA) |
| `search_result_opened` | `results_count`, `position` | тап результату → відкриття вірша |

> D1: **без** `query` raw-тексту. Якщо D1 зміниться — додається `query`.

### Feature adoption

| Event | Props | Коли |
|---|---|---|
| `original_opened` | `book_id` | відкрито Original/Strong's на слові (вхід у word study) |
| `study_tab_switched` | `tab` (verse\|word) | перемикання вкладки Verse↔Word у Bottom Sheet |
| `strongs_viewed` | `strongs_id` | перегляд лексикону Strong's |
| `commentary_opened` | `author` | відкрито коментар (Calvin/Henry/Spurgeon/Owen) |
| `crossref_opened` | — | відкрито cross-references / parallel passages |
| `word_usage_opened` | — | відкрито Word Usage / конкорданс |
| `translation_switched` | `from`, `to` | зміна перекладу |
| `note_created` | — | створено нотатку |
| `highlight_created` | `color` | створено гайлайт |
| `bookmark_created` | — | створено закладку |

> Adoption = distinct-users події ÷ активні за вікно. Рахується **у Mixpanel**.
> Шеврон-навігація між словами/віршами — не окрема adoption-подія, а лічильники в `study_session_summary` (див. вище).

### Відкладено (інструментувати, коли фічу доробимо в беті — зріз 4)

| Event | Чому відкладено |
|---|---|
| `verse_card_added` | картки віршів ще не реалізовано |
| `word_card_added` | картки слів ще не реалізовано |
| `folder_created` / `tag_added` | папки/теги: кнопка є, але **нефункціональний стаб** — інструментувати зламану кнопку немає сенсу |

## Meaningful Study Session (MSS) — рахується в Mixpanel

Додаток шле лише `study_session_summary` (лічильники). MSS — **Custom Event** у Mixpanel:

```
MSS = study_session_summary WHERE
      duration_s >= 120
  AND verses_read >= 2
  AND (study_tool_opens >= 1 OR word_nav_count >= 1 OR verse_nav_count >= 1 OR annotations_created >= 1)
```

- Поріг **тюнабельний у Mixpanel** без релізу.
- `study_tool_opens` інкрементується додатком на кожен `original_opened` / `study_tab_switched` / `strongs_viewed` / `commentary_opened` / `crossref_opened` / `word_usage_opened` у межах сесії; шеврон-навігація йде окремими лічильниками `word_nav_count` / `verse_nav_count` — теж сигнал глибини.
- North Star дашборд: % сесій що MSS; % WAU з ≥1 MSS/тиждень.
- Adoption-флоу — **воронки** (open → search → open verse → annotate), окремо від MSS.

## Acceptance Criteria

- [ ] У бета-білді події летять у Mixpanel; у release-білді (`NoopAnalytics`) — жодного мережевого виклику.
- [ ] Тумблер «Share anonymous usage» (default ON) керує init SDK; вимкнено → жодних подій, без рестарту.
- [ ] Одноразова нижня картка показується рівно раз; «Не зараз» → тумблер OFF; є тумблер+опис у Settings.
- [ ] distinct_id = PreAuthIdentity; нема PII; нема raw-тексту запиту (D1).
- [ ] `study_session_summary` шлеться рівно раз на сесію з коректними лічильниками.
- [ ] `PrivacyInfo.xcprivacy` присутній; token не в git.
- [ ] Build проходить; Swift 6 strict concurrency без помилок.
- [ ] У Mixpanel можна зібрати: retention D1/D7/D30, топ/zero-result пошук, adoption кожної фічі, MSS-дашборд.

## Open Items / Dependencies

- **D1/D2/D3** з [[PDR-Analytics-Mixpanel]] — підпис перед реалізацією.
- Mixpanel Swift SDK: версія + Swift 6 перевірка (web-research).
- Залежить від PreAuthIdentity API ([[ADR-012-unified-user-data-layer]]).
- Відкладені події (`verse_card_added`, `word_card_added`, `folder_created`, `tag_added`) — інструментувати разом із фічею карток/папок Нотаток (зріз 4, у беті).
- **v1.5 (за потреби):** перехід `MixpanelAnalytics` → `NoopAnalytics`, **якщо в цьому буде сенс** (напр. наближення до Free-cap). Це **просто свап реалізації** через наявну абстракцію — окремий remote kill-switch НЕ потрібен. Free-план не білить і щомісяця знову дає 1M, тож зараз нічого спеціального не робимо (абстракція вже це дозволяє).

## Implementation Slices (черговість; виконує Opus інтерактивно на `work`, не автономний Fable)

1. **Каркас:** `AnalyticsService` + `MixpanelAnalytics` + `NoopAnalytics`, гейтинг, distinct_id, картка+тумблер згоди, `PrivacyInfo.xcprivacy`, token через xcconfig. (Acceptance: події летять у бета, no-op у release.)
2. **Engagement + Search:** `app_opened`, `study_session_summary` (вкл. `word_nav_count`/`verse_nav_count`), `search_committed`, `search_result_opened`.
3. **Feature adoption:** події по існуючих фічах: `original_opened`, `study_tab_switched`, `strongs_viewed`, `commentary_opened`, `crossref_opened`, `word_usage_opened`, `translation_switched`, анотації.
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

## Related

[[PDR-Analytics-Mixpanel]] · [[PDR-Auth-Strategy]] · [[ADR-012-unified-user-data-layer]] · [[ADR-005-highlights-bookmarks-notes]]
