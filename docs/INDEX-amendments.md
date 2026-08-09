# INDEX — повні записи

Довгі історії амендментів, винесені з `INDEX.md` 2026-08-07 під час lint-у пам'яті.

**Навіщо розділення.** `INDEX.md` за протоколом `WIKI.md` читається на старті КОЖНОГО
чату й має бути картою — рядок на документ. Він виріс до 68 KB, і окремі рядкиважили
1.5–2.4 KB кожен: карта коштувала як кілька документів разом, тобто переставала окупати
своє призначення. Тут — той самий текст без жодної втрати, лише перенесений.

⛔ Це **не** джерело правди. Джерело — сам ADR/spec/PDR. Цей файл існує, щоб `INDEX.md`
лишався картою; статус документа береться з його шапки, а `scripts/lint_docs.py`
звіряє шапку з рядком INDEX і падає ненульовим кодом на розходженні.

---

<a id="adr-006-localization-translation-provider"></a>

## `ADR-006-localization-translation-provider.md` — Localization: TranslationProvider & Language Switch

**Status:** Accepted

MorphologyDecoder emits MorphKey constants; BundleTranslationProvider for MVP; Bundle.main swizzled via object_setClass for instant switch; upgrade path → DB → Remote | **Amendment 2026-08-03:** `AppLanguage.resolved` / `.narrowed(_:)` — одна резолюція мови замість п'яти різних дефолтів. `appLanguage` пишеться лише пікером, тож до першого дотику до налаштувань ключа немає: свізл бандла брав мову системи (укр ✅), а `@AppStorage(...) = "en"` у About/Menu/Language/Privacy і `nil != "uk"` у `BibleBookNames` давали англійську → **змішаний за мовою перший запуск**. ⛔ `?? default` ловить лише nil: порожній/невалідний рядок проходив, і `.onChange` перевстановлював англійський бандл поверх правильного з `init`.

[← назад до INDEX](INDEX.md)

---

<a id="adr-008-search-architecture"></a>

## `ADR-008-search-architecture.md` — Search Architecture MVP

**Status:** Accepted (amended 2026-06-11, 2026-07-07)

FTS5 text search; predictive via search_terms table; vector search deferred to V1.5 (ONNX + sqlite-vec). Amend 2026-06-11: suggestions rendered inline (Apple Music pattern), `.searchSuggestions` dropped. Amend 2026-07-07: LIMIT 150 → infinite scroll (SQL LIMIT/OFFSET + COUNT, rowid tiebreak); YouVersion-style chip filters Translation/Testament/Book як sheets, фільтри в SQL; translation-фільтр локальний (дефолт = рідер); Strong's/lemma/morph у search-барі ВИКЛЮЧЕНО — доступ через word tap (ADR-013/016). **Amend 2026-08-06 (bug-035):** FTS індексує нову колонку `verse.text_clean`, а НЕ сирий `verse.text` — `unicode61` різав `<S>6757</S>` на токени `S`/`6757`/`S` між словами, і фразовий запит (`makeFTSQuery` обгортає ввід у лапки) не знаходив нічого на 2+ словах, тоді як одне слово працювало; ріже фразу будь-який тег, не лише `<S>`. Побічно: 25.3% термів `search_terms` були числа Стронга. Додано `verify_search_index()` (двослівні якорі + контрольні фрази на нуль) і `scripts/tests/test_search_index.py`. NEAR() відхилено — не тримає порядок слів. ⛔ Інваріант: `text` = парсер, `text_clean` = єдине, що йде у FTS. **Amend 2026-08-07 (інтерв'ю з користувачем):** (1) видача — **канонічний порядок книга→глава→вірш**, BM25 прибрано (у корпусі одного жанру «релевантність» вироджується в довжину вірша; на «Душа» видача йшла Пр.→Єз.→3М.→Пр.). Порядок книг **per-translation** через `COALESCE(book_name.sort_order, book.num-1)`, бо в RST 21 книга інакше (соборні послання перед Павловими); `LEFT JOIN`, не `INNER` — inner ховав би книги без рядка `book_name`. Побічно ШВИДШЕ: `"the"*` KJV 63.7→47.4 ms, OFFSET 2000 83.7→**33.5** ms (BM25 треба порахувати, sort_order — прочитати); rowid-тайбрейк більше не потрібен. (2) `search_terms` → **`(term, lang)` по МОВІ, не по перекладу** — борг «per-translation (крок B)» закрито НЕ на його користь: 3 англ. переклади дали б 3 однакові словники, а каша між мовами, не перекладами. Симптом був `се*` → `себе, себя, сердце, серед, сего, серце` + підказки в НУЛЬ результатів (терм із RST, пошук в UBIO). Заміряно: 61 776 рядків (+1 602 до спільної; per-translation дав би 74 329), +232 KB, короткі префікси до **3× швидші** (`а` 0.335→0.113 ms). Масштабування: нова мова (de/es) розділяється сама через `translation.language`. ru∩uk=4.7% — дублювання дешевше за хибну підказку. ⛔ `него` НЕ якір розділення (є в обох мовах)

[← назад до INDEX](INDEX.md)

---

<a id="adr-021-study-mode-scroll-positioning"></a>

## `ADR-021-study-mode-scroll-positioning.md` — Study Mode — Verse Pinning & Sheet Sizing

**Status:** Accepted (covers-off + covers-on done)

