# ADR-020: Hebrew Transliteration Build-Time Validation

**Status:** Accepted (реалізовано 2026-06; статус виправлено 2026-08-07 lint-ом)  
**Date:** 2026-06-09  
**Реалізація:** колонка `word.xlit_slot` у схемі, 17 місць у `scripts/build_db.py`.
⚠️ Відоме розходження: `verify_xlit_integrity` НЕ падає, хоч docstring обіцяє `SystemExit`
(зафіксовано в `docs/db_build.md` і `docs/original-tab.md`)  
**Deciders:** Ivan  
**Extends:** `docs/features/plan-hebrew-translit-rebuild.md`

---

## Context

`plan-hebrew-translit-rebuild.md` defines a full DB rebuild that adds `slot`, `after_char`, and `xlit_slot` columns. The function `_apply_bh_hebrew_translit()` silently sets `xlit_slot` based on two assumptions that were only spot-checked against Psalm 1:

1. **Word count parity** — each OT verse has the same number of Macula display slots as BibleHub Hebrew words.
2. **Root token agreement** — after stripping our `HELPERS` set from a slot's token list, the first remaining token's Strong's base number matches what BibleHub records for that slot.

If either assumption breaks at scale (different chapter, edge-case parsing, incomplete `HELPERS` set), the wrong transliteration silently populates `xlit_slot` or a slot gets no translit at all. There is currently no mechanism to detect this during the build.

Additionally, the plan has three gaps that need to be addressed before implementation:

**Gap 1 — Unverified HTML structure.**  
The regex pattern assumes `class="c1"` and `<span class="hb">` in BibleHub Hebrew pages. This was inferred from knowledge, not from inspecting a live HTML response. If the actual class names differ, the scraper silently produces 0 entries without erroring.

**Gap 2 — Incomplete transliteration character set.**  
The plan's regex char class `[A-Za-zāēīōūȲḥḫṣṯ\' \-]+` misses several characters that appear in BibleHub Hebrew transliterations: `ṭ ś š ḡ ḵ ṯ ḇ ḏ ḳ ẑ ṁ ṉ` and the combining dot-below/macron forms. A single omitted character silently truncates or drops a transliteration.

**Gap 3 — HELPERS set only tested on Psalm 1.**  
The set `{"H1886a","H871a","H3509a","H1930a","H2050b","H2050c","H2050d","H5105b"}` was derived from Psalm 1. The full OT (607K words) may contain additional Macula-internal helper IDs. An unrecognised helper treated as a root would produce a Strong's mismatch detectable by the validation layer — but only if that layer exists.

---

## Decision

Add a **two-level build-time validation pass** inside `_apply_bh_hebrew_translit()` that:

1. **Per-verse:** compares Macula display-slot count against BibleHub word count. On mismatch: skip `xlit_slot` for the entire verse and log it.
2. **Per-slot:** compares the computed root token's Strong's base number against BibleHub's Strong's base number. On mismatch: set `xlit_slot = NULL` for that slot and log it.

Both levels write to `data/hebrew_translit_mismatches.tsv` and print build summary statistics.

Additionally, fix Gaps 1–3 before the scraper is run.

---

## Options Considered

### Option A: Validate in `_apply_bh_hebrew_translit()` (accepted ✅)

Both sides are available: Macula rows are grouped by verse/slot, BH data is keyed by verse+position. Comparing them is O(n) with no extra I/O.

| Dimension | Assessment |
|---|---|
| Implementation effort | Low — ~60 lines added to existing function |
| Detectability of silent failures | High — catches count mismatches, Strong's mismatches, HELPERS gaps |
| Build time impact | Negligible — all data already in memory |
| Maintenance | No separate script; runs every full rebuild automatically |

**Pros:** Catches all three failure modes; self-documenting via the mismatch file; zero extra steps in the run order.  
**Cons:** Slightly more complex function; mismatch file must be reviewed by developer.

