# Bug Report: H341 (אוֹיֵב "enemy") Non-Clickable in Verse Lexicon + Wrong Strong's on NASB Long-Tap

**Reported:** 2026-06-19  
**Verse:** Prov 24:17 (confirmed; systemic across OT)  
**Severity:** High — affects "enemy" (H341) in ~272+ OT verses  
**Status:** Open — investigation only, no fix implemented yet

---

## Observed Symptoms

### Bug 1 — H341 badge has no chevron, not tappable (Verse tab → Lexicon pill)

In the Original Words section of the Lexicon pill, the row for אוֹיְבְךָ (Prov 24:17, "your enemy") shows H341 but renders as a **non-clickable flat row** — no chevron, gloss hidden, no tap response. All other content words in the same verse (H5307, H8055, H3782) are correctly clickable with chevrons.

Expected: H341 should be clickable like any other content word with a lexical entry.

### Bug 2 — Long-tap on "enemy" in NASB shows H340 ("be hostile"), in KJV shows H341 ("enemy")

Long-pressing the word "enemy" in the verse text:
- **NASB translation** → Word tab opens showing H340, lemma אִיב, gloss "be hostile", no morphology panel
- **KJV translation** → Word tab opens showing H341, lemma אוֹיֵב, gloss "enemy", full morphology (Qal Participle active)

The two translations open different Strong's entries for the same Hebrew word in the same verse.

---

## Root Cause

### The NASB dataset uses H340 where Macula uses H341

NASB and Macula tag the noun form of "enemy" (אוֹיֵב) with **different Strong's numbers**:

| Dataset | Strong's used for "enemy" | Prov 24:17 raw tag |
|---------|--------------------------|---------------------|
| NASB+.SQLite3 | **H340** (verb "to be hostile") | `<S>340</S>` |
| KJV+.SQLite3  | **H341** (noun "enemy")       | `<S>341</S>` |
| Macula (`word.strongs_id`) | **H341**               | `H341` |

H341 (אוֹיֵב) is the Qal active participle of H340 (אָיַב). Strong's assigns them separate numbers, but NASB consistently treats the noun form as H340 (the verbal root), while Macula and KJV use the dedicated noun entry H341. This is a legitimate lexicographic disagreement between datasets.

**Verified from raw NASB data (Prov 24:17):**
```
<S>8055</S>...<S>340</S>...<S>5307</S>...<S>3820</S>...<S>1523</S>...<S>3782</S>
```
Note: "341" is absent. `nasbVerseStrongs` = {"8055", "340", "5307", "3820", "1523", "3782"}.

### Bug 1 — Code path

`isClickable(_ word: BibleWord)` in `ReaderViewModel.swift`:

```swift
func isClickable(_ word: BibleWord) -> Bool {
    guard let sid = word.strongsId else { return false }
    let base = baseStrongsNumber(sid)          // H341 → "341"
    if nasbVerseStrongs.contains(base) { return true }  // "341" ∉ set → false
    guard let morph = word.morphology else { return nasbVerseStrongs.isEmpty }
    if morph.hasPrefix("Td") || morph.hasPrefix("Sp") || morph.hasPrefix("Sd") { return false }
    // H341 is Noun (morph ≈ "Ncmsc"), does not match any exclusion
    return nasbVerseStrongs.isEmpty  // set is NOT empty → returns false ✗
}
```

Result: H341 fails the NASB-gate check and the morph fallback returns `false` because `nasbVerseStrongs` is non-empty (NASB has a verse for Prov 24:17; it just uses H340 instead of H341).

### Bug 2 — Code path

`tapWord(_ segment:, in verse:)` in `ReaderViewModel.swift`:

```swift
let base = baseStrongsNumber(resolved)      // NASB segment: "340"
selectedWord = selectedVerse?.words.first {
    baseStrongsNumber($0.strongsId ?? "") == base  // looks for "340"; Macula has "341" → NO MATCH
}
// selectedWord = nil → falls back to loadStrongs(for: segment) with H340
```

