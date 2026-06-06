// VerseShareFormatter.swift
// SourceBible

import Foundation

enum VerseShareFormatter {
    /// Returns a plain-text share string for a Bible verse.
    ///
    /// Format:
    /// ```
    /// {verse text}
    ///
    /// — {Book} {chapter}:{verse} ({translationId})
    /// ```
    /// Example: "In the beginning God created…\n\n— Genesis 1:1 (KJV)"
    static func format(
        verse: BibleVerse,
        bookName: String,
        translationId: String
    ) -> String {
        let ref = "\(bookName) \(verse.chapter):\(verse.number) (\(translationId))"
        return "\(verse.text)\n\n— \(ref)"
    }
}