### Option B: Separate `scripts/validate_hebrew_translit.py`

**Pros:** Isolated, runnable independently.  
**Cons:** Easy to skip; developer must remember to run it; adds another step to the run order.

### Option C: No validation — trust the spot-check

**Pros:** Zero work.  
**Cons:** Psalm 1 is a short psalm with clean slots. Any book with unusual Macula tokenisation (e.g. Song of Solomon, compound proper names, archaic forms) could produce silent errors at scale. Not acceptable.

---

## Implementation

### Fix 1 — Verify and fix the HTML parse regex

Before writing the scraper, fetch and inspect one real Hebrew page:

```bash
python3 - <<'EOF'
import urllib.request
url = "https://biblehub.com/text/psalms/1-2.htm"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
html = urllib.request.urlopen(req, timeout=15).read().decode("utf-8")
# Find the first Hebrew word block
import re
idx = html.find("hb")
print(html[max(0,idx-100):idx+400])
EOF
```

Confirm actual class names and DOM structure. Only then finalise the regex. Known safe fallback pattern based on Strong's link (always present):

```python
# Safe anchor: every Hebrew slot has a /hebrew/NNNN.htm link with the number
pattern = re.compile(
    r'href="/hebrew/(\d+)\.htm"[^>]*title="[^"]*"[^>]*>'
    r'([^<]+)'    # transliteration text (link text)
    r'</a>',
    re.UNICODE,
)
```

This keys on the Strong's link (structure is stable across BH redesigns) and reads translit as link text. The Hebrew surface form can be found in the same `<td>` above the link.

### Fix 2 — Broaden the transliteration character class

Replace the narrow class with a Unicode-range approach:

```python
# Accept all Latin + Latin Extended + Latin Extended Additional + combining marks
# This covers all BibleHub transliteration characters (ṭ, ś, š, ḡ, ḵ, ṯ, ḇ, ḏ, ḳ, etc.)
TRANSLIT_RE = re.compile(r"[A-Za-zÀ-ɏḀ-ỿ̀-ͯ'\- ]+")

def extract_translit(text):
    """Extract a contiguous transliteration token from link text."""
    m = TRANSLIT_RE.search(text.strip())
    return m.group(0).strip() if m else ""
```

### Fix 3 — Store per-verse BH word count in the JSON

In `fetch_biblehub_translit_hebrew.py`, after parsing a page's Hebrew words, store both per-slot entries and a per-verse count sentinel:

```python
# Store positional entries
for pos, (heb, translit, strong) in enumerate(words, 1):
    key = f"{osis}:{ch}:{vs}:{pos}"
    result[key] = {"translit": translit, "surface": heb, "strong": strong}

# Store verse-level count for validation (key uses pos=0 as sentinel)
verse_key = f"{osis}:{ch}:{vs}:count"
result[verse_key] = len(words)
```

The `:count` sentinel key never conflicts with positional keys (1-based) and allows O(1) verse-count lookup during build without re-scanning all keys.

### Validation in `_apply_bh_hebrew_translit()`

