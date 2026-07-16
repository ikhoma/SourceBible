# ADR-016: Original Pill — NASB-Gated Clickability, Unified Word Page, and Verse Text Highlight

**Status:** Accepted
**Date:** 2026-06-02
**Deciders:** Ivan
**Relates to:** `spec-original-nasb-bridge.md`, supersedes `unified_word_lookup_system_design.md`

---

## Context

The Original pill (Оригінал) in the verse bottom sheet displays Macula Hebrew/Greek words. Three UX problems were identified:

1. **All words are tappable, including grammatical particles** (prepositions בְּ, conjunctions וְ, definite article הָ). Particles have no lexical meaning and tapping them opens a mostly empty Word detail page.

2. **Two entry paths produce different detail pages.** Tapping a word in the Original pill shows full data (morphology, xlit, Greek equivalent). Long-pressing the same word in the verse text shows only the Strong's lexical entry.

3. **Chevron navigation (← →) in Word mode cycles all Macula words**, including particles. The selected word is not highlighted in the verse text when arriving from an Original pill tap.

Additionally, sub-entry Strong's IDs (H835**a**, H3887**a**) do not match base numbers in NASB parsed segments (H835), causing `syncSegment` and `selectedWordDisplayText` to fall through to Hebrew text instead of the translation word.

---

## Decision

**Use NASB Strong's tags as the primary clickability gate (Option A), with a script-generated 391-entry override map for NASB proprietary extended numbers (H9000+), and a morphology-based fallback for the remaining 212 unresolved extended-number cases.**

---

## Options Considered

### Option C: Morphology code gate (rejected after full-Bible analysis)

Mark a word as non-clickable if its morphology starts with `R` (preposition), `C` (conjunction), or `T` (particle/article).

**Rejected because:** Full-Bible analysis across 607,244 Macula words showed this rule blocks 28,000+ words that NASB explicitly tags and users expect to click:

| Word | Strong's | Morph | Occurrences blocked |
|------|----------|-------|---------------------|
| אֲשֶׁר | H834 | Tr | 4,163× |
| עַל | H5921 | R | 2,300× |
| לֹא | H3808 | Tn | 1,915× |
| מִן | H4480 | R | 1,677× |
| כִּי | H3588 | C | 1,355× |
| הִנֵּה | H2009 | Tm | 978× |

These are content words (relative pronouns, standalone prepositions, negatives, key conjunctions) with full BDB/Thayer lexical entries. The R/C/T heuristic was only accurate for prefix particles (בְּ, וְ, הַ) — it cannot distinguish these from standalone words with the same morphological category. Agreement with NASB: 77.2%.

### Option A: NASB base-number match + override map (accepted ✅)

Mark a word as clickable if its Strong's base number appears in the NASB `<S>NNN</S>` markup for the same verse.

**NASB extended numbers (H9000+):** NASB uses 603 proprietary numbers not in the standard Strong's range. A Python script (`scripts/generate_nasb_override.py`) resolved 391 (64.8%) via gloss matching. The remaining 212 use morphology fallback: non-clickable only if morph is `Td` (definite article), `Sp*`/`Sd` (pronominal suffix), or `ART-` (Greek article) — the only categories NASB never tags as standalone lexemes.

| Dimension | Assessment |
|-----------|------------|
| Accuracy | High — directly honours NASB tagging; handles 99%+ of words via direct match |
| Extended numbers | 603 unique; 391 auto-resolved; 212 use safe morph fallback |
| Runtime cost | One extra DB read per verse (NASB verse text, ~0.1ms) |
| Maintenance | Override map is source-generated; can be regenerated with the script |

---

## Implementation

### New file: `Services/NASBExtendedOverride.swift`

Auto-generated 391-entry Swift dictionary. Maps NASB extended base number (String) → Macula base number (String). Example: `"9238": "3887"` (H9238 לֵצִים = H3887a in Macula).

### `Services/DatabaseService.swift`

New method `loadNASBStrongs(bookId:chapter:verse:) -> Set<String>`: fetches raw NASB verse text and extracts all `<S>NNN</S>` numbers. Fast substring scan, no regex.

### `ViewModels/ReaderViewModel.swift`

**New state:** `@Published var nasbVerseStrongs: Set<String>` — base numbers from NASB for the focused verse, loaded once per verse via `loadNASBStrongs(for:)`, which also applies the extended override map.

**New helpers:**
- `baseStrongsNumber(_ id: String) -> String` — strips H/G prefix and letter suffix: "H835a" → "835"
- `isClickable(_ word: BibleWord) -> Bool` — NASB primary check + override + morph fallback
- `var nasbClickableWords: [BibleWord]` — filtered list driving chevron navigation

