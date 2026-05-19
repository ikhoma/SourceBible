// UserDataModels.swift
// SourceBible
//
// Моделі даних користувача: підсвічування, нотатки, закладки.
// Codable — готові до збереження в Core Data / SQLite (v2).
// v1: зберігаються через HighlightRepository (UserDefaults).

import Foundation

// MARK: - Highlight

struct Highlight: Identifiable, Codable {
    let id: String
    let verseId: String
    let color: String
    let createdAt: Date
}

// MARK: - Notes

struct Note: Identifiable, Codable {
    let id: String
    var verseIds: [String]
    var text: String
    var folderId: String?
    let createdAt: Date
    var updatedAt: Date
}

struct NoteFolder: Identifiable, Codable {
    let id: String
    var name: String
    let createdAt: Date
}

// MARK: - Bookmarks

struct Bookmark: Identifiable, Codable {
    let id: String
    var verseIds: [String]
    var categoryId: String?
    let createdAt: Date
}

struct BookmarkCategory: Identifiable, Codable {
    let id: String
    var name: String
    var colorHex: String
    let createdAt: Date
}
