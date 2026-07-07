# plan-ios18-compat: iOS 18 Compatibility Refactor — Safe Half (Fable) + Deferred Sprint

**Status:** Phase A — DONE ✅ (2026-07-06) | Phase B — deferred to compat sprint

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
- **Entry condition Phase B:** Phase A змерджено **І** поточна фіча-робота заморожена (щоб не накопичувати новий unguarded iOS 26 API).

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
9. [ ] **Phase B → compat-спринт:** flip target 26.4→18.0 + повний iOS 18 runtime/QA + SPM min-target check + реліз. Більше нічого в A не додавати.