**Fixed methods:**
- `loadWordsForSelectedVerse()` — now calls `loadNASBStrongs(for:)` after loading Macula words
- `tapWord(_ segment:)` — bridges to `BibleWord` via `baseStrongsNumber` so `WordMeaningView` gets full morphology/xlit/greek from both entry paths
- `tapWord(_ word:)` — replaced `selectedSegment = nil` with `syncSegment(for: word)` so verse text highlights on Original pill tap
- `syncSegment(for:)` — uses `baseStrongsNumber` comparison to handle sub-entry mismatches (H835a ↔ H835)
- `selectedWordDisplayText` — same base-number fix for the Word tab title
- `navigatePreviousWord/NextWord`, `autoSelectFirstWordIfNeeded` — use `nasbClickableWords`

### `Views/BottomSheet/VerseTabContent.swift`

`OriginalWordsView`: removed the old `filter { $0.strongsId != nil }` (was a no-op in practice). Now passes `isClickable: vm.isClickable(word)` to `WordRow`.

### `Views/BottomSheet/WordTabContent.swift`

`WordRow`: added `isClickable: Bool`. Non-clickable rows render as plain `HStack` (no `Button`, no chevron, text dimmed, gloss hidden). Clickable rows behave as before.

### `Views/BottomSheet/VerseBottomSheetView.swift`

`isPrevDisabled` / `isNextDisabled` use `vm.nasbClickableWords` instead of `vm.verseWordsWithStrongs`.

---

## Consequences

**What becomes easier:**
- Original pill and verse-text long-press produce identical Word detail pages.
- Chevron steps through meaningful words only, skipping articles and prefix particles.
- Verse text highlight follows both entry points (Original pill tap and chevron navigation).
- Sub-entry IDs (H835a, H3887a) align correctly with NASB segment text for titles and highlights.

**What becomes harder / to revisit:**
- `verseWordsWithStrongs` is now a legacy property — deprecate once `nasbClickableWords` is confirmed stable (one sprint).
- The override map covers 64.8% of extended numbers. Re-running `generate_nasb_override.py` with better NLP (fuzzy lemma matching) could improve coverage. Not blocking.
- The `verse_markup` canonical DB table (from `unified_word_lookup_system_design.md`) remains valid as a long-term V1.5 project: it would unify Strong's tagging across KJV/ASV/RST and make NASB loading unnecessary.

---

## Verification Checklist

| Scenario | Expected |
|----------|----------|
| Tap H835a (אַשְׁרֵי) in Original pill | Full word detail; title "How blessed"; verse highlights "How blessed" |
| Tap H871a (בַּ) row in Original pill | No navigation; row dimmed, no chevron, no gloss |
| Tap H834 (אֲשֶׁר "who") in Original pill | Full word detail (not blocked by R/C/T rule) |
| Tap H3808 (לֹא "not") in Original pill | Full word detail (not blocked by R/C/T rule) |
| Long-press "blessed" in verse text | Same full detail as tapping from Original pill |
| Long-press "the" or "and" | No Word detail opens |
| Chevron ← → in word mode (Ps 1:1) | 14 words; skips 7 particles; verse highlight follows |
| Title in Word tab header | Translation word ("How blessed"), not Hebrew (אַשְׁרֵי) |

---

## Action Items (all implemented)

- [x] `NASBExtendedOverride.swift` — 391-entry generated dictionary
- [x] `DatabaseService.loadNASBStrongs` — NASB Strong's loader
- [x] `ReaderViewModel.nasbVerseStrongs` + `loadNASBStrongs(for:)`
- [x] `ReaderViewModel.baseStrongsNumber`, `isClickable`, `nasbClickableWords`
- [x] `ReaderViewModel.loadWordsForSelectedVerse` — loads NASB strongs after Macula words
- [x] `ReaderViewModel.tapWord(_ word:)` — `syncSegment` instead of `selectedSegment = nil`
- [x] `ReaderViewModel.tapWord(_ segment:)` — BibleWord bridge
- [x] `ReaderViewModel.syncSegment` — base-number matching
- [x] `ReaderViewModel.selectedWordDisplayText` — base-number segment lookup
- [x] `ReaderViewModel` navigation — use `nasbClickableWords`
- [x] `OriginalWordsView` — pass `isClickable` to `WordRow`
- [x] `WordRow` — conditional Button + chevron + gloss
- [x] `VerseBottomSheetView` — `nasbClickableWords` for disabled states

---

## Amendment 2026-06-22: Per-translation clickability gate + canonical word↔segment mapping

**Status:** Accepted · **Deciders:** Ivan · **Relates to:** P0 lexicon test; supersedes the NASB-set gate of Option A above. Phase 2 spec (cross-translation unification) to follow.

### Context

P0 lexicon testing surfaced three coupled defects, all rooted in the **dual-source** design of Option A — clickability is gated by **NASB**, while highlight and navigation read the **displayed** translation:

