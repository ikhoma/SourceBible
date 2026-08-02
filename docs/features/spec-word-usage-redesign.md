# Word Usage Tab — Redesign Spec

**Status:** Draft  
**Date:** 2026-05-27  
**Author:** Ivan Khoma

---

## Problem Statement

The Word Usage tab currently shows up to 30 occurrences in canonical Bible order. This is misleading in two ways: the label "N occurrences" implies a real total when it is actually a capped sample, and the canonical-order selection means common words always show Genesis/Matthew regardless of where the most theologically rich examples appear. A user studying יהוה (6 512 occurrences) or אָמַר (5 307) sees no meaningful cross-section of the Bible — just the opening chapters, repeatedly.

---

## Goals

1. Show the **true total** occurrence count in the Bible for every word.
2. Give the user a **representative cross-section** of how the word is used across different books.
3. Keep the view **fast and lightweight** — no pagination, no "Load More", no extra taps.
4. Lay the groundwork for a future **full concordance sheet** (separate phase).

---

## Non-Goals

- **Full concordance browsing** — listing all occurrences with filters and book breakdown is a separate future feature, modelled after the Comments sheet. Out of scope here.
- **LXX / Septuagint support** — Greek OT occurrences are deferred to a future phase (LXX data not yet in DB).
- **Sorting or filtering** within the Usage tab — deferred to the full concordance sheet.
- **Pagination / Load More** — deliberately avoided; one example per book is sufficient for v1.
- **Particle suppression** — hiding articles/conjunctions from Usage is deferred; the by-book layout makes these less noisy naturally.

---

## Design

### Layout

```
┌─────────────────────────────────────────────────────┐
│  6 512 випадків в Біблії                            │  ← total count header
├─────────────────────────────────────────────────────┤
│  Буття          ·  164  │                           │
│  І побачив Бог...                                   │  ← one example verse
│  Вихід          ·   398 │                           │
│  І сказав Господь...                                │
│  ...                                                │
└─────────────────────────────────────────────────────┘
```

- **Header row:** total count + "випадків в Біблії / occurrences in the Bible"
- **Per-book row:** localized book name + count in that book (right-aligned or after a dot separator)
- **Example verse:** first occurrence in the book, highlighted (same highlight logic as current concordance), tappable → navigates to that verse
- Only books that contain at least one occurrence are shown
- OT books for Hebrew words (`language = 'hebrew'`), NT books for Greek words (`language = 'greek'`)

### Empty state

