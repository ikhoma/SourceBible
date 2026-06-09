# ADR-019: Source of `strongs.original` — TBESH vs Macula `word.lemma`

**Status:** Accepted  
**Date:** 2026-06-08  
**Deciders:** Ivan  

---

## Context

`strongs.original` stores the Hebrew/Greek lemma glyph displayed in the word detail header
(e.g. `רֵאשִׁית` for H7225). It is shown via `Text(entry.originalWord)` in `WordMeaningView.headerSection`.

The column is currently populated in two steps during `build_db.py`:

1. **Primary — TBESH/TBESG** (`import_stepbible_lexicons`, step [2]): reads the `hebrew`/`lemma`/`greek`
   column from STEPBible TSV files and writes one curated headword per standard Strong's entry.
2. **Fallback — Macula `word.lemma`** (`_enrich_strongs_stubs`, step [7]): for sub-entries not present
   in TBESH (H835a, H871a, etc.), pulls `lemma` from the `word` table using `LIMIT 1`.

The question arose: why not use Macula `word.lemma` as the primary source for all entries, and keep
TBESH only for `xlit_simple` and `short_def`/`long_def`?

---

## Decision

**Keep TBESH as the primary source for `strongs.original`.** Improve the Macula fallback in
`_enrich_strongs_stubs` to use frequency-ranked selection instead of `LIMIT 1`.

---

## Options Considered

### Option A: TBESH primary + Macula fallback (current, with improvement)

| Dimension        | Assessment |
|------------------|------------|
| Determinism      | High — one curated headword per TBESH entry |
| Sub-entry coverage | Needs fallback for ~sub-entries not in TBESH |
| Data quality     | TBESH headword is lexicographically authoritative |
| Complexity       | Low — two-step but each step is clear |

**Pros:**
- TBESH provides exactly one headword per entry; no ambiguity by design
- Matches what users expect: the dictionary "entry form" as chosen by Tyndale lexicographers
- Fallback is only needed for ~sub-entries, which are rare proper nouns and particles

**Cons:**
- Fallback `LIMIT 1` is fragile when Macula tags the same sub-entry ID with multiple lemma forms
- Two-step pipeline adds conceptual overhead

### Option B: Macula `word.lemma` primary + TBESH for xlit/definition

| Dimension        | Assessment |
|------------------|------------|
| Determinism      | Medium — 88% consistent, 11% ambiguous sub-entries |
| Sub-entry coverage | Full (Macula covers 100% of Bible words) |
| Data quality     | Linguistically accurate but not curated as headwords |
| Complexity       | Simpler pipeline — single source for glyphs |

**Pros:**
- Single source of truth for the Hebrew/Greek glyph
- Eliminates `_enrich_strongs_stubs` entirely for the `original` column
- Macula covers sub-entries that TBESH doesn't have

**Cons:**
- **11% of sub-entries (112 of 1008) have multiple distinct `word.lemma` values** under the same
  `strongs_id` — `LIMIT 1` would give a non-deterministic result
- Critical particles are among the inconsistent ones:
  - **H871a**: 3 variants — `בְּ`, `בַּעְיָם`, `כְּ` (preposition בְּ grouped with a proper noun)
  - **H3807a**: 6 variants — `כֹּל`, `לְ`, `לֶחֶם`, `לָכֵן`, `לָמָה`, `לין`
  - **H1886d**: 2 variants — `הוּא`, `נָכָה`
- The inconsistency is not always spelling variants; some cases are genuinely different lexemes
  incorrectly sharing a sub-entry ID in Macula (tagging ambiguity, not a normalization issue)

---

## Trade-off Analysis

TBESH's `hebrew` column is unambiguous by definition — it is a manually curated lexicon entry.
Macula's `word.lemma` is the morphological analysis of each occurrence, which is accurate per-word
but can legitimately vary for the same Strong's ID (alternate spellings, tagging edge cases, compound
proper nouns). For display in a lexicon header, the TBESH headword is the right source.

The 11% inconsistency is not a Macula quality problem — it is a structural mismatch: Strong's
sub-entry IDs sometimes group words that aren't strictly the same lemma. TBESH resolves this editorially;
Macula surfaces it honestly.

The improvement to make: replace `LIMIT 1` in `_enrich_strongs_stubs` with frequency-ranked selection.
For H871a this correctly picks `בְּ` (appears thousands of times) over `בַּעְיָם` (a rare proper noun).

```sql
-- Before (fragile):
SELECT lemma FROM word
WHERE strongs_id = strongs.id AND lemma IS NOT NULL AND lemma != ''
LIMIT 1

-- After (robust):
SELECT lemma FROM word
WHERE strongs_id = strongs.id AND lemma IS NOT NULL AND lemma != ''
GROUP BY lemma ORDER BY COUNT(*) DESC
LIMIT 1
```

---

## Consequences

- `strongs.original` remains TBESH-sourced for all standard Strong's entries (~8,674 Hebrew + ~5,624 Greek)
- Sub-entries missing from TBESH (~1,008 Hebrew sub-entry IDs found in Macula) get the most-frequent
  Macula lemma, which is lexicographically correct for particles and robust for proper nouns
- `_enrich_strongs_stubs` stays in the pipeline; its `original`-fill query gets the frequency fix
- No Swift or schema changes required — this is a build-time data quality improvement only
- The question of switching to Macula-primary is closed unless TBESH coverage degrades significantly

## Action Items

- [ ] Update `_enrich_strongs_stubs` in `build_db.py`: change `LIMIT 1` to `GROUP BY lemma ORDER BY COUNT(*) DESC LIMIT 1` for the `original` fill query
- [ ] Rebuild DB and verify H871a → `strongs.original` = `בְּ` (not `בַּעְיָם` or `כְּ`)
