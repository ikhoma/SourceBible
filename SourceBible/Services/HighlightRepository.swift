// HighlightRepository.swift
// SourceBible
//
// Персистентне зберігання підсвічених віршів.
// v1: UserDefaults — достатньо для Set<String> verseId-ів
// v2: Core Data / SQLite — коли додаємо кольори, дати, зв'язок з нотатками

import Foundation

// MARK: - Protocol

protocol HighlightRepositoryProtocol {
    func isHighlighted(_ verseId: String) -> Bool
    @discardableResult
    func toggle(_ verseId: String) -> Bool   // returns new state: true = highlighted
    func loadAll() -> Set<String>
}

// MARK: - UserDefaults Implementation

final class UserDefaultsHighlightRepository: HighlightRepositoryProtocol {

    private let key = "source_bible.highlighted_verse_ids"
    private var cache: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        cache = Set(saved)
    }

    func isHighlighted(_ verseId: String) -> Bool {
        cache.contains(verseId)
    }

    @discardableResult
    func toggle(_ verseId: String) -> Bool {
        if cache.contains(verseId) {
            cache.remove(verseId)
        } else {
            cache.insert(verseId)
        }
        UserDefaults.standard.set(Array(cache), forKey: key)
        return cache.contains(verseId)
    }

    func loadAll() -> Set<String> {
        cache
    }
}

// MARK: - Preview / Test Mock

final class MockHighlightRepository: HighlightRepositoryProtocol {

    private var highlighted: Set<String>

    init(preHighlighted: Set<String> = []) {
        self.highlighted = preHighlighted
    }

    func isHighlighted(_ verseId: String) -> Bool {
        highlighted.contains(verseId)
    }

    @discardableResult
    func toggle(_ verseId: String) -> Bool {
        if highlighted.contains(verseId) { highlighted.remove(verseId) }
        else { highlighted.insert(verseId) }
        return highlighted.contains(verseId)
    }

    func loadAll() -> Set<String> { highlighted }
}
