# ADR-012: Unified User Data Layer (GRDB + Block-based Notes + Sync-ready Schema)

**Status:** Accepted (amended ×4)  
**Date:** 2026-05-19  
**Amended:** 2026-05-19 (rev 2) — SyncEngine → v2; Auth → v1.5; note_blocks hybrid schema (verse_id/strongs_id as columns); DeviceIdentity pattern for pre-auth user_id; AuthService + SyncEngine as protocols with NoOp v1 impls  
**Amended:** 2026-05-20 (rev 3) — DeviceIdentity renamed to PreAuthIdentity (.userId → .stableId); clarified that ViewModels never access PreAuthIdentity directly; column name user_id retained (maps 1:1 to Supabase auth.uid())  
**Amended:** 2026-05-20 (rev 4) — Architecture review: note_verses vs note_blocks.verse_id dual-purpose documented; NoteWithBlocks + BookmarkWithVerses types defined; GRDB version pinned ~> 6.0; async protocol note added to v2 revisit; highlights confirmed translation-specific (YouVersion behavior)  
**Deciders:** Ivan Khoma  
**Supersedes:** ADR-011 (Notes & Bookmarks Persistence — UserDefaults approach)  
**Features:** F-08 Highlights, F-09 Notes, F-10 Bookmarks, Auth

---

## Context

ADR-011 proposed UserDefaults + JSON for Notes and Bookmarks, following the existing `HighlightRepository` pattern. Since then two new constraints emerged:

1. **Sync requirement.** The app will eventually sync to Supabase (Postgres + RLS), then migrate to a proprietary backend. Building on UserDefaults today means rewriting the entire persistence layer when sync is added — an expensive, risky migration.

2. **Block-based Notes.** Notes will grow beyond plain text in v2+: users will attach verses, Strong's words, commentary quotes, and AI-generated content to a note. A `text: String` model cannot represent this without a schema break.

Additionally, treating Highlights, Notes, and Bookmarks as three separate siloed repositories creates three separate sync engines, three separate dirty-tracking systems, and three separate migration paths. A unified layer is simpler.

The guiding principle from the architecture document: *build a sync-ready local architecture now, even if cloud sync is added later.*

---

## Decision

Replace the three-repository approach (ADR-011) with a **unified `UserDataStore`** backed by **GRDB (SQLite, writable)** with a sync-ready schema. Notes use a **block-based content model** from day one. Highlights are migrated from UserDefaults into the same store.

---

## Options Considered

### Option A: UserDefaults + JSON (ADR-011 — rejected)

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Sync-readiness | None — full rewrite required |
| Block-based notes | Not possible without schema break |
| Query capability | In-memory filter only |
| Migration cost | Low now, very high when sync is added |

**Pros:** Zero new dependencies; consistent with existing `HighlightRepository`  
**Cons:** Dead end — sync requires UUID primary keys, `updated_at`, `deleted_at`, dirty tracking; none of these exist in a JSON blob stored under a UserDefaults key. Adding them later = rewrite.

---

### Option B: GRDB + Unified Store (chosen)

| Dimension | Assessment |
|---|---|
| Complexity | Medium (new dependency, DB setup) |
| Sync-readiness | High — schema maps 1:1 to Supabase tables |
| Block-based notes | Native (note_blocks table with JSON payload) |
| Query capability | Full SQL — folder/category joins, ordering, FTS later |
| Migration cost | Medium now, near-zero when sync is added |
| iOS version | iOS 15+ ✅ |
| Team familiarity | Medium — similar mental model to existing DatabaseService |

**Pros:**
- Schema is sync-ready today: UUID PKs, `created_at`/`updated_at`/`deleted_at`, `is_dirty` flag
- GRDB provides type-safe Swift API, Codable support, WAL mode, built-in migrations
- One sync engine covers all entities
- Block-based note content is first-class from MVP
- `user_data.db` is completely separate from bundled read-only `sourcebible.db` — no interference

**Cons:**
- Adds GRDB as a new SPM dependency
- ~300 lines of DB setup vs. ~30 for UserDefaults
- Requires one-time migration of existing UserDefaults highlights

---

### Option C: Core Data

| Dimension | Assessment |
|---|---|
| Complexity | High |
| Sync-readiness | Medium (CloudKit path exists, Supabase path does not) |
| Block-based notes | Possible but awkward (NSManagedObject vs Codable duality) |
| iOS version | iOS 15+ ✅ |

