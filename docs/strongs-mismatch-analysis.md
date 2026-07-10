# Strong's Numbering Mismatch — NASB/BibleHub ↔ Macula (empirical)

**Date:** 2026-07-10
**Author:** Ivan (analysis run by agent)
**Status:** Reference / analysis — feeds a decision, not itself a decision
**Purpose (why this doc exists):** This analysis exists **specifically to inform the Strong's-gating and source-reconciliation decision** — i.e. the longtap/Original-pill clickability gate (ADR-016) and the BSB/Berean adoption strategy (`bsb-publishing-dataset-analysis.md`). It quantifies *what kind* of mismatch we actually have between the number a **translation** tags (NASB, and by lineage BibleHub/BSB) and the number **Macula** tags for the same word, so we can decide whether a canonical internal key (`mStrong`) is warranted.

**Relates to:** ADR-016 (per-translation gate + `resolvedMaculaBase`), `bsb-publishing-dataset-analysis.md` (BSB/STEPBible datasets), `docs/db_build.md` (TBESH suffix bug). Forward-links to the **`verse_markup` canonical table** already named as Phase 2 in the ADR-016 amendment.

---

## TL;DR

- We ran the whole OT: NASB `<S>` tags (from `data/NASB+.zip`) vs Macula per-word `strongnumberx` (from `data/macula-hebrew-main` TSV), aligned by book/chapter/verse.
- **Most apparent "mismatches" are noise** — Macula zero-pads numbers (`H0834`); after normalization `H0834 == H834`. Not a real disagreement.
- The **real** residue splits into **three distinct types**, and they are NOT the same problem:
  1. **Semantic mismatch** — translation and Macula genuinely disagree on *what the word is* (noun vs verb, masc vs fem form). **No numbering table can fix this** — it is a real editorial disagreement.
  2. **Namespace / extended** — translation uses a proprietary `H9000+` number where Macula uses a standard one. Pure relabeling. **Fully fixable** by a mapping table (this is what `NASBExtendedOverride` does, and what STEPBible eStrong already publishes).
  3. **Name-spelling variants** — same person/place, two different standard numbers (long vs short form, Aramaic vs Hebrew). **Fixable** by a unification table (STEPBible uStrong).

**Consequence for `mStrong`:** a canonical internal number is the right architecture — but it *resolves* types 2 and 3 and only *records a canonical decision* for type 1. It should be anchored to Macula, seeded from STEPBible dStrong/uStrong, and it is functionally the key column of the already-planned `verse_markup` table. See "Should we add an `mStrong` column?" below.

---

## Method

- **Translation side:** `data/NASB+.zip` → `verses.text`, extract `<S>NNN</S>`, normalize (strip `H/G`, strip leading zeros).
- **Original side:** `data/macula-hebrew-main.zip` → `WLC/tsv/macula-hebrew.tsv`, per word `strongnumberx`, `class`, `stronglemma`, `gloss`. Same normalization.
- **Alignment:** by `(book, chapter, verse)`; Macula book codes mapped to NASB MyBible book numbers in canonical OT order (39 books).
- **Mismatch = a Macula content word whose base number is absent from the NASB set for that verse.** Candidate replacement = the NASB number that co-occurs most across the corpus. Particles excluded by Macula `class` (prep/conj/art/adv/etc.).
- **Caveat:** the co-occurrence alignment is a heuristic (Hebrew word order ≠ English), so counts are approximate and a few rows (e.g. `migrash → H1121 ben`) are alignment noise, not true pairs. The pattern is robust; exact counts are indicative.

---

## Type 1 — Semantic mismatch (NOT fixable by any numbering table)

Both sides use a standard number, but they point to genuinely different dictionary entries — different part of speech or grammatical form of the same root/family.

| Macula | NASB | ~count | Word | Nature of disagreement |
|---|---|---|---|---|
| **H341** אֹיֵב | **H340** | 280× | enemy / ворог | Macula = **noun/participle** "enemy"; NASB = **verb** אָיַב "to be hostile". Noun vs verb |
| **H7473** רֹעֶה | **H7462** | 82× | shepherd / пастух | Macula = **noun** "shepherd"; NASB = **verb** רָעָה "to graze/shepherd". Noun vs verb |
| **H3373** יָרֵא | **H3372** | 62× | fearing / боязливий | Macula = **adjective** "fearing"; NASB = **verb** יָרֵא "to fear". Adjective vs verb |
| **H2063** זֹאת | **H2088** | 603× | this / це | Macula = **feminine** demonstrative זֹאת; NASB = **masculine** זֶה. Different grammatical form |
| **H3069** יֱהֹוִה | **H3068** | 314× | Yahweh | Macula = qere form יֱהֹוִה (pointed to be read "Elohim"); NASB flattens to standard יְהוָה |

These are the cases the BSB analysis flagged: BSB's tagging shares NASB's BibleHub lineage, so **adding BSB will not dissolve these**. A canonical key can only *record which reading we treat as canonical* (we anchor to Macula, our original-language backbone) — it cannot make the disagreement disappear.

