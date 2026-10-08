// BookmarkVerseResolver.swift
// SourceBible
//
// bug-037: where a bookmarked verse lives in the translation that is open NOW.
//
// A bookmark stores a verse number in the numbering of the translation it was saved
// under (`BookmarkWithVerses.verseTranslations`, v3 migration). The same number in a
// translation with another versification scheme is a DIFFERENT verse (RST/UBIO Psalter,
// 1Chr 5/6, Dan 3/4 …), so every bookmark surface must hop through `verse_org` first.
//
// One implementation for all of them — the card (BookmarkCardView), the share text
// (EntryShareFormatter) and the reader's bookmark toggle (BookmarksViewModel). Until
// code review 2026-10-08 the card and the share text each carried a copy, and the
// toggle still compared raw numbers: a bookmark made in RST lit up on the wrong KJV
// verse, and tapping it there deleted the RST bookmark.

import Foundation

enum BookmarkVerseResolver {

    struct Ref: Hashable {
        let bookId: String
        let chapter: Int
        let verse: Int

        /// "PSA|50|3" — the app-wide verse id format.
        var verseId: String { "\(bookId)|\(chapter)|\(verse)" }

        init(bookId: String, chapter: Int, verse: Int) {
            self.bookId = bookId
            self.chapter = chapter
            self.verse = verse
        }

        /// nil for anything that is not "BOOK|chapter|verse".
        init?(verseId: String) {
            let p = verseId.split(separator: "|")
            guard p.count == 3, let c = Int(p[1]), let v = Int(p[2]) else { return nil }
            self.init(bookId: String(p[0]), chapter: c, verse: v)
        }
    }

    enum Resolution: Equatable {
        /// Read this reference in the active translation.
        case verse(Ref)
        /// The active translation has no verse for it (merge gap) — show nothing,
        /// never the neighbouring verse at the same number.
        case noCounterpart
    }

    /// - Parameters:
    ///   - verseId: stored verse id, numbered in `source`.
    ///   - source: translation the bookmark was saved under. `nil` = legacy row (pre-v3):
    ///     identity lookup, per Ivan's 2026-09-22 decision not to guess.
    ///   - target: the reader's active translation.
    /// - Returns: `nil` only when `verseId` can't be parsed.
    static func resolve(verseId: String, savedIn source: String?,
                        activeTranslation target: String) -> Resolution? {
        guard let stored = Ref(verseId: verseId) else { return nil }
        guard let source, source != target else { return .verse(stored) }
        switch DatabaseService.shared.hopVerse(bookId: stored.bookId, chapter: stored.chapter,
                                               verse: stored.verse,
                                               source: source, target: target) {
        case .identity:
            return .verse(stored)
        case let .mapped(bookId, chapter, verse):
            return .verse(Ref(bookId: bookId, chapter: chapter, verse: verse))
        case .gap:
            return .noCounterpart
        }
    }
}