**Rejected:** Core Data's CloudKit integration doesn't map to Supabase/custom backend. `NSManagedObject` subclasses conflict with existing `Codable` structs. Steepest learning curve of the three options.

---

### Option D: SwiftData

**Rejected immediately.** Requires iOS 17+. App targets iOS 15+.

---

## Architecture

### Layer diagram

```
SwiftUI Views
    │
    ▼
ViewModels (ReaderViewModel · NotesViewModel · BookmarksViewModel)
    │
    ▼
UserDataStoreProtocol          ← single facade for all user data
    │
    ├── GRDBUserDataStore      ← production (user_data.db)
    └── InMemoryUserDataStore  ← Xcode Previews & unit tests
    │
    ▼
user_data.db  (GRDB / SQLite WAL, Application Support)
    │
    ▼  (async background queue)
SyncEngine
    │
    ▼
Supabase  →  future proprietary backend
```

### Database schema

> **Amendment (2026-05-19):** `user_id` added to all sync-able tables in the LOCAL schema.
> Auth is MVP via Supabase Anonymous Auth — see Auth Strategy section below.
> `note_blocks` intentionally omits `user_id` (cascades from `notes`).

```sql
-- HIGHLIGHTS
-- translation column is intentional — highlights are per-translation (YouVersion behavior).
-- A highlight in KJV does not appear in RST. Users understand this: they're marking a specific rendering.
CREATE TABLE highlights (
    id          TEXT PRIMARY KEY,          -- UUID
    user_id     TEXT NOT NULL,             -- Supabase auth.uid() — set from first launch
    verse_id    TEXT NOT NULL,             -- "PSA|1|1"
    translation TEXT NOT NULL,
    color       TEXT NOT NULL DEFAULT 'green',
    created_at  INTEGER NOT NULL,          -- unix ms
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER,                   -- NULL = active, soft delete for sync
    is_dirty    INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_highlights_verse ON highlights(verse_id, user_id);

-- NOTE FOLDERS
CREATE TABLE note_folders (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL,
    name       TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    is_dirty   INTEGER NOT NULL DEFAULT 1
);

-- NOTES
CREATE TABLE notes (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL,
    folder_id  TEXT REFERENCES note_folders(id),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    is_dirty   INTEGER NOT NULL DEFAULT 1
);

-- NOTE ↔ VERSE  (many-to-many, no user_id — cascades from notes)
-- PURPOSE: denormalized index for the query "find all notes attached to verse X"
-- Used by Reader to show note indicator dots and by "Notes for this verse" in bottom sheet.
-- ⚠️  note_verses and note_blocks.verse_id are TWO different things:
--   • note_verses  → which verses a note is "attached to" (header-level metadata, queryable from Reader)
--   • note_blocks.verse_id → verse referenced INSIDE a block's content
-- saveNote() MUST maintain both atomically in a single GRDB inTransaction block.
CREATE TABLE note_verses (
    note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    verse_id TEXT NOT NULL,
    PRIMARY KEY (note_id, verse_id)
);

-- NOTE BLOCKS  (ordered content within a note, no user_id — cascades from notes)
-- Amendment (rev 2): hybrid schema per ChatGPT review.
-- verse_id + strongs_id extracted as real columns for queryability.
-- Everything else stays in content JSON.
CREATE TABLE note_blocks (
    id         TEXT PRIMARY KEY,
    note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    type       TEXT NOT NULL,    -- 'text' | 'verse' | 'word' | 'quote' | 'ai'
    verse_id   TEXT,             -- set for 'verse' and 'quote' blocks — indexed, queryable
    strongs_id TEXT,             -- set for 'word' blocks — indexed, queryable
    content    TEXT NOT NULL,    -- JSON for all remaining type-specific data
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_note_blocks_note    ON note_blocks(note_id, position);
CREATE INDEX idx_note_blocks_verse   ON note_blocks(verse_id)   WHERE verse_id IS NOT NULL;
CREATE INDEX idx_note_blocks_strongs ON note_blocks(strongs_id) WHERE strongs_id IS NOT NULL;

-- BOOKMARK CATEGORIES
CREATE TABLE bookmark_categories (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL,
    name       TEXT NOT NULL,
    color_hex  TEXT NOT NULL DEFAULT '#4A90D9',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    is_dirty   INTEGER NOT NULL DEFAULT 1
);

-- BOOKMARKS
CREATE TABLE bookmarks (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    category_id TEXT REFERENCES bookmark_categories(id),
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER,
    is_dirty    INTEGER NOT NULL DEFAULT 1
);

-- BOOKMARK ↔ VERSE  (many-to-many, no user_id — cascades from bookmarks)
CREATE TABLE bookmark_verses (
    bookmark_id TEXT NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
    verse_id    TEXT NOT NULL,
    PRIMARY KEY (bookmark_id, verse_id)
);
```

