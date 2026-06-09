# Hebrew Transliteration — Full DB Rebuild Plan

**Status:** Approved for implementation  
**Date:** 2026-06-09  
**Supersedes:** `spec-trailing-chars.md` (ADR-015 absorbed here), `add_after_char.py` migration approach  
**Related:** `ADR-015-trailing-chars.md`, `ADR-016-original-pill-nasb-bridge.md`  
**Extended by:** `ADR-020-hebrew-translit-build-validation.md` — adds per-verse count + per-slot Strong's validation to `_apply_bh_hebrew_translit()`; fixes 3 gaps in §4 and §5 below

---

## 1. Problem Summary

Three overlapping issues that require a coordinated rebuild rather than separate patches:

| Issue | Root cause | Prior approach | Why we're rebuilding instead |
|---|---|---|---|
| Missing maqaf (אַ֥שְֽׁרֵי vs אַ֥שְֽׁרֵי־) | `after_char` column absent; trailing chars from Macula XML `after` attr never stored | ADR-015 migration script (`add_after_char.py`) | Same rebuild needed for slot anyway |
| Per-slot combined transliteration missing | `parse_macula_tsv()` discards `!N` slot number; BibleHub slot-level translit never fetched for Hebrew | Macula per-token `xlit` only (gaps for suffix tokens) | Slot column is a prerequisite; BH scraper is the fix |
| Slot grouping absent | `_group_pos` is parsed but thrown away; `position` is a flat sequential counter | — | Core new feature; enables multi-token display words |

**The right fix for all three is a single coordinated build, not three sequential patches.**

---

## 2. What We Know From Psalm 1 Analysis

These facts constrain the design:

- **Word count parity:** Psalm 1 has exactly 67 Macula display slots = 67 BibleHub Hebrew words. Confirmed for at least two independent books worth of spot-checks.
- **BibleHub bridge rule:** BH always assigns ONE Strong's number per display word = the semantic root (helper tokens H1886a, H871a, H871a, H2050b/c/d stripped). Our root-detection logic (filtering `HELPERS` set) matches BH output.
- **NASB sub-entry differences:** 5 words in Psalm 1 where NASB uses a different sub-entry (H3917b, H5034b, H6213a, H6743b, H4671b). These affect lexicon lookup if H3917b is not in our `strongs` table — use try-sub-entry-first → strip-fallback.
- **H3917 ≠ H3917b:** H3917 = lion (לַיִשׁ), H3917b = mocker (לִיץ). **Do not blindly strip sub-entry letters**. Always try the full sub-entry first.
- **Transliteration gaps in Macula:** 8/67 Psalm 1 slots have missing/partial translit because pronominal suffix tokens (H2050c, H1930a) carry no individual translit in the TSV. BibleHub provides the complete combined translit (e.g., "ḥep̄-ṣōw" for חֶ֫פְצ֥וֹ = H2656 + H2050c). This is the primary motivation for the BH Hebrew fetch.
- **Absorbed words:** Slots where NASB combines two Hebrew words into one English word (e.g., לֹא + verb → "does not [verb]"). These are non-clickable — already handled by ADR-016 NASB bridge.
- **Greek transliteration precedent:** `fetch_biblehub_translit.py` already does this for NT Greek, keyed by normalized surface form. Hebrew requires **positional keying** instead because multiple Macula tokens share one surface slot, and the combined translit doesn't belong to any single token's surface form.

---

## 3. Schema Changes

### 3.1 `word` table — new columns

```sql
slot       INTEGER,     -- Macula !N group position (tokens with same slot form one display word)
after_char TEXT,        -- trailing char from Macula XML `after` attr (maqaf ־, sof pasuq ׃, etc.)
xlit_slot  TEXT,        -- BibleHub slot-level combined translit (root token only; NULL on helpers)
```

**`position` stays unchanged** — sequential token counter within verse, used for ordering and as part of `word.id`. `slot` is an additional grouping key, not a replacement.

### 3.2 Column semantics clarification

| Column | Language | Granularity | Source | Notes |
|---|---|---|---|---|
| `xlit` | Both | Per-token (Macula occurrence) | Macula TSV `transliteration` col | Keeps per-token Macula data; may be NULL for suffix tokens |
| `xlitSimple` (not in DB — computed by app from `strongs.transliteration`) | Both | Per-lemma | TBESH/TBESG | Fallback if `xlit` NULL |
| `xlit_slot` | Hebrew | Per-slot combined | BibleHub positional scrape | Set on ROOT token only; NULL on helper tokens in same slot |

