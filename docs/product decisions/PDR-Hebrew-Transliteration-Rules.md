# PDR: Hebrew Transliteration Rules for `simplify_xlit()`

**Status:** Accepted  
**Date:** 2026-06-08  
**Context:** Lexicon tab displays a simplified Latin transliteration next to each Hebrew word. This document records the decisions and grammar rules behind `simplify_xlit()` in `scripts/build_db.py`, discovered through web research and Macula data analysis.

---

## Problem

The initial `simplify_xlit()` implementation had four bugs, all causing wrong or unreadable transliterations in the Lexicon view:

1. Monosyllabic prepositions/conjunctions showed bare consonants: `בְּ → "b"`, `לְ → "l"`, `וְ → "v"`, `כְּ → "k"`
2. Dagesh forte doubled letters were not collapsed: `הַשָּׁמַיִם → "shshamayim"`, `מֹץ → "mmots"`
3. Spirant peh (פ without dagesh) was not converted to "f": `נֶפֶשׁ → "nepesh"` instead of "nefesh"
4. Modifier letter ᵃ (U+1D43, Macula notation for hateph-patah) was not converted: `ᵃh → "h"` instead of "ah"

---

## Hebrew Grammar Rules That Drive the Implementation

### Inseparable prepositions: בְּ (be), לְ (le), כְּ (ke)

These three prepositions are prefixed directly to the following word. The vowel under the preposition changes depending on what follows:

| Condition | Form | Macula xlit | Simplified |
|-----------|------|-------------|------------|
| Normal | בְּ | `bə` | be |
| Before sheva | בִּ | `bi` | bi |
| Before yod + sheva | בִּ | `bi` | bi |
| Before composite sheva (guttural) | בַּ / בֶּ | `ba` / `be` | ba / be |
| Before accented syllable (qamets) | בָּ | `bā` | ba |
| Before definite article (patah) | בַּ | `ba` | ba |

When the preposition is a spirantized bet (after a vowel-final word), Macula writes `ḇ` instead of `b`. Rule: ḇ → v (so `ḇə → ve`, `ḇa → va`, `ḇi → vi`).

Same vocalization logic applies to לְ and כְּ.

### Conjunction וְ ("and")

Also prefixed. Vocalization changes:

| Condition | Form | Macula xlit | Simplified |
|-----------|------|-------------|------------|
| Normal | וְ | `wə` | ve |
| Before sheva + before ב/מ/פ | וּ | `û` | u |
| Before yod + sheva | וִ | `wi` | vi |
| Narrative consecutive (patah) | וַ | `wa` | va |

Note: `û` (shureq) is Macula's notation for the conjunction before labials — it has no leading `w` character, just `û`, so it maps cleanly to "u" without any special case.

### Word-final shewa: silent vs. vocal