If a word has no concordance data (e.g. hapax legomenon with no Strong's mapping): show "No usage data available."

---

## Requirements

### P0 — Must Have

- [ ] New DB query: `SELECT book_id, COUNT(*) as cnt FROM word WHERE (strongs_id = ? OR strongs_id GLOB ? || '[a-z]') GROUP BY book_id ORDER BY book_id` — returns per-book count
- [ ] New DB query or extension: for each book, fetch the **first** occurrence verse text (lowest chapter + verse in that book)
- [ ] Total count query: `SELECT COUNT(*) ...` with same GLOB sub-entry logic as `loadConcordance`
- [ ] New model `BookUsageGroup`:
  ```swift
  struct BookUsageGroup: Identifiable {
      let bookId: String
      let bookName: String      // localized
      let count: Int
      let example: ConcordanceEntry  // first occurrence in book
  }
  ```
- [ ] `StrongsEntry` gains `totalCount: Int` and `bookGroups: [BookUsageGroup]` (replaces flat `concordance` array, or `concordance` is kept for legacy Preview use only)
- [ ] `WordUsageView` rewritten to render header + list of `BookUsageGroup` rows
- [ ] Example verse tappable — navigates to that verse in the reader (same as current concordance tap behavior)
- [ ] Localized count label: "6 512 випадків в Біблії" / "6,512 occurrences in the Bible"

### P1 — Nice to Have

- [ ] Book count badge styled distinctly from book name (e.g. secondary color)
- [ ] Section divider or subtle separator between book rows for scannability

### P2 — Future

- [ ] "Show all occurrences" → **stacked sheet** зі списком усіх входжень і фільтрами, змодельований за екраном Пошуку (див. Amendment 2026-08-02)
- [ ] LXX support: Greek words show OT occurrences from Septuagint when LXX data is added to DB v2
- [ ] Smarter example selection: instead of first occurrence, pick the verse with highest syntactic/rhetorical weight (requires NLP signal in DB) v1.5

---

## Data Layer Changes

### New method in `DatabaseService`

```swift
func loadBookUsageGroups(strongsId: String,
                         translation: String,
                         fallbackTranslation: String = DatabaseService.defaultFallbackTranslation
) -> (total: Int, groups: [BookUsageGroup])
```

**Step 1 — total count:**
```sql
SELECT COUNT(DISTINCT w.book_id || '|' || w.chapter || '|' || w.verse)
FROM word w
WHERE (w.strongs_id = ?
   OR (w.strongs_id GLOB ? || '[a-z]'
       AND length(w.strongs_id) = length(?) + 1))
```

**Step 2 — per-book counts + first example:**
```sql
SELECT w.book_id,
       COUNT(*) AS cnt,
       MIN(w.chapter * 1000 + w.verse) AS sort_key,  -- to find first occurrence
       -- fetch verse text for the first occurrence via a subquery or separate pass
FROM word w
WHERE (w.strongs_id = ? OR ...)
GROUP BY w.book_id
ORDER BY w.book_id
```

For the example verse, the simplest approach is a single extra query per book (lazy, inside the loop) or a single query using a window function / correlated subquery. Given the small number of books (max 39 OT, 27 NT), per-book queries are fine.

> **Note:** All DB calls for this feature stay on MainActor (same pattern as current `loadConcordance`). Performance is acceptable — group-by on an indexed `book_id` + `strongs_id` column is fast.

---

## User Stories

- As a student studying יהוה, I want to see how many times it appears in each book so that I can understand its distribution across the canon.
- As a reader tapping a word in Psalms, I want to see one example from each book so that I can immediately navigate to a familiar context (e.g. Genesis or Isaiah) for comparison.
- As a user, I want the total count to be accurate (not capped) so that I trust the app's data.

---

## Open Questions

| # | Question | Owner | Blocking? |
|---|----------|-------|-----------|
| 1 | Should the example verse be the **first** occurrence in the book, or a **random** one? First is stable and predictable; random gives variety but changes on each load. | Ivan | No — default to first for v1 |
| 2 | Should `bookGroups` replace `concordance` entirely in `StrongsEntry`, or coexist? Replacing is cleaner; coexisting avoids breaking sample data in Preview. | Engineering | Yes — affects model design |
| 3 | Book name localization: `BibleBookNames` already has EN+UK — confirm it covers all 66 books in both locales before shipping. | Engineering | Yes |

---

## Success Metrics

- **Correctness:** Total count matches reference count from open-source concordance tools (e.g. STEPBible) for a spot-check of 10 words including יהוה, אָמַר, H1, G2316.
- **Performance:** `loadBookUsageGroups` completes in < 100ms on iPhone 12 for the highest-frequency word (יהוה, 6 512 occurrences).
- **Coverage:** All 39 OT books appear for יהוה (it appears in every OT book); all 27 NT books appear for G2316 (θεός).

---

## Timeline

This is a self-contained DB + ViewModel + View change with no external dependencies. Estimated effort: 1–2 days.

Suggested order:
1. Add `loadBookUsageGroups` to `DatabaseService` + unit-test counts against known values
2. Add `BookUsageGroup` model + update `StrongsEntry`
3. Update `ReaderViewModel.loadStrongs` to call new method
4. Rewrite `WordUsageView`
5. Localization strings for count label

---

## Related Docs

- `docs/db_build.md` — `word` table schema, `strongs_id` GLOB sub-entry logic
- `verse_versification_system_design.md` — verse_map context (example verse display may need verse_map correction for Psalms)
- `unified_word_lookup_system_design.md` — how word tap flows into Strong's lookup
- `docs/bugs/new/bug-032.md` — затримка першого відкриття «Вживання»: N+1 запитів у
  `loadBookUsageGroups` (по одному на книгу), синхронний виклик на головному потоці,
  нелінивий рендер. План: спершу замір на пристрої, потім рішення

---

## Amendment 2026-08-02 — перехід із рядка книги прибрано

**Що було.** Рядок у «Вживання» (`ConcordanceView` → `BookUsageRow`) був
клікабельним: тап перекидав на вірш-приклад цієї книги через
`router.pendingVerseId`.

**Що не так.**

1. **Немає афордансу.** Рядок не мав ні шеврона, ні кольору посилання, ні
   press-стану — на відміну від сусіднього `CrossRefsView`, де шеврон є.
   Дію знаходили випадково; автор специфікації про неї не памʼятав.
2. **Стирав історію.** Навігація йшла через `VerseNavSource.fresh`, тобто
   **чистила cross-ref back stack** — кнопка «‹ Назад» зникала. Випадковий тап
   читався як «застосунок сам кудись поїхав».
3. **Не те очікування.** Рядок каже «5 разів у цій книзі». Природне очікування —
   «покажи ці 5», а не «стрибни на один приклад із них».

**Рішення: перехід прибрано** (не полагоджено). Рядок став чистим контентом.
Правильна відповідь на очікування — P2 вище, і вона не зводиться до однієї
навігації: N буває і 5, і 500, тож потрібен власний UI зі списком, пагінацією
та фільтрами. Форма — **stacked sheet поверх наявного**, змодельований за
екраном Пошуку (той самий рядок фільтрів, той самий формат рядка результату),
щоб не вигадувати другий патерн перегляду списку віршів.

**Наслідки для інших доків.** ADR-032 (карта хаптики) — хаптику з цього тапу
знято разом із самим тапом. ADR-024 — питання «чи має `.fresh` із шіта пушити
back stack» більше не стоїть: інших таких входів немає.