**App display priority (Hebrew slots):**  
`xlit_slot` (root token) → `xlit` (any token in slot) → `xlitSimple` (TBESH lemma)

### 3.3 `strongs` table — no schema change

Sub-entry lookup uses try-full → strip-fallback at query time in `DatabaseService.swift`:
```swift
// Try H3917b first; fall back to H3917 if not found
func strongs(id: String) -> StrongsEntry? {
    lookupStrongs(id) ?? lookupStrongs(baseStrongsNumber(id))
}
```

---

## 4. New Script: `scripts/fetch_biblehub_translit_hebrew.py`

### 4.1 Design principle

Unlike Greek (keyed by surface form), Hebrew keys by **verse-slot position**:

```
key:   "{OSIS}:{ch}:{vs}:{display_pos}"
value: {"translit": "ḥep̄-ṣōw", "surface": "חֶ֫פְצ֥וֹ", "strong": "2656"}
```

Where `display_pos` = 1-based position of the display word in the verse (across all OT books).

### 4.2 BibleHub Hebrew HTML structure

```html
<!-- One row per Hebrew display word -->
<td class="c1" valign="top">
  <span class="hb">חֶ֫פְצ֥וֹ</span>
  <br/>
  <span class="translit">
    <a href="/hebrew/2656.htm" title="...">ḥep̄-ṣōw</a>
  </span>
</td>
```

Key differences from Greek:
- CSS class is `c1` (not `greek2`)
- Hebrew `span.hb` contains the surface form (right-to-left)
- Link points to `/hebrew/NNNN.htm`; the number = Strong's base without prefix
- Transliteration is the anchor text inside `span.translit > a`

### 4.3 Parse function

> ⚠️ **Before finalising this regex:** fetch one live BH Hebrew page and confirm the actual class names (`c1`, `hb`) match what the HTML contains. See ADR-020 §"Fix 1". The structure below is the expected form; verify before encoding it.

```python
# All Latin + Latin Extended + combining marks used in BH Hebrew transliterations.
# Covers: ṭ ś š ḡ ḵ ṯ ḇ ḏ ḳ ẑ ḥ ā ē ī ō ū and all other extended forms.
TRANSLIT_RE = re.compile(r"[A-Za-zÀ-ɏḀ-ỿ̀-ͯ'\- ]+")

def parse_hebrew_translit(html):
    """
    Returns list of (heb_surface, translit, strong_num) in document order.
    Anchors on the /hebrew/NNNN.htm link (structurally stable across BH redesigns).
    """
    # Primary pattern: Strong's link carries translit as anchor text
    pattern = re.compile(
        r'href="/hebrew/(\d+)\.htm"[^>]*title="[^"]*"[^>]*>'
        r'([^<]+)'    # translit = link text
        r'</a>',
        re.UNICODE,
    )
    # Hebrew surface: nearest <span class="hb"> before the link in the same <td>
    td_pattern = re.compile(
        r'class="hb"[^>]*>([^<]+)</span>.*?'
        r'href="/hebrew/(\d+)\.htm"[^>]*title="[^"]*"[^>]*>([^<]+)</a>',
        re.UNICODE | re.DOTALL,
    )
    results = []
    for heb, strong, translit_raw in td_pattern.findall(html):
        m = TRANSLIT_RE.search(translit_raw.strip())
        translit = m.group(0).strip() if m else ""
        if translit:
            results.append((heb.strip(), translit, strong))
    return results
```

### 4.4 Key generation

```python
def make_key(osis, ch, vs, pos):
    return f"{osis}:{ch}:{vs}:{pos}"
```

For each verse page, enumerate results with `enumerate(parse_hebrew_translit(html), 1)` — that gives `(1-based-pos, (heb, translit, strong))`.

### 4.5 Output format

`data/hebrew_translit.json`:
```json
{
  "PSA:1:1:1":     {"translit": "'aš-rê-", "surface": "אַ֥שְֽׁרֵי", "strong": "835"},
  "PSA:1:1:2":     {"translit": "hā-'îš",  "surface": "הָאִ֗ישׁ",   "strong": "376"},
  "PSA:1:1:count": 15,
  ...
}
```

