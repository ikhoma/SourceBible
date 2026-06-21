# ADR-023: Контроль стилю статус-бара в SwiftUI App lifecycle

**Status:** Reverted — implementation backed out 2026-06-21 (one open issue: immediate tab-switch coupling — shared HC class + async race). The working algorithm, full code, all variants tried, and fix candidates are preserved in **`docs/features/plan-status-bar-cover-white.md`** (the code exists only there — reverted from git). Note: even Apple Music exhibits the same resting-state failure (black-on-dark hero), confirming this is framework-level, not a bad implementation. Reconsider Option C / design-level scrim if revisited.
**Date:** 2026-06-20
**Deciders:** Ivan
**Зв'язок:** реалізує вимогу білого статус-бара на обкладинках (ADR-017 Book Covers). Стосується dark-mode механізму (`SourceBibleApp.preferredColorScheme`).

## Context

Вимога (дизайн): у light mode на сторінках з обкладинкою книги іконки статус-бара мають бути **білими**, поки обкладинка під статус-баром, і повертатись до theme-default коли обкладинка проскролилась вище.

Проблема: **SwiftUI App lifecycle не має публічного API для стилю статус-бара.** Є тільки `.statusBarHidden`. Стиль (`.lightContent`/`.darkContent`/`.default`) контролює `UIViewController.preferredStatusBarStyle`, а кореневий VC у SwiftUI-застосунку — це системний `UIHostingController`, який ми не створюємо і не можемо підкласити.

Поточна реалізація (цей сесійний прогін): `AppDelegate` через `UIScene.didActivateNotification` **підміняє `window.rootViewController`** на власний `StatusBarContainerController`, який тримає системний `UIHostingController` дитиною і керує статус-баром через `childForStatusBarStyle`/`preferredStatusBarStyle`.

**Що це вже зламало:** `.preferredColorScheme` пропагує appearance до вікна **через те, що hosting controller є коренем вікна**. Як тільки ми зробили його дитиною — dark mode перестав застосовуватись (іконка тоглу рухалась, UI не перемальовувався; freeze на кілька секунд; після clean-install застосунок слідував системній темі). Довелось **перебрати на себе appearance** — контейнер тепер виставляє `overrideUserInterfaceStyle` з `isDarkMode`.

