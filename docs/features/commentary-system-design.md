# Commentary System Design — Bug Diagnoses & Optimal Architecture

**Status:** Draft  
**Date:** 2026-06-03  
**Covers:** Calvin, Matthew Henry, Owen (Hebrews), Spurgeon

---

## 1. Current Schema (keep as-is)

```sql
CREATE TABLE comments (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    source        TEXT    NOT NULL,   -- 'Calvin' | 'Henry' | 'Spurgeon' | 'Owen'
    book_id       TEXT    NOT NULL,
    start_chapter INTEGER NOT NULL,
    start_verse   INTEGER NOT NULL,
    end_chapter   INTEGER NOT NULL,
    end_verse     INTEGER NOT NULL,
    text          TEXT    NOT NULL
);

CREATE TABLE comment_verses (
    comment_id INTEGER NOT NULL,
    book_id    TEXT    NOT NULL,
    chapter    INTEGER NOT NULL,
    verse      INTEGER NOT NULL,
    PRIMARY KEY (book_id, chapter, verse, comment_id)
);
CREATE INDEX idx_cv ON comment_verses(book_id, chapter, verse);
```

The two-table design is correct: `comments` preserves authorial structure, `comment_verses` is a lookup index. **No schema changes needed.**

Lookup path: `verse → comment_verses → comment_id → comments.text`

---

## 2. Bug Diagnoses

### Bug 1 — Henry: Genesis 2:7 shows content from verse 8

**Root cause confirmed by inspecting `MHC01002.HTM`.**

Henry's HTML uses two types of `<A NAME>` anchors:
1. **Cluster anchors** — a tight group of verse anchors placed *directly before* a `<A NAME="SecN">` tag. These declare what verses the upcoming section covers.
2. **In-body anchors** — verse anchors placed *inside* the preceding section's text, serving as navigation targets for cross-references (these do NOT mark a new section).

Actual anchor positions in Genesis 2:
```
Sec1   pos=2447   ← section 1 header ("The Creation")
Ge2_6  pos=7639   ← in-body anchor, 5192 bytes into section 1
Ge2_7  pos=7663   ← in-body anchor, same area
                  (no cluster before Sec1 → section 1 covers v1–7 implicitly)
Ge2_8  pos=18364  ← cluster: 200 bytes before Sec2
Ge2_9  pos=18388
...
Ge2_15 pos=18530
Sec2   pos=18564  ← section 2 header ("The Garden of Eden") covers v8–15
Ge2_16 pos=36013  ← cluster before Sec3
Ge2_17 pos=36038
Sec3   pos=36065  ← section 3 covers v16–17
Ge2_18 pos=43133  ← cluster before Sec4
Sec4   pos=43210  ← section 4 covers v18+
```

**What the current algorithm does:**  
It collects ALL verse anchors seen since the last Sec anchor, then assigns them to the next Sec. So `Ge2_6`, `Ge2_7` (deep in section 1) get bundled with `Ge2_8…Ge2_15` and all assigned to Sec2 (section 2). Section 1 ends up with **zero verse index entries**. Section 2 gets verses 6–15 but its text starts at Sec2, which discusses the Garden of Eden (v8+).

Result: user taps verse 7 → finds section 2 in `comment_verses` → sees Garden of Eden commentary. Tapping verses 1–5 finds nothing at all.

---

### Bug 2 — Owen: Hebrews 1 hangs / blank screen

**DB data is correct.** Inspecting `OwenHebrews-commentary.cmtx`:

```
Hebrews 1 rows: (1,1,1,2), (1,1,3,3), (1,1,4,4), (1,1,5,5), (1,1,6,6),
                (1,1,7,7), (1,1,8,9), (1,1,10,12), (1,1,13,13), (1,1,14,14)
```

All single-chapter (ch_begin = ch_end = 1), so the per-verse range expansion in `import_owen` runs the simple path correctly. Data is in the DB.

**Bug is iOS-side.** Probable causes:
- Commentary view doesn't handle `start_verse != verse` (range sections) — it may show nothing if it only looks for `start_verse == tapped_verse` instead of joining through `comment_verses`.
- Empty state isn't shown when query returns 0 rows (shows blank screen instead).
- If the UI loads commentary on the same query path as the DB lookup, and Owen returns RTF that strips to empty string for any entry, the empty state isn't triggered.

**Action required:** audit `DatabaseService` commentary query — confirm it JOINs through `comment_verses` and doesn't fall back to a direct `start_verse = ?` filter. Also ensure the empty-result state is explicitly handled in the view.

---

### Bug 3 — Henry: range markup (cosmetic / display)

