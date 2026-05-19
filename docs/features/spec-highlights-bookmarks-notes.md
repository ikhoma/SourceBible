# PRD: Highlights, Bookmarks, Notes — Update Spec

**Status:** Draft  
**Date:** 2026-05-22  
**Scope:** Update work on three already-implemented features — not greenfield

---

## Context

All three features are partially implemented in `SourceBible`. The data layer (GRDB schema, ViewModels, store protocol) is largely correct and extensible. The gaps are mostly in: UI completeness, a product-level conflict in Bookmarks, a missing model field in Notes, and a legacy storage artifact in Highlights.

This spec covers what needs to change and why. It is grounded in the **Implementation Guide** (`Implementation Guide for Claude (Notes UPD).md`) and a direct audit of the codebase.

---

## Feature 1: Highlights

### Current State

| Layer | Status | Notes |
|-------|--------|-------|
| DB schema | ✅ GRDB | `highlights(id, user_id, verse_id, translation, color, …)` |
| Store methods | ✅ | `toggleHighlight`, `isHighlighted`, `allHighlightedVerseIds` |
| `Highlight` model | ✅ | Has `color: String`, no `category` |
| Legacy repository | ⚠️ | `UserDefaultsHighlightRepository` still exists in codebase |
| Reader rendering | ⚠️ Incomplete | `VerseTextView` receives `isHighlighted: Bool` — color is lost |
| Color picker UI | ❌ Missing | No UI for choosing color when highlighting |
| Categories | ❌ Missing | Schema has no category column; no UI |

### Problem Statement

The highlight feature marks Bible verses as meaningful, but currently renders all highlights identically (binary on/off) regardless of the stored color. Users who apply highlights for different purposes — promises, commands, prayer, character of God — have no visual way to distinguish them. The legacy `UserDefaultsHighlightRepository` also creates a dead code path that could cause confusion during future changes.

### Goals

1. Highlights render in their stored color in the Reader, not as a binary on/off state.
2. Users can choose a color when adding or editing a highlight.
3. The legacy `UserDefaultsHighlightRepository` is removed; `GRDBUserDataStore` is the single source of truth.
4. The architecture is ready for highlight categories without a schema migration (color → color + category).

### Non-Goals

- **Highlight categories UI (this release):** The Implementation Guide describes categories as a future capability. The schema does not yet have a `category` column. Adding it is a P2 — defer to avoid scope creep.
- **Sync / cloud backup:** `isDirty` flag is already in place; sync implementation is a separate initiative.
- **Sharing highlights:** Export or share functionality is out of scope.

### User Stories

- As a Bible reader, I want to highlight a verse in a specific color so that I can visually distinguish promises from commands from prayers at a glance.
- As a Bible reader, I want to see highlighted verses rendered in their color in the Reader so that the visual system I've built is reflected on screen.
- As a Bible reader, I want to change or remove a highlight color so that I can correct a misclassification without losing the verse reference.

### Requirements

#### P0 — Must Have

**1. Color-aware rendering in Reader**
Pass `highlight.color` (not just `isHighlighted: Bool`) from `ReaderViewModel` through to `VerseTextView`. Render highlighted text with a background or underline in that color.

Acceptance criteria:
- [ ] A verse highlighted in `green` renders with a green background tint in the Reader
- [ ] A verse highlighted in `yellow` renders differently from one highlighted in `green`
- [ ] An un-highlighted verse has no color treatment
- [ ] Color renders correctly on both light and dark mode

**2. Color picker in bottom sheet action bar**
When the user taps the highlight action on a verse:
- If not yet highlighted: show a color picker (e.g., 4–6 color swatches), apply selected color on confirm.
- If already highlighted: show the picker pre-selected on current color; allow re-color or removal.

Acceptance criteria:
- [ ] Tapping "Highlight" on an un-highlighted verse opens a color picker
- [ ] Selecting a color and confirming saves the highlight with that color and dismisses the picker
- [ ] Tapping "Highlight" on an already-highlighted verse shows the picker with the current color pre-selected
- [ ] User can remove the highlight from within the picker
- [ ] Picker supports a minimum of 4 colors: green, yellow, blue, pink (or product-decided palette)

**3. Remove `UserDefaultsHighlightRepository`**
Delete `HighlightRepository.swift` (both `UserDefaultsHighlightRepository` and `MockHighlightRepository`). Replace all call sites with `GRDBUserDataStore`. Ensure `ReaderViewModel` is injected with the GRDB-backed store, not the old UserDefaults one.

