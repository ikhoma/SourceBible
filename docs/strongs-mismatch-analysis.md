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

This is what `NASBExtendedOverride.swift` hand-maps (391/603 = 64.8%, rest on morph fallback).

> **⚠️ Spike correction (2026-07-10):** An earlier draft of this doc claimed STEPBible eStrong "already publishes the complete version of this table." **That is wrong** — see Spike Results below. STEPBible's `H9000+` numbers are *non-lexical prefixes/suffixes* (Tyndale House), a **different numbering universe** from NASB's proprietary `H9000+` lexical numbers. STEPBible does **not** contain NASB's extended numbers, so it cannot replace the override. STEPBible eStrong *does* fix a different problem — the NULL `short_def`/`long_def` lexicon gap (`db_build.md` TBESH suffix bug) — but that is lexicon population, not NASB gating. Keep the two separate.

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

---

## Spike Results (2026-07-10) — how much does STEPBible dStrong/uStrong actually replace?

Read-only measurement from raw sources (`/tmp/spike.py`): STEPBible TBESH+TBESG (19,570 eStrong bases, union-find over dStrong/uStrong links) vs `NASBExtendedOverride.swift` (391 entries) vs the empirical OT mismatch pairs (NASB+.zip ↔ macula-hebrew TSV).

### Measure 1 — can STEPBible replace the 391 manual override entries? **No.**

| Check | Result |
|---|---|
| NASB extended key exists as a STEPBible eStrong | **28 / 391 (7.2%)** |
| STEPBible links that key to our Macula target | **0 / 391 (0.0%)** |

STEPBible's `H9000+` (non-lexical affixes) ≠ NASB's `H9000+` (proprietary lexemes). **STEPBible cannot generate the NASB↔Macula override.** To auto-generate/retire those 391 hand entries, the source must be the **BibleHub-lineage BSB `display` interlinear** (the "tactical" path in `bsb-publishing-dataset-analysis.md`) — not STEPBible.

### Measure 2 — does STEPBible unify the standard-number mismatch pairs?

71 systematic pairs found (21 standard, 50 NASB-extended). STEPBible auto-unifies **8 / 21 standard** pairs; **0 / 50 extended** (same reason as Measure 1).

The 8 it *does* unify are almost all **Type 3 name variants** + a couple form-variants — exactly uStrong's job:

| Unified by STEPBible (uStrong) | Not unified (stays a decision) |
|---|---|
| Joash H3101/H3060, Hezekiah H3169/H2396, Jonathan H3129/H3083, Jeshua/Joshua H3442/H3091, Levi H3881/H3878, Gershon H1647/H1648, Yahweh-qere H3069/H3068, shepherd H7473/H7462 | **enemy H341/H340 (noun/verb)**, fearing H3373/H3372 (adj/verb), this H2063/H2088 (fem/masc), prostitute H2185/H2181, porch H361/H197, fortified H1208/H1219, clothed H3830/H3847, creditor H5378/H5383 (+ a few co-occurrence-noise rows) |

### Bottom line for `mStrong`
- **STEPBible dStrong/uStrong is worth adopting** — but its real contribution is the **name/sense unification layer** (Type 3), which seeds `mStrong` cleanly. ~6 proper-name mismatch families close for free.
- It does **NOT** reduce the `NASBExtendedOverride` burden (0/391). That burden needs the **BSB `display` interlinear** auto-generation path instead.
- **Type 1 (noun/verb) correctly stays unmerged** even in STEPBible — empirical confirmation that these are genuine editorial disagreements, resolvable only by picking a canonical (Macula). No table fixes them.
- Therefore `mStrong` = **Macula canonical**, seeded from **STEPBible (names/senses)** + a **BibleHub/BSB-derived NASB bridge** (extended numbers). Two different source families, two different jobs.

---

## Spike 2 (2026-07-10) — is BSB/BibleHub a clean drop-in? **Inconclusive from local data — needs the real BSB `display` dataset.**

Ran against the local BibleHub OT interlinear cache (`data/bh_cache_hebrew`, 23,213 verses — same lineage as BSB) vs Macula vs NASB (`/tmp/spike2.py`, `/tmp/spike2b.py`).

**What is solid:**
- BibleHub OT interlinear uses **standard Strong's** numbers (`hebrew/NNNN.htm`) — overwhelmingly, not NASB's proprietary `H9000+`. So a BSB-as-clickable-translation would largely avoid the extended-override problem *in principle*.
- **NASB genuinely disagrees with Macula** on the contested lexical calls (clean signal from `<S>` tags): for the 273 verses where Macula tags enemy as the **noun H341**, NASB tags the **verb H340** in 218 and never 341. Same pattern for shepherd (65/72 → H7462 verb), fearing, "this". Type 1 is real and reconfirmed.

**What is NOT reliable (methodological limit):**
- The cached BibleHub **HTML is not clean per-word tagging** — a page carries *extra* Strong's links (footers, related-word/concordance sections). Symptoms: 2,427 stray `9000+` hits across the cache, and the semantic probe shows BibleHub pages contain **both** numbers of a mismatch pair (enemy: 167 pages have H341 **and** 166 have H340). So per-word BSB coverage (measured 52.1% here) and BSB-vs-Macula agreement **cannot be trusted from this cache**.
- ⚠️ **Correction of an in-conversation claim:** an intermediate result suggested "BibleHub agrees with Macula (H341) and thus refutes the BSB doc's inherited-mismatch assumption." The deeper probe shows that was an **extraction artifact** (pages contain both numbers). The BSB doc's caveat is therefore **neither confirmed nor refuted** — it stays open.
- A couple of the "Type 1" pairs are themselves noisy (e.g. "how" H349/H351: NASB actually sides with Macula 54/16 — likely a variant, not a true semantic split). The empirical co-occurrence list has some false members; treat individual low-count rows with caution.

**Conclusion:** the local HTML cache **cannot** settle whether BSB is a clean clickable drop-in. That requires the actual **BSB `display` JSONL** (per-word English↔Strong's↔original tuples) from `bsb-data-output` — the source the BSB analysis already named. Until then: STEPBible's contribution (Spike 1) is quantified and clear; the BSB path remains **blocked on downloading the real dataset**, not evaluable from scraped interlinear pages.

**Sources:** `data/NASB+.zip`, `data/macula-hebrew-main.zip` (WLC TSV), `data/TBESH … STEPBible.org CC BY.txt`; cross-refs `docs/architecture/ADR-016-original-pill-nasb-bridge.md`, `docs/bsb-publishing-dataset-analysis.md`.
