# ADR-003: File Modularity — Splitting Large Files into Focused Modules

**Status:** Proposed  
**Date:** 2026-05-11  
**Deciders:** Ivan Khoma  
**Affects:** All Swift files under `SourceBible/`

---

## Context

The project started with a single-file-per-concern approach which was correct at prototype stage. After completing the core reader, highlight persistence, and Strong's lookup, the codebase has grown to where two files are creating real friction:

| File | Lines | Type count | Problem |
|------|-------|-----------|---------|
| `Views/BottomSheet/VerseBottomSheetView.swift` | 925 | 14 structs/enums | Scroll fatigue; unrelated tabs mixed |
| `Models/BibleModels.swift` | 363 | 30+ types | Search/scroll to find the right type |
| `Views/Entries/EntriesView.swift` | 87 | 4 structs | `MenuView` lives in wrong folder |

A secondary concern: two reusable layout primitives (`FlowLayout`, `CapsuleNavGroupStyle`) are buried inside the bottom-sheet file, which prevents re-use elsewhere without creating a circular dependency between view files.

**Constraints:**
- Single Xcode target (no Swift Package modules) — file-level isolation only
- Xcode 16+ buildable folders — no manual "Add Files" step needed
- No ORM, no third-party dependencies — changes are pure file reorganisation
- Must not break any existing `#Preview` macros

---

## Decision

Reorganise from 13 files to 19 files by applying four targeted changes. No logic changes — pure file splits and moves.

---

## Options Considered

### Option A: No change (status quo)
| Dimension | Assessment |
|-----------|------------|
| Effort | None |
| Risk | None |
| Discoverability | Low — 14 types in one 925-line file |
| Scalability | Poor — BottomSheet will grow with commentaries, grammar |

**Pros:** Zero effort, zero risk of merge conflicts.  
**Cons:** Every tab feature (commentaries, grammar view) added to BottomSheet makes the file longer. Already at 925 lines with MorphologyDecoder embedded mid-file.

---

### Option B: Swift Package targets (full modularisation)
Extract `Models`, `Parsing`, `Services` into separate SPM local packages with explicit `import`.

| Dimension | Assessment |
|-----------|------------|
| Effort | High (2–4 days, Package.swift, import chains) |
| Risk | High — breaks preview hosts, may require @testable import rework |
| Build time | Better (parallel compilation) |
| Scalability | Best — enforces boundaries at compiler level |

**Pros:** True isolation; compiler enforces layering; enables unit tests per module without whole-target rebuild.  
**Cons:** Too early — the app has no build-time problem yet. SPM module boundaries require stable public API surface; we're still discovering the right model shapes (e.g., `ParsedVerse.plainText` not yet a stored property). Overhead is not justified at current scale.

---

### Option C: File-level split within single target ✅ Chosen
Split large files into focused files, move misplaced types, extract reusable components — all within the same Xcode target.

| Dimension | Assessment |
|-----------|------------|
| Effort | Low (≈1–2 hours, no logic changes) |
| Risk | Low — compiler catches any missed move immediately |
| Discoverability | High — 1 file = 1 concern |
| Scalability | Good — each new feature gets its own file from day one |
| Build time | Neutral (same target, incremental builds unchanged) |

**Pros:** Immediate readability win. Zero import changes. Xcode 16 buildable folders auto-detect new files.  
**Cons:** No compiler-enforced layering (internal types remain visible across files). A type could still be placed in the wrong file by mistake.

---

## Trade-off Analysis

Option B is the architecturally purest choice but introduces SPM complexity that would require stabilising the public model API first — premature at this stage. The right time for SPM modules is when we have a second target (e.g., a widget or tests that import `BibleCore`).

Option C gives 80% of the readability benefit at 5% of the effort. The missing 20% (compiler-enforced boundaries) can be added later by moving each folder into an SPM local package — the folder structure we're creating now mirrors what that migration would look like.

---

## Consequences

**What becomes easier:**
- Finding the code for a specific tab (Verse vs Word) without scrolling past unrelated structs
- Adding a new bottom-sheet tab — create a new file, not append to a 900-line one
- Reusing `FlowLayout` in future views (Search results chips, tag clouds) without import gymnastics
- Onboarding a second contributor — file names are self-explanatory

