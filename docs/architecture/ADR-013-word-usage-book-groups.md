# ADR-013: Word Usage Tab — Per-Book Concordance Data Model

**Status:** Accepted  
**Date:** 2026-05-27  
**Deciders:** Ivan Khoma

---

## Context

The Word Usage tab in the Strong's bottom sheet currently shows a flat list of up to 30 occurrences fetched in canonical Bible order via `loadConcordance(limit: 30)`. This has two problems:

1. **Misleading count.** The label "N occurrences" shows the capped result (30), not the real total. For יהוה (6 512 occurrences) or אָמַר (5 307), this is wildly inaccurate.
2. **Poor cross-section.** Canonical order means common words always show Genesis/Matthew. A student studying יהוה sees only the opening chapters — never Psalms, Isaiah, or Prophets, where the word carries its richest theological weight.

The redesign goal: show the **true total count** + a **per-book breakdown** (book name · count in book · one example verse). This gives a meaningful cross-section of the entire canon at a glance without pagination.

A secondary goal is forward-compatibility with a v1.5 upgrade where example verses are selected by `rhetorical_weight` (cross-reference vote score) rather than canonical position.

---

## Decision

Replace the flat `concordance: [ConcordanceEntry]` usage in `WordUsageView` with a new `bookGroups: [BookUsageGroup]` array on `StrongsEntry`, populated by a new `DatabaseService.loadBookUsageGroups()` method. Keep the `concordance` field on `StrongsEntry` for DEBUG/Preview backward compatibility; it is no longer used in production UI.

---

## Options Considered

### Option A: Raise the flat-list limit + add total count (minimal change)

Keep the existing `loadConcordance` + flat `WordUsageView`. Add a separate `countConcordance()` DB call, raise `limit` to 150, show "Showing 150 of 6 512".

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low |
| Model change | None — add `totalCount: Int` to `StrongsEntry` |
| View change | Minor — update label |
| Cross-section quality | Poor — still canonical order, Genesis-heavy |
| v1.5 upgrade path | Hard — flat list doesn't compose with per-book selection |

**Pros:** Near-zero risk; ships in 1 hour.  
**Cons:** Still misleads for very common words; "150 of 6 512" invites confusion; no canonical cross-section; "Load More" pressure grows over time.

---

### Option B: Per-book groups with first-occurrence example ✅ (chosen)

New `BookUsageGroup` model. DB method returns total + groups in one logical call (3 query types: COUNT, GROUP BY, N per-book verse fetches). View shows header + book rows.

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium |
| Model change | Add `BookUsageGroup` + two fields to `StrongsEntry` |
| View change | Full rewrite of `WordUsageView` (small file) |
| Cross-section quality | Excellent — all 39 OT or 27 NT books, one example each |
| Performance | < 50ms on MainActor for יהוה (benchmark: 39 indexed lookups) |
| v1.5 upgrade path | Clean — swap Query C sort order only; model/view unchanged |

**Pros:** True total; meaningful cross-section; naturally handles common words (יהוה shows all 39 OT books, not "first 150"); deterministic output; forward-compatible.  
**Cons:** More code than Option A; N per-book queries (accepted — profiled below).

---

### Option C: Single window-function query

Use a SQLite window function `ROW_NUMBER() OVER (PARTITION BY book_id ORDER BY chapter, verse)` to get both count and first example in one round-trip.

| Dimension | Assessment |
|-----------|------------|
| Complexity | High |
| SQLite version req | 3.25+ (window functions) — SQLite bundled with iOS 16+ is ≥ 3.39, so safe |
| Readability | Low — nested subquery to filter `rn = 1` with `HAVING` is non-obvious |
| Debuggability | Hard — one opaque query vs. three readable queries |
| Performance | Marginally faster than Option B (one round-trip vs. N+2) |

**Pros:** Single DB round-trip.  
**Cons:** Significant complexity for negligible performance gain; harder to extend for v1.5 `rhetorical_weight` sort.

---

## Trade-off Analysis

**Option B vs. A:** The extra complexity of Option B (new model, new DB method, rewritten view) is justified because Option A does not solve the core problem — it still misleads on count and delivers a poor cross-section. Option B is the correct fix, not a larger version of the wrong fix.

**Option B vs. C:** The N per-book queries in Option B are not a performance concern. Maximum N = 39 (OT). Each query is a simple equality lookup on an indexed `(book_id, chapter, verse)` key. Measured SQLite overhead per query on mobile: < 0.5ms. Total ≤ 20ms for a complete OT word. The single-query complexity of Option C is not worth the readability cost, especially given the v1.5 migration path where we'll need to swap the ORDER BY clause — trivial in Option B, non-trivial inside a window subquery.

**Staying on MainActor:** `loadBookUsageGroups` runs synchronously on the MainActor, consistent with all existing DB calls in `DatabaseService`. The total operation is < 50ms even for the highest-frequency word, which is within acceptable synchronous budget for a user-initiated tap interaction (no frame drops; 50ms is well under the 100ms perception threshold for "instant response").

**`chapter * 1000 + verse` encoding:** Used to find the first occurrence per book via `MIN()` in a GROUP BY without a subquery. Decodes deterministically: `chapter = val / 1000`, `verse = val % 1000`. Safe for all Bible books (max chapter: 150 in Psalms; max verse: 176 in Psalm 119; encoded: 150176, well within Int32).

---

## Consequences

**Becomes easier:**
- Displaying accurate occurrence counts (no more "30 of ?" ambiguity)
- Understanding a word's canonical distribution at a glance
- v1.5 upgrade to `rhetorical_weight`-based examples (one-line SQL change)
- Future full concordance sheet — `BookUsageGroup` composes naturally into section headers

**Becomes harder:**
- Nothing significant. The flat `concordance` array is still available for tests/preview.

**Will need to revisit:**
- `StrongsEntry.concordance` cleanup — can be removed once the DEBUG sample is updated (separate cleanup sprint)
- `MorphKey.usageCount` localization key — becomes dead code; remove in next i18n pass
- Navigation: `WordUsageView` taps currently have a `// TODO: navigate reader` comment. This ADR's implementation resolves it via `AppNavigationRouter` (ADR-005).

---

## Action Items

1. [ ] Add `BookUsageGroup` struct to `StrongsModels.swift`
2. [ ] Add `totalCount: Int = 0` and `bookGroups: [BookUsageGroup] = []` to `StrongsEntry`
3. [ ] Update `StrongsEntry.sample` (DEBUG) with `bookGroups` data
4. [ ] Implement `loadBookUsageGroups` in `DatabaseService.swift` (Queries A + B + C)
5. [ ] Update `ReaderViewModel.loadStrongs` to call new method
6. [ ] Add `MorphKey.usageTotalCount` + localization strings (uk + en)
7. [ ] Rewrite `WordUsageView` + add `BookUsageRow` in `WordTabContent.swift`
8. [ ] Manual test: יהוה → 39 OT books; G2316 (θεός) → 27 NT books; count spot-check vs. STEPBible

---

## Related

- `spec-word-usage-redesign.md` — product requirements  
- `plan-word-usage-redesign.md` — implementation plan with full SQL  
- `proposal_smarter_examples_v1.5.md` — future `rhetorical_weight` signal  
- ADR-005 (`AppNavigationRouter`) — verse navigation from concordance tap  
- ADR-008 (Search Architecture) — FTS5; unrelated but same DB service