The `:{vs}:count` sentinel key stores the BibleHub word count per verse. Used by `_apply_bh_hebrew_translit()` for Level-1 word-count parity validation. See ADR-020.

### 4.6 OT book slugs

```python
OT_SLUGS = {
    "GEN": "genesis",     "EXO": "exodus",      "LEV": "leviticus",
    "NUM": "numbers",     "DEU": "deuteronomy",  "JOS": "joshua",
    "JDG": "judges",      "RUT": "ruth",         "1SA": "1-samuel",
    "2SA": "2-samuel",    "1KI": "1-kings",      "2KI": "2-kings",
    "1CH": "1-chronicles","2CH": "2-chronicles", "EZR": "ezra",
    "NEH": "nehemiah",    "EST": "esther",       "JOB": "job",
    "PSA": "psalms",      "PRO": "proverbs",     "ECC": "ecclesiastes",
    "SNG": "songs",       "ISA": "isaiah",       "JER": "jeremiah",
    "LAM": "lamentations","EZK": "ezekiel",      "DAN": "daniel",
    "HOS": "hosea",       "JOL": "joel",         "AMO": "amos",
    "OBA": "obadiah",     "JON": "jonah",        "MIC": "micah",
    "NAM": "nahum",       "HAB": "habakkuk",     "ZEP": "zephaniah",
    "HAG": "haggai",      "ZEC": "zechariah",    "MAL": "malachi",
}
```

### 4.7 Resume / cache behaviour

Mirror the Greek script exactly:
- Cache HTML in `data/bh_cache_hebrew/{OSIS}_{ch}_{vs}.html`
- Separate cache directory from Greek (`bh_cache/`) to avoid collisions
- Write `hebrew_translit.json` every 200 pages
- `DELAY = 0.8` seconds (slightly slower than Greek; OT has more verses)
- OT has ~23,145 verses (vs NT 7,943) — estimated 5–6 hours first run, instant on re-run from cache

### 4.8 Verification: parse Psalm 1 from cache

After scraping, a quick sanity check against the known 67-word table:
```bash
python3 - <<'EOF'
import json
d = json.load(open("data/hebrew_translit.json"))
for i in range(1, 10):
    key = f"PSA:1:2:{i}"
    if key in d: print(key, d[key])
EOF
```

Expected: slot 5 = `{"translit": "ḥep̄-ṣōw", "surface": "חֶ֫פְצ֥וֹ", "strong": "2656"}`.

---

## 5. `build_db.py` Changes

### 5.1 Schema DDL additions

In the `SCHEMA` string, add three columns to `CREATE TABLE word`:

```sql
slot       INTEGER,    -- Macula !N group position; NULL for Greek (one token per slot)
after_char TEXT,       -- trailing char from XML `after` attr (maqaf ־, sof pasuq ׃, paseq ׀)
xlit_slot  TEXT,       -- BibleHub combined slot translit (root token); NULL on helpers/Greek
```

Add index:
```sql
CREATE INDEX IF NOT EXISTS idx_word_slot ON word(book_id, chapter, verse, slot);
```

### 5.2 `parse_macula_tsv()` rewrite

**Current (broken):**
```python
osis, ch, vs, _group_pos = parsed   # _group_pos unused
pos = verse_seq.get(verse_key, 0) + 1
verse_seq[verse_key] = pos
word_id = f"{osis}|{ch}|{vs}|{pos}"
rows.append((word_id, osis, ch, vs, pos, surface, lemma,
             strongs_id, morph, gloss, language, xlit, lexical_class))
```

**New (correct):**
```python
osis, ch, vs, group_pos = parsed   # group_pos = Macula !N slot number

# Sequential position for ordering and ID — unchanged
pos = verse_seq.get(verse_key, 0) + 1
verse_seq[verse_key] = pos

# slot = Macula group position (!N); None for tokens without slot suffix (rare)
slot = group_pos  # integer, already parsed from ref

word_id = f"{osis}|{ch}|{vs}|{pos}"
rows.append((word_id, osis, ch, vs, pos, slot, surface, lemma,
             strongs_id, morph, gloss, language, xlit, lexical_class))
```

The `rows` tuple gains `slot` at index 5 (shifting all subsequent indices by 1).

### 5.3 `import_macula_hebrew()` — BibleHub translit enrichment with validation

