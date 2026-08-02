# plan-ios18-compat: iOS 18 Compatibility Refactor — Safe Half (Fable) + Deferred Sprint

**Status:** Phase A — DONE ✅ (2026-07-06) | **Phase B — TARGET FLIPPED 2026-07-31, QA відкрите** (гілка `ios18-target-flip`)

> **Вердикт Phase A (2026-07-06).** Compiler-oracle аудит (target=18.0) → **0 unguarded iOS 26 викликів**; guard-покриття вже 100%. Фінальний diff **порожній**, target лишається 26.4. Debug + Release + **Archive** зелені; iOS 18 sim smoke-run OK (1 екран); iOS 26 sim без змін. Незалежно підтверджено: чистий git-tree, жодних `#if BETA`/device сліпих зон. **Компіляційний** ризик Phase B знято повністю; **runtime/QA** ризик лишається на Phase B. Fable-звіт: `report-ios18-compat-phase-a.md`.
**Date:** 2026-07-06
**Deciders:** Ivan
**Related:** ADR-001 (Platform Stack — iOS 18 min target, compat sprint deferred), CLAUDE.md (Autonomous mode / Swift 6 / ⛔-інваріанти)

---

## Context

ADR-001 вже прийняв рішення: мінімальна ціль **iOS 18**, iOS 26-фічі за `#available`, а сам flip deployment target — **окремим спринтом після завершення поточних фіч**.

Поточний стан коду:

- `IPHONEOS_DEPLOYMENT_TARGET = 26.4` в **обох** конфігах (Debug + Release), `SWIFT_VERSION = 6.0`, `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone+iPad, без visionOS — ADR-023 нота вже врахована).
- `#available(iOS 26)` guard-и **вже стоять** у: `CapsuleNavStyle.swift` (glassEffect ↔ ultraThinMaterial), `ReaderView.swift` (~L572, ~L694), `SearchView.swift` (~L233). `ContentView.swift` має iOS 18 split TabView з legacy-fallback.
- `LocalizedBundle.swift` — це **SDK-concurrency** (`Bundle` став `@MainActor` в iOS 26 SDK), а **не** runtime-availability; вже вирішено через `nonisolated`. Зниження target його НЕ чіпає.

**Проблема, яку вирішує цей план.** Поки target = 26.4, компілятор трактує весь iOS 26 API як завжди доступний і **не позначає** unguarded виклики. Тобто в коді можуть бути приховані iOS 26-only виклики, які компілюються сьогодні, але зламають iOS 18 build. Покриття наявних guard-ів — неперевірене.

**Мета.** Віддати Fable **зворотну** половину роботи (додати відсутні guard-и) як trial автономного режиму; лишити **незворотну** половину (сам flip target + повний iOS 18 QA + реліз) на плановий compat-спринт — щоб не тягнути QA-навантаження посеред активної розробки фіч.

---

## Decision: розбити на дві фази

- **Phase A (Fable, зараз)** — зворотна, без зміни поведінки на iOS 26. Додати всі відсутні `#available(iOS 26)` guard-и з iOS 18 fallback. **Target лишається 26.4 у фінальному diff.**
- **Phase B (окремий спринт, пізніше)** — власне flip target 26.4→18.0 + повний iOS 18 QA + реліз.

Merge Phase A нічого не ламає на iOS 26 (guard-и адитивні) і повністю де-ризикує майбутній Phase B: коли ти нарешті опустиш target, воно вже скомпілюється чисто.

---

## Core technique: компілятор як audit-oracle

Ручний аудит пропустить приховані виклики. Тому:

1. На **тимчасовій** гілці/worktree Fable ставить `IPHONEOS_DEPLOYMENT_TARGET = 18.0`.
2. Компілятор видає **error на кожен unguarded iOS 26 виклик** — це вичерпний, точний список аудиту (краще за будь-який grep).
3. Fable загортає кожен у `#available(iOS 26, *)` + iOS 18 fallback, повторюючи наявний патерн (див. IN-scope файли).
4. Fable **повертає target назад на 26.4** перед фінальним diff.
5. У merge потрапляють **тільки додані guard-и**. Flip target — не потрапляє.

Так Phase A одночасно **вичерпна** (компілятор перелічив усе) і **зворотна** ( shipping-diff не містить зміни target).