Decision trail for Study-Mode scroll: atomic `StudyPinView` (verse's own background reads frame+offset together — no cross-layer skew) replaces scrollTo; NO top inset (content above gives headroom) — kills the entry jerk AND covers-on rubber band; `toolbarGap`(0) decoupled from `sheetGap`(8, kept <12 so next verse hides behind sheet); `detentTopOffset`(16) empirical (SE-validation pending); `StudyScrollClamper` fixes last-verse exit gap; default interactive dismiss restored; dual sheet-sizing (SwiftUI detent + UIKit applier) confirmed complementary, kept. Lists hard "don't regress" rules

[← назад до INDEX](INDEX.md)

---

<a id="adr-022-analytics-event-collection-strategy"></a>

## `ADR-022-analytics-event-collection-strategy.md` — Analytics Event-Collection Strategy

**Status:** Accepted

Adoption = `feature_adopted_<feature>` once per session, **6 granular features 1:1 with UI surfaces** (original/lexicon/concordance/commentary/cross_reference/parallel_translation — original≠lexicon≠concordance, see glossary); first three form word-study funnel; depth = counters in `study_session_summary` (`<feature>_views_count`, `word_nav_count`, etc.) — NOT a discrete event per tap, to stay under free-tier (1M/mo); search/annotations/translation_switched kept discrete; `SessionTracker.recordFeatureUse(_:)` owns adoption + counters; loses per-view timestamps (acceptable). Supersedes the per-tap Slice 3 draft

[← назад до INDEX](INDEX.md)

---

<a id="adr-024-cross-reference-back-stack"></a>

## `ADR-024-cross-reference-back-stack.md` — Cross-Reference Back-Stack Navigation

**Status:** **Accepted** (реалізовано; `crossRefBackStack` у ReaderViewModel)

Cross-ref переходи у Study Mode тепер мають back-стек (`crossRefBackStack` у ReaderViewModel); leading toolbar морфиться між 3 станами — пікер/«Закрити»(стек порожній)/«‹ Назад»(крок по cross-ref історії); `‹ ›` чеврони (intra-chapter) стек НЕ чіпають; cross-ref тап обходить router (in-Reader пряма навігація); push у success-гілці `navigateToVerse(source:)`; свайп-вниз закриває + чистить стек. Амендить spec-study-mode-redesign R4/R7. Без БД/схеми

[← назад до INDEX](INDEX.md)

---

<a id="adr-023-status-bar-style-control"></a>

## `ADR-023-status-bar-style-control.md` — Status Bar Style Control in SwiftUI App Lifecycle

**Status:** Reverted (backed out 2026-06-21)

Білий статус-бар на обкладинках. SwiftUI App lifecycle не має API для статус-бара. Поточно: підміна `window.rootViewController` контейнером — **зламало `.preferredColorScheme`** (dark mode), бо HC перестав бути коренем; довелось перебрати appearance на `overrideUserInterfaceStyle`. Research: підклас/підміна HC ламає lifecycle; стандарт — **swizzle `childForStatusBarStyle`** (HC лишається коренем). Рекомендація: **Option B (swizzle)** — нативний dark mode, safe на iPad multi-window; Option A прийнятний тимчасово з hardening. Двовходова модель статус-бара ортогональна. (NB: visionOS не таргет — прибрати `7` з device family)

[← назад до INDEX](INDEX.md)

---

<a id="adr-026-reader-chapter-paging-tabview"></a>

## `ADR-026-reader-chapter-paging-tabview.md` — Reader Chapter Paging (TabView → UIPageViewController)

**Status:** **IMPLEMENTED 2026-07-10** (iOS 26; iOS 18 = legacy fallback до Phase B)

Native slide on chevron AND **full-surface** swipe (closes ux-001; PDR-Page-Turn-Gesture-Zone gate passed on device). **TabView(.page) tried & REJECTED empirically**: clips pages to safe area → вбиває cover bleed (ADR-017) і Liquid Glass scroll-edge блюр тулбара; `.scrollDisabled` не діє на page-свайп; sliding window морозив пейджер. Shipped: `UIPageViewController(.scroll)` (`ChapterPagerView`) + `UIHostingController` сторінки з РЕАЛЬНИМ `ChapterScrollContent`; `setContentScrollView(_:for:.top)` на кожному settle = блюр як у базлайні; commit у `didFinishAnimating` + deferred `loadChapter` (hard rule); `versesForPage` non-published prefetch; `willTransitionTo` reset → розділ завжди відкривається зверху (кешований сусід UIPageVC зберігав offset — device-кач на Ps 119); Study lock через `isScrollEnabled`. ADR-021/014/017/resume — verified. Spike B (animated swap) rejected. Archive — на користувачі.

[← назад до INDEX](INDEX.md)

---

<a id="adr-029-ohienko-translation"></a>

## `ADR-029-ohienko-translation.md` — Інтеграція перекладу Огієнка (UBIO'88)

**Status:** **Accepted** (ліцензійний блокер знято 2026-07-31)

✅ **Ліцензія підтверджена 2026-07-31: CC BY-SA 3.0** за прямим дозволом УБТ/UBS на видання Огієнка **до 1991**, включно з ювілейним **1988** (= наш UBIO'88); джерело — blog.wikimedia.org.ua, 2013-11-27. Попередній висновок (2026-07-15) «НЕ суспільне надбання → не шипити» був правильний щодо PD (~2042/2058) і **хибний щодо права на бандл**: тут не PD, а ліцензійний грант — перевірка шукала суспільне надбання замість ліцензії. `LICENSED`-прапорець знято, UBIO шипиться публічно нарівні з KJV/ASV/RST. Умови: **BY** (атрибуція в Menu → About — додано), **SA** (успадковують лише похідні від самого тексту; наші тизери/підводки — окремий твір), **межа «до 1991»** (пізніші редакції УБТ НЕ покриті). Далі — оригінальний план: Український Огієнко → **бандл у ядро** `sourcebible.db` як першокласний переклад (не окремий OTA-модуль: переклад тісно зв'язаний з verse_org/parallel/xref/FTS/book_name — на відміну від коментарів ADR-027). Виміряно з модуля: `strong_numbers=false` (0 `<S>` → **O2 неможливий**), `russian_numbering=true`, 66 книг (27 НЗ), рідні укр. назви книг (живлять ADR-018). Версифікація: 856/930 глав синодальні (rso), 71 — org(Macula)-identity, 3 NONE (PSA 114→116, PSA 141, JER 5). Несподіванка: розбіжні глави лягають на **org чистіше, ніж англійські переклади**. Верифікація без Strong's = **перенесення доведеного мапінгу RST** (Огієнко≈RST синодальні; де структура глав збігається — мапінг має бути ідентичним O2-доведеному RST, розбіжність=прапорець) + 3 ручні override. ZIP розщеплюється: текст→ядро, `.commentaries`→ADR-027. Спирається на ADR-028 (має злитись першим). НЗ-версифікація (Macula Greek) — поза цим ADR

[← назад до INDEX](INDEX.md)

---

<a id="adr-030-strongs-root-concordance"></a>

## `ADR-030-strongs-root-concordance.md` — Кореневий конкорданс через Strong's-деривацію

**Status:** **Accepted**

Групування за коренем не кодує жодне джерело (strongs/word/TBESH/BSB/Macula — перевірено 2026-07-20); Macula coredomain = за значенням, не коренем (зливає r-ch-m+ch-n-n у CORE:036, розсипається на nasa H5375). Рішення: імпорт OpenScriptures Strong's derivation → `root_id` у `strongs` → картка слова рівень «цей корінь» поряд із «це слово». Розширює ADR-019, живить ADR-013/016. Acceptance: r-ch-m→H7355, ch-n-n→H2603, aman→H539, hesed→H2616

[← назад до INDEX](INDEX.md)

---

<a id="adr-028-versification"></a>

## `ADR-028-versification.md` — Версифікація — курований довідник замість евристики

**Status:** **Accepted** — фази 1 і 2 реалізовані (заміряно 2026-08-07: `verse_org` = 155 621, `verse_map` видалена)

**Заміряно: 4 152 з 7 292 рядків `verse_map` хибні (57%)** — «Оригінал» показує іврит чужого вірша. RST Псалтир зламаний майже цілком (2 508 віршів: синод. Пс N = євр. N+1, зсув на ГЛАВУ). KJV 1 Chr 6:5 показує MT 6:36 замість 5:31. Три дефекти: `align_chapter()` шукає лише в межах глави; `best_overlap = -1` → будь-який вірш з перетином 0 б'є identity (звідси `EXO 8:8 → вірш 25`); `findBestMaculaVerse() -> Int` — уся вертикаль (схема→DatabaseService→ViewModel) замкнена на одну главу, крос-главний мапінг недосяжний. Рішення: `verse_map` → **`verse_org`** (тотальна, з `org_chapter`, composite PK = N:M для злитих віршів, ~93k рядків); мапінг стає build-time даними, `findBestMaculaVerse` (усі 3 рівні евристики) **видаляється**. **Три незалежні оракули**: O1 декларативний (UBS `eng/rso.json`, MIT) пропонує → O2 емпіричний (теги Strong's у `KJV+/ASV+/NASB+/RST+` ↔ Macula) перевіряє → O3 структурний (`maxVerses` = масоретський підрахунок як assert). Розбіжність O1≠O2 = **білд падає**, не «беремо кращий». Недоведене (`verified=0`) → «Оригінал» порожній, а не сусідній вірш. Фундамент чистий: Macula=ORG 929/929, KJV/ASV/NASB=ENG 929/929; RST=RSO 923/929 → 6 глав через явний `overrides.tsv` (DAN 3 = второканон). Ризик: довідник UBS сам не валідований (README ubsicap) — тому O1 без O2 не приймається. Скасовує `build_verse_map.py`/`align_chapter()`. **Розширено на весь канон (2026-07-15):** `verse_org` testament-agnostic, НЗ→Macula Greek (`grc`, уже в `word`); НЗ дешевий — Macula Greek=org(GNT) точно (MRK 16:99=коротше закінчення, інертне), різниця перекладів лише 6 глав (ACT 19, ROM 14/16, 2CO 11/13, REV 12), розвʼязуються тим же empirical+O2 з G-Strong's

