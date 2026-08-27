# ADR-031 — Локальні нотіфікації (retention, local-first)

**Status:** Proposed (amended 2026-07-31 — post-review: scheduling model, cadence, permission, analytics)
**Deciders:** Ivan
**Context tags:** UNUserNotificationCenter, retention, engagement, provisional auth, deep-link, local-first
**Related:** [[PDR-Auth-Strategy]] (trust-first) · [[ADR-012-unified-user-data-layer]] · [[ADR-022-analytics-event-collection-strategy]] · [[ADR-025-app-preferences-storage]] · [[ADR-027-modular-commentary-modules]] (майбутній APNs) · [[ADR-005-highlights-bookmarks-notes]] (AppNavigationRouter) · `spec-reader-resume-position` · `spec-notifications` (пишеться) · impl-reference: `~/.agents/skills/push-notifications`

---

## Контекст

Мета — підняти **D1 / D7 / D30 retention** і живити North Star (weekly users з ≥1 Meaningful Study Session, [[PDR-Analytics-Mixpanel]]). Головний важіль повернення в мобільному застосунку — нотіфікації.

Але SourceBible — **не масовий девоційний застосунок**, а інструмент для тих, хто копає глибше (оригінали, Strong's, коментарі, крос-рефи). Стандартні retention-механіки масових Bible-застосунків тут **шкідливі, а не корисні**:

- **«Вірш дня»** генерично й вирвано з контексту — суперечить самій суті продукту (глибина, контекст).
- **Стрік-лічильник** пропагує «культуру ефективності» / гонитву за числом — приваблює не ту аудиторію й не пасує до вдумливого вивчення.

Тому потрібні нотіфікації, що **підсилюють глибину** й повертають користувача до **його власної** роботи, а не смикають генеричним контентом. Формулювання retention для глибокого інструменту: не «чи зайшов сьогодні», а **«чи не втратив нитку дослідження, яке почав»**.

Обмеження:
- **Бекенду немає.** Trust-first, local-first ([[PDR-Auth-Strategy]]): дані на пристрої, без логін-стіни. → Фаза 1 суто локальна, без APNs / серверу / device-token реєстрації.
- **iOS 18 мінімум** (ADR-001). `UserNotifications` повністю доступний на iOS 18 — availability-гейти майже не потрібні.
- **Аналітичний бюджет** (ADR-022): free-tier Mixpanel 1M/міс — нові події мають бути малооб'ємні.
- **Consent-етос:** жодного нав'язування; opt-out тривіальний; низька частота.

## Рішення

### Дві фази (архітектурний шов)

- **Фаза 1 (цей ADR) — локальні нотіфікації** через `UNUserNotificationCenter`. Планувальник на пристрої, контент локалізований (EN/UK, ADR-006). Тут лежать усі retention-важелі.
- **Фаза 2 (відкладено) — віддалені (APNs)** для того, що не можна знати наперед на пристрої: анонси, вихід нового commentary-модуля ([[ADR-027-modular-commentary-modules]] OTA), новини. Потребує інфраструктури відправки → окремий етап. Архітектура Фази 1 лишає шов (`NotificationService` абстрагує джерело), але APNs **не будується зараз**.

### Два канали нотіфікацій

**A. «Продовжити дослідження»** — подієвий (event-driven) local re-engagement по власній незавершеній нитці. Спрацьовує після N днів тиші, коли є що продовжити.
- **Ядро нитки = word-study** (останнє досліджуване слово / Strong's) — це унікальна цінність саме цього продукту.
- Fallback-ланцюг, якщо word-study порожній: остання **позиція читання** (`spec-reader-resume-position`) → незавершена **нотатка / крос-реф стек** (`crossRefBackStack`, ADR-024).
- Тап → deep-link у той самий word page / уривок.
- **A — це нескінченний, завжди свіжий двигун retention:** контент = робота користувача, ніколи не повторюється, не потребує контент-конвеєра. Саме A тримає **steady-state** утримання.

**B. Курований вірш** — плановий (scheduled) local. Один слот, пул контенту ротує **два на-бренд типи**:
- `encourage` — вірш про Слово / роздуми (Пс 1:2, Іс.Нав 1:8, Пс 119:105) → тап відкриває читання;
- `deep_dive` — вірш із реальним різночитанням перекладу (Іс 7:14 עַלְמָה, Пс 22:16 כָּאֲרִי, Флп 2:6 ἁρπαγμός, Рим 9:5) → тап веде в оригінал / паралель із підсвіченою «вилкою». Це **демонстрація цінності тули**, а не просто контент — працює одразу на retention **і** feature-adoption воронку (ADR-022).
- B — вужчий за роллю: **демонстрація цінності у вікні активації**, не щоденний ритм.

### Каденс і стратегія пулу (B)

Каденс B **не хардкодиться** («7 днів» / «місяць») — це **конфіг**, дефолт = те, що витримує наявний пул; frequency governor усе одно кепить частоту (нижче).

- **Front-load у перші ~30 днів** (слоти D4/D11/D18/D25 lifecycle-таблиці — там deep_dive найкраще конвертує в D7/D30), далі **таперинг до ~щомісяця** у steady-state (де retention несе канал A).
- **Без повторів, поки пул не вичерпано.** Вичерпано deep_dive → B падає на `encourage`-бекбон + «як з'явиться нове».
- **Курація розділена за вартістю:**
  - `encourage` — **дешевий** в об'ємі (Писань про Писання багато) → стійкий повільний бекбон. Сід ~10–15.
  - `deep_dive` — **дорогий** (кожен = реальна вилка + яка тула її показує) → преміум, front-loaded. Сід ~6–8 найсильніших.
- **Ростимо пул мінорними апдейтами** (кожна нова порція тимчасово підіймає каденс). Steady-state retention НЕ залежить від дефіцитного deep_dive — його несе A + дешеві encourage.

### Модель планування (scheduling) — recompute-on-transition

**Ключовий інваріант локальних нотіфікацій: у момент доставки код не виконується** (пристрій може бути офлайн, застосунок killed, бекенду нема). Отже:

1. **Контент запікається наперед** при плануванні. «Продовжити дослідження» бере снапшот нитки на момент планування (не на момент показу). Ротація B вибирає конкретний вірш **при плануванні**.
2. **Уся адаптивна логіка — на етапі планування, не доставки.** governor, «пропуск якщо активний», «event б'є планове», lapsing — реалізуються через **перерахунок усього плану на кожному foreground/background-переході**: скасувати всі app-керовані pending → перепланувати **rolling horizon** дискретних нотіфікацій із поточного стану (снапшот нитки, seen-set, toggles, дати).
3. **Rolling horizon дискретних нотіфікацій**, НЕ повторюваний тригер. Кожна запланована нотіфікація — окремий `UNNotificationRequest` зі **своїм** контентом (це і дає ротацію B, якої repeat-тригер не вміє). Горизонт обмежений (напр. наступні ~8 дотиків) → природно поважає **ліміт 64 pending** на застосунок.
4. Стабільні `identifier` за роллю/слотом → ідемпотентне cancel+reschedule без дублікатів.

> ⚠️ Дефолтний приклад у impl-скілі (`scheduleDailyReminder` з `repeats: true` на `UNCalendarNotificationTrigger`) для каналу B **не застосовується** — repeat шле однаковий контент, ротація неможлива. Використовуємо дискретні реквести + refill на foreground.

### Модель дозволу (provisional → full, гібрид)

- **D0: provisional authorization** (`UNAuthorizationOptions.provisional`) — тихо, без діалогу; нотіфікації йдуть у Notification Center без переривань.
- **Full soft-ask — на першому «вау» в застосунку** (кінець першої справжньої study-сесії, часто D0/D1), in-context, не системним промптом наосліп. `upgradeToFullAuthorization()` (provisional → full) з impl-скіла.
- **Чому гібрид, а не «soft-ask лише після D4»:** provisional-дотики тихі (лише Notification Center, без банера/звуку/lock-screen) — тобто front-loaded week-1 нотіфікації майже не видно, поки нема повного дозволу. Гібрид ловить 100% тихо на D0, але для залучених робить week-1 **повновидимим** одразу після першого value-моменту. Незалучені лишаються на тихому каналі — без нав'язування (trust-first).

### Lifecycle schedule (D0–D30, під D1/D7/D30)

Логіка: не частота, а **релевантність і таймінг** — трохи щільніше в критичний перший тиждень, далі тижневий/місячний ритм; подієвий A вклинюється лише коли є що продовжити. Типовий помірно-залучений користувач:

| День | Умова / тригер | Канал | Тип | Ціль | Deep-link |
|---|---|---|---|---|---|
| **D0** | Встановлення, 1-ша сесія | — | *без пушу* — provisional тихо, активація в застосунку | активація | — |
| **D1** | ~20 год без відкриття | A | word-study / welcome deep-dive | **D1** | word page |
| **D4** | Слот B #1 | B | deep_dive (+full soft-ask, якщо ще не питали) | **D7** | паралель + оригінал |
| **D7** | Milestone / є нитка | A | word-study | **D7** | word page |
| **D11** | Слот B #2 | B | encourage | звичка | reader |
| **D14** | Lapsing 3+ дні | A | resume thread | **D30** | reader / word |
| **D18** | Слот B #3 | B | deep_dive | **D30** | паралель + оригінал |
| **D25** | Слот B #4 | B | encourage | **D30** | reader |
| **D28** | Win-back: 7+ днів тиші | B | deep_dive | **D30** реактивація | deep-link |
| **D30** | Milestone | — | без окремого пушу; steady-state ритм триває | — | — |

*(Слоти B — це «до 4 у першому місяці» з front-load; за таперингом далі рідше.)*

**Frequency governor** (застосовується **на етапі планування**, п.2 вище):
- Ліміт: не більше **1 пушу на 3 дні**; ніколи не щодня (≤~8 дотиків / 30 днів).
- **Подієве б'є планове:** є незавершена нитка + тиша → шле A і зсуває найближчий B (без подвоєння).
- **Розумний пропуск:** заходив сьогодні → плановий B цього дня не планується (перерахунок на foreground це і робить).
- **Quiet hours** + доставка у вечірнє локальне вікно користувача.

### Високорівнева архітектура

```
              app foreground/background transition  (єдиний тригер перепланування)
                                  │
        ┌─────────────────────────┼──────────────────────────┐
        ▼                         ▼                            ▼
 StudyThreadTracker        NotificationScheduler        AppPreferences
 (ловить останнє            recompute-on-transition:      (AppStorageKeys:
  word-study / позицію)      cancel all → replan          toggles, cadence,
        │                    rolling horizon (≤64,         last-delivery, seen-set,
        │                    governor, event>scheduled)    thread-snapshot)
        └──────────┬──────────────┘                            ▲
                   ▼                                            │
          NotificationContentProvider ───────────────► curated verse pool
          (вибір без повторів, front-load,              (bundled JSON, inline EN/UK)
           deep_dive преміум / encourage бекбон)
                   │
                   ▼   (контент запікається НАПЕРЕД)
            NotificationService  (UNUserNotificationCenter)
            · requestAuth(provisional → full soft-ask)
            · add(discrete requests)  ·  removePending/reschedule
            · UNUserNotificationCenterDelegate → willPresent / didReceive(tap)
                   │
                   ▼
            AppNavigationRouter (ADR-005) → verse / word / tool deep-link
            (cold-start: pending-route, споживається коли рідер готовий —
             патерн pendingRestoreAnchorId з resume-position)
                   │
                   ▼
            AnalyticsService (ADR-022): notification_* (consent-gated)
```

### Модель даних

**1. Курований датасет віршів (нова залежність).** Bundled-ресурс (JSON), не таблиця в `sourcebible.db`:
```
notification_verse:
  id            — стабільний ключ
  ref           — book/chapter/verse (канонічна нумерація, resolve через verse_org на тап)
  tag           — "encourage" | "deep_dive"
  strongs_id    — оригінальне слово (для deep_dive)
  tool          — яка тула показує вилку ("parallel" | "original" | "reader")
  teaser:       — рядок нотіфікації, локалізований ІНЛАЙН у контенті:
    en / uk
```
*Чому JSON, а не таблиця в БД:* контент курований і рідко змінний, **не має тримати 10-хв ребілд БД**, і природно OTA-оновлюваний у Фазі 2 (як модулі ADR-027).
*Чому teaser локалізований інлайн (а не через LocalizedBundle/xcstrings):* тизер — це **контент, а не UI-chrome**. У проєкті контент (текст вірша, коментарі) живе в даних і локалізується там, а не в xcstrings (пор. PDR-Lexicon-Language: дані ≠ інтерфейсні лейбли). Тизер travels with the content → self-contained, OTA-ready, редагується куратором в одному файлі. (UI Меню-нотіфікацій — навпаки, звичайні інтерфейсні рядки через LocalizedBundle.)

**2. Стан нитки (канал A).** Малий снапшот останнього word-study: `strongs_id`, `verse_ref`, `timestamp`. Живе в **`AppPreferences` / `@AppStorage`** (ADR-025), НЕ в GRDB — дрібне, ефемерне, часто перезаписуване. Хук — існуючий `SessionTracker` / word-tap / `ReaderViewModel`.

**3. Стан планувальника + налаштування.** `lastDeliveryTimestamp`, `cadence`, seen-set (для no-repeat), доставлений lifecycle-крок, **per-type toggles** — нова категорія ключів у `AppStorageKeys` (ADR-025): *notification preferences* (reset-safe: скидаються в дефолти, але не входять у consent/migration clear).

> **Стрік навмисно не потребує reading-day tracking** — стрік відкинуто (див. нижче), тож нового персистентного лічильника днів **не вводимо**.

### iOS API

- Канал B / A / win-back → **дискретні** `UNCalendarNotificationTrigger` / `UNTimeIntervalNotificationTrigger`, **`repeats: false`** (ротація вимагає окремого контенту на реквест; повторюваний тригер заборонено для B). Refill горизонту на foreground.
- **Ліміт 64 pending** на застосунок — інваріант; rolling horizon його поважає.
- `interruptionLevel = .active` (НЕ `.timeSensitive` — поважаємо Focus/DND; це не критичні сповіщення).
- Provisional → опція `.provisional`; повний → `.alert + .sound + .badge` (soft-ask).
- Delegate — рано в `App.init` (`UNUserNotificationCenter.current().delegate`); `willPresent` (foreground) + `didReceive` (тап). iOS 18: `UserNotifications` повністю доступний — **availability-гейти не потрібні**. Swift 6: `NotificationService`/delegate — `@MainActor`.
- Deep-link: категорії/`userInfo` → `AppNavigationRouter` (ADR-005). **Cold-start:** тап із killed-стану кладе pending-route, який споживається коли рідер готовий (той самий патерн, що `pendingRestoreAnchorId` у resume-position).

### Аналітика (consent-gated, ADR-022)

Дискретні, малооб'ємні (≤~8/міс на користувача, під free-tier): **`notification_scheduled`**, **`notification_opened`** (тап) з `type` (A/B), `content_tag` (encourage/deep_dive), `lifecycle_step`. Опційно `notification_presented` лише коли застосунок на передньому плані (`willPresent`).
> ⛔ **`notification_delivered` НЕ вводимо** — для локальних нотіфікацій колбека доставки немає (він існує лише для remote через Notification Service Extension). Спостережувані тільки scheduled / opened / presented(foreground). (Уникаємо «measure before claiming».)

Гейтяться на `analyticsEnabled`. Дозволяють міряти D1/D7/D30 когорти й **відсікати тип, що не рухає retention**.

## Options Considered / Чому не так

- **«Вірш дня» + стрік** — відкинуто: генерично й гейміфіковано, суперечить бренду глибокого інструменту, приваблює не ту аудиторію. `deep_dive` вірш зберігає ідею «курованого вірша», але переосмислену в демонстрацію тули.
- **APNs зараз** — відкинуто: вимагає бекенду/інфраструктури, не виправдано до релізу; шов лишено, будується у Фазі 2 разом із ADR-027.
- **Повторюваний тригер для каналу B** — відкинуто: `repeats: true` шле однаковий контент, ротація неможлива. → дискретні реквести + refill (див. scheduling model).
- **Логіка вибору контенту в момент доставки** — неможлива: код при доставці не виконується. → recompute-on-transition, контент запікається наперед.
- **Курований датасет як таблиця в `sourcebible.db`** — відкинуто: прив'язало б контент до 10-хв ребілду й ускладнило б майбутнє OTA; JSON-ресурс розв'язує обидва.
- **Тизер через LocalizedBundle/xcstrings** — відкинуто: тизер — контент, не chrome; тримаємо інлайн у даних (self-contained, OTA-ready), як текст вірша/коментаря.
- **Стан нитки / налаштування в GRDB (ADR-012)** — надлишково: значення дрібні й ефемерні; GRDB лишається для user-authored даних.
- **`.timeSensitive` рівень** — відкинуто: обхід Focus для не-критичного контенту зашкодив би довірі.
- **Provisional-only через увесь week-1** — відкинуто: тихі дотики майже не видно → підриває front-load. → гібрид (provisional D0 + full soft-ask на першому value-моменті).

## Наслідки

- **+** Retention-важіль, вирівняний із брендом: кожен дотик або повертає до **власної** роботи, або показує **глибину**. Низька частота + повний opt-out.
- **+** `deep_dive` працює подвійно — retention **і** feature-adoption воронка (ADR-022).
- **+** Steady-state retention несе канал A (нескінченний, без контент-конвеєра) → малий пул B не є блокером.
- **+** Абстракція `NotificationService` лишає дешевий шов для APNs (Фаза 2).
- **−** Нова **тривала залежність — курація** датасету віршів (особливо дефіцитні `deep_dive`); ростимо мінорними апдейтами.
- **−** Треба стежити за permission-conversion воронкою (provisional → full); якщо soft-ask конвертує погано — тюнити момент/копірайт.
- **−** `SessionTracker` / word-tap обростають хуком захоплення снапшота нитки.
- **−** Планувальник має бути суворо ідемпотентним (cancel+replan на кожному переході) — інакше дублікати / вихід за 64.

## Revisit-тригери

- Дані Mixpanel показують, що якийсь тип не рухає D7/D30 → прибрати/переробити.
- З'являється бекенд → Фаза 2 APNs (анонси, ADR-027 модулі).
- Пул `deep_dive` виріс достатньо → підняти дефолтний каденс B.
- Тестери просять щоденний ритм / дайджест → переглянути частоту (зараз навмисно рідка).

## Обсяг реалізації (Фаза 1)

**IN:**
- `Services/NotificationService.swift` — auth (provisional + full soft-ask), add/cancel дискретних реквестів, delegate (`willPresent`/`didReceive`) + deep-link через `AppNavigationRouter`.
- `Services/NotificationScheduler.swift` — **recompute-on-transition**: lifecycle-крок + frequency governor + rolling horizon (≤64).
- `Services/NotificationContentProvider.swift` — завантаження пулу, вибір без повторів, front-load, deep_dive-преміум / encourage-бекбон, локалізація (inline).
- `Services/StudyThreadTracker.swift` (або розширення `SessionTracker`) — снапшот останнього word-study.
- `Resources/notification_verses.json` — стартовий курований пул: **~6–8 `deep_dive` + ~10–15 `encourage`**.
- `AppStorageKeys` (ADR-025): нова категорія *notification preferences* (per-type toggles, cadence, last-delivery, seen-set, thread-snapshot).
- Меню → «Нотіфікації»: тумблери типів + каденс + вимкнути (нативний `Form`/`Toggle`, HIG; рядки через LocalizedBundle).
- Аналітика: `notification_scheduled` / `notification_opened` (+ опц. `_presented`), consent-gated. **Без `_delivered`.**
- App lifecycle hook (foreground/background) → тригер перепланування.
- Info.plist — нічого спец. для локальних (APNs entitlement — Фаза 2).

**OUT (backlog, не в MVP):**
- APNs / віддалені (Фаза 2, з ADR-027) — impl-скіл покриває (TokenService, silent push, Service Extension, rich notifications).
- Стрік / reading-day tracking (відкинуто як off-brand).
- Тижневий рефлексивний дайджест («12 слів у 4 книгах») — кандидат після MVP.
- Напівавтоматичний генератор кандидатів `deep_dive` (там, де переклади розходяться на одному Strong's).

**Impl-reference:** `~/.agents/skills/push-notifications` — коректні патерни provisional / delegate / deep-link router / scheduler-скелет / sim-тести (`simctl push`) / Swift 6. Використовуємо як механіку під цим ADR; його repeat-тригер приклад для B **не застосовуємо** (див. scheduling model).

**Наступний крок:** `spec-notifications.md` — детальні вимоги, копірайт нотіфікацій (EN/UK), схема курованого пулу + стартовий сід, UI Меню, тест-план (sim launch-args), і Work Order під реалізацію в окремій гілці.

**Донат-запит (`pos-001`) — поза обсягом цього ADR.** Рішення 2026-08-26 (Іван): запит про пожертву — суто **in-app** UI (банер/модалка одразу після Meaningful Study Session, поки застосунок на передньому плані), **без** `UNUserNotificationCenter` і без спільного frequency governor каналів A/B. Причина розведення: канали A/B цього ADR — retention-пуші саме для **відсутнього** користувача (Notification Center, поза застосунком), тоді як MSS триґериться **всередині активної сесії** — це різні механізми, не один канал під однією машинерією. Донат-ask має власний, окремий і простий rate-limit (напр. локальний прапорець «показано, дата»), який не проходить через `NotificationScheduler` / `recompute-on-transition` / rolling horizon. Раніше тут стояла позначка про тікет `pos-011` («амендмент ADR-031 — механізм донат-нотифікації») як передумову для `pos-001` — знято разом із цим рішенням, амендмент цього ADR більше не потрібен. Refs: `pos-001`, `pos-011` (закрито рішенням, не кодом).
