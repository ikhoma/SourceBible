# Word Usage Tab — Implementation Plan

**Status:** Draft  
**Date:** 2026-05-27  
**Spec:** `spec-word-usage-redesign.md`  
**Estimated effort:** 1–2 days

---

## 1. Requirements Summary

### Functional
- Show true total occurrence count (whole Bible) for any Strong's ID
- Group occurrences by book; per-book row shows: book name, count in book, one example verse
- OT books for Hebrew words, NT books for Greek words
- Example verse is the first occurrence in the book (stable, deterministic)
- Example verse tappable → navigates reader to that verse
- v1.5 (future): replace "first" with highest-`rhetorical_weight` verse

### Non-Functional
- All DB calls stay on MainActor (consistent with current `loadConcordance` pattern)
- Total query + group-by query: < 100ms on iPhone 12 even for יהוה (6 512 occurrences)
- Zero breaking changes to existing Preview data in DEBUG builds

### Constraints
- SwiftUI + SQLite, no ORM; iOS 18+ deployment target
- Swift 6 strict concurrency — no new `@MainActor` isolation issues to introduce
- `strongs_id` GLOB sub-entry logic must be preserved (H835a, H871a etc.)

---

## 2. High-Level Design

```
┌──────────────────────────────────────────────────────────────────┐
│ WordUsageView                                                    │
│  header: "6 512 випадків в Біблії"                               │
│  ForEach BookUsageGroup:                                         │
│    BookRow(name, count, example → tap → router.navigate)         │
└───────────────────────┬──────────────────────────────────────────┘
                        │ StrongsEntry.bookGroups / .totalCount
┌───────────────────────▼──────────────────────────────────────────┐
│ ReaderViewModel.loadStrongs()                                    │
│  calls db.loadBookUsageGroups() → (total, [BookUsageGroup])      │
└───────────────────────┬──────────────────────────────────────────┘
                        │
┌───────────────────────▼──────────────────────────────────────────┐
│ DatabaseService.loadBookUsageGroups()                            │
│  Query A: COUNT(*) — total across all books                      │
│  Query B: GROUP BY book_id — count + first (chapter,verse) key   │
│  Query C: per-book verse text fetch (N ≤ 39/27 queries)         │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Model

### New: `BookUsageGroup`

**File:** `SourceBible/Models/StrongsModels.swift`

```swift
/// One book's contribution to a Strong's word concordance.
struct BookUsageGroup: Identifiable {
    let id: String               // bookId — unique per StrongsEntry
    let bookId: String
    let bookName: String         // localized, from BibleBookNames
    let count: Int               // total occurrences in this book
    let example: ConcordanceEntry  // first occurrence — for display + navigation
}
```

### Updated: `StrongsEntry`

Add two new fields; keep `concordance` for Preview backward-compat only.

```swift
struct StrongsEntry: Identifiable {
    // … existing fields unchanged …
    var concordance: [ConcordanceEntry]   // kept for DEBUG sample only; unused in prod UI
    var totalCount: Int                   // NEW: true total across whole Bible
    var bookGroups: [BookUsageGroup]      // NEW: per-book breakdown
}
```

**Default values** (so existing call sites compile without changes):
```swift
// In init — add with defaults:
var totalCount: Int = 0
var bookGroups: [BookUsageGroup] = []
```

### Updated: `StrongsEntry.sample` (DEBUG)

Add `bookGroups` sample data so Preview continues to render `WordUsageView`:

```swift
static let sample = StrongsEntry(
    // … existing …
    totalCount: 45,
    bookGroups: [
        BookUsageGroup(id: "PSA", bookId: "PSA", bookName: "Psalms", count: 26,
            example: ConcordanceEntry(id: "PSA|1|1", reference: "Psalm 1:1",
                text: "Blessed is the man...", bookId: "PSA", chapter: 1, verse: 1)),
        BookUsageGroup(id: "PRO", bookId: "PRO", bookName: "Proverbs", count: 8,
            example: ConcordanceEntry(id: "PRO|3|13", reference: "Proverbs 3:13",
                text: "Blessed is the man who finds wisdom...", bookId: "PRO", chapter: 3, verse: 13)),
        BookUsageGroup(id: "GEN", bookId: "GEN", bookName: "Genesis", count: 4,
            example: ConcordanceEntry(id: "GEN|30|13", reference: "Genesis 30:13",
                text: "Happy am I, for daughters will call me blessed.", bookId: "GEN", chapter: 30, verse: 13)),
    ]
)
```

---

## 4. Database Layer

### New method: `DatabaseService.loadBookUsageGroups`

**File:** `SourceBible/Services/DatabaseService.swift`

**Signature:**
```swift
func loadBookUsageGroups(
    strongsId: String,
    translation: String,
    fallbackTranslation: String = DatabaseService.defaultFallbackTranslation
) -> (total: Int, groups: [BookUsageGroup])
```

#### Query A — Total count

Count distinct verses (not word tokens) to match user intuition:

```sql
SELECT COUNT(DISTINCT w.book_id || '|' || w.chapter || '|' || w.verse) AS total
FROM word w
WHERE (w.strongs_id = ?
   OR (w.strongs_id GLOB ? || '[a-z]'
       AND length(w.strongs_id) = length(?) + 1))
