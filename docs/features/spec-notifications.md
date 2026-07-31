# Notifications — Feature Spec (Phase 1, local-first)

**Status:** Draft
**Date:** 2026-07-31
**Owner:** Ivan
**Implements:** [[ADR-031-notifications]]
**Related:** ADR-012 (user data) · ADR-022 (analytics) · ADR-025 (AppPreferences) · ADR-005 (AppNavigationRouter) · ADR-028 (verse_org) · ADR-029 (UK licence) · `spec-reader-resume-position` · impl-reference `~/.agents/skills/push-notifications`

---

## 1. Problem Statement

SourceBible is a deep-study tool. New users install, explore once, and many never return — D1/D7/D30 retention is the gap. Generic devotional re-engagement (verse-of-the-day, streaks) is off-brand and would attract the wrong audience. We need notifications that pull the user back into **depth** and into **their own unfinished study**, respecting a trust-first, low-frequency ethos. Not solving it caps growth of the North Star (weekly users with ≥1 Meaningful Study Session).

## 2. Goals

1. Lift **D7 retention** (primary) and D1/D30 for new-user cohorts via well-timed, on-brand re-engagement.
2. Every notification either **returns the user to their own work** (channel A) or **demonstrates a tool only SourceBible has** (channel B `deep_dive`).
3. Keep it **trust-first**: quiet by default (provisional), trivial opt-out, ≤~8 touches / 30 days.
4. Feed **feature-adoption** funnel (ADR-022) — `deep_dive` taps drive original/parallel usage.
5. Ship **local-only** (no backend), leaving a clean seam for APNs (Phase 2).

## 3. Non-Goals

- **Remote / APNs** (announcements, OTA module releases) — Phase 2, needs infrastructure (ADR-027).
- **Streaks / reading-day tracking** — rejected as off-brand (gamification); no new day-counter store.
- **Verse-of-the-day (devotional)** — rejected; replaced by curated `deep_dive` (tool demo).
- **Weekly reflective digest** — post-MVP candidate.
- **Rich/actionable notifications, communication notifications, images** — Phase 2 (impl-skill covers).

## 4. Success Metrics

**Leading (days–weeks):**
- Provisional→full **permission conversion** ≥ 25% of engaged users (tap of first `deep_dive`). Measure via `notification permission` state events.
- **Notification open rate** (opened / scheduled) ≥ 8% overall; `deep_dive` ≥ 12%.
- `deep_dive` tap → `feature_adopted_original`/`parallel_translation` within session ≥ 40%.

**Lagging (weeks–months):**
- **D7 retention** of notification-enabled cohort vs disabled/holdout: **+X pp** (set holdout at launch).
- **D30 retention** uplift; increase in weekly users with ≥1 MSS.

**Measurement:** Mixpanel cohorts on `notification_scheduled`/`notification_opened` + permission state; evaluate at 2 wks (leading) and 4–8 wks (lagging). Keep a **holdout** (notifications off) for causal read.

## 5. User Stories

- As a **returning student**, I want to be reminded of the word study I left unfinished, so I can pick up my own train of thought — not a generic verse.
- As a **curious new user**, I want an occasional verse that reveals something I can only see with the original-language tools, so I understand why this app is different.
- As a **privacy-minded user**, I want notifications quiet and easy to turn off per-type, so I never feel nagged.
- As a **lapsing user**, I want a single well-timed nudge after I've been away, so returning feels inviting, not spammy.
- As **any user**, when I tap a notification, I want to land exactly on that verse/word with the right tool open, so there's zero friction.

## 6. Requirements

### P0 — Must have (MVP)

**P0-1 · Permission (hybrid).**
- On first launch, request **provisional** authorization silently (`.provisional`), no prompt.
- After the user's **first completed study moment** in-app (first word-study opened, or first commentary/cross-ref viewed), present an in-context **soft-ask** → system full-authorization prompt (`upgradeToFullAuthorization()`).
- Handle `.denied` gracefully: no re-prompt; Settings deep-link (`UIApplication.openSettingsURLString`) surfaced only from Menu → Notifications.
- Acceptance: Given a fresh install, When app launches, Then no permission dialog appears and provisional status is set. Given the user finishes a first word study, When the soft-ask shows and they accept, Then status becomes `.authorized`.