> See ADR-020 for the full validated implementation of `_apply_bh_hebrew_translit()`, including per-verse count check, per-slot Strong's alignment check, and mismatch TSV output. The skeleton below shows the call site only.

After loading rows from `parse_macula_tsv()`, compute slot-level BH translit:

```python
def _apply_bh_hebrew_translit(rows, bh_translit):
    """
    For each Hebrew verse, rank slots in document order (1-based),
    then set xlit_slot on the first ROOT token of each slot.

    Root token = first (lowest position) token in a slot whose strongs_id
    is NOT in HELPER_STRONGS.
    """
    HELPER_STRONGS = {
        "H1886a", "H871a", "H3509a", "H1930a",
        "H2050b", "H2050c", "H2050d", "H5105b",
    }

    from collections import defaultdict

    # Group rows by verse, then by slot within verse
    # rows index: 0=id, 1=book_id, 2=ch, 3=vs, 4=pos, 5=slot, 6=surface, ...
    verse_slots = defaultdict(lambda: defaultdict(list))
    for i, row in enumerate(rows):
        book_id, ch, vs, pos, slot = row[1], row[2], row[3], row[4], row[5]
        if slot is not None:
            verse_slots[(book_id, ch, vs)][slot].append((pos, i))

    # For each verse, rank slots and assign xlit_slot to root token
    xlit_overrides = {}   # {row_index: xlit_string}
    for (book_id, ch, vs), slots_dict in verse_slots.items():
        # Sort slots by minimum position within slot (= document order)
        ordered_slots = sorted(slots_dict.items(), key=lambda kv: min(p for p, _ in kv[1]))
        for display_pos, (slot_num, token_list) in enumerate(ordered_slots, 1):
            key = f"{book_id}:{ch}:{vs}:{display_pos}"
            bh_entry = bh_translit.get(key)
            if not bh_entry:
                continue
            translit = bh_entry.get("translit", "")
            if not translit:
                continue
            # Set xlit_slot on the first root (non-helper) token in this slot
            token_list_sorted = sorted(token_list, key=lambda x: x[0])
            for pos, row_idx in token_list_sorted:
                row = rows[row_idx]
                strongs_id = row[7]  # index 7 after slot insertion
                if strongs_id not in HELPER_STRONGS:
                    xlit_overrides[row_idx] = translit
                    break  # only the first root token

    # Apply overrides — rows are tuples, rebuild those that need xlit_slot
    # xlit_slot is the last field we'll add to the INSERT
    result = []
    for i, row in enumerate(rows):
        xlit_slot = xlit_overrides.get(i)
        result.append(row + (xlit_slot,))
    return result
```

Call this after `parse_macula_tsv()` in `import_macula_hebrew()`:

```python
bh_translit_path = DATA_DIR / "hebrew_translit.json"
bh_translit = {}
if bh_translit_path.exists():
    bh_translit = json.loads(bh_translit_path.read_text("utf-8"))
    print(f"  BibleHub Hebrew translit loaded: {len(bh_translit):,} entries")
else:
    print("  No hebrew_translit.json — run fetch_biblehub_translit_hebrew.py for slot xlit")

rows = parse_macula_tsv(raw, language="hbo", strongs_col="strongnumberx", lang_prefix="H")
rows = _apply_bh_hebrew_translit(rows, bh_translit)
```

### 5.4 `after_char` from XML enrichment

In `enrich_macula_from_xml()` → the inner loop that builds `updates`:

```python
# CORRECT — do NOT strip; preserve exact value from XML
raw_after = mac.get('after', '')
after_char = raw_after if raw_after not in ('', ' ') else None

updates.append((
    mac.get('gloss', '') or None,
    mac.get('role', '')  or None,
    mac.get('greek', '') or None,
    greek_strong          or None,
    after_char,           # ← new (was missing)
    word_id,
))
```

Update the `executemany` UPDATE:
```python
cur.executemany("""
    UPDATE word
    SET gloss_macula=?, syntax_role=?, greek=?, greek_strong=?, after_char=?
    WHERE id=?
""", updates)
```

### 5.5 `INSERT` statement updates

`import_macula_hebrew()` INSERT must include the new columns:

```python
cur.executemany(
    "INSERT OR IGNORE INTO word "
    "(id, book_id, chapter, verse, position, slot, surface, lemma, "
    " strongs_id, morph, gloss, language, xlit, lexical_class, xlit_slot) "
    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    rows
)
```