1. Words NASB-tags but the displayed translation does not render as **dead clickable rows** (clickable in the Original pill, but no verse highlight and skipped by chevron navigation).
2. Word `← →` navigation auto-selected the **first word in Hebrew order**, not translation order, and skipped earlier words.
3. Repeated words (e.g. לֹא…לֹא…לֹא) **jumped to a previous instance**: `tapWord(segment)` resolved the tapped segment to `words.first` by base number, ignoring which occurrence was tapped.

### Measurement (`scripts/measure_strongs_coverage.py`, 2026-06-22)

All four bundled modules are Strong's-tagged with comparable density. **Word-level clickable coverage per gate:** ASV 52.2% · KJV 52.6% · **NASB 51.4%** · RST 53.8%. The premise behind Option A (NASB maximizes tagged words) **does not hold** — NASB is the lowest. Modules are not subsets of one another (each tags 50–69K base-occurrences the others lack; NASB-only 41–53K). → **No coverage cost** to gating per displayed translation; a slight per-module gain.

### Decision (supersedes the NASB-set gate)

Clickability, navigation, highlight, and the Word-tab title are all driven by **one canonical per-verse mapping** (`verseWordSegmentPairs`): tagged segments of the **displayed** translation matched to Macula words, in **translation reading order**, **occurrence-indexed** (consume-in-order by `resolvedMaculaBase`, which still applies `nasbExtendedOverride` so NASB H9000+ numbers resolve to Macula bases).

- A Macula word is **clickable iff it appears in that mapping** (the displayed translation tags it). Particles/affixes fall out naturally (their own Strong's is never tagged by a translation) — the NASB-set + morph fallback (`Td`/`Sp`/`Sd`/`ART-`) is **retired**.
- **No NASB-union fallback** — measurement shows it is unnecessary.

### Consequences

- Clickable set == navigation set == highlightable set, in translation order → fixes all three defects.
- `nasbVerseStrongs` / `loadNASBStrongs(for:)` gating path retired. `DatabaseService.loadNASBStrongs` and `NASBExtendedOverride` are **retained** (override still used by `resolvedMaculaBase` for NASB pairing). `nasbClickableWords` removed; `verseWordsWithStrongs` left as legacy.
- Interim per-module coverage ~52–54% of Macula tokens (rest are particles/affixes/untagged).
- **Forward link — Phase 2 (separate spec):** unify and normalize Strong's tagging across all four modules (domap missing, bring to one scheme) — the `verse_markup` canonical table — pushing clickable coverage above any single module's ~52%.

### Changed (Swift, `ReaderViewModel.swift` unless noted)

`verseWordSegmentPairs` + `clickableWordIDs` (new) · `isClickable` (mapping-based) · `translationOrderedClickableWords` (= pairs) · `selectedWordDisplayText` (pair lookup) · `syncSegment` (pair lookup) · `tapWord(_ segment:)` (pair-by-segment.id) · `navigateToPrevious/NextWord` (iterate pairs) · `autoSelectFirstWordIfNeeded` (first pair) · removed `nasbVerseStrongs` + `loadNASBStrongs(for:)` + `nasbClickableWords`.

---

## Amendment 2026-07-15 — CHEAT MODE for Strong's-less translations (UBIO)

**Context:** ADR-029 added UBIO (Огієнко), which has **no Strong's tags** (`strong_numbers=false`).
The per-translation gate above yields an **empty** `verseWordSegmentPairs` for every UBIO
verse → **no** original word is clickable → word-study is completely dead for a whole
translation. The `verse_org` work (ADR-028) already lets UBIO *display* the correct
original; this closes the *interaction* half.

**Decision:** `clickableWordIDs` gains a fallback. When the pair set is **empty** (the gate
has no input — i.e. the displayed translation tags nothing), fall back to making **every
original word with a lexicon entry** (`strongsId != nil`) directly tappable. Tap opens the
lexicon from **Macula's own Strong's** (`tapWord(_ word:)` already works standalone);
`syncSegment` returns nil → no translation cross-highlight (no pairing possible) — accepted.

- Triggers **only** when pairs are empty → translations WITH Strong's (KJV/ASV/NASB/RST) are
  **unaffected**; no regression on their tuned Original screen (verify: their chevron set
  unchanged).
- Direction is Original-tab → lexicon only. Translation-text long-press → original still
  requires translation Strong's (dead for UBIO by nature) — out of scope.
- **Known follow-up:** `<>` word-navigation (`translationOrderedClickableWords`) still keys
  on pairs → empty for UBIO, so tap-to-open works but next/prev word-nav does not. Left as
  polish (merge/head-token mapping lives in the View, not the VM). Verify on device whether
  the empty nav needs the chevrons hidden.
- Does **not** close `spec-nt-lemma-form-clickability` (Deferred): that gap is a *partial*
  mismatch on translations that DO tag Strong's (Greek lemma vs form), where the pair set is
  non-empty → cheat mode does not trigger.

**Changed:** `ReaderViewModel.clickableWordIDs` (fallback branch) only.