### Block content payloads (JSON in `note_blocks.content`)

```swift
// MVP: only text + verse blocks are created via UI
// word, quote, ai — schema ready, UI in v2+

struct TextBlock:  Codable { var body: String }

struct VerseBlock: Codable {
    var verseId: String        // "PSA|1|1"
    var translationId: String
    var text: String           // snapshot at save time
}

struct WordBlock: Codable {
    var strongsId: String      // "H835"
    var surface: String        // "אֶשֶׁר"
    var gloss: String?
}

struct QuoteBlock: Codable {
    var theologianId: String   // "calvin" | "henry" | "spurgeon"
    var verseId: String
    var text: String
}

struct AIBlock: Codable {
    var prompt: String
    var response: String
    var modelId: String
}
```

### UserDataStore protocol

```swift
// Aggregate types returned by the store — combine DB entities into one value for ViewModels
struct NoteWithBlocks {
    var note: Note             // notes row
    var blocks: [NoteBlock]    // note_blocks rows, ordered by position
    var verseIds: [String]     // note_verses rows — header-level verse attachments
}

struct BookmarkWithVerses {
    var bookmark: Bookmark
    var verseIds: [String]     // bookmark_verses rows
}

protocol UserDataStoreProtocol {
    // Highlights
    func isHighlighted(verseId: String) -> Bool
    func allHighlightedVerseIds() -> Set<String>
    func toggleHighlight(verseId: String, color: String)

    // Notes
    func notes(folderId: String?) -> [NoteWithBlocks]
    func saveNote(_ note: Note, blocks: [NoteBlock], verseIds: [String])
    func deleteNote(id: String)
    func folders() -> [NoteFolder]
    func saveFolder(_ folder: NoteFolder)
    func deleteFolder(id: String)

    // Bookmarks
    func bookmarks(categoryId: String?) -> [BookmarkWithVerses]
    func saveBookmark(_ bookmark: Bookmark, verseIds: [String])
    func deleteBookmark(id: String)
    func categories() -> [BookmarkCategory]
    func saveCategory(_ category: BookmarkCategory)
    func deleteCategory(id: String)
}
// NOTE: Protocol is synchronous — GRDB reads on MainActor are <1ms for v1 data volumes.
// Revisit in v2 when SyncEngine writes from server on background queue (see Consequences).
```

### Version roadmap

| Version | Scope |
|---|---|
| **v1 MVP** | GRDB local store. Notes, Bookmarks, Highlights. No auth, no sync. Auth/Sync protocols defined with NoOp impls. |
| **v1.5** | Supabase Auth (Apple/Google/Email). DeviceIdentity UUID → real Supabase UUID migration. Data exists on server but no active pull/push sync yet. |
| **v2** | SyncEngine. Multi-device pull/push. last-write-wins. |

---

### Pre-auth user_id: PreAuthIdentity pattern

> **Naming note (rev 3):** The class was previously called `DeviceIdentity` with a `.userId` property. This was renamed to `PreAuthIdentity` with a `.stableId` property because:
> 1. "Device" suggests hardware identity (IDFV/serial number) rather than a pre-auth data-ownership placeholder.
> 2. `.userId` returning a device UUID is misleading — it is not a user ID, it is a stable proxy that gets replaced by a real user ID in v1.5.
>
> The DB column remains `user_id` — this is intentional. It maps 1:1 to `auth.uid()` in Supabase RLS (`USING (user_id = auth.uid())`), which is the correct name at the server level. The pre-auth period is a local implementation detail, not a schema concern.
>
> **Rule: ViewModels never access `PreAuthIdentity` directly.** The only consumer is `LocalAuthService`. All other code calls `authService.userId` (protocol), which abstracts over both the pre-auth and post-auth phases.

`user_id TEXT NOT NULL` is in the schema from v1. Before real auth exists, every record gets a stable Keychain UUID via `PreAuthIdentity`:

```swift
// PreAuthIdentity.swift
// Generates once, persisted in Keychain. Sole job: stable local owner ID before auth.
// ⛔ Do NOT call this outside LocalAuthService. Use authService.userId everywhere else.
enum PreAuthIdentity {
    static var stableId: String {
        if let stored = Keychain.read("preauth.stableId") { return stored }
        let id = UUID().uuidString
        Keychain.write("preauth.stableId", value: id)
        return id
    }

    static func markMigrated() {
        Keychain.delete("preauth.stableId")
    }
}
```