---

## Scope — Phase A (Fable зараз)

**IN scope (Fable може чіпати):**

- Будь-який `SourceBible/**/*.swift`, де компілятор (з тимчасовим target=18.0) позначив unguarded iOS 26 API.
- Додавання `#available(iOS 26, *)` + iOS 18 fallback, за наявним патерном у:
  - `CapsuleNavStyle.swift` — glassEffect ↔ `.ultraThinMaterial`
  - `ReaderView.swift` (~L572, ~L694)
  - `SearchView.swift` (~L233)
  - `ContentView.swift` — iOS 18 TabView split (референс-патерн, не переписувати)

**OUT of scope (Fable НЕ чіпає):**

- `IPHONEOS_DEPLOYMENT_TARGET` — у фінальному diff лишається **26.4** (тимчасовий 18.0 тільки на scratch-прогін, реверт обов'язковий).
- `LocalizedBundle.swift` concurrency — SDK `@MainActor`, не availability; вже вирішено.
- Реімплементація tuned UI — тільки **обгортати**, не переписувати (feedback-правило «не чіпай tuned UI без підпису»).
- DB / `scripts/` / схема / Python.
- Corner radius / `.presentationCornerRadius` — не додавати (⛔ CLAUDE.md).
- Нові архітектурні рішення. Якщо задача вимагає вийти за scope — **зупинитись і спитати**.

---

## Acceptance criteria (Phase A «готово»)

- На scratch-прогоні з target=18.0 проєкт компілюється з **нулем availability-errors**.
- **Фінальний diff має target назад на 26.4.**
- `⌘B` Debug — зелений **І `Product > Archive` (Release) — зелений** (ловить пастку `#Preview` + DEBUG-samples, яка валить тільки Archive).
- Застосунок запускається на iOS 26 sim **без візуальних/поведінкових змін** (guard-и адитивні).
- (Доказ, не мерджиться) build+run на iOS 18 sim зі scratch-прогону — скріншот у звіт.
- Підготовлено **повний diff + короткий звіт** змін для ревʼю.

---

## Guardrails (з CLAUDE.md-інваріантів)

- Працювати **тільки в окремій git-гілці/worktree**, ніколи в робочій гілці напряму.
- Wrap, don't reimplement tuned UI; не re-map `@Published` під час анімацій.
- iOS 26 API **research перед** вибором fallback (developer.apple.com / createwithswift.com).
- **Жодних незворотних дій** (реверт target — обов'язковий; ніяких змін схеми/бази/force-push).
- Нове рішення всередині прогону → зафіксувати як ADR-amendment і **позначити у звіті** (підпис Ivan пост-фактум).
- **Вихід:** прогін завершується видачею diff на ревʼю; merge робить Ivan.

---

## Execution model (orchestration)

Fable = **оркестратор + верифікатор**; bulk-правки сам не пише. Спавнить субагентів оптимальної моделі для економії:

- **Sonnet** (механічне, дешеве, більшість обсягу): audit-прогін (тимчасово target=18.0 → зібрати всі availability-errors у структурований список), застосування guard-ів за наявним патерном, прогони білдів.
- **Opus** (judgment): вибір правильного iOS 18 fallback там, де він неочевидний (research developer.apple.com); фінальне ревʼю diff (target ревертнуто на 26.4, tuned-UI не переписано, guard-и адитивні, Archive зелений).
- **Fable сам:** секвенування субагентів, реверт target→26.4, збірка фінального diff + звіту, gate-перевірки Acceptance.

Default = Sonnet; ескалація на Opus тільки для fallback-рішень і фінального verify. Верифікацію робити окремим субагентом (не тим, що писав guard-и).

## What stays for the dedicated sprint (Phase B)

- Власне flip `IPHONEOS_DEPLOYMENT_TARGET` 26.4 → 18.0 (Debug + Release).
- **Повний iOS 18 QA-pass** кожного екрана: glass-fallbacks, legacy-TabView шлях, sheets/detents, Study Mode pinning (ADR-021), book covers, status-bar.
- Перевірка `LocalizedBundle` swizzle + `activate` на iOS 18.
- Перф на старіших пристроях (не-Pro).
- Release notes / App Store min-version bump.
- ~~**Entry condition Phase B:** Phase A змерджено **І** поточна фіча-робота заморожена~~ — **свідомо порушено 2026-07-31 (рішення Івана).** Фічі НЕ заморожені (нотіфікації, онбординг, тематичні плани в роботі). Обґрунтування: target=26.4 означав, що тестер на iOS 18 не може **встановити** TestFlight-білд — тобто будь-яка інша фіча в цьому білді коштує нуль для частини тестерів. Ціна порушення: новий unguarded iOS 26 API може зайти непоміченим, бо гейт «фічі заморожені» більше не тримає. Компенсація: компілятор під target=18.0 тепер сам є постійним oracle-ом — будь-який unguarded виклик валить білд одразу, а не через спринт.

---

## Options considered

### Option 1: Повний flip зараз
| Dimension | Assessment |
|---|---|
| Complexity | Med |
| Risk | High (перетест усього на iOS 18 посеред фіч) |
| Fit as Fable trial | Погано (незворотне + важкий QA) |

**Проти:** конфлікт з таймінгом ADR-001; QA-навантаження не вчасно. **Rejected.**

### Option 2: Guard-и зараз, flip потім (chosen)
| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Risk | Low (адитивно, зворотно) |
| Fit as Fable trial | Відмінно (механічно, scoped, testable) |

**Chosen.**

### Option 3: Ручний аудит без compiler-oracle
**Проти:** пропускає приховані unguarded виклики (компілятор не бачить їх при target=26.4). **Rejected** на користь техніки з тимчасовим target=18.0.

---

## Action items

1. [x] Ivan: **approve** цей план (autonomous-gate entry). — 2026-07-06
2. [x] Створити worktree/гілку. — прогін у `work` за вказівкою Ivan; git-tree лишився чистим.
3. [x] Fable: scratch-set target = 18.0 → зібрати всі availability-errors. — **0 errors**.
4. [x] Fable: загорнути кожен виклик у `#available(iOS 26, *)` + iOS 18 fallback. — н/д, чіпати не було чого.
5. [x] Fable: **реверт target → 26.4**. — diff порожній, реверт точний.
6. [x] Fable: Debug + **Archive** зелені; run на iOS 26 sim; (доказ) run на iOS 18 sim. — Archive зібрано (Ivan, 2026-07-06).
7. [x] Fable: підготувати diff + короткий звіт. — `report-ios18-compat-phase-a.md`.
8. [x] Ivan: ревʼю. — merge н/д (diff порожній).
9. [~] **Phase B → compat-спринт:** flip target 26.4→18.0 ✅ 2026-07-31; iOS 18 runtime/QA ✅ 2026-08-02 (16 Pro, SE 3rd gen, 16); **Archive ✅ 2026-08-02**. Лишились: SPM min-target check, UK-локалізація на 18, iPhone XS (немає симулятора), реліз.

---

## Phase B — виконання flip'у (2026-07-31)

**Що зроблено.** `IPHONEOS_DEPLOYMENT_TARGET` 26.4 → 18.0 у двох конфігах
(`project.pbxproj`, рядки 312 і 361). Більше нічого — жодного коду, жодних нових guard'ів.
Diff Phase B = **2 рядки**. Гілка `ios18-target-flip`, відгалужена від `work`.

**Що перевірено.**

| перевірка | результат |
|---|---|
| Compile @ target=18.0 (Debug) | ✅ 0 errors, 0 warnings |
| Runtime launch, iOS 18.0 sim (iPhone 16 Pro) | ✅ застосунок стартує |
| Візуальний smoke: рідер | ✅ обкладинка Доре з bleed під тулбар (ADR-017), пікери «Gen 1 / KJV», чеврон, таб-бар — усе на місці |

Прогноз Phase A підтвердився повністю: аудит 2026-07-06 обіцяв 0 unguarded викликів —
компілятор під реальним target=18.0 не знайшов жодного.

**Інтерактивне QA на iOS 18.0 (iPhone 16 Pro), пройдено 2026-08-01 через computer-use.**

| сценарій | результат |
|---|---|
| Резюм позиції при холодному старті | ✅ відкрився Пс 33 зі збереженим скролом |
| Меню → секція «Translation», обидва рядки | ✅ рендеряться |
| Пікер «Translation on launch» (2 опції + сабтайтли + чекмарк) | ✅ |
| Режим `lastUsed`: рядок конкретного перекладу ховається | ✅ зникає |
| `lastUsed`: перемкнув на UBIO → kill → relaunch | ✅ відкрився UBIO |
| Режим `fixed`: рядок повертається, показує KJV | ✅ |
| `fixed`: kill → relaunch при lastUsed=UBIO | ✅ відкрився KJV (UBIO проігноровано) — регресія для наявних користувачів виключена |
| UBIO: рідні укр. назви книг (ADR-018) | ✅ «Пс. 33 / Псалом 33» |
| Study Mode: тап вірша, pin під тулбаром, sheet, морф тулбара в «Close» (ADR-021/024) | ✅ геометрія без дефектів |
| Study Mode → Cross Refs | ✅ Eph 5:19 / Ps 96:1 / Isa 42:10 / 1Chr 25:7 |
| Study Mode → Original (verse_org, ADR-028) | ✅ іврит + xlit + Strong's + морфологія; sub-entry H3807a коректний (ADR-019) |
| Chapter paging чевроном (ADR-026 legacy-шлях на 18) | ✅ Пс 33 → Пс 34, глава відкрилась зверху |
| Тулбар без Liquid Glass | ✅ деградує в плаский системний вигляд, без артефактів |

**Знайдено й полагоджено під час QA: bug-030.**
Чеврони Study Mode на iOS 18 закривали sheet замість переходу по віршах, і затемнення
sheet'а не прибиралось. Одна причина: `largestUndimmedDetentIdentifier` вказував на detent,
який `StudySheetDetentApplier` затирав, тож undimmed-режим мовчки не застосовувався.
Фікс — 2 рядки в `StudySheetDetent.swift`, верифіковано на 18 і 26. Деталі: `docs/bugs/in-progress/bug-030.md`.
Це рівно той клас дефектів, заради якого існувала entry-умова «фічі заморожені»: під target=26.4
гілка була недосяжною і ніколи не виконувалась.

**Шапка пошуку — виправлено 2026-08-02.** Смуга фільтрів на iOS 18 була закріпленою
секційною шапкою ВСЕРЕДИНІ скролу, тож її фон обмежувався висотою чипів: над ним
лишалась смуга, крізь яку проїжджав текст («дірка»), а сам фон читався як окрема
плашка. Замінено на `safeAreaInset(edge: .top)` — прямий предок `safeAreaBar` з iOS 15 —
з `ignoresSafeArea` ТІЛЬКИ на фоні. Матеріал `.bar` (не `.ultraThinMaterial`), щоб
збігався з тулбаром. Заразом прибрано три милиці: `pinnedViews`, параметр
`pinnedFilterBar` через три функції і `-20` горизонтального падінгу.

**Що ЛИШАЄТЬСЯ на ручне QA.**

- [x] **Archive/Release** — ✅ **зібрано 2026-08-02**, після всіх правок гілки. Останній
  блокер перед TestFlight знято. (Історія пункту нижче — лишена як запис, чому попередній
  архів не рахувався.)
  ~~⛔ НЕ закрито. Архів, зроблений раніше, був ДО flip'у й ДО пікера,~~
  тож не рахується. Спроба зібрати Release у сесії обірвалась (лок build-бази, далі втрата
  містка). Обовʼязково перед TestFlight — у Debug не видно `#Preview`-пасток (CLAUDE.md).
- [x] **iPhone SE (3rd gen)** — ✅ перевірено 2026-08-02. Закрило й давній пункт ADR-021
  «SE-validation pending»: реальна Δ там інша, рантайм-калібрування підхопило (bug-031).
  Заразом перевірено iPhone 16 (393×852).
  ~~найвужчий екран у пулі iOS 18; ADR-021 має незакритий~~
  «SE-validation pending» саме по `detentTopOffset`. Не перевірявся.
- **Full-surface свайп** перегортання (перевірено лише чеврон; PDR-Page-Turn-Gesture-Zone
  має rollback-клаузу саме на конфлікт свайпу з тапом/лонгпресом).
- **SPM min-target check.**
- Локалізація UI на UK при iOS 18 (перевірялось лише EN).