```

Bindings: `[base, base, base]` where `base` = stripped strongsId (same GLOB logic as `loadConcordance`).

> **Why distinct verses, not word tokens?** A verse can contain the same Strong's word twice (e.g. לֵב in a parallelism). "26 times in Psalms" should mean 26 verses, not 26 tokens — consistent with how users think about concordance data.

#### Query B — Per-book first occurrence key

```sql
SELECT w.book_id,
       COUNT(DISTINCT w.chapter || '|' || w.verse) AS book_count,
       MIN(w.chapter * 1000 + w.verse)             AS first_cv
FROM word w
WHERE (w.strongs_id = ?
   OR (w.strongs_id GLOB ? || '[a-z]'
       AND length(w.strongs_id) = length(?) + 1))
GROUP BY w.book_id
ORDER BY w.book_id
```

Decode: `chapter = first_cv / 1000`, `verse = first_cv % 1000`.

> **Encoding safety:** Bible max chapter = 150 (Psalms), max verse = 176 (Psalm 119). `150 * 1000 + 176 = 150176`. Well within Int range and unambiguous.

#### Query C — Verse text per book

For each row from Query B, fetch the example verse text (same JOIN logic as current `loadConcordance`):

```sql
SELECT COALESCE(vm.trans_verse, w.verse) AS display_verse,
       COALESCE(v.text, v_fb.text)       AS resolved_text,
       CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
FROM word w
LEFT JOIN verse_map vm    ON vm.translation = ?
                          AND vm.book_id    = w.book_id
                          AND vm.chapter    = w.chapter
                          AND vm.macula_verse = w.verse
LEFT JOIN verse v    ON v.book_id    = w.book_id
                    AND v.chapter    = w.chapter
                    AND v.verse      = COALESCE(vm.trans_verse, w.verse)
                    AND v.translation = ?
LEFT JOIN verse_map vm_fb ON vm_fb.translation = ?
                          AND vm_fb.book_id    = w.book_id
                          AND vm_fb.chapter    = w.chapter
                          AND vm_fb.macula_verse = w.verse
LEFT JOIN verse v_fb ON v_fb.book_id   = w.book_id
                    AND v_fb.chapter   = w.chapter
                    AND v_fb.verse     = COALESCE(vm_fb.trans_verse, w.verse)
                    AND v_fb.translation = ?
WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
  AND (w.strongs_id = ?
   OR (w.strongs_id GLOB ? || '[a-z]'
       AND length(w.strongs_id) = length(?) + 1))
LIMIT 1
```

**N ≤ 39 calls** (OT books) or N ≤ 27 (NT). Each is a simple indexed lookup. Total wall time for יהוה (39 books): < 10ms.

#### Book name resolution

```swift
let bookName = BibleBookNames.name(for: bookId, locale: currentLocale)
```

`BibleBookNames` already covers all 66 books in EN + UK. No changes needed.

#### Reference string

Build it the same way `loadConcordance` does — using `BibleBookNames` + chapter + display_verse.

---

## 5. ViewModel Layer

**File:** `SourceBible/ViewModels/ReaderViewModel.swift`

Replace the `loadConcordance` call in `loadStrongs(strongsId:)`:

```swift
private func loadStrongs(strongsId: String) {
    isLoadingStrongs = true
    var entry = db.loadStrongs(id: strongsId)
    if var e = entry {
        let result = db.loadBookUsageGroups(strongsId: strongsId,
                                            translation: currentTranslation.id)
        e.totalCount = result.total
        e.bookGroups = result.groups
        // concordance kept empty — no longer used in production UI
        entry = e
    }
    strongsEntry = entry
    isLoadingStrongs = false
}
```

Also update the translation-switch re-load path (line ~155) — same call site, no extra changes needed since it already calls `loadStrongs(for: word)`.

---

## 6. View Layer

**File:** `SourceBible/Views/BottomSheet/WordTabContent.swift`

### Replace `WordUsageView`

```swift
// MARK: - Word Usage

struct WordUsageView: View {
    let entry: StrongsEntry
    @EnvironmentObject private var router: AppNavigationRouter  // for verse navigation