```swift
// LocalAuthService (v1) — the ONLY place PreAuthIdentity is called
class LocalAuthService: AuthServiceProtocol {
    var userId: String { PreAuthIdentity.stableId }
    var isAuthenticated: Bool { false }
    ...
}
```

**v1.5 migration** — one SQL statement per table when Supabase Auth returns real UUID:
```swift
migrator.registerMigration("assign_supabase_user_id") { db in
    let supabaseId = try AuthService.shared.resolvedUserId()
    let preAuthId  = PreAuthIdentity.stableId
    guard supabaseId != preAuthId else { return }
    for table in ["highlights", "notes", "note_folders",
                  "bookmarks", "bookmark_categories"] {
        try db.execute(sql: "UPDATE \(table) SET user_id = ? WHERE user_id = ?",
                       arguments: [supabaseId, preAuthId])
    }
    PreAuthIdentity.markMigrated()
}
```

This is the only migration v1.5 needs. All local data carries forward intact.

---

### AuthService — protocol-first, NoOp in v1

```swift
protocol AuthServiceProtocol {
    var userId: String { get }
    var isAuthenticated: Bool { get }
    func signInWithApple() async throws
    func signInWithGoogle() async throws
    func signInWithEmail(_ email: String, password: String) async throws
    func signOut()
}

// v1 — uses PreAuthIdentity, no network calls
class LocalAuthService: AuthServiceProtocol {
    var userId: String { PreAuthIdentity.stableId }
    var isAuthenticated: Bool { false }
    func signInWithApple() async throws { throw AuthError.notImplemented }
    func signInWithGoogle() async throws { throw AuthError.notImplemented }
    func signInWithEmail(_ email: String, password: String) async throws { throw AuthError.notImplemented }
    func signOut() {}
}

// v1.5 — swap in, zero other changes
class SupabaseAuthService: AuthServiceProtocol { /* Supabase SDK */ }
```

**iOS Auth providers (v1.5):**
- Apple Sign In — required for App Store if Google/email are offered
- Google Sign In — via `supabase-swift` OAuth flow
- Email/password — fallback

**Supabase RLS (v1.5 — configured when Supabase tables are created):**
```sql
ALTER TABLE highlights ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own data only" ON highlights
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
-- same for notes, note_folders, bookmarks, bookmark_categories
```

---

### SyncEngine — protocol-first, NoOp in v1 and v1.5

```swift
protocol SyncEngineProtocol {
    func start()
    func stop()
    func syncNow() async
}

// v1 + v1.5 — does nothing
class NoOpSyncEngine: SyncEngineProtocol {
    func start() {}
    func stop() {}
    func syncNow() async {}
}

// v2 — swap in
class SupabaseSyncEngine: SyncEngineProtocol {
    // last-write-wins, batched 5s, dirty queue
}
```

**v2 Sync strategy (last-write-wins, batched):**
```
Write path:
  1. Write to GRDB → is_dirty = 1, bump updated_at
  2. UI updates instantly (offline-first ✅)

Upload:
  SELECT * WHERE is_dirty = 1 → UPSERT to Supabase → is_dirty = 0

Pull:
  Fetch WHERE user_id = current AND updated_at > last_sync_at
  → upsert locally (remote wins on conflict)
  → apply remote soft-deletes locally
```

---

### Migration from UserDefaults (one-time)

```swift
// Runs once on first launch after update
// Moves highlight IDs from UserDefaults into GRDB highlights table
class MigrationService {
    func migrateHighlightsIfNeeded(store: UserDataStoreProtocol) {
        let key = "migration.v1.highlights.done"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let ids = UserDefaults.standard.stringArray(
                      forKey: "sourcebible.highlights") ?? []
        for verseId in ids {
            store.toggleHighlight(verseId: verseId, color: "green")
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
```

---

## Trade-off Analysis

The core tension is **complexity now vs. rewrite later.**

UserDefaults is simpler to implement today by ~2–3 days of work. But when sync is added — which is a planned v2 feature, not speculative — it requires: replacing every storage key with a UUID-keyed SQLite row, adding `updated_at`/`deleted_at` to every model, implementing dirty tracking from scratch, and migrating all existing user data. That's 2–3 weeks of risk at a much worse time (when the app has real users).