**P0-2 · Channel A — "Continue your study" (event-driven).**
- On app **background/foreground transition**, capture/refresh a **thread snapshot** (last word-study: `strongs_id`, `verse_ref`, `timestamp`; fallback: last reading position; fallback: last open note / cross-ref stack).
- If a snapshot exists and the user goes inactive, schedule an A notification per the lifecycle plan (D1, D7-if-thread, D14-lapsing) with content **baked from the snapshot**.
- Tap → deep-link to that word page / verse (§10).
- Acceptance: Given a user studied a word then closed the app, When ~20h pass with no open, Then an A notification referencing that word is delivered; tapping opens it.

**P0-3 · Channel B — curated verse (scheduled).**
- Deliver from the bundled pool (§8), rotating `encourage`/`deep_dive`, **no repeat until pool exhausted**, front-loaded per lifecycle (D4/D11/D18/D25), then tapered.
- Cadence is a **config value** (default set to what the seed pool sustains ≈ every 7–10 d in month 1, ~monthly after); governor caps frequency.
- `deep_dive` tap → deep-link to verse with the named tool open (parallel/original); `encourage` tap → reader at the verse.
- Acceptance: Given the pool has unseen verses, When a B slot fires, Then an unseen verse of the scheduled tag is shown; When all `deep_dive` seen, Then B falls back to `encourage`/none (never repeats within the unseen window).

**P0-4 · Scheduling model (recompute-on-transition).**
- No logic runs at delivery. On every foreground/background transition: **cancel all app-managed pending → recompute the full rolling horizon → re-add** discrete `UNNotificationRequest`s with baked content.
- Discrete triggers only (`repeats: false`); **never** a repeating trigger for rotating content.
- Rolling horizon bounded (≤ ~8 pending) to respect the **64-pending** app limit.
- Governor at schedule time: ≤1 push / 3 days; event-A cancels an overlapping B; skip a B if the user was active today; quiet hours + evening local window.
- Acceptance: Given the user opens the app mid-plan, When it foregrounds, Then pending notifications are recomputed and no duplicates exist; pending count ≤ horizon.

**P0-5 · Settings (Menu → Notifications).**
- Master toggle + per-type toggles (Continue study / Curated verse) + cadence picker + Settings deep-link when denied. Native `Form`/`Toggle`/`Label` (HIG); labels via LocalizedBundle (EN/UK).
- Stored in `AppStorageKeys` new *notification preferences* category (reset-safe; excluded from consent/migration clears).

**P0-6 · Deep-link routing.**
- Notification `userInfo` (category + target) → `AppNavigationRouter` (ADR-005). Cold-start: store pending route, consume when reader is ready (pattern of `pendingRestoreAnchorId`, `spec-reader-resume-position`). Refs resolved via `verse_org` (ADR-028) to the user's translation.

**P0-7 · Analytics (consent-gated, ADR-022).**
- `notification_scheduled`, `notification_opened` (props: `type` A/B, `content_tag`, `lifecycle_step`). Optional `notification_presented` (foreground `willPresent` only). Permission state change event.
- ⛔ **No `notification_delivered`** — not observable for local notifications.
- Gated on `analyticsEnabled`.

### P1 — Nice to have

- **Win-back** (D28, 7+ days silent) `deep_dive`.
- Cadence auto-scales as pool grows (bump default when unseen `deep_dive` count rises).
- Notification **thread grouping** (`threadIdentifier`) so repeated types collapse in Notification Center.
- Localized **evening delivery window** tuned per user's historical active hour.

### P2 — Future (design-compatible, not built)