Acceptance criteria:
- [ ] `HighlightRepository.swift` no longer exists in the project
- [ ] No call site references `UserDefaultsHighlightRepository`
- [ ] Existing highlights stored in UserDefaults do not need to be migrated (acceptable data loss for early users; document this)
- [ ] `MockHighlightRepository` is replaced by a mock that conforms to `UserDataStoreProtocol` for previews/tests

#### P1 — Nice to Have

**4. Highlights panel / list view**
A dedicated screen listing all highlighted verses, grouped by color or sorted by book/chapter. Useful for review.

**5. Highlight count badge**
Show a small indicator on the Reader (e.g., in the verse margin or bottom tab) of how many highlights exist.

#### P2 — Future Considerations

**6. Highlight categories**
Add a `category TEXT` column to the `highlights` table (migration v2). Categories: Promises, Commands, Prayer, God's Character, Other. Color picker and category picker become a combined sheet. Architecture should not block this — store `color` and `category` as separate fields, not encoded together.

---

## Feature 2: Bookmarks

### Current State

| Layer | Status | Notes |
|-------|--------|-------|
| DB schema | ✅ GRDB | `bookmarks`, `bookmark_verses`, `bookmark_categories` |
| Store methods | ✅ | `saveBookmark`, `deleteBookmark`, `categories`, etc. |
| `Bookmark` model | ⚠️ Conflict | Has `categoryId: String?` — conflicts with product spec |
| `BookmarkCategory` model | ⚠️ Conflict | Entire model + schema exists — conflicts with product spec |
| Editor UI | ⚠️ Conflict | Category picker present in `BookmarkEditorView` |
| Navigation | ❌ Missing | Tapping a bookmark does not navigate to that verse in Reader |
| Verse text preview | ❌ Missing | `BookmarkRowView` shows verse ID but no verse text snapshot |

### Product Conflict: Categories

The Implementation Guide is explicit:

> **Bookmarks should NOT have categories.**
> Reason: Categories overlap with highlights and future study notes. Bookmarks should remain lightweight.

The current implementation fully contradicts this. `bookmark_categories` table, `BookmarkCategory` model, and the category picker in `BookmarkEditorView` all exist.

**Recommended resolution:** Remove category support from Bookmarks entirely. The table can be soft-dropped in a migration (or left as dead schema) — it does not need to be physically deleted from the DB file, but all UI and ViewModel logic referencing categories should be removed.

This is a non-trivial change because `BookmarksViewModel` has `categories: [BookmarkCategory]`, `saveCategory`, `deleteCategory`, and `BookmarkEditorView` has a `Picker`. All of this needs to be removed.

### Problem Statement

Bookmarks exist as a navigation tool — a way to return to a verse quickly. Currently, tapping a bookmark does nothing (no navigation), the bookmark list shows raw verse IDs instead of human-readable references, and the feature is burdened with a category system that blurs the boundary between bookmarks and highlights. Users who want to organise their study have unclear guidance on which feature to use.

### Goals

1. Tapping a bookmark navigates the Reader to the bookmarked verse.
2. The bookmark list shows readable verse references and enough context to identify the verse.
3. Bookmarks are lightweight: no categories, no labels, no extra metadata.
4. The codebase is clean: category model and UI are removed, boundary with Highlights is clear.

### Non-Goals

- **Bookmark labels or names:** Per the Implementation Guide, knowledge organisation belongs to Notes. Bookmarks remain pure navigation.
- **Multiple verses per bookmark:** The schema supports `bookmark_verses` (many-to-many), but the UI should continue creating single-verse bookmarks for now. Multi-verse is a P2.
- **Folders for bookmarks:** Folders belong to Notes.

### User Stories

- As a Bible reader, I want to tap a bookmark and be taken directly to that verse in the Reader so that I can return to important passages without scrolling.
- As a Bible reader, I want to see a readable verse reference (e.g., "Romans 5:1") and a short text snippet in my bookmarks list so that I can identify the verse without opening it.
- As a Bible reader, I want to add a bookmark from the verse bottom sheet with a single tap so that the action is fast and doesn't interrupt my reading.
- As a Bible reader, I want to delete a bookmark with a swipe so that I can keep my list uncluttered.

### Requirements

#### P0 — Must Have

**1. Remove bookmark categories**
Delete all category UI, ViewModel methods, and model references. Specifically:
- Remove `BookmarkCategory` struct from `UserDataModels.swift`
- Remove `bookmark_categories` table methods from `GRDBUserDataStore` (`saveCategory`, `deleteCategory`, `categories()`)
- Remove `categories` published property from `BookmarksViewModel`
- Remove category `Picker` section from `BookmarkEditorView`
- Leave the `bookmark_categories` table in the SQLite schema as-is (do not add a destructive migration — simply stop writing to it)