```python
def _apply_bh_hebrew_translit(rows, bh_translit):
    """
    Applies BibleHub slot-level transliterations to Hebrew word rows.
    Validates:
      1. Per-verse word count parity (Macula slots == BH count)
      2. Per-slot root Strong's alignment (our root base == BH base)
    Writes mismatches to data/hebrew_translit_mismatches.tsv.
    """
    from collections import defaultdict
    from pathlib import Path

    HELPER_STRONGS = {
        "H1886a","H871a","H3509a","H1930a",
        "H2050b","H2050c","H2050d","H5105b",
    }

    def base_num(sid):
        """'H3887a' → '3887', 'H3808' → '3808'"""
        if not sid:
            return ""
        digits = "".join(c for c in sid if c.isdigit())
        return digits

    # Group rows by verse and by slot within verse
    # rows tuple after slot insertion: [0]=id [1]=book_id [2]=ch [3]=vs [4]=pos [5]=slot [6]=surface [7]=lemma [8]=strongs_id ...
    verse_slots = defaultdict(lambda: defaultdict(list))
    for i, row in enumerate(rows):
        book_id, ch, vs, pos, slot = row[1], row[2], row[3], row[4], row[5]
        if slot is not None and row[6]:   # skip empty-surface rows
            verse_slots[(book_id, ch, vs)][slot].append((pos, i))

    xlit_overrides = {}
    mismatches = []    # list of dict for TSV output

    for (book_id, ch, vs), slots_dict in verse_slots.items():
        # Sort slots into document order
        ordered_slots = sorted(
            slots_dict.items(),
            key=lambda kv: min(p for p, _ in kv[1])
        )
        macula_count = len(ordered_slots)

        # ── Validation Level 1: per-verse word count ──
        bh_count_key = f"{book_id}:{ch}:{vs}:count"
        bh_count = bh_translit.get(bh_count_key)
        if bh_count is not None and bh_count != macula_count:
            mismatches.append({
                "type":         "COUNT_MISMATCH",
                "ref":          f"{book_id} {ch}:{vs}",
                "slot":         "",
                "macula_surf":  "",
                "macula_strong":"",
                "bh_surf":      "",
                "bh_strong":    "",
                "detail":       f"Macula slots={macula_count} BH words={bh_count}",
            })
            # Skip xlit_slot for the entire verse — data is untrustworthy
            continue

        for display_pos, (slot_num, token_list) in enumerate(ordered_slots, 1):
            key = f"{book_id}:{ch}:{vs}:{display_pos}"
            bh_entry = bh_translit.get(key)
            if not bh_entry:
                continue   # BH data absent for this verse/pos — skip silently

            translit    = bh_entry.get("translit", "").strip()
            bh_strong   = bh_entry.get("strong", "")
            bh_surf     = bh_entry.get("surface", "")

            # Find root token (first non-helper by position)
            token_list_sorted = sorted(token_list, key=lambda x: x[0])
            root_row_idx = None
            root_strongs = None
            combined_surf = ""
            for pos_t, row_idx in token_list_sorted:
                row = rows[row_idx]
                sid = row[8]   # strongs_id (index 8 after slot at 5)
                combined_surf += row[6] or ""
                if root_row_idx is None and sid not in HELPER_STRONGS:
                    root_row_idx = row_idx
                    root_strongs = sid

            # ── Validation Level 2: per-slot Strong's alignment ──
            if root_strongs and bh_strong:
                macula_base = base_num(root_strongs)
                bh_base     = base_num("H" + bh_strong)
                if macula_base != bh_base:
                    mismatches.append({
                        "type":          "STRONG_MISMATCH",
                        "ref":           f"{book_id} {ch}:{vs}",
                        "slot":          str(slot_num),
                        "macula_surf":   combined_surf,
                        "macula_strong": root_strongs,
                        "bh_surf":       bh_surf,
                        "bh_strong":     f"H{bh_strong}",
                        "detail":        f"base {macula_base} ≠ {bh_base}",
                    })
                    # Do not set xlit_slot — translit may belong to wrong word
                    continue

            # All checks passed — apply translit to root token
            if root_row_idx is not None and translit:
                xlit_overrides[root_row_idx] = translit

    # Write mismatch report
    if mismatches:
        out_path = Path(__file__).resolve().parent.parent / "data" / "hebrew_translit_mismatches.tsv"
        headers = ["type","ref","slot","macula_surf","macula_strong","bh_surf","bh_strong","detail"]
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("\t".join(headers) + "\n")
            for m in mismatches:
                f.write("\t".join(m[h] for h in headers) + "\n")
        print(f"  ⚠  {len(mismatches)} mismatches → {out_path}")
    else:
        print("  ✓ All verse counts and Strong's aligned.")

    # Print summary
    count_mm = sum(1 for m in mismatches if m["type"] == "COUNT_MISMATCH")
    strong_mm = sum(1 for m in mismatches if m["type"] == "STRONG_MISMATCH")
    print(f"  Validation: {count_mm} verse-count mismatches, {strong_mm} Strong's mismatches "
          f"out of {sum(len(v) for v in verse_slots.values())} slots")

    # Apply overrides and return extended rows
    result = []
    for i, row in enumerate(rows):
        xlit_slot = xlit_overrides.get(i)
        result.append(row + (xlit_slot,))
    return result
```

