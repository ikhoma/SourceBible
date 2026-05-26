# ADR-011: Notes & Bookmarks Persistence Layer

**Status:** Superseded by ADR-012  
**Date:** 2026-05-19  
**Deciders:** Ivan Khoma  
**Features:** F-09 Notes, F-10 Bookmarks

---

## Context

SourceBible needs local persistence for user-generated content: notes (text attached to verses, organised in folders) and bookmarks (verse references, organised in colour-coded categories). The app is iOS 15+, SwiftUI, no backend in v1. Data models (`Note`, `NoteFolder`, `Bookmark`, `BookmarkCategory`) are already `Codable` in `UserDataModels.swift`. The existing precedent is `HighlightRepositoryProtocol` backed by UserDefaults — a simple, working pattern already in production.

The key tension: pick a storage backend that is simple enough to ship fast, but structured enough to migrate to CloudKit or a backend in v2 without rewriting Views.

---

## Decision

Use **UserDefaults + JSON encoding** for v1, hidden behind repository protocols, with two separate `ObservableObject` ViewModels injected via `.environmentObject`.

---

## Options Considered

### Option A: UserDefaults + JSON (chosen)

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| iOS version req. | iOS 15+ ✅ |
| Migration to v2 | Protocol swap — Views unchanged |
| Team familiarity | High — same pattern as HighlightRepository |
| Query capability | Manual filter/sort in Swift |
| Data size limit | ~1MB practical limit; fine for v1 note volumes |

**Pros:**
- Zero new dependencies
- Consistent with existing HighlightRepository pattern
- Codable models are already written
- Instant reads from in-memory cache after first load

**Cons:**
- Not queryable — full-text search over notes requires loading all records into memory
- No atomic cross-entity transactions (e.g. delete folder + reassign notes)
- Practically capped at a few hundred notes before noticeable load time

---

### Option B: Separate writable SQLite file

| Dimension | Assessment |
|---|---|
| Complexity | Medium |
| iOS version req. | iOS 15+ ✅ |
| Migration to v2 | Schema migration tooling needed |
| Team familiarity | Medium — DatabaseService exists but is read-only |
| Query capability | Full SQL — joins, FTS, indexes |
| Data size limit | Effectively unlimited |

**Pros:**
- Full SQL queries — efficient folder-grouped fetches, full-text search
- Atomic transactions — safe cascade deletes
- Scales to thousands of notes

**Cons:**
- Requires writable SQLite setup (separate from bundled read-only DB)
- Schema migration complexity (ALTER TABLE, versioning)
- Adds ~200 lines of boilerplate before a single note is saved
- Over-engineered for v1 expected data volumes

---

### Option C: Core Data

| Dimension | Assessment |
|---|---|
| Complexity | High |
| iOS version req. | iOS 15+ ✅ |
| Migration to v2 | CloudKit via NSPersistentCloudKitContainer |
| Team familiarity | Low |
| Query capability | NSPredicate / NSFetchRequest |

**Pros:**
- First-class CloudKit sync path
- NSFetchedResultsController for live list updates

**Cons:**
- Heaviest option — `.xcdatamodeld`, NSManagedObject subclasses, merge policies
- Parallel model definitions (Codable structs vs NSManagedObject) or full migration away from Codable
- Hardest to onboard a new engineer quickly

---

### Option D: SwiftData

Requires **iOS 17+**. App targets iOS 15+. Ruled out immediately.

---

## Trade-off Analysis

The realistic v1 user has tens to low hundreds of notes. UserDefaults handles this comfortably. The only scenario where Option A fails is a power user with 500+ notes and full-text search — which is explicitly out of scope for v1 (BRD §14, "Advanced note-taking: out of scope").

The protocol boundary (`NoteRepositoryProtocol`, `BookmarkRepositoryProtocol`) is the load-bearing decision here, not the storage backend. It means Option A can be swapped for Option B or Core Data in v2 by writing a new conforming class — Views and ViewModels don't change.

---

## Architecture

```
ContentView
  └── .environmentObject(NotesViewModel())
  └── .environmentObject(BookmarksViewModel())

NotesViewModel: ObservableObject
  @Published notes: [Note]
  @Published folders: [NoteFolder]
  @Published draftNote: Note?          ← shared editor state (2 entry points)
  repo: NoteRepositoryProtocol

BookmarksViewModel: ObservableObject
  @Published bookmarks: [Bookmark]
  @Published categories: [BookmarkCategory]
  @Published draftBookmark: Bookmark?
  repo: BookmarkRepositoryProtocol

UserDefaultsNoteRepository: NoteRepositoryProtocol
  key "sourcebible.notes"              → [Note]   JSON
  key "sourcebible.noteFolders"        → [NoteFolder] JSON

UserDefaultsBookmarkRepository: BookmarkRepositoryProtocol
  key "sourcebible.bookmarks"          → [Bookmark] JSON
  key "sourcebible.bookmarkCategories" → [BookmarkCategory] JSON
```

**Cross-ViewModel coordination:** `ReaderViewModel` receives `NotesViewModel` via init or environment and calls `notesVM.openNewNote(attachedTo: verse)` from the bottom sheet action bar.

**New method needed in ReaderViewModel:**
```swift
func navigateTo(bookId: String, chapter: Int, verse: Int)
```
Called from note/bookmark card ↗ tap to deep-link back into Reader.

---

## Consequences

**Easier:**
- Ship Notes and Bookmarks within the existing architecture pattern
- No new dependencies or build config changes
- Previews work instantly — inject `InMemoryNoteRepository` conformance

**Harder:**
- Full-text search over notes (filter in-memory only)
- Atomic cascade deletes (delete folder → set `folderId = nil` on all affected notes — two separate writes)
- Sorting/filtering at scale (all records loaded, sorted in Swift)

**Revisit in v2:**
- When note count grows past ~300 or full-text search is requested → migrate to SQLite or Core Data
- When cross-device sync is required → swap to `CloudKitNoteRepository` or backend-backed repo

---

## Action Items

1. [ ] Add `UserDefaultsNoteRepository` conforming to `NoteRepositoryProtocol`
2. [ ] Add `UserDefaultsBookmarkRepository` conforming to `BookmarkRepositoryProtocol`
3. [ ] Create `NotesViewModel` with CRUD + `draftNote` state
4. [ ] Create `BookmarksViewModel` with CRUD + `draftBookmark` state
5. [ ] Inject both ViewModels in `SourceBibleApp` / `ContentView`
6. [ ] Add `navigateTo(bookId:chapter:verse:)` to `ReaderViewModel`
7. [ ] Wire "Нотатка" button in `VerseBottomSheetView` action bar → `notesVM.openNewNote(attachedTo:)`
8. [ ] Build `NoteEditorView` (verse attachment, folder picker, text area, Save)
9. [ ] Build `NotesListView` replacing `NotesEmptyView` (grouped by folder, ↗ ✏️ actions)
10. [ ] Build `BookmarkEditorView` (verse picker, category picker + color, Save)
11. [ ] Build `BookmarksListView` replacing `BookmarksEmptyView` (grouped by category)
12. [ ] Add `InMemoryNoteRepository` + `InMemoryBookmarkRepository` for Xcode Previews
