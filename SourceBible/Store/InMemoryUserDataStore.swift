// InMemoryUserDataStore.swift
// SourceBible
//
// In-memory UserDataStoreProtocol conformance for Xcode Previews and unit tests.
// Not thread-safe — use on MainActor only (same as the rest of the app in v1).

import Foundation

final class InMemoryUserDataStore: UserDataStoreProtocol {

    // MARK: - Storage

    private var highlights:        [String: Highlight]   = [:]
    private var noteFolders:       [String: NoteFolder]  = [:]
    private var notes:             [String: Note]        = [:]
    private var noteBlocksMap:     [String: [NoteBlock]] = [:]  // noteId → [NoteBlock]
    private var noteVersesMap:     [String: [String]]    = [:]  // noteId → [verseId]
    private var bookmarkRecords:   [String: Bookmark]    = [:]
    private var bookmarkVersesMap: [String: [String]]    = [:]  // bookmarkId → [verseId]

    private let previewUserId = "preview-user"

    // MARK: - Init (optionally pre-seeded for Previews)

    init() {}

    // MARK: - Highlights

    func isHighlighted(verseId: String, translation: String) -> Bool {
        highlights.values.contains {
            $0.verseId == verseId && $0.translation == translation && $0.deletedAt == nil
        }
    }

    func highlightColors(translation: String) -> [String: String] {
        Dictionary(
            highlights.values
                .filter { $0.translation == translation && $0.deletedAt == nil }
                .map { ($0.verseId, $0.color) },
            uniquingKeysWith: { _, last in last }
        )
    }

    func toggleHighlight(verseId: String, translation: String, color: String) {
        let existingKey = highlights.first {
            $0.value.verseId == verseId && $0.value.translation == translation
        }?.key

        if let existingKey {
            let wasDeleted = highlights[existingKey]?.deletedAt != nil
            if wasDeleted {
                highlights[existingKey]?.deletedAt = nil
                highlights[existingKey]?.color     = color
            } else {
                highlights[existingKey]?.deletedAt = Date()
            }
            highlights[existingKey]?.updatedAt = Date()
        } else {
            let h = Highlight(
                id: UUID().uuidString, userId: previewUserId,
                verseId: verseId, translation: translation, color: color,
                createdAt: Date(), updatedAt: Date(), deletedAt: nil, isDirty: true)
            highlights[h.id] = h
        }
    }

    func updateHighlightColor(verseId: String, translation: String, color: String) {
        guard let key = highlights.first(where: {
            $0.value.verseId == verseId &&
            $0.value.translation == translation &&
            $0.value.deletedAt == nil
        })?.key else { return }
        highlights[key]?.color     = color
        highlights[key]?.updatedAt = Date()
    }

    // MARK: - Notes

    func notes(folderId: String?) -> [NoteWithBlocks] {
        notes.values
            .filter { note in
                guard note.deletedAt == nil else { return false }
                if let fId = folderId { return note.folderId == fId }
                return true
            }
            .map { assembleNote($0) }
            .sorted { $0.note.createdAt > $1.note.createdAt }
    }

    func note(id: String) -> NoteWithBlocks? {
        guard let note = notes[id], note.deletedAt == nil else { return nil }
        return assembleNote(note)
    }

    private func assembleNote(_ note: Note) -> NoteWithBlocks {
        NoteWithBlocks(
            note: note,
            blocks: (noteBlocksMap[note.id] ?? []).sorted { $0.position < $1.position },
            verseIds: noteVersesMap[note.id] ?? []
        )
    }

    func saveNote(_ note: Note, blocks: [NoteBlock], verseIds: [String]) {
        notes[note.id]         = note
        noteBlocksMap[note.id] = blocks
        noteVersesMap[note.id] = verseIds
    }

    func deleteNote(id: String) {
        notes[id]?.deletedAt = Date()
        notes[id]?.updatedAt = Date()
    }

    func folders() -> [NoteFolder] {
        noteFolders.values
            .filter { $0.deletedAt == nil }
            .sorted { $0.name < $1.name }
    }

    func saveFolder(_ folder: NoteFolder) {
        noteFolders[folder.id] = folder
    }

    func deleteFolder(id: String) {
        noteFolders[id]?.deletedAt = Date()
        for key in notes.keys where notes[key]?.folderId == id {
            notes[key]?.folderId = nil
            notes[key]?.updatedAt = Date()
        }
    }

    // MARK: - Bookmarks

    func bookmarks() -> [BookmarkWithVerses] {
        bookmarkRecords.values
            .filter { $0.deletedAt == nil }
            .map { BookmarkWithVerses(bookmark: $0, verseIds: bookmarkVersesMap[$0.id] ?? []) }
            .sorted { $0.bookmark.createdAt > $1.bookmark.createdAt }
    }

    func saveBookmark(_ bookmark: Bookmark, verseIds: [String]) {
        bookmarkRecords[bookmark.id]   = bookmark
        bookmarkVersesMap[bookmark.id] = verseIds
    }

    func deleteBookmark(id: String) {
        bookmarkRecords[id]?.deletedAt = Date()
        bookmarkRecords[id]?.updatedAt = Date()
    }
}
