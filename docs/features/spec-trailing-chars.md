# Trailing Characters — System Design

**Status:** Draft  
**Problem:** Original text display drops post-word characters (maqaf `־`, sof pasuq `׃`, paseq `׀`, Greek punctuation `,` `.` `·`) because they live in the Macula `after` XML attribute, separate from the surface word form. Psalm 1:1 word 1 is `אַ֥שְֽׁרֵי־` but we show `אַ֥שְֽׁרֵי`.

---

## 1. Requirements

**Functional**
- Display every Hebrew/Greek word with its trailing character(s) exactly as they appear in the Macula dataset
- Trailing char is part of the word's visual representation in `WordRow` (Original tab)
- The `word.text` field stays clean (surface form only) — `afterChar` is additive so existing features (Strong's lookup, xlit, search) are unaffected

**Non-functional**
- No rebuild required — a migration script patches the existing DB in ~1 min
- No new network fetch or runtime computation
- Backward-compatible: if `after_char` is NULL (column absent in old DB), display gracefully degrades to current behavior

**Scope**
- Phase 1 (this spec): Hebrew `after` from Macula Hebrew XML lowfat — covers the reported bug
- Phase 2 (future): Greek `after` from Macula Greek XML — Greek punctuation is lower priority

---

## 2. Data Source

### Macula Hebrew XML `<w>` nodes

Every `<w>` element in `WLC/lowfat/*.xml` carries an `after` attribute:

| Value | Meaning |
|---|---|
| `" "` | Word boundary (space) — no visual significance |
| `"־"` | Maqaf — connects two words into one stress unit |
| `"׃"` | Sof pasuq — verse-end marker |
| `"׀"` | Paseq — syntactic separator |
| `""` (absent) | End of line, no suffix |

We already open these files in `enrich_macula_from_xml()` and extract `gloss`, `role`, `greek`, `greekstrong`. Adding `after` is a one-line change in the same loop.

**Filter rule:** store NULL for space (`" "`) and absent; store the character for everything else. This keeps the column sparse and the view logic trivial.

---

## 3. Architecture

Four layers, each a small, isolated change:

```
build_db.py / add_after_char.py  ←  DB schema + populate
         ↓
    DatabaseService.swift         ←  SELECT w.after_char
         ↓
      BibleWord model             ←  add afterChar: String?
         ↓
       WordRow view               ←  display word.text + afterChar
```

---

## 4. Implementation Plan

### Step 1 — DB schema: add `after_char` column

**`scripts/build_db.py`** — `CREATE TABLE word`:
```sql
after_char  TEXT,              -- trailing char from Macula `after` attr (maqaf, sof pasuq, etc.)
```

**`enrich_macula_from_xml()`** — in the `updates.append(...)` call, add `after` extraction:
```python
raw_after = mac.get('after', '').strip()
after_char = raw_after if raw_after and raw_after != ' ' else None

updates.append((
    mac.get('gloss', '')  or None,
    mac.get('role', '')   or None,
    mac.get('greek', '')  or None,
    greek_strong          or None,
    after_char,                       # ← new
    word_id,
))
```

Update `executemany` SQL:
```python
cur.executemany("""
    UPDATE word
    SET gloss_macula=?, syntax_role=?, greek=?, greek_strong=?, after_char=?
    WHERE id=?
""", updates)
```

---

### Step 2 — Migration script (no rebuild)

**`scripts/add_after_char.py`** — for existing databases, runs in ~1 min:

```
1. ALTER TABLE word ADD COLUMN after_char TEXT
   (no-op if column already exists — catch OperationalError)
2. Open macula-hebrew-main.zip
3. For each chapter: load XML nodes, match to DB words (reuse _xml_match_verse logic)
4. UPDATE word SET after_char=? WHERE id=?
5. VACUUM (optional — keeps file size clean)
```

Run order:
```bash
cd ~/Projects/SourceBible
python3 scripts/add_after_char.py sourcebible.db
cp sourcebible.db SourceBible/Resources/sourcebible.db
# Xcode: ⇧⌘K → Run
```

---

### Step 3 — `BibleWord` model

**`Models/BibleModels.swift`**:
```swift
struct BibleWord: Identifiable, Hashable {
    // existing fields...
    let afterChar: String?    // trailing char from Macula `after` attr (e.g. "־", "׃")

    init(... afterChar: String? = nil) {
        // ...
        self.afterChar = afterChar
    }
}
```

---

### Step 4 — `DatabaseService.loadWords()`

**`Services/DatabaseService.swift`** — add `w.after_char` to SELECT:
```swift
let sql = """
    SELECT w.id, w.surface, w.strongs_id, w.morph, w.gloss_macula,
           COALESCE(NULLIF(s.transliteration,''), '') AS xlit_lex,
           w.xlit AS xlit_ctx,
           w.syntax_role, w.greek, w.greek_strong,
           w.after_char                                          -- col 10
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
    ORDER BY w.position
    """
```

In the row-reading closure:
```swift
let afterChar = optString(stmt, 10)
words.append(BibleWord(..., afterChar: afterChar))
```

**Backward-compat note:** if the running DB is pre-migration (column absent), SQLite returns NULL for missing columns and `optString` returns nil — display degrades gracefully.

---

### Step 5 — `WordRow` view

**`Views/BottomSheet/WordTabContent.swift`** — `WordRow.body`, in the top HStack:

```swift
// Before: Text(word.text)
// After:
(Text(word.text) + Text(word.afterChar ?? "").foregroundColor(.secondary))
    .font(.system(size: 26, weight: .light))
    .foregroundStyle(.primary)
```

Or simpler since trailing chars are part of the same script:
```swift
Text(word.text + (word.afterChar ?? ""))
    .font(.system(size: 26, weight: .light))
    .foregroundStyle(.primary)
```

The maqaf `־` is visually part of the word glyph cluster; same font and weight is correct. No separate styling needed.

---

## 5. Trade-offs

| Option | Pros | Cons | Decision |
|---|---|---|---|
| **Store in DB `after_char` column** | Authoritative, fast read, no runtime logic | Requires migration/rebuild | ✅ Chosen |
| Compute at runtime from verse text | No DB change | Fragile — requires reconstructing order from raw text, error-prone with cantillation marks | ✗ |
| Embed trailing char in `surface` during import | Single field to read | Breaks Strong's matching, xlit, search — `surface` must stay clean | ✗ |

---

## 6. Phase 2 — Greek (future)

Macula Greek XML (`macula-greek-main.zip`) has the same `after` attribute convention with Greek punctuation. Design is identical — add a second enrichment pass in `enrich_macula_from_xml` that handles `language='grc'` books. Deferred because the current bug report is Hebrew-only and Greek punctuation is less semantically significant than maqaf.

---

## 7. Files Changed

| File | Change |
|---|---|
| `scripts/build_db.py` | Add `after_char` column to schema; populate in `enrich_macula_from_xml` |
| `scripts/add_after_char.py` | **New** — fast migration script for existing DB |
| `SourceBible/Models/BibleModels.swift` | Add `afterChar: String?` to `BibleWord` |
| `SourceBible/Services/DatabaseService.swift` | Add `w.after_char` to `loadWords()` SELECT |
| `SourceBible/Views/BottomSheet/WordTabContent.swift` | Append `afterChar` in `WordRow` display |

No localization changes. No new DB tables. No new indexes (lookup is always by `word.id`).