Acceptance criteria:
- [ ] `BookmarkEditorView` shows only the verse reference, no category picker
- [ ] `BookmarksViewModel` has no category-related methods or properties
- [ ] No new rows are written to `bookmark_categories`

**2. Navigate to verse on bookmark tap**
Tapping a bookmark row in `BookmarksListView` should dismiss the bookmarks view and navigate the Reader to the bookmarked verse. Requires coordination with `ReaderViewModel` (scroll to chapter + highlight verse).

Acceptance criteria:
- [ ] Tapping a bookmark row opens the Reader at the correct book, chapter, and verse
- [ ] The tapped verse is visually indicated (selected state) after navigation
- [ ] Navigation works for all 66 books

**3. Human-readable verse reference in bookmark list**
`BookmarkRowView` must display the verse reference in readable form (e.g., "Romans 5:1") not the raw `verseId` string ("ROM|5|1"). Optionally show a short text snippet if available (requires a snapshot or a DB lookup).

Acceptance criteria:
- [ ] Bookmark rows show book name + chapter:verse (e.g., "Пс 23:1" or "Romans 5:1" depending on active translation)
- [ ] If verse text snapshot is stored, show first ~60 characters as subtitle
- [ ] If no snapshot is available, show only the reference (acceptable fallback)

**4. Simplify `BookmarkEditorView`**
After removing categories, the editor becomes trivial. Evaluate whether a full-screen editor is still needed or whether the bookmark can be saved immediately on tap (no editor sheet at all).

Acceptance criteria:
- [ ] Adding a bookmark from the bottom sheet either (a) saves immediately with no sheet, or (b) shows a minimal confirmation that does not require user input
- [ ] Decision documented in code comments

#### P1 — Nice to Have

**5. Verse text snapshot on save**
When saving a bookmark, store a text snapshot of the verse (translation + text) so the list can show it offline without a DB lookup. Requires adding a `verse_text` column to `bookmark_verses` or a new `bookmark_snapshot` field.

**6. Sort and filter bookmarks**
Allow sorting by date added or by Bible order (book/chapter/verse).

#### P2 — Future Considerations

**7. Multi-verse bookmarks**
The schema already supports `bookmark_verses` (many-to-many). Future UI could allow bookmarking a passage (e.g., Romans 5:1–5). Architecture is already correct — do not add FK constraints that would block this.

---

## Feature 3: Notes

### Current State

| Layer | Status | Notes |
|-------|--------|-------|
| DB schema | ✅ GRDB | `notes`, `note_blocks`, `note_verses`, `note_folders` |
| Block types | ✅ Defined | text, verse, word, quote, ai — all in `NoteBlockType` |
| `Note` model | ⚠️ Missing field | No `title` column/property — planned for V2 |
| Multi-verse foundation | ✅ Schema-ready | `note_verses` join table exists; UI currently creates single-verse notes only |
| Editor UI | ⚠️ MVP only | Shows verse block + UIKit text area; no title input |
| Folder management UI | ❌ Missing | `NoteFolder` model and DB exist; no UI to create/rename/delete folders |
| Verse → Reader navigation | ❌ Missing | Tapping verse block in editor does not navigate to that verse |
| Word block UI | ❌ Missing | Defined in schema; not rendered in editor |
| Note list preview | ⚠️ Partial | `NoteRowView` exists; shows verse ref fallback, no title field yet |

### Problem Statement

The Notes data model is well-architected (block-based, container pattern, future-proof for Study Notes). However, the UI only exposes a fraction of the model's capability: there is no way to navigate back to the verse from within a note, no folder management, and the note list shows a raw preview with no clear identity. The MVP ships with verse + text as the core interaction; title and richer organisation follow in V2.

### Goals

1. Users can write a reflection on a verse and return to that verse from the note with one tap.
2. The notes list gives enough context (verse reference + text preview) to identify a note without opening it.
3. Users can create and delete folders to organise their notes.
4. The architecture guarantees that adding multi-verse notes, a title field, and word blocks in V2 requires only UI changes — zero schema migrations.

### Non-Goals

- **Note title (this release):** MVP works with verse reference as the note's identity. Title field (DB column + editor input + list display) is a V2 item — schema must leave room for it, but UI is not built now.
- **Word blocks UI (this release):** The schema supports word blocks; rendering them in the editor requires word lookup UI. Defer to keep scope tight.
- **Quote blocks UI (this release):** Commentary integration is a future Study Notes feature. Not in scope.
- **AI blocks:** Explicitly V2+. No UI needed now.
- **Rich text formatting in notes:** Bold, italic, lists — the current UIKit text editor is plain text. Defer; requires editor replacement.
- **Multi-verse note UI (this release):** Schema already supports it via `note_verses`. Do not build UI for adding a second verse now, but do not make implementation decisions that assume a note has exactly one verse.