## Type 2 — Namespace / extended (fully fixable — this is what the override does)

Translation uses a proprietary `H9000+` number; Macula uses a standard one. Pure relabeling of the same referent.

| Macula | NASB | ~count | Word |
|---|---|---|---|
| H7451 רָעָה | H9567 | 431× | evil / зло |
| H2403 חַטָּאת | H9128 | 292× | sin / гріх |
| H2416 חַיִּים | H9132 | 264× | life / життя |
| H3519 כָּבוֹד | H9202 | 198× | glory / слава |

This is exactly what `NASBExtendedOverride.swift` hand-maps (391/603 = 64.8%, rest on morph fallback). **STEPBible eStrong already publishes the complete, authoritative version of this table** (`data/TBESH…`, field `eStrong#`, mapped to BDB via OpenScriptures).

## Type 3 — Name-spelling variants (fixable by unification / uStrong)

Same individual or place, two different standard numbers — long vs short form, or Aramaic vs Hebrew spelling.

| Macula | NASB | ~count | Name |
|---|---|---|---|
| H3442 יֵשׁוּעַ | H3091 יְהוֹשֻׁעַ | 29× | Jeshua vs Joshua |
| H3169 | H2396 | 43× | Hezekiah (long/short form) |
| H3101 | H3060 | 47× | Joash |
| H3129 | H3083 | 42× | Jonathan |
| H3110 | H3076 | 22× | Johanan |

STEPBible **uStrong** ("Unified") is designed precisely for this: it links numbers that "can be regarded as a single word, such as Aramaic & Hebrew versions or different spellings of the same word, and alternate names of the same individual." So this bucket is closeable by adopting the STEPBible unified layer.

---

## Should we add our own `mStrong` column?

**Short answer: yes, conceptually — but "our own" should mean "Macula-anchored, seeded from STEPBible," not hand-built from scratch, and it does not erase Type 1.**

### What `mStrong` would be
A single **canonical internal Strong's key** that every source we operate on maps *into*:

```
Macula word.strongnumberx  ─┐
NASB  <S> tag              ─┤
BSB / BibleHub tag         ─┼──►  mStrong  ──►  strongs (lexicon) row
KJV / ASV / RST tag        ─┤
TBESH / TBESG lexicon id   ─┘
```

### Why it's the right shape
- **O(N) instead of O(N²).** Today reconciliation is pairwise (NASB↔Macula via `resolvedMaculaBase`). Add BSB and you'd want BSB↔Macula too, then BSB↔NASB… With `mStrong`, each source has **one** map to the canonical key. Adding a translation = one new mapping, not a matrix.
- **Moves work from runtime to build time.** `resolvedMaculaBase` + `verseWordSegmentPairs` currently reconcile numbers *live in the ViewModel per verse*. Precomputing `mStrong` per tagged segment in the DB makes the gate a plain equality join.
- **It is already forward-referenced.** The ADR-016 amendment names Phase 2 as "unify and normalize Strong's tagging across all four modules — the `verse_markup` canonical table." **`mStrong` is the key column of that table.** This isn't a new idea to invent; it's the concrete schema for a decision already parked.

### What it does NOT do (be honest)
- **Type 1 stays.** `mStrong` for H341/H340 "enemy" forces us to *pick* a canonical (Macula's noun) and map NASB's verb-number onto it — recording a decision, not discovering a truth. Acceptable, but it means `mStrong == Macula-canonical`, so we should own that framing explicitly.
- **It is not free of the semantic gate consequence:** if a translation tags the "wrong" (per Macula) number, mapping it to `mStrong` makes the word clickable and joins it to Macula's lexeme — which is what we want, but it silently overrides the translation's own lexical opinion. Fine for a study tool; worth stating.

### Recommended shape (if we pursue it — would graduate to an ADR)
1. **Canonical = Macula disambiguated number** (our original-language backbone). Name it `mStrong` (Macula/Master Strong).
2. **Seed the cross-source map from STEPBible dStrong/uStrong** (CC-BY) — this hands us Types 2 and 3 for free — plus a thin residue table for anything STEPBible doesn't cover.
3. **Store `mStrong` at build time** on the translation-markup side (the `verse_markup` table), not just Macula. Retire `NASBExtendedOverride` + runtime `resolvedMaculaBase` once the column exists.
4. **Licensing:** STEPBible mappings are CC-BY (fine to ship with attribution); the Abridged-BDB *definitions* need Online Bible permission (numbers/mappings are free, prose glosses are not — cf. `db_build.md`).

### Next step
If accepted, this becomes **ADR-028: `mStrong` canonical Strong's key + `verse_markup` build-time table**, superseding the runtime `resolvedMaculaBase` path and folding in the BSB "auto-generate override" option from the BSB analysis.

**Sources:** `data/NASB+.zip`, `data/macula-hebrew-main.zip` (WLC TSV), `data/TBESH … STEPBible.org CC BY.txt`; cross-refs `docs/architecture/ADR-016-original-pill-nasb-bridge.md`, `docs/bsb-publishing-dataset-analysis.md`.