**Research (2026-06):**
- Підміна/підклас кореневого `UIHostingController` **ламає app-lifecycle фічі** (`onOpenURL`, scene-зв'язки). ([Arcush: UIHostingController pitfalls](https://medium.com/arcush-tech/two-pitfalls-to-avoid-when-working-with-uihostingcontroller-534d1507563e))
- `preferredColorScheme` коректно працює **тільки** коли HC — корінь вікна або top of nav stack. ([той самий source])
- Спільнотний стандарт — **swizzle `childForStatusBarStyle` на `UIHostingController`** (HC лишається коренем): бібліотеки [swiftui-statusbarstyle](https://github.com/xavierdonnellon/swiftui-statusbarstyle), [PRND/StatusBarStyling](https://github.com/PRNDcompany/StatusBarStyling). Swizzling — «last resort», але тут це **публічний стабільний getter**, не приватний API. ([philip trauner: dynamic status bar](https://philip-trauner.me/blog/post/swift-ui-dynamic-status-bar-style))

**Forces / constraints:**
- Таргети — **iPhone + iPad** (НЕ visionOS — Vision Pro не в планах). iPad = multi-window / Stage Manager, тому підхід, що ітерує `connectedScenes` і мутує кожен key window, тут крихкий. Примітка: `TARGETED_DEVICE_FAMILY = "1,2,7"` містить `7` (visionOS) — ймовірно ненавмисний Xcode-default; варто прибрати до `"1,2"` (окремо від цього ADR).
- ADR-001: min iOS 18, iOS 26 за `#available`. Swift 6 strict concurrency.
- ADR-008 цінність: **zero нових залежностей**.
- Зберегти нативний dark-mode (не тримати власну копію appearance-логіки довго).

## Decision

**Перейти з підміни кореневого VC (Option A) на контейнований swizzle `UIHostingController.childForStatusBarStyle` (Option B).** HC лишається коренем вікна → `.preferredColorScheme` і lifecycle працюють нативно (прибирає цілий клас dark-mode багів і власну appearance-логіку). Статус-бар читає shared `StatusBarStyleState` (вже є). Обгородити iPhone/iPad; на visionOS — no-op.

> Рішення потребує підпису Ivan. Поточний працюючий Option A прийнятний як тимчасовий, якщо рев'ю вирішить не робити swizzle — тоді обов'язкові hardening action items нижче.

## Options Considered

### Option A: Window-root container (поточна реалізація)
| Dimension | Assessment |
|---|---|
| Complexity | Med — власний root VC + перебрана appearance-логіка |
| Cost | Working, але re-owns dark mode |
| Scalability | ⚠️ ітерує `connectedScenes`/key windows — крихко на iPad multi-window / Stage Manager |
| Team familiarity | High (вже є UIKit-interop у проекті) |

**Pros:** без swizzling; повний контроль; вже працює.
**Cons:** зламав `.preferredColorScheme` → змусив тримати власний `overrideUserInterfaceStyle`; ризик зламати майбутні `onOpenURL`/scene/state-restoration; multi-scene (iPad/Vision) непокритий; розходиться з нативним SwiftUI appearance.

### Option B: Swizzle `childForStatusBarStyle` на UIHostingController (рекомендовано)
| Dimension | Assessment |
|---|---|
| Complexity | Low-Med — один контейнований swizzle + допоміжна `StatusBarStylingView` |
| Cost | Менше коду; **прибирає** власну appearance-логіку |
| Scalability | Per-controller, не чіпає scenes → safe на iPad multi-window |
| Team familiarity | Med (swizzle, але публічний стабільний getter) |

**Pros:** HC лишається коренем → `.preferredColorScheme` + lifecycle нативні; dark-mode баг неможливий by construction; community-proven; zero deps (свій ~40 рядків).
**Cons:** swizzling = глобальний side-effect, треба ідемпотентність + однократність; Apple-discouraged технічно; залежить від того що SwiftUI рендерить через `UIHostingController` (стабільно роками).

### Option C: Не керувати статус-баром (design-level)
| Dimension | Assessment |
|---|---|
| Complexity | Lowest — жодного UIKit-хака |
| Cost | Найдешевше |
| Scalability | Ідеально cross-platform |
| Team familiarity | — |

**Pros:** нуль ризику; нативний appearance недоторканий.
**Cons:** не дає білих іконок у light mode точно; максимум — темний scrim під статус-баром або прийняти dark іконки на синій обкладинці (гірша читабельність / слабша за дизайн-намір).

### Option D: 3rd-party (StatusBarStyling / swiftui-statusbarstyle)
**Pros:** готове, підтримуване. **Cons:** залежність всупереч ADR-008 zero-dep; під капотом той самий swizzle — краще свої 40 рядків. **Rejected.**

## Trade-off Analysis

Ключовий розмін — **хто володіє appearance**. Option A забирає його у SwiftUI (тому й зламав dark mode і тепер дублює логіку). Option B лишає appearance повністю за SwiftUI і втручається **тільки** в статус-бар — вужча площа, менше регресій, безпечніше на iPad/Vision. Ціна B — swizzle, але публічного стабільного getter'а, контейнованого в один файл, з guard на однократність.

Option C найбезпечніший, але не виконує дизайн. Тримаємо в резерві якщо B/A визнають надмірними для фічі такого масштабу.

## Consequences

**Легше:** dark mode знову нативний (видаляємо `interfaceStyle`/`overrideUserInterfaceStyle` гілку); поведінка консистентна на iPad multi-window; менше коду для майбутніх lifecycle-фіч (deep links).
**Важче:** swizzle треба ставити рівно раз, рано, thread-safe; потрібен smoke-test що SwiftUI sheets/alerts не ламають статус-бар.
**Revisit:** якщо Apple дасть нативний SwiftUI API для статус-бара (можливий на майбутніх iOS) — викинути swizzle.

## Action Items

**Option B — реалізовано 2026-06-20:**
1. [x] Swizzle `preferredStatusBarStyle` на **terminal-VC класі**, знайденому в рантаймі через walk `childForStatusBarStyle` (надійніше за здогад про приватний клас HC; покриває UITabBar/UINavigation backing). `StatusBarStyleController.start()` з `AppDelegate`. Getter повертає `.lightContent`/`.default`.
2. [x] Прибрано `StatusBarContainerController` + підміну root у `AppDelegate`.
3. [x] **Повернено** `.preferredColorScheme(isDarkMode …)`; прибрано `interfaceStyle`/env-injection; `StatusBarStyleState` → `@MainActor` singleton (`.shared`).
4. [x] Двовходова модель (`coverBehindStatusBar && readerTabActive`) + Reader/ContentView-драйвери збережені.
5. [x] Build clean (iOS 26 SDK, Swift 6). iOS 18 build — перевірити в compatibility-спринті.
6. [ ] **Smoke-test на пристрої** (sim cold-launch таймаутить tooling): dark-mode toggle (instant, no freeze), обкладинка (біла→default), таб-світч, verse sheet, iPad split view.

**Якщо лишаємо Option A (тимчасово):**
1. [ ] Звузити `wrapRootViewControllerIfNeeded` до єдиної foreground-active window scene; ігнорувати додаткові scenes (iPad Stage Manager).
2. [ ] Документувати, що контейнер **володіє** appearance (`overrideUserInterfaceStyle`), і що `.preferredColorScheme` навмисно прибрано.
3. [ ] Тест state-restoration / (майбутній) `onOpenURL` на iPhone + iPad.

**Окремо (не цей ADR):** прибрати `7` з `TARGETED_DEVICE_FAMILY` → `"1,2"` (visionOS не таргет).