Greek stays unchanged (no slot, no xlit_slot — both NULL):
```python
cur.executemany(
    "INSERT OR IGNORE INTO word "
    "(id, book_id, chapter, verse, position, surface, lemma, "
    " strongs_id, morph, gloss, language, xlit, lexical_class) "
    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
    rows
)
```

### 5.6 `_ensure_strongs_stubs` — no change needed

This function uses `r[7]` (strongs_id). After inserting `slot` at index 5, `strongs_id` shifts to index 8. **Fix this index** in the function:

```python
# BEFORE (wrong after schema change):
sid = r[7]
# AFTER:
sid = r[8]   # slot inserted at index 5 shifts strongs_id from 7 → 8
```

---

## 6. `DatabaseService.swift` Changes

Add the three new columns to the `loadWords()` SELECT:

```swift
let sql = """
    SELECT w.id, w.surface, w.strongs_id, w.morph, w.gloss_macula,
           COALESCE(NULLIF(s.transliteration,''), '') AS xlit_lex,
           w.xlit        AS xlit_ctx,
           w.syntax_role, w.greek, w.greek_strong,
           w.after_char,                                  -- col 10
           w.slot,                                        -- col 11
           w.xlit_slot                                    -- col 12
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
    ORDER BY w.position
    """
```

---

## 7. `BibleWord` Model Changes

```swift
struct BibleWord: Identifiable, Hashable {
    // … existing fields …
    let afterChar: String?    // trailing char (maqaf ־, sof pasuq ׃, etc.)
    let slot: Int?            // Macula !N group position; nil for Greek
    let xlitSlot: String?     // BibleHub combined slot translit (root token only)

    /// Surface form with trailing connector for text display.
    var displayText: String { text + (afterChar ?? "") }

    /// Best transliteration for display:
    /// 1. BibleHub combined slot translit (covers suffix-combined words)
    /// 2. Macula per-occurrence translit from TSV
    /// 3. TBESH lemma translit (from strongs.transliteration, passed as xlitSimple)
    func bestXlit(xlitSimple: String?) -> String? {
        xlitSlot ?? xlit ?? xlitSimple
    }
}
```

---

## 8. App Downstream — Slot Grouping (separate sprint)

This plan intentionally defers the slot-grouping UI changes to the next sprint. The DB rebuild delivers all necessary data. The app continues to render individual token rows unchanged until slot grouping is implemented.

**What changes in the next sprint:**

