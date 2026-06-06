// VerseShareFormatter.swift
// SourceBible

import Foundation

enum VerseShareFormatter {
    /// Returns a plain-text share string for a Bible verse.
    ///
    /// `bookName` should be pre-resolved by the caller from
    /// `ReaderViewModel.translationBookNames`, falling back to `BibleBookNames`.
    ///
    /// Format:
    /// ```
    /// "{verse text}"
    ///
    /// — {bookName} {chapter}:{verse} ({translationId})
    /// ```
    static func format(verse: BibleVerse, bookName: String, translationId: String) -> String {
        let ref = "\(bookName) \(verse.chapter):\(verse.number) (\(translationId))"
        return "\"\(verse.text)\"\n\n— \(ref)"
    }
}
