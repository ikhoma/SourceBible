// BookmarksViewModel.swift
// SourceBible
//
// Bookmarks are pure navigation tools — no categories, no editor sheet.
// Adding a bookmark saves immediately; the list is the only management UI.

import Foundation
import Combine

@MainActor
final class BookmarksViewModel: ObservableObject {

    @Published var bookmarks: [BookmarkWithVerses] = [] {
        didSet { verseIndexCache = [:] }
    }

    /// translation → (verseId in THAT translation's numbering → bookmark id).
    /// bug-037: a bookmark's stored number belongs to the translation it was saved
    /// under, so "is this verse bookmarked?" must be asked after hopping it into the
    /// reader's translation (BookmarkVerseResolver). Built lazily per translation —
    /// at most two verse_org queries per bookmark — and dropped whenever the list changes.
    private var verseIndexCache: [String: [String: String]] = [:]

    private let store:       UserDataStoreProtocol
    private let authService: AuthServiceProtocol

    // Analytics (Slice 3): injected via view .task — default noop so VM is
    // usable in previews and unit tests without an analytics service wired up.
    var analytics:      any AnalyticsService = NoopAnalytics.shared
    var sessionTracker: SessionTracker       = .noop

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
    /// `translation` (bug-037) is the reader's active translation at save time — stored
    /// so the card can later hop through verse_org instead of an identity lookup when
    /// the reader switches to a translation with a different versification scheme.
    @discardableResult
    func addBookmark(verseId: String, translation: String) -> BookmarkWithVerses {
        if let existing = bookmark(at: verseId, in: translation) {
            return existing
        }
        let now      = Date()
        let bookmark = Bookmark(
            id: UUID().uuidString, userId: authService.userId,
            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
        let bwv = BookmarkWithVerses(bookmark: bookmark, verseIds: [verseId],
                                     verseTranslations: [verseId: translation])
        store.saveBookmark(bookmark, verseIds: [verseId], translation: translation)
        refresh()
        // Analytics: discrete bookmark_created + aggregate annotation counter (Slice 3 §C).
        analytics.track(.bookmarkCreated)
        sessionTracker.incAnnotation()
        return bwv
    }

    func deleteBookmark(id: String) {
        store.deleteBookmark(id: id)
        refresh()
    }

    /// True if any active bookmark points at this verse of `translation`
    /// (`verseId` is numbered in `translation`, i.e. the reader's verse id).
    func isBookmarked(verseId: String, translation: String) -> Bool {
        bookmark(at: verseId, in: translation) != nil
    }

    /// The bookmark that points at `verseId` once every bookmark is resolved into
    /// `translation` — never a bookmark that merely shares the number (bug-037).
    private func bookmark(at verseId: String, in translation: String) -> BookmarkWithVerses? {
        guard let id = verseIndex(for: translation)[verseId] else { return nil }
        return bookmarks.first { $0.bookmark.id == id }
    }

    private func verseIndex(for translation: String) -> [String: String] {
        if let cached = verseIndexCache[translation] { return cached }
        var index: [String: String] = [:]
        for item in bookmarks {
            for stored in item.verseIds {
                let key: String
                switch BookmarkVerseResolver.resolve(verseId: stored,
                                                     savedIn: item.verseTranslations[stored],
                                                     activeTranslation: translation) {
                case .verse(let ref):  key = ref.verseId
                case .noCounterpart:   continue          // no such verse in this translation
                case nil:              key = stored      // unparsable id — exact match only
                }
                if index[key] == nil { index[key] = item.bookmark.id }
            }
        }
        verseIndexCache[translation] = index
        return index
    }

    /// Toggle bookmark for a verse. Returns true if now bookmarked.
    @discardableResult
    func toggleBookmark(verseId: String, translation: String) -> Bool {
        // Однаково в обидва боки: постановка й зняття закладки рівнозначні,
        // на відміну від highlight, де створення відчутніше за скасування.
        Haptics.lightTransition()
        if let existing = bookmark(at: verseId, in: translation) {
            deleteBookmark(id: existing.bookmark.id)
            return false
        } else {
            addBookmark(verseId: verseId, translation: translation)
            return true
        }
    }
}
