# ADR-017: Book Covers — Architecture

**Status:** Accepted  
**Date:** 2026-06-05  
**Deciders:** Ivan  
**Related:** PDR-Book-Covers.md, spec-book-covers.md

## Context

The app shows a test hero image (Doré engraving) only for Genesis chapter 1. The product decision (PDR-Book-Covers) calls for extending this to all 66 books with a consistent design: blue gradient background, optional Doré engraving, typographic overlay with book name + canonical section + chapter count. A Settings toggle must let users revert to the existing Large Title view.

## Decision

Introduce two new files — `BookCoverView` (pure SwiftUI view) and `BookCoverData` (static data model) — with minimal surgical changes to `ReaderView` and `MenuView`. Covers are **on by default**; the setting is "Hide Book Covers" (`hideBookCovers = false`).

## Options Considered

### Option A: Extend the existing genesis_header pattern inline in ReaderView *(rejected)*

| Dimension | Assessment |
|---|---|
| Complexity | Low initially, high long-term |
| Maintainability | Poor — 66 books = giant if/else or switch in the view |
| Testability | Hard — data and view mixed |
| Extensibility | Adding a new book image = editing view logic |

**Pros:** No new files, minimal diff  
**Cons:** Turns `ReaderView` into a data + layout blob; section labels and metadata scattered across the view layer

### Option B: BookCoverView + BookCoverData (chosen)

| Dimension | Assessment |
|---|---|
| Complexity | Low — two small files, clear responsibilities |
| Maintainability | High — data in one dict, view in one component |
| Testability | `BookCoverData` is a pure enum — trivially unit-testable |
| Extensibility | Adding an image = one dict entry in `BookCoverData` |

**Pros:** Single responsibility, `ReaderView` changes are 6 lines, data is co-located  
**Cons:** Two new files vs zero

### Option C: DB-driven cover config *(rejected)*

Store section labels and image names in SQLite. Would allow OTA updates without app releases.

**Pros:** Dynamic  
**Cons:** Overkill — covers change on release cycles, not at runtime; adds DB query on every chapter-1 load; complicates the build pipeline

## Trade-off Analysis

The core tension is **simplicity vs. flexibility**. Option A is simpler in the short term but doesn't scale to 66 books cleanly. Option C is more flexible but adds infrastructure for a problem that doesn't exist (covers are static). Option B hits the right point: the data is static and belongs in code, but it belongs in a dedicated module rather than in the view.

The `hideBookCovers` (default `false`) vs `showBookCovers` (default `true`) naming choice matters because `@AppStorage` persists across installs. Naming the key `"hideBookCovers"` means: users who never touch the setting get covers; users who disable covers have `hideBookCovers = true` stored. If the feature were ever removed, leftover `true` values in UserDefaults are inert — nothing reads `hideBookCovers` anymore and the old Large Title path is the only path.

## Consequences

**Easier:**
- Adding Doré images for more books: drop PNG in xcassets + one line in `BookCoverData.coverImages`
- Localizing section labels: single `switch` in `BookCoverData.sectionText(for:)` reads `appLanguage`
- Unit-testing section/metadata logic: `BookCoverData` has no UIKit/SwiftUI dependencies

**Harder:**
- Nothing — the two existing files (`ReaderView`, `MenuView`) each change by <10 lines

**To revisit:**
- Psalms Book subdivisions (Books 1–5): extend `rightMeta` to accept `chapterNumber` once needed
- Transition animation when toggling the setting while on chapter 1

## Action Items

1. [x] Write `BookCoverView.swift` — `Views/Reader/`
2. [x] Write `BookCoverData.swift` — `Models/`
3. [x] Update `ReaderView.swift` — swap genesis-only block for generic cover
4. [x] Update `MenuView.swift` — add Hide Book Covers toggle
5. [x] Add `menu.hide_book_covers` localization key (EN + UK)
6. [ ] Add Doré images for EXO, JOS, AMO to xcassets when ready