GRDB costs more upfront but the sync-readiness is baked in: the local schema maps directly to Supabase tables. When `SyncEngine` is implemented, the local data model requires zero changes — only the network layer is new work.

The block-based note model follows the same logic. A `text: String` note cannot represent a verse attachment or an AI response without a breaking schema change. Building `note_blocks` now means v2 Note features are additive, not destructive.

---

## Consequences

**Easier after this decision:**
- Adding Supabase sync: implement `SyncEngine` only, no data model changes
- New block types (word, quote, ai): add UI, content struct is already defined
- Querying: SQL joins for folder-grouped notes, category-grouped bookmarks
- Testing: `InMemoryUserDataStore` makes ViewModels fully testable without DB
- Future full-text search over notes: add FTS5 virtual table on `note_blocks.content`

**Harder after this decision:**
- Initial setup: GRDB SPM dependency, DB schema, migration service
- Xcode Previews: require `InMemoryUserDataStore` injection (not automatic)
- Schema migrations: any column change needs a GRDB migration step

**Revisit in v1.5:**
- Implement `SupabaseAuthService` replacing `LocalAuthService`
- Run `assign_supabase_user_id` GRDB migration
- Create Supabase tables + RLS policies

**Revisit in v2:**
- Implement `SupabaseSyncEngine` replacing `NoOpSyncEngine`
- Consider CRDT if multi-device concurrent editing becomes a requirement
- Add FTS5 index on `note_blocks.content` when note search is needed
- Replace Supabase with proprietary backend: only `SyncEngine` changes
- Sign-out UX: keep or wipe local data (recommend: keep for v2)
- `UserDataStoreProtocol` write methods may need to become `async` when SyncEngine writes from server on background queue; evaluate at v2 design time

---

## Action Items

### Foundation
1. [ ] Add GRDB via Swift Package Manager — pin to `~> 6.0` (iOS 15+ compatible, current stable)
2. [ ] Create `UserDataStore` protocol (`UserDataStoreProtocol`)
3. [ ] Implement `GRDBUserDataStore` with schema + GRDB migrations
4. [ ] Implement `InMemoryUserDataStore` for Previews and tests
5. [ ] Write `MigrationService` — migrate highlights from UserDefaults → GRDB
6. [ ] Inject `UserDataStore` in `SourceBibleApp` via `.environmentObject`
7. [ ] Replace `HighlightRepository` usage in `ReaderViewModel` with `UserDataStore`

### Notes (F-09)
8. [ ] Create `NotesViewModel` with CRUD, `draftNote` state, folder management
9. [ ] Build `NoteEditorView` (block list: add verse block, add text block, folder picker, Save)
10. [ ] Build `NotesListView` replacing `NotesEmptyView` (grouped by folder, ↗ ✏️)
11. [ ] Wire "Нотатка" button in `VerseBottomSheetView` → `notesVM.openNewNote(attachedTo:)`

### Bookmarks (F-10)
12. [ ] Create `BookmarksViewModel` with CRUD, `draftBookmark` state, category management
13. [ ] Build `BookmarkEditorView` (verse picker, category + color picker, Save)
14. [ ] Build `BookmarksListView` replacing `BookmarksEmptyView` (grouped by category, ↗ ✏️)

### Navigation
15. [ ] Add `navigateTo(bookId:chapter:verse:)` to `ReaderViewModel`
16. [ ] Wire ↗ taps on Note and Bookmark cards → Reader navigation

### Auth-ready (v1 — protocol + NoOp only, no Supabase)
17. [ ] Create `PreAuthIdentity` (Keychain UUID, stable pre-auth; consumed only by LocalAuthService)
18. [ ] Define `AuthServiceProtocol`, implement `LocalAuthService` (NoOp)
19. [ ] Define `SyncEngineProtocol`, implement `NoOpSyncEngine`
20. [ ] Inject both protocols via `SourceBibleApp` (swappable in v1.5/v2)

### Auth (v1.5 — swap implementations)
21. [ ] Add `supabase-swift` via SPM
22. [ ] Implement `SupabaseAuthService` (Anonymous → Apple/Google/Email link)
23. [ ] Write GRDB migration `assign_supabase_user_id` (bulk UPDATE device UUID → Supabase UUID)
24. [ ] Create Supabase tables mirroring local schema + RLS policies
25. [ ] Add Sign In UI to MenuView

### Sync (v2 — swap implementation)
26. [ ] Implement `SupabaseSyncEngine` (dirty queue, 5s batch, pull on launch)
27. [ ] Store `last_sync_at` in UserDefaults per table
