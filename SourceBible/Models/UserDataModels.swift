// UserDataModels.swift
// SourceBible
//
// User-generated data models: highlights, notes (block-based), bookmarks.
// All sync-ready: UUID PKs, userId, createdAt/updatedAt/deletedAt, isDirty.
// Persisted via GRDBUserDataStore (user_data.db). See ADR-004.

import Foundation

// MARK: - Highlight

struct Highlight: Identifiable, Codable {
    let id: String
    let userId: String
    let verseId: String
    let translation: String     // highlights are per-translation (YouVersion behavior)
    var color: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?        // nil = active; non-nil = soft-deleted
    var isDirty: Bool           // true = needs sync upload
}

// MARK: - Note Folder

struct NoteFolder: Identifiable, Codable {
    let id: String
    let userId: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var isDirty: Bool
}

// MARK: - Note

/// A note has no text content directly — content lives in NoteBlock rows.
/// Header-level verse attachments live in note_verses (see NoteWithBlocks aggregate).
struct Note: Identifiable, Codable {
    let id: String
    let userId: String
    var folderId: String?
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var isDirty: Bool
}

// MARK: - Note Block

enum NoteBlockType: String, Codable {
    case text   // free text
    case verse  // attached Bible verse (snapshot)
    case word   // Strong's word entry
    case quote  // theologian commentary quote
    case ai     // AI-generated content (v2+)
}

/// One ordered content unit inside a note.
/// verse_id and strongs_id are extracted as real columns in SQLite for queryability.
/// All other type-specific data lives in `content` as a JSON-encoded payload struct.
struct NoteBlock: Identifiable, Codable {
    let id: String
    let noteId: String
    var position: Int
    var type: NoteBlockType
    var verseId: String?        // set for .verse and .quote blocks
    var strongsId: String?      // set for .word blocks
    var content: String         // JSON — encode/decode with the payload structs below
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Block content payload structs
// MVP creates TextBlock and VerseBlock via UI. Others are schema-ready for v2.

struct TextBlockContent: Codable {
    var body: String
}

struct VerseBlockContent: Codable {
    var verseId: String         // "PSA|1|1"
    var translationId: String
    var text: String            // snapshot of verse text at save time
}

struct WordBlockContent: Codable {
    var strongsId: String       // "H835"
    var surface: String         // original language surface form
    var gloss: String?
}

struct QuoteBlockContent: Codable {
    var theologianId: String    // "calvin" | "henry" | "spurgeon" | "owen"
    var verseId: String
    var text: String
}

struct AIBlockContent: Codable {
    var prompt: String
    var response: String
    var modelId: String
}

// MARK: - Bookmark
// Note: bookmark_categories table and categoryId have been removed per product spec.
// Bookmarks are pure navigation tools — no categories, no labels.

struct Bookmark: Identifiable, Codable {
    let id: String
    let userId: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var isDirty: Bool
}