[← назад до INDEX](INDEX.md)

---

<a id="adr-027-modular-commentary-modules"></a>

## `ADR-027-modular-commentary-modules.md` — Модульні commentary-модулі з OTA-оновленням

**Status:** Proposed

Винести коментарі з моноліту `sourcebible.db` в окремі read-only SQLite-модулі (1 файл = твір), оновлювані OTA незалежно від релізу App Store; одиниця оновлення = книга; ядро (Macula/verse/strongs) лишається монолітом. Привід: діри в джерелах (Calvin Isaiah 49–66 нема в SWORD; Genesis/John у MyBible) + потреба швидкого MT-циклу «випусти→вичитуй». Інваріанти: **майстер (git-текст+provenance) ≠ артефакт (.db)**; версифікація нормалізується до канонічної (Macula/MT) на збірці; **стабільні природні ключі, не rowid**; user-data (ADR-012) поза замінним модулем; атомарна заміна temp→verify(checksum)→swap→rollback; provenance+`translation_status`(source/raw-mt/reviewed/final) на розділ; маніфест на статичному сховищі (без сервера). Відкрите: власна схема vs MyBible-сумісна (реком. власна+імпортер); FTS5 (ADR-008) через `ATTACH` — спайк. Пілот на Кальвіні (закрити Ісаю 49–66). Продовжує ADR-012, паралель ADR-006