---

## Mismatch Categories and Response Protocol

| Type | Cause | Build action | Follow-up |
|---|---|---|---|
| `COUNT_MISMATCH` | Macula and BH have different word counts for a verse | Skip entire verse's `xlit_slot`; use `xlit` / `xlitSimple` fallback | Review verse; check if BH has merged or split a compound word; update `HELPERS` if needed |
| `STRONG_MISMATCH` (base differs) | Our `HELPERS` set is missing a helper, or BH uses a different semantic root | Skip that slot's `xlit_slot` | Check if missing helper ID should be added to `HELPERS`; sub-entry differences (H3887a vs H3887) are handled by `base_num()` and should not appear here |
| `STRONG_MISMATCH` (known NASB sub-entry) | NASB uses H3917b, BH uses H3887 for the same word | Will appear in the file | These are genuine lexicographic differences — not errors; annotate in the mismatch file with a `NASB_VARIANT` sub-type if desired |

**Expected mismatch rate (estimate):**  
Based on Psalm 1 analysis: 0 count mismatches, ~13% of slots have a Strong's difference that base_num() catches as identical (H3887a→H3887). True mismatches (base numbers genuinely different) are expected to be < 1% of OT slots, primarily NASB sub-entry variants.

A mismatch rate > 5% on COUNT_MISMATCH is a signal that the HTML parser is failing silently — check the regex first.

---

## Plan Amendments Required

Update `plan-hebrew-translit-rebuild.md` section 4 (`fetch_biblehub_translit_hebrew.py`) and section 5 (`build_db.py`):

| Amendment | Location |
|---|---|
| Pre-scrape HTML structure verification step | §4.3 "Parse function" |
| Broadened `TRANSLIT_RE` character class | §4.3 |
| `:count` sentinel key in JSON output | §4.5 "Output format" |
| Full `_apply_bh_hebrew_translit()` code with validation | §5.3 |
| `hebrew_translit_mismatches.tsv` added to output files | §10 "Run Order" and §12 "Files Changed" |

---

## Consequences

**What becomes easier:**
- Discovering `HELPERS` set gaps automatically rather than manually after noticing wrong transliterations
- Identifying BH HTML structure changes (count mismatch spike)
- Quantifying transliteration coverage before shipping (% of slots with `xlit_slot != NULL`)

**What becomes harder:**
- Build produces a file that must be reviewed by the developer; non-zero mismatch file should not block the build but should block the release

**Revisit when:**
- Mismatch rate for `STRONG_MISMATCH` exceeds 2% (indicates systematic `HELPERS` gap or BH numbering policy change)
- BH pages change structure (count mismatch spike to > 10% indicates parser failure)

---

## Action Items

1. - [ ] Verify BH Hebrew HTML structure by fetching one live page before writing the regex (Fix 1)
2. - [ ] Replace narrow char class with `TRANSLIT_RE` Unicode range (Fix 2)
3. - [ ] Add `:count` sentinel key to `fetch_biblehub_translit_hebrew.py` output (Fix 3)
4. - [ ] Replace `_apply_bh_hebrew_translit()` skeleton in plan with the validated version above
5. - [ ] Review `data/hebrew_translit_mismatches.tsv` after first OT build; expand `HELPERS` for any `STRONG_MISMATCH` rows where Macula root is actually a helper
6. - [ ] Update `plan-hebrew-translit-rebuild.md` §4, §5, §10, §12 with amendments from this ADR