- APNs channel (announcements, OTA modules) reusing `NotificationService` seam.
- Actionable buttons ("Open word", "Snooze 3 days").
- Semi-automatic `deep_dive` candidate generator (translations diverging on one Strong's).
- Weekly reflective digest.

## 7. Notification Copy

Refs stored in **canonical/English numbering**, resolved to the user's translation via `verse_org` on tap.

### 7.1 Channel A templates (baked from snapshot)

| Case | EN | UK |
|---|---|---|
| word-study | "Pick up your study of **{word}** ({strongs}) in {ref}." | "Продовж дослідження **{word}** ({strongs}) у {ref}." |
| reading position | "Continue reading where you left off — {book} {chapter}." | "Продовж читання, де зупинився — {book} {chapter}." |
| open note | "Your note on {ref} is waiting." | "Твоя нотатка до {ref} чекає." |

### 7.2 Channel B — see the seed pool (§8) for per-verse teasers.

## 8. Curated Verse Pool (starter seed)

Bundled resource `Resources/notification_verses.json`. Teasers are **our original UX copy**, not verbatim translation quotes. Schema per verse: `id, ref, tag, strongs_id?, tool, teaser{en,uk}`.

> **Note (2026-07-31):** this is now a **design choice, not a licensing constraint.** The UK licence blocker is gone — Ohienko (UBIO) is CC BY-SA by direct УБТ/UBS grant (ADR-029, unblocked 2026-07-31), and UBIO already ships in core `sourcebible.db`. Verbatim UK verse quoting in teasers is therefore **available** if we want it. Keeping teasers as original invitational copy stays defensible on brand grounds — a teaser should invite into the tool, not substitute for opening the verse — but that is now Ivan's product call, not something forced by legal. If we do quote verbatim, CC BY-SA attribution is already satisfied by the Menu → About licence list.

### 8.1 `deep_dive` (≈8 — premium, front-loaded)

| id | ref | strongs | tool | teaser EN | teaser UK |
|---|---|---|---|---|---|
| dd_isa_7_14 | Isaiah 7:14 | H5959 עַלְמָה | parallel | "Isaiah 7:14 — 'virgin' or 'young woman'? One Hebrew word, עַלְמָה, split the translations." | "Ісая 7:14 — 'діва' чи 'молода жінка'? Одне слово עַלְמָה розділило переклади." |
| dd_ps_22_16 | Psalm 22:16 | — | original | "Psalm 22:16 — 'they pierced my hands' or 'like a lion'? One Hebrew form divides the manuscripts." | "Псалом 22:16 — 'прокололи руки' чи 'як лев'? Одна форма розділяє рукописи." |
| dd_php_2_6 | Philippians 2:6 | G725 ἁρπαγμός | parallel | "Philippians 2:6 — did Christ not 'grasp' equality, or not 'cling' to it? One of the NT's hardest words." | "Филип'ян 2:6 — Христос не 'вхопився' за рівність чи не 'тримався' її? Одне з найважчих слів НЗ." |
| dd_rom_9_5 | Romans 9:5 | — | parallel | "Romans 9:5 — where does the sentence end? A comma decides whether Christ is called 'God over all'." | "Римлян 9:5 — де кінець речення? Кома вирішує, чи названо Христа 'Богом над усім'." |
| dd_jhn_1_1 | John 1:1 | G2316 θεός | original | "John 1:1 — 'the Word was God': the Greek word order and article behind centuries of debate." | "Івана 1:1 — 'Слово було Бог': грецький порядок слів і артикль за століттями дискусій." |
| dd_gen_1_1 | Genesis 1:1 | H7225 רֵאשִׁית | original | "Genesis 1:1 — 'In the beginning God created' or 'When God began to create'? The grammar of verse one." | "Буття 1:1 — 'На початку Бог створив' чи 'Коли Бог почав творити'? Граматика першого вірша." |
| dd_ps_23_6 | Psalm 23:6 | — | original | "Psalm 23:6 — 'dwell in the house of the LORD' or 'return'? One vowel changes the psalm's ending." | "Псалом 23:6 — 'перебуватиму в домі Господньому' чи 'повернуся'? Одна голосна змінює кінець псалма." |
| dd_jhn_3_16 | John 3:16 | G3439 μονογενής | original | "John 3:16 — 'only begotten' or 'one and only' Son? What μονογενής really means." | "Івана 3:16 — 'єдинородний' чи 'єдиний' Син? Що насправді означає μονογενής." |

### 8.2 `encourage` (≈14 — cheap backbone; teaser = our invitation + ref, EN quotes may use PD KJV/ASV)

| id | ref | tool | teaser EN | teaser UK |
|---|---|---|---|---|
| en_ps_1_2 | Psalm 1:2 | reader | "To meditate on His law day and night — the mark of the blessed. (Psalm 1:2)" | "Роздумувати над законом Його день і ніч — ознака блаженного. (Псалом 1:2)" |
| en_jos_1_8 | Joshua 1:8 | reader | "Meditate on it — then live it. (Joshua 1:8)" | "Роздумуй над ним — і живи ним. (Іс. Навина 1:8)" |
| en_ps_119_105 | Psalm 119:105 | reader | "A lamp to your feet, a light to your path — open the Word. (Psalm 119:105)" | "Світильник для ніг і світло для стежки — відкрий Слово. (Псалом 119:105)" |
| en_2ti_3_16 | 2 Timothy 3:16 | reader | "All Scripture is God-breathed and profitable. (2 Timothy 3:16)" | "Усе Писання богонатхненне й корисне. (2 Тимофія 3:16)" |
| en_heb_4_12 | Hebrews 4:12 | reader | "The Word is living and active, sharper than any sword. (Hebrews 4:12)" | "Слово живе й діяльне, гостріше від усякого меча. (Євреїв 4:12)" |
| en_jas_1_22 | James 1:22 | reader | "Be a doer of the Word, not a hearer only. (James 1:22)" | "Будь виконавцем Слова, а не тільки слухачем. (Якова 1:22)" |
| en_act_17_11 | Acts 17:11 | reader | "Like the Bereans — examine the Scriptures daily. (Acts 17:11)" | "Як віряни — досліджуй Писання щодня. (Дії 17:11)" |
| en_ps_119_18 | Psalm 119:18 | reader | "Open my eyes to see wonders in Your law. (Psalm 119:18)" | "Відкрий очі, щоб бачити чуда в законі Твоєму. (Псалом 119:18)" |
| en_mat_4_4 | Matthew 4:4 | reader | "We live by every word from God's mouth. (Matthew 4:4)" | "Живемо кожним словом з уст Божих. (Матвія 4:4)" |
| en_col_3_16 | Colossians 3:16 | reader | "Let the word of Christ dwell in you richly. (Colossians 3:16)" | "Нехай слово Христове живе у вас багато. (Колосян 3:16)" |
| en_ps_19_7 | Psalm 19:7 | reader | "The law of the LORD is perfect, reviving the soul. (Psalm 19:7)" | "Закон Господній досконалий, оживляє душу. (Псалом 19:7)" |
| en_jer_15_16 | Jeremiah 15:16 | reader | "His words became a joy and the delight of the heart. (Jeremiah 15:16)" | "Слова Твої стали радістю й потіхою серця. (Єремії 15:16)" |
| en_ps_119_11 | Psalm 119:11 | reader | "Store His word in your heart. (Psalm 119:11)" | "Заховай Слово Його у серці своєму. (Псалом 119:11)" |
| en_isa_55_11 | Isaiah 55:11 | reader | "His word does not return empty. (Isaiah 55:11)" | "Слово Його не вертається порожнім. (Ісая 55:11)" |

> **Curation note:** `deep_dive` teasers are **evenhanded** — they pose the crux, never resolve it doctrinally. Grow the pool via minor updates; `deep_dive` is the scarce/premium set, `encourage` the sustainable backbone.

## 9. Components (Swift, `Services/`)

- **`NotificationService`** (`@MainActor`) — auth (`.provisional` + `upgradeToFullAuthorization()`), `add`/`removePending`, `UNUserNotificationCenterDelegate` (`willPresent` → `.banner/.list/.sound`; `didReceive` → router). Delegate set in `App.init`.
- **`NotificationScheduler`** — recompute-on-transition: reads state, computes lifecycle step + governor, builds bounded rolling horizon, cancels+re-adds discrete requests. Stable identifiers per role/slot.
- **`NotificationContentProvider`** — loads `notification_verses.json`, selects next unseen by tag (no-repeat via seen-set), applies front-load/backbone rules, resolves localized teaser (inline).
- **`StudyThreadTracker`** (or extend `SessionTracker`) — captures thread snapshot from word-tap / `ReaderViewModel`.
- **`AppStorageKeys`** additions (ADR-025, *notification preferences*): `notificationsMasterEnabled`, `notifyContinueStudy`, `notifyCuratedVerse`, `notifyCadenceDays`, `notifLastDelivery`, `notifSeenIds`, `notifThreadSnapshot`, `notifPermissionSoftAsked`.
- **Menu → NotificationsSettingsView** — `Form` with toggles + cadence + denied-state Settings link.
- App lifecycle hook (scenePhase background/active) → `NotificationScheduler.recompute()`.

## 10. Data Flow (deep-link)

```
tap → NotificationDelegate.didReceive(userInfo)
    → parse {category: "A"|"B", target: word|verse, ref, strongs?, tool}
    → AppNavigationRouter.pending = route         (cold-start safe)
    → RootView.onChange(router.pending): resolve ref via verse_org → open reader/word/tool, clear pending
```

## 11. iOS API Notes

- Discrete `UNCalendarNotificationTrigger`/`UNTimeIntervalNotificationTrigger`, `repeats: false`. Refill horizon on foreground. Respect 64-pending.
- `interruptionLevel = .active` (not `.timeSensitive`).
- iOS 18: `UserNotifications` fully available — no `#available` guard. Swift 6 strict-concurrency: delegate + service `@MainActor`.
- Badge: reset on `.active` (`setBadgeCount(0)`, iOS 16+).
- Do NOT copy impl-skill's `scheduleDailyReminder` (`repeats:true`) for channel B.

## 12. Test Plan

- **Unit:** `NotificationScheduler` recompute is idempotent (no dupes; horizon ≤ cap); governor rules (≤1/3d; event beats scheduled; skip-if-active); `NotificationContentProvider` no-repeat until exhausted, then fallback.
- **Sim (launch-args, ref [[reference_sim_qa_launch_args]]):** seed a thread snapshot + fast-forward "days since install" via launch arg → assert the expected lifecycle notification is scheduled; tap-route lands on correct verse/word (verify with existing `-lastRead*` open + screenshot).
- **Permission:** provisional set silently at launch; soft-ask after first study; denied path shows Settings link, no re-prompt.
- **Deep-link cold start:** kill app → deliver → tap → app opens directly to verse/word/tool.
- **Build:** Debug + **Archive** green (watch `#Preview` sample-data rule); Swift 6 clean.

## 13. Work Order (implementation, separate branch)

1. **Slice 1 — plumbing:** `NotificationService` (auth provisional + delegate + deep-link to router), `AppStorageKeys` category, Menu settings shell. Provisional at launch; tap routes. *No content yet.*
2. **Slice 2 — content + B:** `notification_verses.json` seed (§8), `NotificationContentProvider`, `NotificationScheduler` (recompute + horizon + governor), channel B scheduled. Soft-ask hook after first study.
3. **Slice 3 — A:** `StudyThreadTracker` snapshot, channel A event-driven + win-back (P1).
4. **Slice 4 — analytics + polish:** `notification_*` events (consent-gated), thread grouping (P1), cadence auto-scale (P1). Holdout flag for retention read.

## 14. Open Questions

- ~~**UK verse text licence (blocking for any verbatim UK quote).**~~ **RESOLVED 2026-07-31.** Ohienko (UBIO) is licensed CC BY-SA by direct grant from УБТ/UBS covering pre-1991 editions, incl. the 1988 edition we bundle (ADR-029 unblocked; attribution added to Menu → About). Nothing in this spec is legally gated any more. What remains is a product question, not a legal one: **do UK `encourage` teasers stay original invitational copy, or quote UBIO verbatim?** Spec currently assumes original copy (§8). *(Owner: Ivan — product call.)*
- **First "study moment" definition for the soft-ask** — first word-study open only, or any of original/lexicon/commentary/cross-ref? Ties to ADR-022 `recordFeatureUse`. *(Owner: Ivan / eng.)*
- **Default cadence value** for month-1 vs steady-state given the 8+14 seed. *(Owner: data, tune post-launch.)*
- **Holdout size** for causal retention read without starving the treatment. *(Owner: data.)*
- **Evening delivery window** — fixed (e.g. 19:00 local) for MVP, or learned from active hour (P1)? *(Owner: Ivan.)*

## 15. Out of Scope (this spec)

APNs/remote, streaks, digest, rich/communication notifications, actionable buttons, image cards, semi-auto `deep_dive` generation — see ADR-031 §OUT and P2.
