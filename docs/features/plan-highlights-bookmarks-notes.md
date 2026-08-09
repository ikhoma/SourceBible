# Implementation Plan: Highlights, Bookmarks, Notes Updates

**Status:** Draft

**Based on:** `spec-highlights-bookmarks-notes.md`  
**Date:** 2026-05-22  
**Stack:** SwiftUI + GRDB, iOS 16+

---

## Architectural Decision: Cross-Tab Navigation

Before the phases, one structural problem must be solved first — it blocks both Bookmarks and Notes navigation.

### Problem

`EntriesView` (Bookmarks + Notes) does not have access to `selectedTab` or `ReaderViewModel`. Both live in `ContentView`. When a user taps a bookmark or a verse in a note, the app must:

1. Switch `selectedTab` to `.bible`
2. Call `readerVM.navigateTo(book:chapter:)` and set `selectedVerse`

Neither step is possible from `BookmarksListView` or `NoteEditorView` today.

### Solution: `AppNavigationRouter`

Add a lightweight observable coordinator owned by `ContentView`. Both `readerVM` and the entries views read from it.

```swift
// AppNavigationRouter.swift  (new file)
@MainActor
final class AppNavigationRouter: ObservableObject {
    @Published var pendingVerseId: String? = nil   // e.g. "ROM|5|1"
}
```

**In `ContentView`:**

```swift
@StateObject private var router = AppNavigationRouter()

// Pass to all tabs that need it
ReaderView().environmentObject(router)
EntriesView().environmentObject(router)

// React to navigation requests
.onChange(of: router.pendingVerseId) { verseId in
    guard let verseId else { return }
    selectedTab = .bible
    readerVM.navigateToVerse(id: verseId)   // see below
    router.pendingVerseId = nil
}
```

**In `ReaderViewModel`**, add:

```swift
func navigateToVerse(id: String) {
    // Parse "ROM|5|1" → book, chapter, verse
    // Call existing navigateTo(book:chapter:) then set selectedVerse
}
```

**In `BookmarksListView` / `NoteEditorView`**, inject `@EnvironmentObject var router: AppNavigationRouter` and call `router.pendingVerseId = verseId` on tap.

This pattern is:
- Zero coupling between features — no direct VM references across tabs
- Easily extended (search results, cross-references can also trigger navigation the same way)
- No Combine subjects, no singletons, no notification center

> **Implement `AppNavigationRouter` first. Everything else depends on it or is blocked without it.**

---

## Phase 1 — Cleanup & Data Correctness

*Goal: remove dead code, fix the Bookmarks product conflict, establish the navigation foundation.*  
*Nothing visible to users changes in the Reader yet.*

### Step 1.1 — Remove `UserDefaultsHighlightRepository`

**File:** `SourceBible/Services/HighlightRepository.swift` → **delete**

**Files to audit for call sites:**

```
grep -r "UserDefaultsHighlightRepository\|HighlightRepositoryProtocol" --include="*.swift"
```

Expected hits: `ReaderViewModel.swift`, `SourceBibleApp.swift` or wherever the app is bootstrapped. Replace with direct `UserDataStoreProtocol` calls — the methods already exist in `GRDBUserDataStore`:
- `isHighlighted(verseId:translation:)` ✅
- `allHighlightedVerseIds(translation:)` ✅
- `toggleHighlight(verseId:translation:color:)` ✅

**For Previews/Tests:** create `MockUserDataStore` (if not already present) that conforms to `UserDataStoreProtocol`. Remove `MockHighlightRepository`.

**UserDefaults migration:** Do not migrate. Add a one-time `UserDefaults.standard.removeObject(forKey: "source_bible.highlighted_verse_ids")` on first GRDB launch to clean up stale keys. Document in code.

---

### Step 1.2 — Remove Bookmark Categories

**Files to change:**

