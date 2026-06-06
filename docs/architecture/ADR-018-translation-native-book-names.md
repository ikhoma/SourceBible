# ADR-018 — Translation-Native Book Names and Order

**Status:** Accepted  
**Date:** 2026-06-06

---

## Context

Book names and display order are currently hardcoded in `BibleBookNames.swift` — a Swift enum with static dictionaries for EN and UK locales, plus `ruFull` added in 2026-06 to support RST sharing.

This creates two problems:

**1. Names don't match the translation source.**  
Each MyBible source SQLite ships a `books` table with `long_name` and `short_name` in the translation's own language and tradition. For example:
- RST's source has "Псалтирь", "Иеремия", "Иакова" — authoritative Synodal names
- The Swift `ruFull` dictionary we added is a manual approximation of the same data

There is no guarantee that the Swift fallback stays in sync with the actual translation sources as new translations are added.

**2. Book order is hardcoded to Protestant canonical sequence (1–66).**  
`loadBooks()` always does `ORDER BY num`, where `num` is the Protestant canonical number. MyBible `books` table rows are ordered per that translation's tradition. For the current 4 translations (KJV, ASV, NASB, RST) this is identical, but it won't hold for Catholic or Orthodox translations (which have different orderings and deuterocanonical books).

---

## Decision

### New DB table: `book_name`

```sql
CREATE TABLE IF NOT EXISTS book_name (
    book_id        TEXT NOT NULL,
    translation_id TEXT NOT NULL,
    long_name      TEXT NOT NULL,
    short_name     TEXT NOT NULL,
    sort_order     INTEGER NOT NULL,
    PRIMARY KEY (book_id, translation_id),
    FOREIGN KEY (book_id)        REFERENCES book(id),
    FOREIGN KEY (translation_id) REFERENCES translation(id)
);
CREATE INDEX IF NOT EXISTS idx_book_name_tid ON book_name(translation_id);
```

`sort_order` is the position from the translation source's `books` table — not assumed to equal the Protestant `book.num`.

### `build_db.py` changes

During `import_translations()`, after opening the MyBible SQLite, attempt to read the `books` table:

```python
def _extract_book_names(src, book_mapping):
    """
    Read long_name / short_name from a MyBible `books` table.
    Returns list of (osis_id, long_name, short_name, sort_order).
    Falls back to empty list if the table doesn't exist (some stripped modules omit it).
    """
    try:
        cur = src.cursor()
        rows = cur.execute(
            "SELECT book_number, long_name, short_name FROM books ORDER BY book_number"
        ).fetchall()
    except Exception:
        return []   # `books` table absent — caller will use name_en fallback

    result = []
    for sort_order, (book_num, long_name, short_name) in enumerate(rows):
        osis = book_mapping.get(int(book_num))
        if osis and long_name:
            result.append((osis, long_name.strip(), (short_name or long_name).strip(), sort_order))
    return result
```

Insert into `book_name` per translation. If the `books` table is absent, fall back to `name_en` from the `book` table (already populated from the `BOOKS` constant).

### `DatabaseService` — new method

```swift
/// Returns {bookId → (longName, shortName, sortOrder)} for a given translation.
func loadBookNames(for translationId: String) -> [String: (long: String, short: String, order: Int)] {
    var result: [String: (String, String, Int)] = [:]
    let sql = """
        SELECT book_id, long_name, short_name, sort_order
        FROM book_name WHERE translation_id = ?
        ORDER BY sort_order
    """
    query(sql, [translationId]) { stmt in
        let id    = string(stmt, 0)
        let long  = string(stmt, 1)
        let short = string(stmt, 2)
        let order = Int(sqlite3_column_int(stmt, 3))
        result[id] = (long, short, order)
    }
    return result
}
```

### `ReaderViewModel` — cache per translation

```swift
/// Book name map for the current translation: bookId → (long, short, sortOrder).
/// Nil until loadBookNames() completes. Consumers fall back to BibleBookNames while nil.
@Published var translationBookNames: [String: (long: String, short: String, order: Int)] = [:]
```

Load (async, on translation change) alongside `loadChapter`. Invalidate and reload whenever `currentTranslation` changes.

Ordered book list for the picker:

```swift
var allBooks: [BibleBook] {
    // Re-order using sort_order from translationBookNames if available,
    // otherwise keep the canonical num order from the DB.
    let names = translationBookNames
    guard !names.isEmpty else { return _allBooks }
    return _allBooks.sorted {
        (names[$0.id]?.order ?? Int.max) < (names[$1.id]?.order ?? Int.max)
    }
}
```

### `BibleBookNames` — scope reduced to UI-only contexts

`BibleBookNames` remains the source of truth for UI strings that are **not tied to a specific translation**:
- Search result references
- Notes and bookmarks cards (which can span multiple translations)
- Cross-reference labels
- Chapter title in the reader toolbar
- Any context where `currentTranslation` is unavailable

It is **not** used in:
- Verse sharing (already uses translation-aware formatter)
- Book picker display names (will use `translationBookNames`)
- Any label rendered directly adjacent to verse text from a specific translation

### `VerseShareFormatter` — no change needed

Already calls `BibleBookNames.full(for:inLanguage:)`. After this ADR is implemented, the formatter should be updated to use `translationBookNames` passed from the ViewModel — the `inLanguage` fallback becomes unnecessary for any translation whose source has a `books` table.

---

## Fallback Chain

For any context that needs a book name for a specific translation:

```
translationBookNames[bookId]?.long
    ?? BibleBookNames.full(for: bookId, inLanguage: translation.language)
    ?? BibleBookNames.full(for: bookId)   // UI locale
```

This ensures the UI is never blank even if a new translation is added before its `build_db.py` import is updated.

---

## Consequences

### Positive
- Book names always come from the authoritative translation source
- Book order respects translation tradition — ready for Catholic/Orthodox additions
- `BibleBookNames` handwritten dictionaries become a pure fallback, not a maintenance burden
- Adding a new translation automatically gets correct names without touching Swift code

### Negative
- Requires a full DB rebuild (`build_db.py` + `build_verse_map.py`)
- Adds one async load per translation switch (small — 66 rows, ~1ms)
- `BibleBookNames.ruFull` added in ADR-018's implementation PR becomes dead code once RST's `books` table is extracted (can be removed in the same sprint or left as fallback)

### Neutral
- `book.num` and `book.testament` remain the canonical identifiers — `sort_order` in `book_name` is display-only
- The `books` table absence fallback makes the import robust against stripped MyBible modules

---

## Alternatives Considered

**Keep `BibleBookNames` as-is, add more language dicts manually.**  
Rejected: doesn't solve the "true to translation" requirement, and becomes a maintenance burden as translations grow. We'd need to verify every new translation's names against the source.

**Store only `long_name`, derive `short_name` by truncation.**  
Rejected: MyBible short names have translation-specific abbreviation conventions that can't be reliably derived (e.g., RST "1Пар" vs a generic "1П").

**One `book_name` row per language (not per translation).**  
Rejected: two translations in the same language can disagree on names (e.g., a modern Russian translation vs Synodal). Per-translation is the correct granularity.