When tapping in **NASB** text: segment has H340, Macula word has H341 → no match → `selectedWord = nil` → loads H340 lexical entry (verb "be hostile") with no morphology enrichment from Macula.

When tapping in **KJV** text: segment has H341, Macula word has H341 → match → `selectedWord` = full Macula word → loads H341 lexical entry (noun "enemy") with morphology.

---

## Scale of Impact

This is **not** an isolated one-verse issue:

| Metric | Count |
|--------|-------|
| OT verses where NASB uses H340 | **272 verses** |
| OT verses where NASB uses H341 | 0 (the 2 hits are NT Greek G341 "renew") |
| OT verses where KJV uses H341 | 277 verses |
| Books affected | Gen, Exo, Lev, Num, Deu, Josh, Judg, 1Sam (20!), 2Sam (16!), 1Kin, 2Kin, 1Chr, 2Chr, Ezr, Neh, Esth, Job, Ps (72!), Prov, Isa, Jer (18!), Lam (15!), Ezek, Hos, Am, Mic, Nah, Zeph |

Psalms alone has 72 affected verses. "Enemy" is one of the most theologically significant Hebrew nouns in the OT. Every single occurrence is un-clickable in the Verse Lexicon when NASB gating is active.

---

## Why the Existing Override Map Doesn't Help

`NASBExtendedOverride.swift` only maps **NASB proprietary extended numbers (H9000+)** to Macula base numbers. The H340/H341 conflict involves two standard Strong's numbers and falls completely outside that mechanism.

---

## Fix Options (for discussion — not implemented)

### Option A — Add H340→H341 to a "standard number override" map (recommended)

Extend (or create alongside) `NASBExtendedOverride` with a `nasbStandardOverride: [String: String]` map for known cases where NASB uses a different standard Strong's number than Macula for the same word form:

```swift
// In NASBExtendedOverride.swift (or a new NASBStandardOverride.swift)
static let nasbStandardOverride: [String: String] = [
    "340": "341",   // אָיַב (NASB: verb root) → אוֹיֵב (Macula: noun/participle)
    // ... other confirmed pairs
]
```

Then in `loadNASBStrongs(for:)`, after inserting `num` into `bases`, also insert `nasbStandardOverride[num]` if it exists (analogous to the existing extended-override block).

And in `tapWord(_ segment:)`, the segment-to-Macula bridge should also check `nasbStandardOverride` when the base-number lookup fails.

**Pros:** Minimal change, same pattern as existing override map, surgical fix.  
**Cons:** Needs a discovery script to find all H→H pairs where NASB and Macula systematically disagree.

### Option B — Check N-1 / N+1 fallback in isClickable

If `nasbVerseStrongs` doesn't contain `base`, also check `String(Int(base)! - 1)` and `String(Int(base)! + 1)`. H340+1 = H341.

**Pros:** Zero maintenance, no map to keep.  
**Cons:** Could cause false positives for unrelated adjacent numbers.

### Option C — Add H341 to `helperStrongs` exemption with inverted logic

Not applicable — H341 is a content word, not a particle.

### Recommended approach

Option A with a small discovery script that queries the NASB dataset for all `<S>NNN</S>` numbers, cross-references them against Macula's `strongs_id` values for the same verse position, and outputs pairs that systematically disagree (like 340↔341). This would catch any other similar pairs across the whole OT.

---

## Files Involved

| File | Role |
|------|------|
| `SourceBible/ViewModels/ReaderViewModel.swift` | `isClickable()`, `tapWord(_ segment:)`, `loadNASBStrongs()` |
| `SourceBible/Services/NASBExtendedOverride.swift` | Existing override map (H9000+); needs companion for standard numbers |
| `SourceBible/Services/DatabaseService.swift` | `loadNASBStrongs()` — parses `<S>NNN</S>` from NASB verse text |
| `data/NASB+.SQLite3` | Source of truth — confirmed `<S>340</S>` for "enemy" in Prov 24:17 |
| `data/KJV+.SQLite3` | Uses `<S>341</S>` for same word — matches Macula |