This is working correctly at the DB level. Henry sections are stored with `start_verse / end_verse` ranges (e.g. 8–15), and all verses in the range are indexed. The iOS UI currently shows the commentary without indicating which verse range it covers. Users see content that seems to "start at verse 8" when they tapped verse 10, because there's no "Verses 8–15" header in the display.

**Action required:** iOS display layer should show `"Verses {start}–{end}"` when `start_verse != end_verse`, and `"Verse {start}"` when they're equal.

---

## 3. Fixes

### Fix 1 — Henry `_henry_extract_sections` rewrite

**Principle:** A verse anchor belongs to the section it immediately precedes (cluster), not the section it's embedded inside.

**Algorithm:**

For each `SecN` anchor, scan **backwards** through the anchor list and collect verse anchors that form an immediate cluster before it. "Immediate" means the gap between consecutive anchors is ≤ 1500 characters of raw HTML. Stop collecting when the gap exceeds 1500 chars or when hitting another Sec anchor.

Then infer the verse range for each section:
- If a section HAS a cluster: `start_verse = min(cluster)`
- If a section has NO cluster: `start_verse = previous_section.end_verse + 1` (or 1 for the first section)
- `end_verse = next_section.start_verse - 1` (or last verse of chapter for final section)

```python
GAP_THRESHOLD = 1500  # chars of raw HTML between cluster anchors

def _henry_extract_sections(html: str, chapter: int):
    # Collect all anchors in order
    anchors = [(m.start(), m.group(1))
               for m in re.finditer(r'<A\s+NAME="([^"]+)"', html, re.IGNORECASE)]

    verse_re = re.compile(r'^[A-Za-z]+\d+_(\d+)$')

    # Find Sec anchors and their preceding verse clusters
    sec_indices = [i for i, (_, name) in enumerate(anchors) if name.startswith("Sec")]
    sections = []  # [(sec_pos, [verse_ints], content_start_pos)]

    for si in sec_indices:
        sec_pos = anchors[si][0]
        cluster = []

        # Walk backwards from sec index, collecting immediate verse anchors
        for j in range(si - 1, -1, -1):
            apos, aname = anchors[j]
            if aname.startswith("Sec"):
                break
            m = verse_re.match(aname)
            if m:
                # Check gap to next item in cluster (or to Sec anchor itself)
                gap_to_next = (anchors[j + 1][0] if j + 1 < len(anchors) else sec_pos) - apos
                if gap_to_next <= GAP_THRESHOLD:
                    cluster.insert(0, int(m.group(1)))
                else:
                    break  # gap too large → in-body anchor, stop

        sections.append((sec_pos, cluster))

    if not sections:
        return []

    # Assign implicit verse ranges
    # Pass 1: determine each section's start verse
    section_starts = []
    for i, (sec_pos, cluster) in enumerate(sections):
        if cluster:
            section_starts.append(min(cluster))
        else:
            prev_end = section_starts[i - 1] + 1 if i > 0 else 1
            # prev_end is approximate; refine in pass 2
            section_starts.append(prev_end if i == 0 else None)

    # Fill None entries (sections with no cluster whose predecessor had no cluster either)
    for i in range(len(section_starts)):
        if section_starts[i] is None:
            # Infer from next section with known start
            for j in range(i + 1, len(section_starts)):
                if section_starts[j] is not None:
                    section_starts[i] = section_starts[j] - 1
                    break
            else:
                section_starts[i] = 1

    # Pass 2: determine end verse for each section
    result = []
    for i, (sec_pos, cluster) in enumerate(sections):
        next_start = section_starts[i + 1] if i + 1 < len(sections) else 999
        start_vs = section_starts[i]
        end_vs = next_start - 1 if next_start < 999 else 999  # 999 = "end of chapter"

        end_pos = sections[i + 1][0] if i + 1 < len(sections) else len(html)
        text = _strip_henry_html(html[sec_pos:end_pos])
        if text and start_vs >= 1:
            result.append((list(range(start_vs, end_vs + 1)), text))

    return result
```

**Validation**: after rebuild, `SELECT COUNT(*) FROM comment_verses WHERE book_id='GEN' AND chapter=2` should return ≥ 25 (covering at least the first 25 verses). Verse 7 should resolve to section 1, not section 2.

---

### Fix 2 — Owen iOS query audit

In `DatabaseService`, find the commentary lookup function and confirm it uses:

```swift
// CORRECT — via comment_verses join
SELECT c.* FROM comments c
JOIN comment_verses cv ON cv.comment_id = c.id
WHERE cv.book_id = ? AND cv.chapter = ? AND cv.verse = ?
AND c.source = 'Owen'
ORDER BY c.start_chapter, c.start_verse
```