1. `OriginalWordsView` — group `verseWords` by `slot` before rendering; one `WordRow` per slot group
2. `WordRow` — display combined surface: concatenate `word.displayText` for all tokens in slot (preserving RTL order)
3. Transliteration display: use `tokens.compactMap(\.xlitSlot).first ?? tokens.compactMap(\.xlit).first ?? …`
4. Clickability: only the ROOT token's Strong's triggers lexicon lookup; helper tokens within the slot are non-clickable (already satisfied by ADR-016 NASB bridge — they have no NASB Strong's tag)
5. `after_char` display: append to the last token in the slot group (the one with the maqaf)

---

## 9. Sub-entry Lookup Fix (app)

**`DatabaseService.swift`** — update `strongs(id:)` method:

```swift
/// Looks up a Strong's entry, trying the full sub-entry ID first (e.g. H3917b),
/// then falling back to the base number (H3917) if the sub-entry isn't in our DB.
/// This handles both Macula sub-entries (H835a → H835) and NASB-specific sub-entries
/// (H3917b → try H3917b first; only fall back if absent, because H3917 ≠ H3917b).
func strongs(id: String) -> StrongsEntry? {
    lookupStrongs(id) ?? lookupStrongs(baseNumber(id))
}

private func baseNumber(_ id: String) -> String {
    // "H3917b" → "H3917",  "H835a" → "H835",  "H3808" → "H3808"
    let stripped = id.drop(while: { !$0.isNumber })
    let digits   = stripped.prefix(while: { $0.isNumber })
    let prefix   = id.prefix(1)   // "H" or "G"
    return "\(prefix)\(digits)"
}
```

---

## 10. Run Order (Full Rebuild)

```bash
cd ~/Projects/SourceBible

# Step 1 — fetch BibleHub Hebrew translit (one-time; ~5 hrs first run, instant if cached)
python3 scripts/fetch_biblehub_translit_hebrew.py
# → data/hebrew_translit.json  (~23,145 entries, one per OT verse-slot position)

# Step 2 — full DB rebuild
python3 scripts/build_db.py               # ~10 min
python3 build_verse_map.py sourcebible.db  # ~1 min, 7292 rows
python3 scripts/import_commentaries.py sourcebible.db  # ~2 min

# Step 3 — copy and clean build
cp sourcebible.db SourceBible/Resources/sourcebible.db
# Xcode: ⇧⌘K → Run
```

**No migration scripts needed.** Full rebuild replaces all previous patches (`fix_subentry_xlit.py`, `add_after_char.py`, etc.).

---

## 11. Verification Checklist

| Check | How | Expected |
|---|---|---|
| `after_char` populated | `SELECT surface, after_char FROM word WHERE book_id='PSA' AND chapter=1 AND verse=1 LIMIT 5` | Row 1: `אַ֥שְֽׁרֵי` / `־` |
| `slot` populated | `SELECT surface, slot, position FROM word WHERE book_id='PSA' AND chapter=1 AND verse=2` | Rows with same slot (e.g. חֶ֫פְצ֥וֹ tokens share slot 5) |
| `xlit_slot` populated | `SELECT surface, xlit_slot FROM word WHERE book_id='PSA' AND chapter=1 AND verse=2 AND slot=5` | Root token: `ḥep̄-ṣōw`; helper token: NULL |
| Display word count | `SELECT COUNT(DISTINCT slot) FROM word WHERE book_id='PSA' AND chapter=1 AND verse=1` | 15 |
| Combined surface for slot 2:5 | Group tokens where `book_id='PSA' AND chapter=1 AND verse=2 AND slot=5`, concat `surface+after_char` | `חֶ֫פְצ֥וֹ` |
| Maqaf shows in simulator | Psalm 1:1 Original tab | אַ֥שְֽׁרֵי－ visible |
| `verse_map` row count | `SELECT COUNT(*) FROM verse_map` | 7,292 |
| strongs sub-entry fallback | Tap H3917b in any mocker verse | Shows correct "mocker/scoffer" definition, not "lion" |

---

## 12. Files Changed

| File | Change |
|---|---|
| `scripts/fetch_biblehub_translit_hebrew.py` | **New** — positional BH Hebrew scraper (verify HTML structure before finalising regex per ADR-020) |
| `scripts/build_db.py` | `SCHEMA`: add `slot`, `after_char`, `xlit_slot` columns + index; `parse_macula_tsv()`: save `slot`; `_ensure_strongs_stubs`: fix index after slot insertion; `enrich_macula_from_xml()`: add `after_char`; `import_macula_hebrew()`: call `_apply_bh_hebrew_translit()` |
| `SourceBible/Models/BibleModels.swift` | Add `afterChar`, `slot`, `xlitSlot` to `BibleWord`; add `displayText` and `bestXlit()` |
| `SourceBible/Services/DatabaseService.swift` | Add three columns to `loadWords()` SELECT; update `strongs(id:)` with sub-entry fallback |
| `SourceBible/Views/BottomSheet/WordTabContent.swift` | Use `word.displayText` in `WordRow` (maqaf fix) |
| `docs/INDEX.md` | Add this plan |
| ~~`scripts/add_after_char.py`~~ | Superseded — delete after rebuild |
| ~~`scripts/fix_subentry_xlit.py`~~ | Superseded — delete after rebuild |
| ~~`scripts/migrate_word_schema.py`~~ | Superseded — delete after rebuild |

---

## 13. Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| BibleHub page structure changes mid-scrape | Low | Cache HTML; re-parse from cache any time |
| Word count mismatch (Macula ≠ BH) for some verses | Low (confirmed parity for Ps 1) | Log mismatches during build; use NULL `xlit_slot` as fallback |
| Helper ID set incomplete | Medium | HELPER_STRONGS set tested against Psalm 1; add any new IDs discovered during build |
| `_ensure_strongs_stubs` index off-by-one | Certain without fix | Fixed: strongs_id shifts from index 7 → 8 after slot insertion at index 5 |
| BibleHub rate limiting | Medium | `DELAY = 0.8`s + exponential backoff on 429/503; OT scrape is a one-time operation |