| File | Change |
|------|--------|
| `UserDataModels.swift` | Delete `BookmarkCategory` struct |
| `GRDBUserDataStore.swift` | Delete `BookmarkCategoryRow`, `saveCategory()`, `deleteCategory()`, `categories()` methods |
| `BookmarksViewModel.swift` | Delete `@Published var categories`, `saveCategory()`, `deleteCategory()` |
| `BookmarkEditorView.swift` | Remove entire "Категорія" `Section` and `@State var selectedCategoryId` |
| `EntriesView.swift` | Remove "Нова категорія" menu item from toolbar |
| `UserDataStoreProtocol.swift` (if exists) | Remove category method signatures |

**Schema:** Drop `bookmark_categories` table via a new GRDB migration. No users affected yet — this is safe to do destructively:

```swift
migrator.registerMigration("v2_drop_bookmark_categories") { db in
    try db.execute(sql: "DROP TABLE IF EXISTS bookmark_categories")
}
```

Also drop the `category_id` column from `bookmarks` if SQLite version supports `DROP COLUMN` (SQLite 3.35+, available iOS 15.4+). If targeting iOS 15 exactly, use a table-rebuild migration instead:

```swift
// iOS 15.4+ (SQLite 3.35+):
try db.execute(sql: "ALTER TABLE bookmarks DROP COLUMN category_id")

// Fallback for older SQLite:
// CREATE TABLE bookmarks_new (...without category_id...);
// INSERT INTO bookmarks_new SELECT id, user_id, created_at, ... FROM bookmarks;
// DROP TABLE bookmarks;
// ALTER TABLE bookmarks_new RENAME TO bookmarks;
```

Since minimum deployment target determines which path to take, check `SourceBibleApp` target settings first.