NOT:
```swift
// WRONG — direct range filter misses single-verse Owen entries stored as ranges
SELECT * FROM comments
WHERE book_id = ? AND start_chapter = ? AND start_verse = ?
```

Also ensure the commentary view has an explicit `.emptyState` (or equivalent) when the result array is empty, instead of leaving the view blank.

---

### Fix 3 — iOS range header display

In the commentary cell/view, add a header line showing the section's coverage:

```swift
var rangeLabel: String {
    if comment.startVerse == comment.endVerse {
        return "Verse \(comment.startVerse)"
    } else {
        return "Verses \(comment.startVerse)–\(comment.endVerse)"
    }
}
```

---

## 4. Calvin — Status

Calvin's 13,342 sections are **all single-verse** in the OSIS source (`annotateRef="Bible:Gen.1.1"` etc. — no range refs). The OSIS-direct parser in `import_commentaries.py` is correct. The old BZV-based `import_calvin.py` was broken (sliced at arbitrary byte offsets). Current state is correct.

The 181 chapter-only refs (e.g., `1Tim.1`) are stored as `start_verse=0, end_verse=0` (chapter overview). These are not indexed in `comment_verses`. If the app wants to show them as chapter introductions, add handling separately.

---

## 5. Owen multi-chapter range expansion

The current `import_owen` uses a `min(v_e, v_s + 50)` heuristic for intermediate chapters in cross-chapter ranges. This is fragile — Hebrews chapters have ≤ 29 verses so it hasn't caused data loss, but the heuristic can fail for longer books if Owen data is ever extended.

**Fix**: replace with actual verse counts from the `verse` table:

```python
def _heb_verse_count(cur_main, chapter: int) -> int:
    row = cur_main.execute(
        "SELECT MAX(verse) FROM verse WHERE book_id='HEB' AND chapter=?", (chapter,)
    ).fetchone()
    return row[0] if row and row[0] else 50  # fallback

# In import_owen, for multi-chapter ranges:
for ch in range(ch_begin, ch_end + 1):
    v_s = vs_begin if ch == ch_begin else 1
    v_e = vs_end   if ch == ch_end   else _heb_verse_count(main_db_cursor, ch)
    for v in range(v_s, v_e + 1):
        insert_verse_index(cur, comment_id, "HEB", ch, v)
```

---

## 6. Build & Validation Checklist

After rebuilding the DB:

```bash
python3 scripts/import_commentaries.py sourcebible.db
```

Run validation queries:

```sql
-- 1. Henry: Genesis 2:7 must resolve to section 1 (v1–7), not section 2
SELECT c.start_verse, c.end_verse, substr(c.text, 1, 80)
FROM comments c
JOIN comment_verses cv ON cv.comment_id = c.id
WHERE cv.book_id='GEN' AND cv.chapter=2 AND cv.verse=7 AND c.source='Henry';
-- Expected: start_verse=1 (or 1–7), text about man's creation

-- 2. Henry: All verses 1–7 in Genesis 2 must be indexed
SELECT verse FROM comment_verses WHERE book_id='GEN' AND chapter=2
AND comment_id IN (SELECT id FROM comments WHERE source='Henry')
ORDER BY verse;
-- Expected: 1,2,3,4,5,6,7 (no gaps)

-- 3. Owen: All verses of Hebrews 1 must be indexed
SELECT verse FROM comment_verses WHERE book_id='HEB' AND chapter=1
AND comment_id IN (SELECT id FROM comments WHERE source='Owen')
ORDER BY verse;
-- Expected: 1,2,3,4,5,6,7,8,9,10,11,12,13,14

-- 4. No commentary text duplicated
SELECT source, COUNT(*) as n, COUNT(DISTINCT text) as uniq FROM comments GROUP BY source;
-- Expected: n == uniq for all sources

-- 5. Total row counts (rough sanity)
SELECT source, COUNT(*) FROM comments GROUP BY source;
-- Expected: Calvin ~13342, Henry ~7000+, Spurgeon ~1000+, Owen ~200+
```

---

## 7. Summary

| Issue | Layer | Fix |
|-------|-------|-----|
| Henry: wrong verse→section mapping | `import_commentaries.py` | Rewrite `_henry_extract_sections` with backwards cluster detection |
| Owen: Hebrews 1 blank screen | iOS `DatabaseService` | Audit query path; add empty state UI |
| Henry: no range header in UI | iOS view layer | Show "Verses X–Y" header when `start_verse != end_verse` |
| Owen: heuristic verse expansion | `import_commentaries.py` | Use actual verse counts from `verse` table |
| Calvin: OSIS parsing | — | Already correct, no action needed |

Schema is correct. All fixes are in the import script and iOS display layer only.
