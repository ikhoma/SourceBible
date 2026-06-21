# BSB-publishing Datasets — Analysis for SourceBible

**Date:** 2026-06-21
**Source org:** https://github.com/BSB-publishing (8 repositories)
**Question:** What from these datasets is useful for our stack, and what should we download? Does anything help the NASB↔Macula Strong's mismatch fix?

---

## TL;DR

BSB-publishing is the official tooling + data org for the **Berean Standard Bible**, built from the same **BibleHub** word-level interlinear source we already pull from (cf. `xlit_slot` / ADR-020). The BSB text is **true public domain (CC0)** — unlike NASB, which is copyrighted.

The single repo worth mining is **`bsb-data`** (output published to `bsb-data-output`). It emits a dozen ready-to-use datasets, several of which map directly onto problems we have already solved by hand or filed as bugs — most importantly the **STEPBible TBESH/TBESG lexicon** and the **UBS versification mappings**.

BSB will **not** auto-dissolve the NASB↔Macula verb→noun mismatch (its Strong's tagging is BibleHub-derived, same lineage as NASB's), but it opens a cleaner strategic and tactical path around the override-table maintenance burden.

---

## Repo-by-repo

| Repo | What it is | Verdict |
|------|-----------|---------|
| **bsb-data** | Preprocessing pipeline → 12 enriched datasets (lexicon, versification, concordance, cross-refs, geography, proper names, glosses) | **Mine this.** The payload. |
| **bsb2usfm** | BSB/MSB → USFM/USJ/USX. Releases ship `BSB_full_strongs` ZIPs | Useful for text + Strong's in standard formats |
| **bsb-data-output** | Published build output of bsb-data | Download target (or build locally) |
| **bsb-align** | Word-level forced-alignment audio timings, all 66 books, `{text,start,end}` JSON (Bob Hays narration) | Sleeper — only if we ever do audio read-along |
| **bsb-interlinear** | TypeScript web UI | Skip (UI, not data) |
| **csv2usfm / usj2bsb / blb2bsb** | Format converters | Skip |

---

## Direct hits on known SourceBible problems

### 1. Extended Lexicon (`base/lexicon/`) — biggest win
20,192 entries (9,345 Hebrew + 10,847 Greek) from **STEPBible TBESH/TBESG**, with BDB (Hebrew) and Abbott-Smith (Greek) corrected definitions: `strongs`, `lemma`, `transliteration`, `gloss`, full `definition`.

This is the exact source behind our `docs/db_build.md` **TBESH suffix bug** — the one where `H1471a`/`H6213a`-style rows were silently skipped and `short_def`/`long_def` came out NULL for ~542 IDs. They have already parsed it cleanly, with suffix propagation handled. It also aligns with our standing decision (memory: *LLM-generated content trust hypothesis*) to prefer human-authored lexica (BDB, Thayer's) over LLM definitions.

### 2. Versification mappings (`base/versification/`)
UBS Paratext, 9,658 mappings across English / Hebrew / LXX / Vulgate. This is a maintained, authoritative version of our hand-built `verse_map` (the 459-chapter Psalm-heading shift; expected 7,292 rows). At minimum use it to **validate** verse_map; potentially to replace it.

### 3. Display format (`base/display/`)
Per-verse JSONL with English word ↔ Strong's ↔ original Hebrew/Greek word, internally consistent — essentially a free public-domain interlinear, i.e. the thing `NASBExtendedOverride` is hand-assembling.

### 4. Other reusable datasets
- **Concordance** (`base/concordance/`) — Strong's → verse refs, pre-built; plus English-word concordance (~14,600 entries).
- **Cross-references** — TSK (Treasury of Scripture Knowledge) via Scrollmapper; feeds our `cross_reference` table.
- **Glosses** (`glosses.json`) — we currently synthesize these in `process_glosses.py`.
- **Proper names** (TIPNR) — 3,124 people + 997 places, disambiguated with genealogy (separates the 6 Marys, etc.).
- **Geography** — 1,342 places with coordinates + Wikidata links (maps feature potential).

---

## On the NASB↔Macula Strong's mismatch specifically

**Honest caveat:** BSB's Strong's tagging is **BibleHub-derived, same lineage as NASB's**, so BSB likely carries the same `H340`-for-"enemy" that disagrees with Macula's `H341`. Adding BSB will **not** automatically resolve the verb→noun mismatch against Macula.

What it does give us is two real options:

1. **Strategic** — add BSB as a public-domain *clickable* translation. Its English↔Strong's↔original are self-consistent (all BibleHub), so within-BSB clickability needs **no override tables** — and it's commercially clean, unlike NASB.
2. **Tactical** — use the `display` interlinear as a programmatic cross-check to **auto-generate** the NASB↔Macula override entries instead of hand-curating six pairs at a time.

---

## Licensing — important given commercial plans

(Cf. memory: *Owen Hebrews commentary* is non-sellable. Same diligence applies here.)

| Tier | Datasets | Commercial use |
|------|----------|----------------|
| **CC0 / Public Domain** | BSB/MSB text, display, concordances, TSK, Nave's, HelloAO, text-only | Sell freely |
| **CC-BY 4.0** | OSHB morphology, TBESH/TBESG lexicon, geography, proper names | Sell, attribution required |
| **CC-BY-SA 4.0 (viral)** | UBS versification, UBS dictionaries/MARBLE, OpenScriptures Strong's dict | Usable, but share-alike — keep as a build-time mapping table; don't contaminate a closed dataset |

The lexicon and morphology we most want are **CC-BY** (fine). The versification is **CC-BY-SA** — usable, but treat it as a build-time input, not redistributed modified data.

---

## What to download (concretely)

Don't scrape the repos — pull built data:

- **Option A:** grab the published output from **`bsb-data-output`**.
- **Option B:** clone `bsb-data` and run:
  ```bash
  bash scripts/fetch-sources.sh
  python3 -m scripts.build --lexicon --versification --display
  ```
  ⚠️ Their pipeline needs **Python 3.10+** (`usfmtc`, `openpyxl`) — run it in a throwaway venv, **not** against our Python 3.9 build scripts.
- **Text + Strong's only:** the `bsb2usfm` releases ship `BSB_full_strongs` ZIPs (USFM / USJ / USX).

**Skip for now:** `bsb-interlinear` (UI), the format converters, and `bsb-align` (unless we pursue an audio Bible with read-along highlighting).

---

## Suggested next steps

1. Pull `base/lexicon/` and diff TBESH/TBESG against our `strongs` table — close the NULL `short_def`/`long_def` gap.
2. Pull `base/versification/` and diff against `verse_map` (7,292 rows / 459 chapters) as a correctness check.
3. Decide BSB-as-clickable-translation vs. override-table auto-generation as the NASB mismatch strategy.

**Sources:** [bsb-data](https://github.com/BSB-publishing/bsb-data) · [bsb2usfm](https://github.com/BSB-publishing/bsb2usfm) · [bsb-align](https://github.com/BSB-publishing/bsb-align)
