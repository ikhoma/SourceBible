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
