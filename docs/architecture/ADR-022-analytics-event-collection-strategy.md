# ADR-022: Analytics Event-Collection Strategy (adoption events + rich session summary)

**Status:** Accepted
**Date:** 2026-06-20
**Deciders:** Ivan
**Related:** [[PDR-Analytics-Mixpanel]] · `spec-analytics-mixpanel` · [[ADR-012-unified-user-data-layer]]

## Context

Slice 2 shipped engagement/search analytics. Slice 3 adds feature-adoption signals (lexicon/Strong's, commentary, cross-references, parallel translations, word usage). The first Slice 3 draft fired a **discrete event per interaction** (e.g. `strongs_viewed` on every word inspected). In a deep study session that is dozens of events; multiplied across users it threatens the Mixpanel **free-tier ceiling (1M events/month)** — the very ceiling that triggers the costly swap to another backend.

Forces:
- Need **adoption funnels** ("did the user ever use feature X?") — a discrete signal.
- Need **depth signals** for the North Star (Meaningful Study Session) — how *much* each tool was used.
- Must keep event volume low (free-tier; trust-first ⇒ minimal data).
- No raw user content (D1), anonymous (PreAuthIdentity).

## Decision

Split signals by what each is for, not by "one event per tap":

1. **Adoption = one discrete event per feature, once per session** (fired on first use that session). Features are **granular — one per UI surface** (NOT an umbrella), so each maps 1:1 to what the user actually did and the word-study funnel is visible:
   `feature_adopted_original` (original-words list) → `feature_adopted_lexicon` (a word's Strong's definition / `WordMeaningView`) → `feature_adopted_concordance` (word usage / `ConcordanceView`), plus `feature_adopted_commentary`, `feature_adopted_cross_reference`, `feature_adopted_parallel_translation`.
   These answer "who adopts what" with at most 6 events/session, and the first three form the word-study drop-off funnel (open original → drill into lexicon → check concordance). See [[glossary]] for the term distinctions (original ≠ lexicon ≠ concordance — the BibleHub "NASB Lexicon" word-by-word view blurs these).

2. **Depth = counters rolled into `study_session_summary`** (one event per session, on background+grace):
   `duration_s`, `verses_opened`, `word_nav_count` (chevron moves between words in the Word tab), `verse_nav_count`, `searches_count`, `annotations_created`, plus per-feature `<raw>_views_count` for each `AnalyticsFeature` (`original_views_count`, `lexicon_views_count`, `concordance_views_count`, `commentary_views_count`, `cross_reference_views_count`, `parallel_translation_views_count`).

3. **Kept discrete (already low-volume, high-value):**
   - `app_opened` (one per foreground).
   - `search_committed` / `search_result_opened` — search quality funnel (zero-result rate, result position). Search is occasional, not per-word; its rich events stay. *Search adoption is derivable from "≥1 `search_committed`", so no separate `feature_adopted_search` event is emitted.*
   - `note_created` / `highlight_created` (color) / `bookmark_created` — deliberate, low-frequency actions; discrete events are cheap and useful. Also counted as `annotations_created`.
   - `translation_switched` (from, to) — deliberate, low-frequency.

4. **`SessionTracker` owns the once-per-session logic via a single generic entry point.** Views/VMs call `tracker.recordFeatureUse(.lexicon)` (one method, an `AnalyticsFeature` enum case — NOT a method per feature). The tracker (a) emits `feature_adopted_<raw>` the first time that feature is used in the session, and (b) increments `featureCounts[feature]`. Adding a tool in a future slice = **one new `AnalyticsFeature` case**; the adoption event and the `<raw>_views_count` summary field (iterated over `AnalyticsFeature.allCases`) come for free with no new code. The adoption event is a single `featureAdopted(AnalyticsFeature)` case, not one case per feature.

**Per-session event budget:** ~1 `app_opened` + ≤6 `feature_adopted_*` + a few search/annotation/translation events + 1 `study_session_summary` ≈ **<15 events even for a deep session**, versus 50+ under the per-tap design.

## Options Considered

### Option A — Discrete event per interaction (original draft)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Low (fire-and-forget at each call site) |
| Cost (volume) | **High** — `strongs_viewed` per word inspected |
| Analytics power | High granularity (per-view timeline) |

**Pros:** simplest call sites; per-view timestamps.
**Cons:** highest volume; fastest path to the free-tier ceiling; granularity we don't actually need for the North Star.

### Option B — Adoption-once + counters in summary (chosen)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium (session-scoped counters + once-per-session guards in `SessionTracker`) |
| Cost (volume) | **Low** — bounded per session |
| Analytics power | Adoption funnels + depth distributions; loses per-view timestamps (not needed) |

**Pros:** bounded volume; depth lives in one tunable event; adoption still funnel-able; matches the existing counter pattern (verses/nav) from Slice 2.
**Cons:** loses fine-grained per-view timing; counters must be reset/guarded correctly per session (more `SessionTracker` logic).

### Option C — Everything in `study_session_summary` (no discrete adoption)
**Pros:** absolute minimum volume (1 event/session).
**Cons:** can't build time-ordered adoption funnels or first-touch analysis; harder to see *when* in the journey a feature is first used. Rejected — adoption funnels are worth 4 small events.

## Trade-off Analysis

The granularity we sacrifice (per-view timestamps) is not used by the North Star or adoption analysis; the volume we save is the difference between staying on free-tier and hitting the swap trigger early. Keeping search/annotation/translation discrete is justified because they are already low-frequency and their per-event properties (zero-result rate, highlight color, from→to) carry real analytical value that a counter would erase.

## Consequences

- **Easier:** staying under free-tier; tuning MSS from the rich summary; reasoning about a session as one record.
- **Harder:** `SessionTracker` grows (per-feature counters + once-per-session adoption guards); call sites must route through the tracker rather than calling `analytics.track` directly for study-tool views.
- **Revisit:** if a discrete per-view timeline is ever needed (e.g. dwell-time per Strong's entry), add a sampled or opt-in detailed stream. The `AnalyticsService` abstraction (PDR) makes the eventual backend swap cheap regardless.
- **Pre-prod tuning (data-driven, Slice 4):** before the public release, review event volume + value on real beta data and trim. Candidates: dedup `lexicon_views_count` to unique Strong's IDs (a Set, like `verses_opened`) if "unique words studied" is wanted rather than raw view count; reassess low-value props like `highlight_created.color`; drop any discrete event that the summary counters already cover. Decide with actual distributions, not upfront. (The original/lexicon/concordance double-count framing is resolved by the granular split — each surface now counts itself.)

## Action Items

1. [x] Add `AnalyticsFeature: String, CaseIterable` enum — **6 granular cases** (`original`, `lexicon`, `concordance`, `commentary`, `crossReference="cross_reference"`, `parallelTranslation="parallel_translation"`). Update `AnalyticsEvent`: single `featureAdopted(AnalyticsFeature)` case (name `feature_adopted_<raw>`); expand `studySessionSummary` (per-feature `<raw>_views_count` from `allCases` + `word_nav_count`, `verse_nav_count`, `verses_opened`, `searches_count`, `annotations_created`); remove the per-tap `strongsViewed`/`commentaryOpened`/`crossRefOpened`/`wordUsageOpened`/`originalOpened`/`studyTabSwitched` cases.
2. [x] `SessionTracker`: `featureCounts: [AnalyticsFeature: Int]` + `adopted: Set<AnalyticsFeature>` + one generic `recordFeatureUse(_ f: AnalyticsFeature)` that emits `feature_adopted_<raw>` once then counts. (`annotations_created` stays an aggregate counter — per-type detail already lives in the discrete `note_created`/`highlight_created`/`bookmark_created` events.)
3. [x] Call sites: `.original` pill → `recordFeatureUse(.original)`; `WordMeaningView` → `.lexicon`; `ConcordanceView` (renamed from `WordUsageView`) → `.concordance`; commentary/crossRefs/translations pills → their features. `incWordNav()` (renamed from `incLexiconNav`) on word chevrons.
3. [ ] Rewire Slice 3 call sites to `tracker.recordX()` (see `spec-analytics-mixpanel` → Slice 3 Work Order).
4. [ ] Update MSS definition (Mixpanel Custom Event) to use the new counter names.
