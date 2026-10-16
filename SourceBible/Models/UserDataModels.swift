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

/// Block type, stored as its raw string in `note_blocks.type`.
///
/// Forward-compatibility guard (2026-10, before the 1.0 App Store release): a type this
/// build doesn't know — e.g. a `heading` / `checklist` added in a later version and read
/// here via sync or a restored backup — becomes `.unsupported(raw)` instead of silently
/// falling back to `.text`. The raw string AND the block's `content` JSON round-trip
/// untouched through `saveNote` (which deletes + reinserts every block), so an older
/// build can open and save a newer note without destroying the parts it can't render.
/// Before this, `NoteBlockType(rawValue:) ?? .text` turned such a block into an empty
/// text block on the next save — permanent data loss.
///
/// ⚠️ Never remove or rename a case's raw string: old rows keep it forever.
enum NoteBlockType: RawRepresentable, Codable, Hashable {
    case text   // free text
    case verse  // attached Bible verse (snapshot)
    case word   // Strong's word entry
    case quote  // theologian commentary quote
    case ai     // AI-generated content (v2+)
    /// A type from a newer app version. Preserve, don't render, never rewrite.
    case unsupported(String)

    /// Never fails — unknown strings map to `.unsupported`.
    /// `nonisolated`: the GRDB row mapping calls this off the main actor (module
    /// default isolation is MainActor).
    nonisolated init?(rawValue: String) {
        switch rawValue {
        case "text":  self = .text
        case "verse": self = .verse
        case "word":  self = .word
        case "quote": self = .quote
        case "ai":    self = .ai
        default:      self = .unsupported(rawValue)
        }
    }

    nonisolated var rawValue: String {
        switch self {
        case .text:  return "text"
        case .verse: return "verse"
        case .word:  return "word"
        case .quote: return "quote"
        case .ai:    return "ai"
        case .unsupported(let raw): return raw
        }
    }

    // Explicit Codable: always the bare raw string («text», «heading»…), the same value
    // as `note_blocks.type`. Left to synthesis, an enum with an associated value may be
    // encoded as a keyed object ({"unsupported":{"_0":"heading"}}) — a format a future
    // backup/sync of NoteBlock must not inherit.
    nonisolated init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NoteBlockType(rawValue: raw) ?? .unsupported(raw)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    var theologianId: String    // "calvin" | "henry" | "spurgeon" | "owen" | "edwards"
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