**After removal**, `BookmarkEditorView` becomes so minimal it may only show the verse reference. Evaluate at this point whether the editor sheet is worth keeping or whether the bookmark should save immediately on tap (see Open Question #1 from spec). Recommend: **immediate save, no sheet**. Remove `BookmarkEditorView.swift` entirely if that's the decision.

---

### Step 1.3 — Implement `AppNavigationRouter`

**New file:** `SourceBible/Navigation/AppNavigationRouter.swift`

**Changes:**
- `ContentView.swift`: add `@StateObject var router`, pass via `.environmentObject(router)` to `ReaderView` and `EntriesView`, add `.onChange(of: router.pendingVerseId)` handler
- `ReaderViewModel.swift`: add `func navigateToVerse(id: String)` — parse the pipe-delimited ID, call `navigateTo(book:chapter:)`, set `selectedVerse`

No UI changes. No user-visible change yet. But the foundation is live.

---

### Step 1.4 — Human-Readable Verse References (Bookmarks list)

**File:** `BookmarksListView.swift` → `BookmarkRowView`

Parse `verseId` string ("ROM|5|1") into a displayable reference. A `VerseReference` helper (or extension on `String`) should already exist or be added:

```swift
extension String {
    /// "ROM|5|1" → "Romans 5:1" (uses BibleBookNames)
    var verseDisplayRef: String { ... }
}
```

Show only the reference for now (no text snapshot — that's P1.5).

---

### Phase 1 Checklist

- [ ] `HighlightRepository.swift` deleted, no remaining call sites
- [ ] `BookmarkCategory` struct deleted from model
- [ ] All category ViewModel methods removed
- [ ] `EntriesView` toolbar has no "Нова категорія" item  
- [ ] `BookmarkEditorView` has no category picker (or file deleted if going immediate-save)
- [ ] `AppNavigationRouter.swift` exists, wired into `ContentView`
- [ ] `ReaderViewModel.navigateToVerse(id:)` implemented
- [ ] Bookmark rows show "Romans 5:1" not "ROM|5|1"
- [ ] Build passes, no warnings

---

## Phase 2 — Navigation & Color Rendering

*Goal: make all three features interactive in the ways the spec promises.*

### Step 2.1 — Bookmark Tap → Reader Navigation

**File:** `BookmarksListView.swift`

Add `@EnvironmentObject var router: AppNavigationRouter`. On row tap:

```swift
.onTapGesture {
    guard let verseId = item.verseIds.first else { return }
    router.pendingVerseId = verseId
    // ContentView.onChange fires → tab switches → reader navigates
}
```

Remove `bookmarksVM.openEdit(bookmark:)` call from row tap (editing is now only via swipe action or long-press if desired).

---

### Step 2.2 — Color-Aware Highlight Rendering

This requires a small data flow change across three layers.

**`ReaderViewModel.swift`**

Change `allHighlightedVerseIds` from `Set<String>` to `[String: String]` (verseId → color):

```swift
// Before
@Published var highlightedVerseIds: Set<String> = []

// After  
@Published var highlightColors: [String: String] = [:]   // verseId → "green" | "yellow" | ...

// Load from store:
highlightColors = store.highlightColors(translation: currentTranslation)
// Add to UserDataStoreProtocol:
func highlightColors(translation: String) -> [String: String]
```

Implement `highlightColors(translation:)` in `GRDBUserDataStore` as a raw SQL query returning `(verse_id, color)` pairs.

**`VerseTextView.swift`**

Change signature:

```swift
// Before
var isHighlighted: Bool

// After
var highlightColor: String?   // nil = not highlighted
```

In `makeUIView` / `updateUIView`, apply background color based on `highlightColor`:

```swift
private func color(for token: String?) -> UIColor? {
    guard let token else { return nil }
    switch token {
    case "yellow": return UIColor.systemYellow.withAlphaComponent(0.35)
    case "green":  return UIColor.systemGreen.withAlphaComponent(0.30)
    case "blue":   return UIColor.systemBlue.withAlphaComponent(0.25)
    case "pink":   return UIColor.systemPink.withAlphaComponent(0.25)
    default:       return UIColor.systemYellow.withAlphaComponent(0.35)
    }
}
```

Apply as `NSBackgroundColorAttributeName` over the full attributed string. Both light and dark mode handled by `UIColor.system*` adaptive colors.

**All callers of `VerseTextView`** (`ReaderView` or wherever it's instantiated) — update to pass `highlightColor: highlightColors[verse.id]`.

---

### Step 2.3 — Color Picker in Bottom Sheet

**File:** `VerseBottomSheetView.swift`

The highlight action button currently calls `vm.toggleHighlight(...)`. Replace with a color picker sheet.

Add a new view `HighlightColorPicker`:

```swift
struct HighlightColorPicker: View {
    let currentColor: String?          // nil if not highlighted
    var onSelect: (String) -> Void     // called with chosen color token
    var onRemove: () -> Void
    
    private let palette = ["yellow", "green", "blue", "pink"]
    // Render as HStack of circle swatches + "Remove" button
}
```

In `VerseBottomSheetView`, show `HighlightColorPicker` as a `.sheet` or `.confirmationDialog` when the highlight button is tapped. On selection, call `store.toggleHighlight(verseId:translation:color:)` — the GRDB method already handles new/update/restore.

**State to track:** whether the current verse is highlighted and its color — derive from `vm.highlightColors[verse.id]`.

---

### Step 2.4 — Verse → Reader Navigation from Note Editor

**File:** `NoteEditorView.swift`

Add `@EnvironmentObject var router: AppNavigationRouter`.

Make `VerseContextCard` tappable:

```swift
ForEach(verseBlocks, id: \.id) { block in
    if let content = decodeVerseBlock(block) {
        VerseContextCard(verseId: content.verseId, text: content.text)
            .onTapGesture {
                dismiss()                                    // close note editor
                router.pendingVerseId = content.verseId     // trigger navigation
            }
    }
}
```

Notes without verse blocks have no `VerseContextCard` rendered at all — so no dead tap target (guard already implicit in `verseBlocks` being empty).

Ensure `NoteEditorView` receives the `router` in its environment — it's presented as a `.sheet`, so the environment must be explicitly passed at the call site in `NotesListView` and `VerseBottomSheetView`.

---

### Phase 2 Checklist

- [ ] Tapping a bookmark row switches to Bible tab and scrolls to verse
- [ ] Highlighted verses show their stored color (not just highlight/no-highlight)
- [ ] Un-highlighted verses show no color treatment
- [ ] Color picker opens on highlight action tap in bottom sheet
- [ ] Color picker pre-selects current color for already-highlighted verses
- [ ] Remove highlight works from color picker
- [ ] Tapping verse card in note editor closes editor and navigates to that verse
- [ ] Notes with no verse block: no crash, no dead tap target
- [ ] `AppNavigationRouter` injected correctly at all note editor call sites

---

## Phase 3 — Notes List Usability & Architectural Guards

*Goal: clean up the Notes list UX and verify multi-verse invariants.*

### Step 3.1 — Notes List: Verse Reference + Text Preview

**File:** `NotesListView.swift` → `NoteRowView`

```swift
private struct NoteRowView: View {
    let item: NoteWithBlocks
    
    var headline: String {
        if let verseId = item.verseIds.first {
            return verseId.verseDisplayRef          // "Romans 5:1"
        }
        return "Нотатка"
    }
    
    var preview: String? {
        item.blocks
            .first(where: { $0.type == .text })
            .flatMap { try? JSONDecoder().decode(TextBlockContent.self, from: Data($0.content.utf8)) }
            .map { String($0.body.prefix(80)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.body).fontWeight(.medium)
            if let preview { Text(preview).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
```

---

### Step 3.2 — Multi-Verse Architectural Guard Audit

This is a code review step, not a feature. Before shipping Phase 3, verify:

**`NoteEditorView.swift`**
- [ ] Verse block display uses `ForEach(verseBlocks, id: \.id)` — not `verseBlocks.first` or `verseBlocks[0]`

**`NoteRowView`**
- [ ] Headline uses `item.verseIds.first` — not a forced unwrap or index access

**`NotesViewModel.openNewNote(attachedTo:)`**
- [ ] Method signature: `func openNewNote(attachedTo verse: BibleVerse, translation: String)` — single verse, but `saveNote` is called with `verseIds: [verse.id]` (array)
- [ ] No method that takes a single `String` and passes it directly to a single-verse storage path

**`GRDBUserDataStore.assembleNote`**
- [ ] `NoteVerseRow` query has no `LIMIT 1`

If any of these fail the audit, fix before tagging the release.

---

### Step 3.3 — `EntriesView` Toolbar Cleanup

After Phase 1 removed "Нова категорія", also remove "Нова папка" from the toolbar if folder management UI is not being built in this cycle (P1). Keep only:
- Нова нотатка
- Нова закладка

Add folder creation back when Phase P1 folder UI is built.

---

### Phase 3 Checklist

- [ ] Notes list rows show verse reference as headline
- [ ] Notes list rows show text preview as subtitle (empty notes show only headline)
- [ ] "Нотатка" fallback shown for notes with no verse
- [ ] Multi-verse audit passed (all 4 items above)
- [ ] `EntriesView` toolbar matches current feature set (no dead menu items)

---

## P1 Cycle — Title + Folders

*Ship after Phase 3 is stable.*

### Notes Title (P1.4 → P1.6)

**Order of operations — strictly sequential:**

1. **DB migration first** (`GRDBUserDataStore.applyMigrations`):
   ```swift
   migrator.registerMigration("v2_notes_title") { db in
       try db.execute(sql: "ALTER TABLE notes ADD COLUMN title TEXT")
   }
   ```

2. **`Note` struct**: add `var title: String?`

3. **`NoteRow`**: add `var title: String?` field, update `toDomain()` and `from(_:)`

4. **`NoteEditorView`**: add `@State var noteTitle: String` initialized from `noteWithBlocks.note.title ?? ""`. Add `TextField("Назва…", text: $noteTitle)` above the verse context cards. Save `noteTitle` into `note.title` in `saveAndDismiss()`.

5. **`NoteRowView`**: update headline priority: `note.title` (if non-empty) → verse reference → "Нотатка"

---

### Folder Management UI (P1.7–P1.9)

The `NoteFolder` model and all store methods already exist. Only UI is missing.

**`NotesListView.swift`** — add a folder sidebar or segmented control:

```
[All] [Folder A] [Folder B] [+]
```

- "+" button → creates a new folder (inline text input or sheet)
- Selecting a folder → filters `notesVM.notes` to `folderId == selected`
- Long-press on folder chip → rename / delete options

**`NoteEditorView.swift`** — add a folder picker (e.g., a `Menu` button in the nav bar):

```swift
Menu {
    Button("Без папки") { selectedFolderId = nil }
    ForEach(notesVM.folders) { folder in
        Button(folder.name) { selectedFolderId = folder.id }
    }
} label: {
    Label(selectedFolderName, systemImage: "folder")
}
```

Save `selectedFolderId` into `note.folderId` in `saveAndDismiss()`.

**Deletion:** use existing `notesVM.deleteFolder(id:)` — notes are detached (folder_id → NULL), not deleted. Show a confirmation alert.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| `navigateToVerse(id:)` in ReaderViewModel scrolls to wrong verse due to verse_map offset | Medium | High | Test with Psalm 3 (verse_map affected chapter); use existing `findBestMaculaVerse` logic |
| `VerseTextView` color rendering conflicts with selected-word highlight state | Medium | Medium | Keep color as background tint, selected-word highlight as foreground overlay — different attribute keys |
| `v2_drop_bookmark_categories` migration fails on device | Very Low | Low | No users yet; migration wrapped in GRDB transaction — rolls back cleanly on failure; `DROP TABLE IF EXISTS` is safe even if table doesn't exist |
| GRDB migration `v2_notes_title` fails on device if user has read-only DB | Very Low | High | Always run migrations in `applyMigrations()` which GRDB wraps in a transaction; test on device before shipping |
| `AppNavigationRouter.pendingVerseId` set before tab switch animation completes → reader doesn't scroll | Low | Medium | Add small delay in `ContentView.onChange` if needed, or use `DispatchQueue.main.asyncAfter(0.3)` |

---

## File Change Summary

```
NEW
├── SourceBible/Navigation/AppNavigationRouter.swift

CHANGED
├── SourceBible/ContentView.swift                      (router wiring, onChange)
├── SourceBible/ViewModels/ReaderViewModel.swift       (navigateToVerse, highlightColors dict)
├── SourceBible/ViewModels/BookmarksViewModel.swift    (remove categories)
├── SourceBible/ViewModels/NotesViewModel.swift        (guard multi-verse)
├── SourceBible/Models/UserDataModels.swift            (remove BookmarkCategory; P1: add Note.title)
├── SourceBible/Store/GRDBUserDataStore.swift          (remove category methods; highlightColors(); P1: migration)
├── SourceBible/Views/Reader/VerseTextView.swift       (isHighlighted→highlightColor)
├── SourceBible/Views/BottomSheet/VerseBottomSheetView.swift  (color picker)
├── SourceBible/Views/Bookmarks/BookmarksListView.swift       (tap→router, readable refs)
├── SourceBible/Views/Notes/NoteEditorView.swift              (verse card tap→router)
├── SourceBible/Views/Notes/NotesListView.swift               (NoteRowView headline+preview)
├── SourceBible/Views/Entries/EntriesView.swift               (remove dead toolbar items)

NEW (Phase 2)
├── SourceBible/Views/BottomSheet/HighlightColorPicker.swift

DELETED
├── SourceBible/Services/HighlightRepository.swift
├── SourceBible/Views/Bookmarks/BookmarkEditorView.swift      (if immediate-save decision)
```

---

## Implementation Order

```
1. AppNavigationRouter        (unblocks navigation in Phase 2)
2. Remove HighlightRepository (standalone, no deps)
3. Remove Bookmark categories (standalone, no deps)
4. Readable bookmark refs     (standalone)
──── Phase 1 complete ────
5. ReaderViewModel.navigateToVerse + highlightColors dict
6. VerseTextView color rendering
7. Color picker (HighlightColorPicker)
8. Bookmark tap → router
9. Note verse card tap → router
──── Phase 2 complete ────
10. NoteRowView headline + preview
11. Multi-verse audit
12. EntriesView toolbar cleanup
──── Phase 3 complete ────
13. (P1) v2_notes_title migration + Note.title + editor + list
14. (P1) Folder management UI
```
