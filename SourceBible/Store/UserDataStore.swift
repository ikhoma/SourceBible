// UserDataStore.swift
// SourceBible
//
// Protocol + aggregate types for all user-generated data.
// GRDBUserDataStore   — production (user_data.db)
// InMemoryUserDataStore — Xcode Previews & unit tests
//
// NOTE: methods are synchronous. GRDB reads on MainActor are <1ms for v1 data volumes.
// Revisit for async when SyncEngine writes from a background queue in v2.

import Foundation

// MARK: - Aggregate types (returned by store, consumed by ViewModels)

/// A note together with its ordered blocks and header-level verse attachments.
/// • note.blocks is ordered by NoteBlock.position
/// • verseIds mirrors the note_verses join table — used by Reader to show note indicators
struct NoteWithBlocks {
    var note: Note
    var blocks: [NoteBlock]   // ordered by position ascending
    var verseIds: [String]    // header-level verse attachments (note_verses rows)
}

/// A bookmark together with its associated verse IDs (bookmark_verses rows).
struct BookmarkWithVerses {
    var bookmark: Bookmark
    var verseIds: [String]
    /// verseId → translation it was saved under. Only present for bookmarks saved
    /// after bug-037's v3 migration — absent (legacy) means "unknown", not "KJV" or
    /// any other guess, per Ivan's 2026-09-22 decision not to backfill a guess.
    var verseTranslations: [String: String] = [:]
}

// MARK: - Protocol

@MainActor
protocol UserDataStoreProtocol: AnyObject {

    // MARK: Highlights

    /// True if the verse has an active (non-deleted) highlight for the given translation.
    func isHighlighted(verseId: String, translation: String) -> Bool

    /// All verse IDs with active highlights for the given translation.
    /// Returns a dict: verseId → color rawValue (e.g. "yellow").
    func highlightColors(translation: String) -> [String: String]

    /// Toggle highlight on/off. Creates a new record or soft-deletes/restores existing.
    /// color must be a valid HighlightColor.rawValue.
    func toggleHighlight(verseId: String, translation: String, color: String)

    /// Change the color of an existing active highlight without toggling it off first.
    /// No-op if the verse is not currently highlighted.
    func updateHighlightColor(verseId: String, translation: String, color: String)

    // MARK: Notes

    /// All non-deleted notes. Pass folderId to filter, nil to get all.
    func notes(folderId: String?) -> [NoteWithBlocks]

    /// Single note by ID, or nil if not found / deleted.
    func note(id: String) -> NoteWithBlocks?

    /// Upsert a note with its blocks and verse attachments.
    /// Replaces all existing blocks and verse rows for this note atomically.
    func saveNote(_ note: Note, blocks: [NoteBlock], verseIds: [String])

    /// Soft-delete a note (sets deleted_at).
    func deleteNote(id: String)

    /// All non-deleted folders.
    func folders() -> [NoteFolder]

    /// Upsert a folder.
    func saveFolder(_ folder: NoteFolder)

    /// Soft-delete a folder. Notes inside become folder-less (folderId = nil).
    func deleteFolder(id: String)

    // MARK: Bookmarks
    // Bookmarks are pure navigation tools — no categories.

    /// All non-deleted bookmarks, sorted by createdAt descending.
    func bookmarks() -> [BookmarkWithVerses]

    /// Upsert a bookmark with its verse IDs. Replaces existing verse rows atomically.
    /// `translation` (bug-037) is the translation active when the bookmark was created —
    /// stored per verse so BookmarkCardView can hop through verse_org on translation
    /// switch instead of an identity (same-number) lookup. Pass nil only for flows that
    /// genuinely don't know it; legacy callers should always have it now.
    func saveBookmark(_ bookmark: Bookmark, verseIds: [String], translation: String?)

    /// Soft-delete a bookmark.
    func deleteBookmark(id: String)
}