**What becomes harder:**
- Slightly more files to `⌘ click` through (19 vs 13)
- `MorphologyDecoder` (currently at line 666 of BottomSheet) needs its destination decided — `WordTabContent.swift` is proposed (it's word-view-specific logic)

**What we'll need to revisit:**
- When `CommentariesView` grows significantly, split into `Views/BottomSheet/CommentariesView.swift`
- If a widget target or test target is added, promote folders to SPM local packages (ADR-004)

---

## Proposed File Map

### Changes only (unchanged files omitted)

```
BEFORE → AFTER

Views/Entries/EntriesView.swift          → Views/Entries/EntriesView.swift  (MenuView removed)
                                          + Views/Menu/MenuView.swift         (NEW — moved)

Views/BottomSheet/VerseBottomSheetView.swift (925 lines, 14 types)
  → Views/BottomSheet/VerseBottomSheetView.swift  (container + sheet chrome, ~100 lines)
  → Views/BottomSheet/VerseTabContent.swift        (NEW — VerseTabView, VersePill, PillSection,
                                                     CrossRefsView, TranslationsView,
                                                     OriginalWordsView, CommentariesView,
                                                     CommentaryDetailView)
  → Views/BottomSheet/WordTabContent.swift         (NEW — WordTabView, WordSubTab,
                                                     WordMeaningView, WordUsageView,
                                                     WordCard, MorphologyDecoder)
  → Views/Components/FlowLayout.swift              (NEW — moved, reusable Layout)
  → Views/Components/CapsuleNavStyle.swift         (NEW — moved, reusable ViewModifier)

Models/BibleModels.swift (363 lines, 30+ types)
  → Models/BibleModels.swift     (core reading: BibleBook, Testament, BibleVerse,
                                   BibleWord, Translation, VerseTranslation,
                                   ParsedVerse, VerseSegment, SegmentStyle,
                                   ParsedFootnote, FootnoteKind, CrossReference,
                                   Theologian, Commentary + sample extensions)
  → Models/StrongsModels.swift   (NEW — StrongsEntry, ConcordanceEntry)
  → Models/UserDataModels.swift  (NEW — Highlight, Note, NoteFolder, Bookmark,
                                   BookmarkCategory)
```

### Execution order (dependencies matter)

1. **MenuView** — extract from `EntriesView.swift` → `Views/Menu/MenuView.swift`  
   _Risk: none. `ContentView` imports nothing explicitly._

2. **Components** — move `FlowLayout` + `CapsuleNavGroupStyle` → `Views/Components/`  
   _Must happen before BottomSheet split so WordTabContent can reference FlowLayout._

3. **BottomSheet split** — divide 925 lines into 3 files  
   _Biggest change. Each struct is self-contained; split is mechanical._

4. **Models split** — divide `BibleModels.swift` into 3 files  
   _Lowest risk. Same target — no import needed._

---

## Action Items

1. [ ] Create `Views/Menu/MenuView.swift`, move `MenuView` struct, remove from `EntriesView.swift`
2. [ ] Create `Views/Components/FlowLayout.swift` — move `FlowLayout: Layout`
3. [ ] Create `Views/Components/CapsuleNavStyle.swift` — move `CapsuleNavGroupStyle: ViewModifier`
4. [ ] Create `Views/BottomSheet/VerseTabContent.swift` — move 8 types
5. [ ] Create `Views/BottomSheet/WordTabContent.swift` — move 6 types + `MorphologyDecoder`
6. [ ] Trim `VerseBottomSheetView.swift` to container only (~100 lines)
7. [ ] Create `Models/StrongsModels.swift` — move `StrongsEntry`, `ConcordanceEntry`
8. [ ] Create `Models/UserDataModels.swift` — move 5 user-data types
9. [ ] Verify all `#Preview` macros still compile
10. [ ] Consider making `MorphologyDecoder` internal to `WordTabContent.swift` (not `enum` at top level) — reduces global namespace noise