[← назад до INDEX](INDEX.md)

---

<a id="adr-031-notifications"></a>

## `ADR-031-notifications.md` — Локальні нотіфікації (retention, local-first)

**Status:** **Proposed** (amended 2026-07-31)

Local-first push; APNs → Фаза 2 (з ADR-027), зараз лише `UNUserNotificationCenter`. Два канали: **A «Продовжити дослідження»** (event-driven, ядро=word-study, fallback позиція→нотатка/`crossRefBackStack`; **нескінченний двигун steady-state retention** — власна робота, без контент-конвеєра) + **B курований вірш** (пул `encourage`/`deep_dive` — deep_dive=різночитання перекладу Іс7:14/Пс22:16/Флп2:6, deep-link в оригінал/паралель → демонструє тулу + feature-adoption ADR-022). **«Вірш дня» + стрік ВІДКИНУТО** (off-brand). **Scheduling model = recompute-on-transition:** код при доставці не виконується → контент запікається наперед, весь план перераховується на кожному foreground/background, **rolling horizon дискретних реквестів** (`repeats:false`; повторюваний тригер ЗАБОРОНЕНО для B — ротація; поважає ліміт 64 pending). **Каденс B = конфіг** (не хардкод), front-load у перші ~30д (слоти D4/D11/D18/D25) → таперинг ~щомісяця; no-repeat поки пул не вичерпано; сід ~6–8 deep_dive (преміум) + ~10–15 encourage (дешевий бекбон); ростити мінорними апдейтами. **Permission = гібрид:** provisional D0 (тихо) → full soft-ask на 1-му value-моменті в застосунку (не лише після D4; тихі дотики інакше не видно). **Lifecycle D0–D30** під D1/D7/D30 + frequency governor (≤1/3дні, подієве б'є планове, пропуск якщо активний, quiet hours). Дані: пул = **bundled JSON** (`notification_verses.json`, НЕ в БД, teaser локалізований ІНЛАЙН — контент, не chrome; OTA-ready); снапшот нитки+toggles = **AppPreferences** (ADR-025, НЕ GRDB). Аналітика: `notification_scheduled`/`_opened` consent-gated; **`_delivered` НЕ вимірюється** (нема колбека для local). iOS18 без гейтів; `.active` (не timeSensitive); deep-link через `AppNavigationRouter` (ADR-005) + cold-start pending-route. impl-reference: `~/.agents/skills/push-notifications`. Наступне: `spec-notifications.md`. ⛔ верифікація: build + sim launch-arg

[← назад до INDEX](INDEX.md)

---

<a id="adr-032-haptic-feedback-map"></a>

## `ADR-032-haptic-feedback-map.md` — Карта хаптики — семантичні методи замість сил вібрації

**Status:** **Accepted** (2026-08-02)

Один тип `Haptics` (`Views/Components/`), три семантичні методи: `selectionChanged()` (selection — тап по слову, чеврони вірш/слово, зняття highlight), `lightTransition()` (impact `.light` — тап по вірші → Study Mode, перехресне посилання **і назад по стеку** ADR-024, закладка), `meaningfulAction()` (impact `.medium` — постановка highlight). Градація за **слідом дії** (рух по елементах → створення даних), не за «важливістю екрана» (HIG). Крос-реф навмисно важчий за чеврон: чеврон = крок на сусідній вірш, перехресне = стрибок в іншу книгу. `VerseNavSource.fresh` без хаптики — спільний лійок `AppNavigationRouter`, куди входять **не-дотикові** входи (cold-start deep-link, нотіфікація ADR-031): хаптика там вібрувала б на старті. Звідси правило: хаптика на call-site, не на спільному шляху. **Побічний результат: перехід із «Вживання» на вірш-приклад ПРИБРАНО** (`ConcordanceView`) — не мав афордансу (ні шеврона, ні press-стану, на відміну від `CrossRefsView`), стирав back-stack (ішов через `.fresh`), і не відповідав очікуванню від рядка («покажи всі 5 входжень», а не «стрибни на один»). Заміна — stacked sheet зі списком і фільтрами в стилі Пошуку, `spec-word-usage-redesign.md` Amendment 2026-08-02. ⛔ **БЕЗ хаптики: зміна глави** (гортають постійно → шум) **і перемикання перекладу** (є свій фідбек: закриття шіта + перемальований текст). Окремий перемикач у Налаштуваннях НЕ потрібен — генератори поважають системну настройку. До зміни хаптика була в 1 рядку (`VerseTextView`, `.medium` на найчастішу дію). 11 call-site'ів. ⛔ верифікація: build + sim (сама вібрація — лише на пристрої/TestFlight)

[← назад до INDEX](INDEX.md)

---

<a id="adr-034-markup-stripping-single-source"></a>

## `ADR-034-markup-stripping-single-source.md` — Зняття розмітки вірша — одне джерело правди

**Status:** **Accepted** (реалізовано 2026-08-07; кроки 6–7 відкриті)

Правила `<S>/<f>/<n>/<i>` реалізовані ТРИЧІ: `build_db.py::_search_text` (build-time → `text_clean`), `String+BibleMarkupCore` (runtime, 4 поверхні), `VerseParser` (токенайзер, рідер). Заміряно: вузький regex `<S>\d+[a-z]?</S>` не брав 834 багатономерні теги ASV/NASB і 281 зі СЛОВОМ (`<S>8147, Joshua82</S>`) → **261 вірш** просочував слово в концорданс/крос-рефи/паралельні/сніпет, 761 — кому з цифрами, 1 330 — маркер `[2]` (у `<f>` не було правила ніде). Рідер був ПРАВИЛЬНИЙ весь час (`VerseParser` буферизує вміст) — тому дефект і прожив місяці. Дисципліна коментарів провалилась двічі за день: «the two must agree» стояв в обох копіях, і той самий коміт, що звів копії в одну, розвів мови на 985 віршах. Перевірити ніде: **тестового таргета в проєкті немає**, лише `application`. **Рішення (Option C):** після вирівнювання пунктуації розходження py↔swift = **3 з 155 621**, тобто `text_clean` УЖЕ є display-текстом → 4 call-site читають `v.text_clean`, рантайм-стрипер видаляється, **приріст бази 0 MB** (нова колонка `text_display` відхилена: +23.7 MB за дублікат наявної). Інваріант «однаковий вивід» скасовано як хибний (index-нормалізація ≠ показ) → «плоский текст для показу має ОДНЕ джерело, рантайм розмітку не знімає». Голден-фікстура + Swift-таргет (Option A) — ПІСЛЯ, і звужено до «той самий набір слів», бо `VerseParser` навмисно розходиться (він показує † там, де колонка викидає `<f>`). ⛔ 2 з 3 залишкових розходжень — баг порядку: `S>\d*[a-z]?` перед загальним `<[^>]+>` робить із `</S>` невиліковне `</`

[← назад до INDEX](INDEX.md)

---

<a id="adr-033-lexicon-stem-ranking"></a>

## `ADR-033-lexicon-stem-ranking.md` — Лексикон: порода цієї форми, а не діапазон кореня

**Status:** **Accepted** (2026-08-03)

BDB-стаття івритського дієслова двошарова: `1)` = склеєний заголовок кореня, `1a)/1b)` = породи. Рендерились у порядку джерела, тож першим ішов заголовок. Ос. 4:6 `נִדְמוּ` (Niphal, «народ **знищено**») показував першим «to cease, cause to cease, **destroy**, perish» → читач бачить активне «destroy» і розуміє навпаки. Це **illegitimate totality transfer** (Барр): приписати формі весь діапазон кореня; наш порядок до цього підштовхував. **Рішення:** (1) злиту секцію `stemName == ""` НЕ рендерити, якщо є хоч одна порода; (2) породу з `word.morphology` підняти нагору + позначка «ця форма»; (3) звірка через **код OSHB → канонічна англ. назва**, НЕ через підпис (`MorphologyDecoder` віддає локалізовану назву — українською не збіжиться ніколи). ⛔ Інші породи НЕ прибирати й НЕ згортати — Qal→Niphal→Piel і є дериваційна логіка, заради якої відкривають оригінал. Fail-safe (лишаємо як є): немає порід / немає morphology / породи немає в BDB / рідкісна порода поза 8 кодами OSHB / грецький аутлайн Abbott-Smith. Мінус: порядок більше не збігається з друкованим BDB — свідомо. Відкрито: підпис позначки, чи потрібен заголовок «Інші породи»

[← назад до INDEX](INDEX.md)

---

<a id="plan-uk-interlinear-glosses"></a>

## `plan-uk-interlinear-glosses.md` — Український послівний підрядник + інструмент вичитки

**Status:** **Draft** (фаза 2 пайплайну)

**ПЕРЕМІРЯНО 2026-08-05: одиниця = display-слот, не токен.** `ref` у Macula = `PSA 51:7!5`, де `!5` — слот; кілька токенів = ОДНЕ слово (`VerseTabContent.displayWords`, head = останній не-енклітичний). 470 537 токенів → **305 349 слотів**; 46.4% слотів багатотокенні = 65.2% токенів. 63 487 токенних трійок проти **78 451 слотової одиниці**. Покриття 80%: **5 584** токенні трійки або **21 874** слотові. ⚠️ Старе число 8 951 НЕ відтворюється (80%=5 584, 85%=10 444, freq≥5=8 293) — розходження в підрахунку, не в даних. Важіль малих книг: Йона 457 трійок = 44.9% токенів ВЗ → пілот на Йоні. UI: правити у вірші, поширювати за одиницею; відвантаження — бета з % покриття, позначка зникає при закритті книги. Джерела за ролями: Macula = форма + `slot`, `gloss_macula` = **фраза рівня слота, порізана по токенах** (дієслово несе `she`, суфікс `conceived.me`), `gloss_display` = синтез і те, що бачить читач, `gloss` (TSV `english`) = єдина по-токенно вирівняна колонка; BSB = фразовий рівень, TBESH = діапазон, Огієнко+Громов = укр. лексика й другий свідок (обидва на рівні вірша, потрібен стемінг), NASB+/RST = сигнал. **Правило: англ. глоса дає лексичний вибір, івритська морфологія дає форму.** Пілот: 24 вірші × 8 жанрів = 398 токенів → **259 слотів → 209 одиниць** (`pilot_sample.tsv` + `pilot_sample_slots.tsv`, інваріанти з ненульовим виходом) + **золотий набір 60 слотових одиниць наосліп ДО генерації** через `data/gold_entry.html` (частота й ярус приховані, таймер міряє сек/одиницю). Перша версія набору була нестратифікована: стеля 3×8=24, решту добирала догонялка → DEU 23 + 1CH 9 з 50, tail=8; виправлено квотами + round-robin + стеля 20% на книгу + `GoldError`. Точність іде в хвіст: head 14 / mid 20 / **tail 26**. 4 автоперевірки без еталона. **Вартість перерахована:** Opus 5 = $8 батчем на 80%, $30 на все — різниця з Haiku $6, тож обирає якість; ⚠️ thinking рахується як вихід (+$273 за 500 ток./од.). **Локальна Gemma 31B розгорнута** — питання моделі закрито. Людський час — єдине незаміряне: 18–122 год розкид 6.7×. **Виправлено в конвеєрі:** стадія 4 не працювала через межу слота («Шма» показувала `God our`/`heart your`, 22 094 слоти), дужки доходили до екрана (1 386 NULL→сире + 2 503 непарні, бо Macula ріже пару між токенами) → тепер `[`/`]` = 0. **Пастка: `russian_numbering` бреше** (Огієнко ставить, Громов ні, обидва синодальні) — зсув Псалтиря вимірюється за кількістю віршів, 144/150 розвʼязано

[← назад до INDEX](INDEX.md)

---

<a id="plan-status-bar-cover-white"></a>

## `plan-status-bar-cover-white.md` — White Status Bar over Book Cover — algorithm + history

**Status:** Deferred (working code preserved)

Full code (4 files + ReaderView/ContentView hooks) for the swizzle solution that worked, the variants tried (window-root/class-swizzle/per-instance/scrim) and results, and the ONE open problem: immediate tab-switch (shared HC class + async race; Apple Music sidesteps it via per-screen UIKit VCs). Fix candidates incl. synchronous driver, correct per-instance target, or design-level scrim. Implements ADR-023. Code is here ONLY (reverted from git)

[← назад до INDEX](INDEX.md)

---

<a id="plan-semantic-search-rag"></a>

## `plan-semantic-search-rag.md` — Semantic Search + On-Device RAG

**Status:** Proposal (V1.5)

Apple-native on-device stack: `NLContextualEmbedding` (embed) + `sqlite-vec` (store) + Foundation Models (RAG generation, iOS 26 за `#available`, fallback до semantic search на iOS 18). **Амендить ADR-008** V1.5 upgrade path (свіч embedder ONNX→Apple, +додає generation шар). On-device indexing (НЕ в build_db.py). Open: corpus scope, search-only vs full RAG. ⛔ LLM не генерує лексичні визначення (trust-rule). Spike на якість ембедингів перед коммітом

[← назад до INDEX](INDEX.md)

---

<a id="spec-windowed-verse-rendering"></a>

## `spec-windowed-verse-rendering.md` — Windowed Verse Rendering (Doom-style) for Fast Verse Open

**Status:** Draft / Proposed (fallback)

Render a window `[focus−2 … focus+12]` around the navigated verse + chapter title instead of the whole chapter; present immediately, assemble the rest on sheet dismiss (scroll is locked in Study Mode). Targets ONLY "open verse fast from another chapter/book" (Ps 119 = 176 UITextViews eagerly built → slow → sheet sizes at 45% fallback). Fallback if the `setVerseHeight` `objectWillChange` hotfix (2026-06-22) is insufficient. Hard parts: pin headroom (title mitigates), prepend-without-jump, chevron window growth, StudyPin/clamper geometry re-derivation

[← назад до INDEX](INDEX.md)

---

<a id="spec-reader-resume-position"></a>

## `spec-reader-resume-position.md` — Reader Resume Position (last book/chapter/scroll)

**Status:** Draft

Persist last reading position so app reopens where user left off instead of always Genesis 1:1; `@AppStorage` keys (launchBehavior/lastReadBookId/chapter/verseAnchorId) — NOT GRDB (abstracted via `ReadingPositionStore` for later sync); anchor = top-visible verse in reading (`scrollPosition(id:)` + `scrollTargetLayout`, read-only — safe on plain `VStack` since no `scrollTargetBehavior` = no snapping) OR `selectedVerse.id` when Study Mode open; restore via `pendingRestoreAnchorId` + `proxy.scrollTo` (verified in sim: `JHN|3|16` launch-arg → opens John 3 at v16); IMPLEMENTED — builds green, capture-during-scroll pending device test; Menu «Reading» picker = Continue reading / Last bookmark (most-recently-created); decoupled from StudyPin/scrollTo to avoid regressions (ADR-021/024). **Amend 2026-07-31 (§15, implemented):** брат `LaunchBehavior` — `TranslationLaunchBehavior` (`fixed` дефолт / `lastUsed`) відповідає «який ПЕРЕКЛАД відкрити»; резолюція в `ReadingPositionStore.launchTranslationId()` (ViewModel не знає про ключі); `lastUsed` пише в `selectTranslation`, падає на `defaultTranslationId` якщо порожньо; рядок конкретного перекладу в Меню ховається в режимі `lastUsed`; Debug зелений, device-QA + Archive відкриті

[← назад до INDEX](INDEX.md)

---

<a id="plan-ios18-compat"></a>

## `plan-ios18-compat.md` — iOS 18 Compatibility Refactor — Safe Half (Fable) + Deferred Sprint

**Status:** Phase A DONE (2026-07-06) · **Phase B: target flipped 2026-07-31, QA відкрите**

Розбиває відкладений compat-спринт (ADR-001) на дві фази. **Phase A (Fable зараз):** додати відсутні `#available(iOS 26)` guard-и + iOS 18 fallback, target ЛИШАЄТЬСЯ 26.4 у фінальному diff (зворотно, без зміни поведінки на iOS 26). Техніка: тимчасово виставити target=18.0 на scratch-гілці → компілятор перелічує кожен unguarded виклик (audit-oracle) → загорнути → **реверт target→26.4**. IN-scope: view-файли з flagged API (патерн з CapsuleNavStyle/ReaderView/SearchView/ContentView). OUT: target flip, LocalizedBundle (SDK-concurrency, не availability), tuned-UI reimpl, DB, corner radius. Acceptance: 0 availability-errors на 18.0-прогоні, diff з target=26.4, Debug+**Archive** зелені, iOS 26 sim без змін. **Phase B (окремий спринт):** власне flip 26.4→18.0 + повний iOS 18 QA + реліз; entry = A змерджено та фічі заморожені. **ВИКОНАНО 2026-07-31** (гілка `ios18-target-flip`): flip = 2 рядки в `project.pbxproj`, компіляція під 18.0 чиста (0 err/0 warn — прогноз Phase A підтвердився), рантайм-запуск на iOS 18.0 sim ОК, рідер візуально цілий. Entry-умову «фічі заморожені» **свідомо порушено** (рішення Івана): target 26.4 блокував УСТАНОВКУ TestFlight-білда на iOS 18, тож решта фіч у білді коштувала нуль для цих тестерів. ⛔ Відкрито: Study Mode/paging/Menu QA на 18, SE-валідація, **Archive**, SPM min-target

[← назад до INDEX](INDEX.md)

---

<a id="fable-brief-crossref-verse-org"></a>

## `fable-brief-crossref-verse_org.md` — Fable Run-Brief — ALL verse_map consumers → verse_org (ADR-028 Phase 2)

**Status:** **Done** (виконано; заміряно 2026-08-07: `verse_map` у базі немає, `verse_org` = 155 621)

**3 SQL-споживачі verse_map** (усі биті для UBIO=0 рядків + 57% хибні): `loadConcordance`, `loadBookUsageGroups` (UBIO Псалми Usage → англ. KJV fallback), `loadCrossReferences`/`convertVerse` (чужий вірш+«Text unavailable»). Мігрувати ВСІ на reverse `verse_org` (idx_verse_org_rev), тоді DROP. Раніше: мігрувати крос-рефи з `verse_map` (57% хибний → крос-рефи теж брешуть у зсунутих главах) на `verse_org`, тоді DROP verse_map/convertVerse/build_verse_map.py. Кодує поточний механізм (KJV-pivot, vm_x/vm_t JOIN, v_fb fallback) + design hint (verse_org крос-глава/N:M ламає JOIN-припущення → резолвити в Swift через forward+reverse verse_org, idx_verse_org_rev). Scope ALLOW/DENY, acceptance (on-device QA: RST Пс 50/1Хр 6/Дан 6/Іс 64 + регресія на незсунутих), огорожа. DENY: Original tab/verse_org схема (фаза 1, заморожено)

[← назад до INDEX](INDEX.md)

---

<a id="fable-brief-adr026-paging"></a>

## `fable-brief-adr026-paging.md` — Fable Run-Brief — Reader Chapter Paging (ADR-026 Phase 2)

**Status:** **Done** (прогін завершено, ADR-026 IMPLEMENTED 2026-07-10)

Autonomous brief for `TabView(.page)` chapter paging. ALLOW: reader container in `ReaderView.swift`, selection binding, chevron+full-surface swipe, current±1 prefetch, retire `EdgeSwipeNavigator`. DENY: reimplement chapter view, Study-Mode logic (ADR-021), DB, ADR-016/024, analytics. Hard rules: page REAL view (no rewrite), no `loadChapter()` during transition, iOS 26 `#available`+18 fallback, Swift 6 clean. Acceptance incl. device gesture-check → rollback to edge-only per PDR if real clash; Archive green

[← назад до INDEX](INDEX.md)

---

<a id="spec-nt-lemma-form-clickability"></a>

## `spec-nt-lemma-form-clickability.md` — NT Greek lemma-vs-form — word clickability gap

**Status:** **Deferred**

НЗ: Macula тегує ЛЕМУ (σύ G4771), переклади ФОРМУ (ὑμῖν G5213) → займенники/частки перекладу не мапляться на Macula за номером → не-клікабельні в «Оригіналі». Виявлено при ADR-028 O2. **Найпевніше НЕ варто чіпати:** не показує хибного, зачіпає майже лише займенники (частки й так не-клікабельні за ADR-016), низька цінність тап-цілі, не нова й не наша. Тригери повернення: тестери просять тапати займенники / НЗ-word-study стає першокласним / вимір показав страждають ЗМІСТОВНІ слова. Фікс (якщо треба): грецька таблиця форма→лема через наявний `nasbExtendedOverride`, авто-виводиться з Macula. Перший крок — виміряти масштаб

[← назад до INDEX](INDEX.md)

---

<a id="spec-analytics-mixpanel"></a>

## `spec-analytics-mixpanel.md` — Analytics (Mixpanel) Integration

**Status:** Draft

Mixpanel in beta AND prod (D3 ✅), gated on consent toggle (`analyticsEnabled`, default ON) — NOT `#if BETA`; PreAuthIdentity distinct_id; event taxonomy (engagement/retention, search, feature adoption); per-session `study_session_summary` → MSS as tunable Mixpanel Custom Event; North Star = weekly users with ≥1 MSS; `PrivacyInfo.xcprivacy`; card/folder/tag events deferred to slice 4; Slice 1+2+3 Work Orders inside; swap MixpanelAnalytics→custom impl when free-tier insufficient (abstraction swap, no remote kill-switch); ⚠️ code still `#if BETA`-gated — needs gating change (Slice 1.5/2)

[← назад до INDEX](INDEX.md)

---

<a id="conventions-uk-interlinear"></a>

## `conventions-uk-interlinear.md` — Конвенції українського підрядника — чернетка v0.1

**Status:** Draft (2026-08-05)

Правила глосування ОДНОГО display-слота, виведені емпірично з подвійного проходу по золотому набору. Ядро: (1) слот несе рівно свій матеріал — не позичати в сусіда й не лишати сусідові; (2) **форму дає `morph`, лексичний вибір — англійська глоса** (плутанина цих двох джерел дає кальку в називному); (3) число й стан за тегом, не за українським віршем — Огієнко поруч є джерелом лексики й регістру, не граматики. Пілот показав: 10 із 18 розбіжностей між гілками генерації — саме невимовлені конвенції, а не якість моделі. Живить `plan-uk-interlinear-glosses.md` і волонтерську вичитку (епік 3 у `uk-interlinear-program.md`)

[← назад до INDEX](INDEX.md)

---

<a id="spec-notifications"></a>

## `spec-notifications.md` — Notifications (Phase 1, local-first)

**Status:** Draft

Реалізує ADR-031. P0: **permission-гібрид** (provisional D0 → soft-ask full після 1-го study-моменту), **канал A** «Продовжити дослідження» (event-driven, снапшот word-study), **канал B** курований вірш (rotating `encourage`/`deep_dive`, no-repeat, front-load), **scheduling recompute-on-transition** (rolling horizon дискретних реквестів, ≤64, governor ≤1/3д), Settings Меню (per-type toggles/cadence, AppStorageKeys ADR-025), deep-link через AppNavigationRouter+cold-start, аналітика `scheduled`/`opened` (без `delivered`). **Стартовий сід: 8 `deep_dive`** (Іс7:14/Пс22:16/Флп2:6/Рим9:5/Ів1:1/Бут1:1/Пс23:6/Ів3:16 — evenhanded, teaser=наш копірайт) **+ 14 `encourage`**. Копірайт A/B EN/UK. Work Order 4 slices. **Open Q ліцензії — ЗНЯТО 2026-07-31** (Огієнко CC BY-SA 3.0, ADR-029 розблоковано; спека більше нічим не гейтиться юридично). Лишилось **продуктове** питання: UK `encourage` teaser — наша інвітаційна копія (як зараз у §8) чи дослівна цитата UBIO. Тест: sim launch-args + Archive

[← назад до INDEX](INDEX.md)

---

<a id="pdr-analytics-mixpanel"></a>

## `PDR-Analytics-Mixpanel.md` — Analytics (Mixpanel)

**Status:** Proposed

Mixpanel in beta AND prod, anonymous (PreAuthIdentity), no PII; gated on consent toggle (default ON), not build-flag; North Star = Meaningful Study Session; metric defs live in Mixpanel (tunable); D1 no query-text ✅, D2 beta consent (default ON) ✅, D3 prod analytics ✅, D4 prod consent = opt-IN (default OFF; beta stays opt-out) ✅, D5 separate Dev/Beta/Prod projects (runtime token by isTestFlight) ✅; swap to custom (self-hosted OSS/paid, not bespoke) when free-tier insufficient; reconciles with trust-first

[← назад до INDEX](INDEX.md)

---

<a id="pdr-lexicon-language"></a>

## `PDR-Lexicon-Language.md` — Lexicon Language — English glosses/definitions for MVP

**Status:** Accepted 2026-07-14

Lexical **data** (Macula glosses, Strong's short/long_def) is English-only for MVP regardless of UI language or translation — dataset is human-authored English, no RST/UA gloss column, MT of definitions rejected on trust grounds. **Interface labels MUST still localize** — that split is the bug-005/027 verdict (label half was a real defect: `String(localized:)` bypassed the LocalizedBundle swizzle, fixed 2026-07-13). Closes bug-006 as by-design; Accept decision in known-design-friction. Revisit: licensed UA lexicon, ~3 reporters, or paid tier

[← назад до INDEX](INDEX.md)

---
