// BookmarksViewModel.swift
// SourceBible
//
// Bookmarks are pure navigation tools — no categories, no editor sheet.
// Adding a bookmark saves immediately; the list is the only management UI.

import Foundation
import Combine

@MainActor
final class BookmarksViewModel: ObservableObject {

    @Published var bookmarks: [BookmarkWithVerses] = []

    private let store:       UserDataStoreProtocol
    private let authService: AuthServiceProtocol

    init(store: UserDataStoreProtocol, authService: AuthServiceProtocol) {
        self.store       = store
        self.authService = authService
        refresh()
    }

    // MARK: - Data

    func refresh() {
        bookmarks = store.bookmarks()
    }

    var authUserId: String { authService.userId }

    // MARK: - Add / Remove

    /// Save a bookmark for the given verse immediately — no editor sheet.
    /// Idempotent: if a bookmark for this verseId already exists, returns it unchanged.
    @discardableResult
    func addBookmark(verseId: String) -> BookmarkWithVerses {
        if let existing = bookmarks.first(where: { $0.verseIds.contains(verseId) }) {
            return existing
        }
        let now      = Date()
        let bookmark = Bookmark(
            id: UUID().uuidString, userId: authService.userId,
            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
        let bwv = BookmarkWithVerses(bookmark: bookmark, verseIds: [verseId])
        store.saveBookmark(bookmark, verseIds: [verseId])
        refresh()
        return bwv
    }

    func deleteBookmark(id: String) {
        store.deleteBookmark(id: id)
        refresh()
    }

    /// True if any active bookmark contains this verseId.
    func isBookmarked(verseId: String) -> Bool {
        bookmarks.contains { $0.verseIds.contains(verseId) }
    }

    /// Toggle bookmark for a verse. Returns true if now bookmarked.
    @discardableResult
    func toggleBookmark(verseId: String) -> Bool {
        if let existing = bookmarks.first(where: { $0.verseIds.contains(verseId) }) {
            deleteBookmark(id: existing.bookmark.id)
            return false
        } else {
            addBookmark(verseId: verseId)
            return true
        }
    }
}