### User Stories

- As a Bible student, I want to write a reflection on a verse and tap its reference to jump back to the Reader so that I can re-read the context while reviewing my note.
- As a Bible student, I want the notes list to show the verse reference and a short text preview so that I can identify a note at a glance without opening it.
- As a Bible student, I want to create a folder and move notes into it so that I can organise my reflections by book, topic, or study series.
- As a Bible student, I want to delete a folder without losing its notes so that reorganising doesn't destroy my work.

### Requirements

#### P0 — Must Have

**1. Verse block → Reader navigation**
In `NoteEditorView`, the `VerseContextCard` (read-only verse display) should be tappable and navigate the user to that verse in the Reader. This requires dismissing the editor and triggering navigation in `ReaderViewModel`.

Acceptance criteria:
- [ ] Tapping the verse context card in a note dismisses the note editor
- [ ] The Reader opens at the correct book, chapter, verse
- [ ] The navigated verse is visually indicated (selected state) in the Reader
- [ ] Notes with no attached verse have no tappable verse card (no crash, no dead tap target)

**2. Notes list verse reference + text preview**
`NoteRowView` must display a human-readable verse reference as the primary label and the first ~80 characters of the text block as a subtitle. Title field does not exist yet — verse reference is the only identity signal at this stage.

Acceptance criteria:
- [ ] Row headline shows verse reference (e.g., "Romans 5:1") derived from the first `note_verses` entry
- [ ] Notes with no attached verse show "Нотатка" as the headline fallback
- [ ] Row subtitle shows first ~80 characters of the first `.text` block body, or nothing if empty
- [ ] Layout does not crash or show raw IDs

**3. Multi-verse architectural guard**
No code in this release may assume a note has exactly one verse. This is an implementation constraint, not a UI feature.

Acceptance criteria:
- [ ] `NoteEditorView` reads verse blocks from `noteWithBlocks.blocks` (array), not a hardcoded `[0]` index
- [ ] `NoteRowView` derives its headline from `noteWithBlocks.verseIds.first` — first of potentially many
- [ ] `openNewNote(attachedTo:)` in `NotesViewModel` inserts one `note_verses` row; the method signature and store call are written to accept `[String]` not a single `String`
- [ ] No `LIMIT 1` added to `note_verses` queries in `GRDBUserDataStore`

#### P1 — Nice to Have

**4. Add `title` field to `Note` model and DB**
Add `title TEXT` (nullable) to the `notes` table via a new GRDB migration `v2_notes_title`. Add `var title: String?` to the `Note` struct and update `NoteRow` serialisation. No UI yet — this is schema prep for V2.

Acceptance criteria:
- [ ] `notes` table has a nullable `title` column after migration
- [ ] Existing notes (null title) are unaffected
- [ ] `Note.title` round-trips correctly through `NoteRow`
- [ ] No editor input or list display for title yet (UI ships in a follow-up)

**5. Title input in `NoteEditorView`** *(requires P1.4)*
Add a title text field above the verse context card. Optional — saving is not blocked if empty.

**6. Title display in notes list** *(requires P1.4)*
`NoteRowView` shows `note.title` as the headline when non-nil and non-empty, falling back to verse reference.

**7. Folder creation and deletion UI**
`NotesListView` should expose a way to create, rename, and delete folders. On delete, notes in that folder are detached (moved to "no folder"), not deleted — this matches the existing `deleteFolder` logic in `GRDBUserDataStore`.

Acceptance criteria:
- [ ] User can create a new folder with a name
- [ ] User can rename an existing folder
- [ ] User can delete a folder; its notes move to the unorganised list
- [ ] Folder list is visible as a sidebar or picker in `NotesListView`
- [ ] Empty folders are allowed

**8. Assign note to folder from editor**
In `NoteEditorView`, allow the user to pick a folder for the note (or remove it from a folder).

**9. Filter notes by folder**
`NotesListView` can be filtered to show only notes in a specific folder.

#### P2 — Future Considerations

**10. Word blocks in editor**
Render `NoteBlock` with `type == .word` as a tappable Strong's word card inside the note. Tapping opens the word detail (same as long-press in Reader). Requires the Strong's lookup to be callable from the note context.