**Key rule:** Shewa at the end of a word is **silent (shewa nach)** when the word has other vowels — drop it. But for monosyllabic particles (בְּ, לְ, כְּ, etc.) the shewa **is** the vowel (shewa na' = vocal shewa) — keep it so it becomes "e".

Implementation: strip final `ə` only when `stem` (everything before `ə`) already contains a vowel character.

Examples:
- `hālaḵə` → stem `hālaḵ` has `ā` → strip → "halakh" ✓
- `bə` → stem `b` has no vowel → keep → ə→e → "be" ✓

### Dagesh forte (consonant doubling)

When a letter carries dagesh forte (strengthening dagesh), Macula writes it doubled in the transliteration: `šš`, `mm`, `yy`, `nn`, etc. In simplified consumer-facing transliteration, doubling is not shown.

Fix: after all character replacements, collapse:
- `shsh → sh`, `khkh → kh`, `tsts → ts`, `chch → ch`
- `([bcdfghjklmnpqrstvwxyz])\1 → \1` (handles mm→m, yy→y, nn→n, etc.)

### Begad-kefat spirants (letters without dagesh)

Hebrew has six letters that spirantize when they appear without dagesh: ב ג ד כ פ ת.

| Letter | With dagesh | Without dagesh (Macula) | Simplified |
|--------|-------------|--------------------------|------------|
| ב | b | ḇ (U+1E07, precomposed) | v |
| ג | g | ḡ (U+1E21, precomposed) | g |
| ד | d | ḏ (U+1E0F, precomposed) | d |
| כ | k | ḵ (U+1E35, precomposed) | kh |
| פ | p | p̄ (U+0070 + U+0304, **combining sequence**) | f |
| ת | t | ṯ (U+1E6F, precomposed) | t |

**Important:** Spirant peh (p̄) is the only spirant that is NOT a precomposed Unicode character. Macula writes it as plain `p` + U+0304 (COMBINING MACRON ABOVE). Without an explicit replacement before the NFD diacritic-strip pass, the macron would be silently dropped, leaving "p" instead of "f". The replacement `('p̄', 'f')` must appear in the list **before** the NFD+Mn strip.

Affected words include: נֶפֶשׁ (nefesh = soul), כָּנָף (kanaf = wing), אָסַף (asaf = gather), רָפָא (rafa = heal).

### Macula modifier letter ᵃ (U+1D43)

Macula occasionally uses the Unicode modifier letter small a (ᵃ, U+1D43) to denote hateph-patah vowels under guttural consonants. Example: `ᵃh` for the definite article before aleph-initial words. This character has Unicode category `Lm` (letter modifier), **not** `Mn` (non-spacing mark), so the standard NFD+Mn strip does not remove it. Add explicit replacement `('ᵃ', 'a')` (and ᵉ, ᶦ, ᵒ, ᵘ for completeness) to the list.

---

## Decisions

1. **Simplified, not academic.** We output "be", "ve", "le", "ke" rather than "bə", "wə", "lə", "kə". Target audience is not Hebrew scholars; readable phonetic approximations are preferred.

2. **Spirant ב/כ/ת → v/kh/t, not w/ch/th.** We follow TBESH/STEPBible convention: ו/ב-spirant → v (not w), ת-spirant → t (not th), כ-spirant → kh. Matches what TBESH already uses in `strongs.xlit_simple`.

3. **No doubling from dagesh.** Consumer simplified form drops dagesh forte doubling entirely. "shamayim" is preferred over "shshamayim".

4. **Diphthongs preserved.** "ay" (patah+yod) and "ey" (tsere+yod) are kept. Only word-final "-iy" (hiriq-yod mater lectionis) is stripped to "-i" (כִּי → ki).

5. **Lexicon xlit source priority:** For the per-token xlit shown in the Lexicon:
   - `strongs.xlit_simple` (from TBESH, dot-separated form with dots removed) for entries that exist in TBESH
   - `word.xlit` (Macula per-token transliteration processed by `simplify_xlit`) for sub-entries and particles not in TBESH (H871a, H1886a, H2050b, etc.)

---

## Test Cases

Key regression cases for `simplify_xlit()`:

| Input | Expected | Notes |
|-------|----------|-------|
| `bə` | `be` | bet prep normal |
| `ḇə` | `ve` | bet spirant (no dagesh) |
| `wə` | `ve` | waw conj normal |
| `û` | `u` | waw conj before labials (shureq) |
| `lə` | `le` | lamed normal |
| `kə` | `ke` | kaf normal |
| `hālaḵə` | `halakh` | polysyllabic: final shewa silent |
| `ššāmayim` | `shamayim` | dagesh forte collapse |
| `mmōṣ` | `mots` | dagesh forte collapse |
| `nep̄eš` | `nefesh` | spirant peh (combining sequence) |
| `kānāp̄` | `kanaf` | spirant peh at word end |
| `ᵃh` | `ah` | modifier letter ᵃ before article h |
| `kiy` | `ki` | hiriq-yod mater guard |
