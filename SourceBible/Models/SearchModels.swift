// SearchModels.swift
// SourceBible

import Foundation

// MARK: - Search Result

struct SearchResult: Identifiable, Hashable {
    let id: String          // "\(bookId)|\(chapter)|\(verse)" — used for navigation
    let reference: String   // "Бут 1:1"
    let snippet: String     // highlighted excerpt with ❮…❯ markers
}

// MARK: - Per-book result count (Book filter sheet)

struct SearchBookCount: Identifiable, Hashable {
    let bookId: String      // OSIS id, e.g. "PSA"
    let count: Int          // matches in this book for the current query
    var id: String { bookId }
}