    var body: some View {
        let totalLabel = String(
            format: NSLocalizedString(MorphKey.usageTotalCount, comment: ""),
            entry.totalCount
        )
        return PillSection(verbatimTitle: totalLabel) {
            ForEach(entry.bookGroups) { group in
                BookUsageRow(group: group, strongsId: entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        router.navigateTo(verseId: group.example.id)
                    }
                Divider()
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - BookUsageRow

private struct BookUsageRow: View {
    let group: BookUsageGroup
    let strongsId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.bookName)
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
                Spacer()
                Text("\(group.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(highlightedVerseText(raw: group.example.rawText,
                                      fallback: group.example.text,
                                      strongsId: strongsId))
                .font(.callout).lineSpacing(3)
        }
        .padding(.bottom, 8)
    }
}
```

### Localization key: `MorphKey.usageTotalCount`

Add to `MorphKey.swift`:
```swift
static let usageTotalCount = "word.usage.total_count"   // "6 512 випадків в Біблії"
```

Add to `uk.lproj/Localizable.strings`:
```
"word.usage.total_count" = "%d випадків в Біблії";
```
Add to `en.lproj/Localizable.strings`:
```
"word.usage.total_count" = "%d occurrences in the Bible";
```

The existing `MorphKey.usageCount` key (`word.usage.count`) can be removed or kept as dead code until the next cleanup pass.

---

## 7. v1.5 Forward Compatibility

The `BookUsageGroup.example` field is a `ConcordanceEntry` — it doesn't care how the example was selected. Upgrading to `rhetorical_weight`-based selection in v1.5 only requires changing Query C:

```sql
-- v1.5: replace "ORDER BY w.chapter, w.verse LIMIT 1" with:
ORDER BY v.rhetorical_weight DESC, w.chapter ASC, w.verse ASC
LIMIT 1
```

No model changes, no view changes. The `verse.rhetorical_weight` column is additive — it can be added by `build_db.py` in v1.5 without breaking v1 queries (COALESCE to 0 if absent).

---

## 8. Trade-off Analysis

| Decision | Chosen | Alternative | Why |
|---|---|---|---|
| N per-book queries for verse text | ✅ Simple, < 10ms | Single query with window function | Window function subquery is hard to read + maintain; N ≤ 39 queries is negligible |
| Count distinct verses (not tokens) | ✅ User intuition | Count word tokens | "26 in Psalms" means 26 verses, not 26 word occurrences |
| Keep `concordance` field in `StrongsEntry` | ✅ Backward compat | Remove entirely | Preview sample data uses it; safe to clean up in next refactor sprint |
| Stay on MainActor | ✅ Consistent pattern | Background queue | Total time < 50ms even for יהוה; background queue adds complexity for no UX benefit at this scale |
| `chapter * 1000 + verse` encoding | ✅ SQLite-native, no extra column | Separate MIN(chapter) per group + follow-up | Avoids a second GROUP BY pass; decodes cleanly in Swift |

---

## 9. Implementation Order

| Step | File | What |
|---|---|---|
| 1 | `StrongsModels.swift` | Add `BookUsageGroup`; add `totalCount` + `bookGroups` to `StrongsEntry` with defaults; update sample |
| 2 | `DatabaseService.swift` | Add `loadBookUsageGroups(strongsId:translation:fallbackTranslation:)` |
| 3 | `ReaderViewModel.swift` | Replace `loadConcordance` call with `loadBookUsageGroups`; assign `totalCount` + `bookGroups` |
| 4 | `MorphKey.swift` | Add `usageTotalCount` key |
| 5 | `Localizable.strings` (uk + en) | Add `word.usage.total_count` string |
| 6 | `WordTabContent.swift` | Rewrite `WordUsageView`; add `BookUsageRow` |
| 7 | Manual test | Verify: יהוה shows 39 books, count matches STEPBible; G2316 shows 27 NT books |

---

## 10. Open Questions (from spec)

| # | Question | Decision |
|---|---|---|
| 1 | First vs. random example | **First** — deterministic, stable across sessions |
| 2 | Replace or coexist `concordance`? | **Coexist** with defaults — replace in a future cleanup sprint |
| 3 | BibleBookNames coverage? | Verify during Step 7 testing; all 66 books expected from ADR-007 work |

---

## Related Docs

- `spec-word-usage-redesign.md` — product requirements
- `proposal_smarter_examples_v1.5.md` — future `rhetorical_weight` selection
- `docs/db_build.md` — `word` table schema, GLOB sub-entry logic
- `verse_versification_system_design.md` — verse_map (affects example verse display in Psalms)
