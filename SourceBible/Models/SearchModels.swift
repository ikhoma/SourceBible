// SearchModels.swift
// SourceBible

import Foundation

// MARK: - Search Result

struct SearchResult: Identifiable, Hashable {
    let id: String          // "\(bookId)|\(chapter)|\(verse)" — used for navigation
    let reference: String   // "Бут 1:1"
    let snippet: String     // highlighted excerpt with ❮…❯ markers
}
