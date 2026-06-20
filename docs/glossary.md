# Glossary — SourceBible terms

Єдине джерело правди для термінів, щоб не плутатись (особливо у word-study, де BibleHub «NASB Lexicon» показує все word-by-word і змішує поняття). Якщо термін у коді/доках розходиться з цим — правити під глосарій.

---

## Word-study поверхні (часто плутаються)

Це **різні** екрани/дії. Один word-study прохід зазвичай: відкрив **original** → тапнув слово → побачив **lexicon** → перейшов у **concordance**.

| Термін | Що це | View / файл | User-facing лейбл | Analytics feature |
|---|---|---|---|---|
| **Original** (оригінал) | Список оригінальних слів вірша (іврит/грека, Macula-токени) — **перелік слів**, не визначення | `OriginalWordsView` (пілюля `.original` у Verse-табі) | «Оригінал» (`verse.pill.original`) | `original` |
| **Lexicon** (лексикон) | Визначення Strong's **конкретного слова** (значення, морфологія, transliteration) | `WordMeaningView` (суб-вкладка `.meaning` Word-таба) | «Значення» (`tabMeaning`) | `lexicon` |
| **Concordance** (конкорданс) | Де ще це слово **вживається** по всій Біблії (per-book breakdown) | `ConcordanceView` (суб-вкладка `.usage`; раніше `WordUsageView`) | «Вживання» (`tabUsage`) | `concordance` |
| **Commentary** (коментар) | Богословський коментар до вірша (Calvin / Henry / Spurgeon / Owen) | `CommentaryDetailView` | «Коментарі» | `commentary` |
| **Cross-references** | Перехресні посилання на інші вірші | `CrossRefsView` (пілюля `.crossRefs`) | «Перехресні» | `crossReference` |
| **Parallel translations** | Той самий вірш у кількох перекладах (parallel passages) | `TranslationsView` (пілюля `.translations`) | «Переклади» | `parallelTranslation` |

> ⚠️ **Original ≠ Lexicon ≠ Concordance.** «Original» — це список слів; «Lexicon» — визначення одного слова; «Concordance» — його вживання. BibleHub «NASB Lexicon» подає це одним word-by-word списком — звідси історична плутанина.

**Suтіжні поняття:**
- **Strong's** — система нумерації слів оригіналу (H#### іврит, G#### грека) + лексикон визначень.
- **Macula** — джерело токенізації оригіналу (іврит/грека), MT-нумерація.
- **Word tab / Verse tab** — дві вкладки Bottom Sheet: Verse (пілюлі: cross-refs, translations, original, commentaries) і Word (суб-вкладки: meaning, usage).
- **Chevron nav** — стрілки ‹ › для переходу між словами (`word_nav_count`) або віршами (`verse_nav_count`) у відкритому Sheet.

---

## Аналітика (таксономія — [[ADR-022-analytics-event-collection-strategy]])

| Термін | Значення |
|---|---|
| **`AnalyticsFeature`** | Enum із 6 word-study/study фіч (`original`, `lexicon`, `concordance`, `commentary`, `crossReference`, `parallelTranslation`). Додавання інструменту = новий case (adoption-подія + лічильник зʼявляються самі). |
| **`feature_adopted_<feature>`** | Дискретна подія «вперше за сесію скористався фічею». Раз/сесію. Дає adoption-воронку. |
| **`study_session_summary`** | Одна подія в кінці сесії з усіма лічильниками глибини (`*_views_count`, `word_nav_count`, `verse_nav_count`, `verses_opened`, `searches_count`, `annotations_created`, `duration_s`). |
| **`<feature>_views_count`** | Скільки разів за сесію переглянули фічу (напр. `lexicon_views_count`). Через `SessionTracker.recordFeatureUse(_:)`. |
| **`app_opened`** | Foreground (cold start + повернення з фону). DAU/WAU/retention. |
| **`search_committed` / `search_result_opened`** | Пошук закомічено / тапнуто результат. Дискретні (низький обсяг). Без raw-тексту запиту (D1). |
| **`translation_switched` / `note_created` / `highlight_created` / `bookmark_created`** | Дискретні низькочастотні дії. Анотації також рахуються агрегатом `annotations_created`. |
| **MSS — Meaningful Study Session** | North Star. Custom Event у Mixpanel над `study_session_summary` (провізорно: `duration_s >= 60` AND depth-сигнал >= 1). Тюниться без релізу. |
| **Adoption funnel** | `feature_adopted_original` → `_lexicon` → `_concordance` — де у word-study відвалюються. |

---

## Сесія та згода

| Термін | Значення |
|---|---|
| **Session (сесія)** | «Сидіння» = безперервна взаємодія з апкою. Старт на foreground, кінець на background + grace. НЕ відкриття-закриття Sheet. |
| **Grace (~30с)** | Коротке повернення з фону (<30с) не плодить нову сесію / дубль summary. Реалізовано через `beginBackgroundTask` (інакше iOS присипляє апку до flush). |
| **`SessionTracker`** | `@MainActor`-компонент: тримає лічильники сесії + adoption-Set, шле `study_session_summary` на flush. |
| **Consent (згода)** | Тумблер `analyticsEnabled`. **Бета/dev** — default ON (opt-out, D2). **Прод** — default OFF (opt-in, D4). Дефолт обирається за `isTestFlight`. |
| **Lazy init** | `MixpanelAnalytics` НЕ вантажить SDK до згоди — `enable()` після ON, `disable()` (optOut) на OFF. Нуль мережі до згоди (D4). |

---

## Mixpanel проекти (PDR D5)

| Проект | Білд | Токен (`Config/Secrets.xcconfig`) | Вибір |
|---|---|---|---|
| **Dev** | DEBUG (симулятор/дев) | `MIXPANEL_DEV_TOKEN` | `#if DEBUG` |
| **Beta** | TestFlight (Release + isTestFlight) | `MIXPANEL_TOKEN` | рантайм `isTestFlight` |
| **Prod** | App Store (Release + !isTestFlight) | `MIXPANEL_PROD_TOKEN` | рантайм `!isTestFlight` |

> Розділені, щоб бета-тестери не отруювали прод-метрики. `is_beta` super-prop — додатковий запобіжник.

---

## Related
[[ADR-022-analytics-event-collection-strategy]] · `spec-analytics-mixpanel` · [[PDR-Analytics-Mixpanel]] · [[ADR-012-unified-user-data-layer]]