**11. Multiple verse references per note — UI**
The schema and `GRDBUserDataStore` already support multiple `note_verses` rows per note. This P2 adds the UI: an "Add verse" button inside `NoteEditorView` that appends a second `VerseContextCard` and a new entry in `note_verses`. Architecture is already correct (see P0.3 guard).

**12. Search across notes**
Full-text search over note titles and text block content. Requires FTS5 index on `note_blocks.content` (filtered to `type = 'text'`).

---

## Cross-Cutting Requirements

### Architecture invariants (do not violate)

- **Notes are containers, not verse properties.** The verse is attached to the note; the note does not belong to the verse. `note_verses` is the join table. Do not add a `verse_id` foreign key directly to `notes`.
- **Bookmarks are navigation tools only.** Do not evolve Bookmarks toward knowledge management. If a user wants to annotate a verse, that is a Note.
- **Highlights classify text.** They are the only feature that semantically annotates the Bible text itself. Notes and Bookmarks operate at the verse level, not the word level (for now).

### Shared DB concerns

All three features share `user_data.db` via `GRDBUserDataStore`. Migrations must be additive. The current migration key is `v1_initial_schema`. New migrations should use `v2_notes_title`, `v3_highlights_...` etc.

---

## Open Questions

| # | Question | Owner | Blocking? |
|---|----------|-------|-----------|
| 1 | **Bookmark editor vs. immediate save:** Should adding a bookmark show a confirmation sheet at all, or save immediately (tap → done)? If immediate, how does the user change their mind? | Design | Yes — affects P0.4 |
| 2 | **Highlight color palette:** What are the exact 4–6 colors? Do they need to respect system dark/light mode (use adaptive colors)? | Design | Yes — affects P0 Highlights |
| 3 | **UserDefaults → GRDB migration for Highlights:** Early users (TestFlight) may have highlights in UserDefaults. Migrate on first launch, or accept data loss and document it? | Product | No — but must decide before shipping |
| 4 | **Bookmark navigation coordination:** `ReaderViewModel` needs a "navigate to verse" method callable from `BookmarksListView`. What is the right coordination pattern — a shared navigation state object, a Combine subject, or environment injection? | Engineering | Yes — affects P0.2 Bookmarks |
| 5 | **Note title length:** Should there be a visible character counter or a max enforced in UI? | Design | No |

---

## Phasing Recommendation

**Phase 1 (current sprint) — Data correctness & core gaps**
- Remove `UserDefaultsHighlightRepository`
- Add `title` to Note model + migration
- Remove Bookmark categories from UI and ViewModel
- Human-readable verse refs in bookmark list

**Phase 2 — Navigation & rendering**
- Color-aware highlight rendering in Reader
- Color picker in bottom sheet
- Bookmark tap → Reader navigation
- Verse block tap → Reader navigation from Note editor

**Phase 3 — Usability polish**
- Notes list: verse reference headline + text preview
- Multi-verse architectural guard (P0.3) verified in code review
- Folder management UI

**V2 — Next cycle**
- Note `title` field: DB migration + editor input + list display
- Highlights list view
- Bookmark text snapshots
- Note word blocks
- Multi-verse note UI (schema already ready)

---

## Success Metrics

These features are shipping for the first time with full UI. No baseline exists. Targets are set as hypotheses to validate, not benchmarks against prior behavior.

### Leading Indicators (first 30 days)

| Metric | Definition | Target |
|--------|-----------|--------|
| Highlight adoption | % of active users who highlight at least one verse | ≥ 30% |
| Color variety | % of highlights created in a color other than the default | ≥ 40% — signals users understand the system |
| Bookmark adoption | % of active users who add at least one bookmark | ≥ 25% |
| Bookmark navigation rate | % of bookmark list opens that result in a Reader navigation tap | ≥ 50% — validates that bookmarks are used as navigation, not just collected |
| Note creation | % of active users who create at least one note | ≥ 20% |
| Note with verse context | % of notes created from the bottom sheet (verse attached) vs. standalone | Measure only — no target yet |

### Lagging Indicators (60–90 days)

| Metric | Definition | Target |
|--------|-----------|--------|
| Highlight retention | Users who highlighted in week 1 still highlighting in week 8 | ≥ 60% |
| Notes return rate | Users who create a note return to the Notes tab within 7 days | ≥ 40% |
| Feature co-use | % of users who use at least 2 of the 3 features | ≥ 30% — signals coherent study workflow, not isolated feature use |

### Stability

| Metric | Target | Window |
|--------|--------|--------|
| Crash-free rate on Highlights, Bookmarks, Notes screens | ≥ 99.5% | First 7 days post-launch |
| No data loss reports (highlights, notes, bookmarks disappearing) | 0 confirmed reports | First 30 days |
