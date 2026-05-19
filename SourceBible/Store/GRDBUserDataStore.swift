// GRDBUserDataStore.swift
// SourceBible
//
// Production UserDataStoreProtocol backed by GRDB (user_data.db, WAL mode).
// Requires GRDB ~> 6.0 via Swift Package Manager.
// ⚠️ Add GRDB in Xcode: File → Add Package Dependencies →
//    https://github.com/groue/GRDB.swift  (Up to Next Major: 6.0.0)

import Foundation
import GRDB

// MARK: - Store

final class GRDBUserDataStore: UserDataStoreProtocol {

    private let dbQueue: DatabaseQueue
    private let authService: AuthServiceProtocol

    // MARK: - Init

    init(authService: AuthServiceProtocol, path: String? = nil) throws {
        self.authService = authService

        let dbURL: URL
        if let path {
            dbURL = URL(fileURLWithPath: path)
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            dbURL = support.appendingPathComponent("user_data.db")
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try applyMigrations()
    }

    // MARK: - Migrations

    private func applyMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS highlights (
                    id          TEXT PRIMARY KEY,
                    user_id     TEXT NOT NULL,
                    verse_id    TEXT NOT NULL,
                    translation TEXT NOT NULL,
                    color       TEXT NOT NULL DEFAULT 'green',
                    created_at  INTEGER NOT NULL,
                    updated_at  INTEGER NOT NULL,
                    deleted_at  INTEGER,
                    is_dirty    INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX IF NOT EXISTS idx_highlights_verse
                    ON highlights(verse_id, user_id, translation);

                CREATE TABLE IF NOT EXISTS note_folders (
                    id         TEXT PRIMARY KEY,
                    user_id    TEXT NOT NULL,
                    name       TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    deleted_at INTEGER,
                    is_dirty   INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS notes (
                    id         TEXT PRIMARY KEY,
                    user_id    TEXT NOT NULL,
                    folder_id  TEXT REFERENCES note_folders(id),
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    deleted_at INTEGER,
                    is_dirty   INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS note_verses (
                    note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    verse_id TEXT NOT NULL,
                    PRIMARY KEY (note_id, verse_id)
                );
                CREATE INDEX IF NOT EXISTS idx_note_verses_verse
                    ON note_verses(verse_id);

                CREATE TABLE IF NOT EXISTS note_blocks (
                    id         TEXT PRIMARY KEY,
                    note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    position   INTEGER NOT NULL,
                    type       TEXT NOT NULL,
                    verse_id   TEXT,
                    strongs_id TEXT,
                    content    TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_note_blocks_note
                    ON note_blocks(note_id, position);
                CREATE INDEX IF NOT EXISTS idx_note_blocks_verse
                    ON note_blocks(verse_id) WHERE verse_id IS NOT NULL;
                CREATE INDEX IF NOT EXISTS idx_note_blocks_strongs
                    ON note_blocks(strongs_id) WHERE strongs_id IS NOT NULL;

                CREATE TABLE IF NOT EXISTS bookmark_categories (
                    id         TEXT PRIMARY KEY,
                    user_id    TEXT NOT NULL,
                    name       TEXT NOT NULL,
                    color_hex  TEXT NOT NULL DEFAULT '#4A90D9',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    deleted_at INTEGER,
                    is_dirty   INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS bookmarks (
                    id          TEXT PRIMARY KEY,
                    user_id     TEXT NOT NULL,
                    category_id TEXT REFERENCES bookmark_categories(id),
                    created_at  INTEGER NOT NULL,
                    updated_at  INTEGER NOT NULL,
                    deleted_at  INTEGER,
                    is_dirty    INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS bookmark_verses (
                    bookmark_id TEXT NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
                    verse_id    TEXT NOT NULL,
                    PRIMARY KEY (bookmark_id, verse_id)
                );
                CREATE INDEX IF NOT EXISTS idx_bookmark_verses_verse
                    ON bookmark_verses(verse_id);
            """)
        }

        // v2: drop bookmark_categories table and category_id column from bookmarks.
        // No users affected at time of migration — safe to do destructively.
        // iOS 26+ (SQLite 3.47+) supports DROP COLUMN directly.
        migrator.registerMigration("v2_drop_bookmark_categories") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS bookmark_categories")
            try db.execute(sql: "ALTER TABLE bookmarks DROP COLUMN category_id")
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - GRDB Record types (internal)

    private struct HighlightRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "highlights" }
        var id: String
        var user_id: String
        var verse_id: String
        var translation: String
        var color: String
        var created_at: Int64
        var updated_at: Int64
        var deleted_at: Int64?
        var is_dirty: Int64

        func toDomain() -> Highlight {
            Highlight(
                id: id, userId: user_id, verseId: verse_id,
                translation: translation, color: color,
                createdAt: msToDate(created_at),
                updatedAt: msToDate(updated_at),
                deletedAt: deleted_at.map(msToDate),
                isDirty: is_dirty != 0
            )
        }

        static func from(_ h: Highlight) -> HighlightRow {
            HighlightRow(
                id: h.id, user_id: h.userId, verse_id: h.verseId,
                translation: h.translation, color: h.color,
                created_at: dateToMs(h.createdAt), updated_at: dateToMs(h.updatedAt),
                deleted_at: h.deletedAt.map(dateToMs), is_dirty: h.isDirty ? 1 : 0
            )
        }
    }

    private struct NoteFolderRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "note_folders" }
        var id: String
        var user_id: String
        var name: String
        var created_at: Int64
        var updated_at: Int64
        var deleted_at: Int64?
        var is_dirty: Int64

        func toDomain() -> NoteFolder {
            NoteFolder(
                id: id, userId: user_id, name: name,
                createdAt: msToDate(created_at), updatedAt: msToDate(updated_at),
                deletedAt: deleted_at.map(msToDate), isDirty: is_dirty != 0
            )
        }

        static func from(_ f: NoteFolder) -> NoteFolderRow {
            NoteFolderRow(
                id: f.id, user_id: f.userId, name: f.name,
                created_at: dateToMs(f.createdAt), updated_at: dateToMs(f.updatedAt),
                deleted_at: f.deletedAt.map(dateToMs), is_dirty: f.isDirty ? 1 : 0
            )
        }
    }

    private struct NoteRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "notes" }
        var id: String
        var user_id: String
        var folder_id: String?
        var created_at: Int64
        var updated_at: Int64
        var deleted_at: Int64?
        var is_dirty: Int64

        func toDomain() -> Note {
            Note(
                id: id, userId: user_id, folderId: folder_id,
                createdAt: msToDate(created_at), updatedAt: msToDate(updated_at),
                deletedAt: deleted_at.map(msToDate), isDirty: is_dirty != 0
            )
        }

        static func from(_ n: Note) -> NoteRow {
            NoteRow(
                id: n.id, user_id: n.userId, folder_id: n.folderId,
                created_at: dateToMs(n.createdAt), updated_at: dateToMs(n.updatedAt),
                deleted_at: n.deletedAt.map(dateToMs), is_dirty: n.isDirty ? 1 : 0
            )
        }
    }

    private struct NoteVerseRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "note_verses" }
        var note_id: String
        var verse_id: String
    }

    private struct NoteBlockRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "note_blocks" }
        var id: String
        var note_id: String
        var position: Int64
        var type: String
        var verse_id: String?
        var strongs_id: String?
        var content: String
        var created_at: Int64
        var updated_at: Int64

        func toDomain() -> NoteBlock {
            NoteBlock(
                id: id, noteId: note_id, position: Int(position),
                type: NoteBlockType(rawValue: type) ?? .text,
                verseId: verse_id, strongsId: strongs_id, content: content,
                createdAt: msToDate(created_at), updatedAt: msToDate(updated_at)
            )
        }

        static func from(_ b: NoteBlock) -> NoteBlockRow {
            NoteBlockRow(
                id: b.id, note_id: b.noteId, position: Int64(b.position),
                type: b.type.rawValue, verse_id: b.verseId, strongs_id: b.strongsId,
                content: b.content,
                created_at: dateToMs(b.createdAt), updated_at: dateToMs(b.updatedAt)
            )
        }
    }

    private struct BookmarkRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "bookmarks" }
        var id: String
        var user_id: String
        var created_at: Int64
        var updated_at: Int64
        var deleted_at: Int64?
        var is_dirty: Int64

        func toDomain() -> Bookmark {
            Bookmark(
                id: id, userId: user_id,
                createdAt: msToDate(created_at), updatedAt: msToDate(updated_at),
                deletedAt: deleted_at.map(msToDate), isDirty: is_dirty != 0
            )
        }

        static func from(_ b: Bookmark) -> BookmarkRow {
            BookmarkRow(
                id: b.id, user_id: b.userId,
                created_at: dateToMs(b.createdAt), updated_at: dateToMs(b.updatedAt),
                deleted_at: b.deletedAt.map(dateToMs), is_dirty: b.isDirty ? 1 : 0
            )
        }
    }

    private struct BookmarkVerseRow: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "bookmark_verses" }
        var bookmark_id: String
        var verse_id: String
    }

    // MARK: - Highlights

    func isHighlighted(verseId: String, translation: String) -> Bool {
        (try? dbQueue.read { db in
            try HighlightRow
                .filter(Column("verse_id") == verseId &&
                        Column("translation") == translation &&
                        Column("deleted_at") == nil)
                .fetchCount(db) > 0
        }) ?? false
    }

    func highlightColors(translation: String) -> [String: String] {
        // Returns verseId → color rawValue for all active highlights in this translation.
        // Raw SQL avoids partial-decode failures when fetching specific columns.
        struct Row: FetchableRecord {
            let verseId: String
            let color: String
            init(row: GRDB.Row) {
                verseId = row["verse_id"]
                color   = row["color"]
            }
        }
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT verse_id, color FROM highlights
                 WHERE translation = ? AND deleted_at IS NULL
            """, arguments: [translation])
        }) ?? []
        return Dictionary(rows.map { ($0.verseId, $0.color) }, uniquingKeysWith: { _, last in last })
    }

    func toggleHighlight(verseId: String, translation: String, color: String) {
        let userId = authService.userId
        dbWrite { db in
            if let existing = try HighlightRow
                .filter(Column("verse_id") == verseId &&
                        Column("translation") == translation)
                .fetchOne(db) {
                if existing.deleted_at == nil {
                    // Active → soft-delete
                    try db.execute(
                        sql: """
                        UPDATE highlights
                           SET deleted_at = ?, updated_at = ?, is_dirty = 1
                         WHERE id = ?
                        """,
                        arguments: [nowMs(), nowMs(), existing.id])
                } else {
                    // Deleted → restore
                    try db.execute(
                        sql: """
                        UPDATE highlights
                           SET deleted_at = NULL, color = ?, updated_at = ?, is_dirty = 1
                         WHERE id = ?
                        """,
                        arguments: [color, nowMs(), existing.id])
                }
            } else {
                // New highlight
                let row = HighlightRow(
                    id: UUID().uuidString, user_id: userId,
                    verse_id: verseId, translation: translation, color: color,
                    created_at: nowMs(), updated_at: nowMs(),
                    deleted_at: nil, is_dirty: 1)
                try row.insert(db)
            }
        }
    }

    func updateHighlightColor(verseId: String, translation: String, color: String) {
        dbWrite { db in
            try db.execute(
                sql: """
                UPDATE highlights
                   SET color = ?, updated_at = ?, is_dirty = 1
                 WHERE verse_id = ? AND translation = ? AND deleted_at IS NULL
                """,
                arguments: [color, nowMs(), verseId, translation])
        }
    }

    // MARK: - Notes

    func notes(folderId: String?) -> [NoteWithBlocks] {
        (try? dbQueue.read { db in
            var request = NoteRow.filter(Column("deleted_at") == nil)
            if let fId = folderId {
                request = request.filter(Column("folder_id") == fId)
            }
            let noteRows = try request.fetchAll(db)
            return try noteRows.map { try self.assembleNote($0, in: db) }
        }) ?? []
    }

    func note(id: String) -> NoteWithBlocks? {
        try? dbQueue.read { db in
            guard let row = try NoteRow.fetchOne(db, key: id),
                  row.deleted_at == nil else { return nil }
            return try assembleNote(row, in: db)
        }
    }

    private func assembleNote(_ row: NoteRow, in db: Database) throws -> NoteWithBlocks {
        let blocks = try NoteBlockRow
            .filter(Column("note_id") == row.id)
            .order(Column("position").asc)
            .fetchAll(db)
            .map { $0.toDomain() }
        let verseIds = try NoteVerseRow
            .filter(Column("note_id") == row.id)
            .fetchAll(db)
            .map(\.verse_id)
        return NoteWithBlocks(note: row.toDomain(), blocks: blocks, verseIds: verseIds)
    }

    func saveNote(_ note: Note, blocks: [NoteBlock], verseIds: [String]) {
        dbWrite { db in
            try NoteRow.from(note).save(db)
            // Replace blocks atomically
            try db.execute(sql: "DELETE FROM note_blocks WHERE note_id = ?",
                           arguments: [note.id])
            for block in blocks {
                try NoteBlockRow.from(block).insert(db)
            }
            // Replace verse attachments atomically
            try db.execute(sql: "DELETE FROM note_verses WHERE note_id = ?",
                           arguments: [note.id])
            for verseId in verseIds {
                try NoteVerseRow(note_id: note.id, verse_id: verseId).insert(db)
            }
        }
    }

    func deleteNote(id: String) {
        dbWrite { db in
            try db.execute(
                sql: "UPDATE notes SET deleted_at = ?, updated_at = ?, is_dirty = 1 WHERE id = ?",
                arguments: [nowMs(), nowMs(), id])
        }
    }

    func folders() -> [NoteFolder] {
        (try? dbQueue.read { db in
            try NoteFolderRow
                .filter(Column("deleted_at") == nil)
                .order(Column("name").asc)
                .fetchAll(db)
                .map { $0.toDomain() }
        }) ?? []
    }

    func saveFolder(_ folder: NoteFolder) {
        dbWrite { db in
            try NoteFolderRow.from(folder).save(db)
        }
    }

    func deleteFolder(id: String) {
        dbWrite { db in
            try db.execute(
                sql: "UPDATE note_folders SET deleted_at = ?, updated_at = ?, is_dirty = 1 WHERE id = ?",
                arguments: [nowMs(), nowMs(), id])
            // Detach notes — two-write cascade (no FK cascade on folder_id)
            try db.execute(
                sql: "UPDATE notes SET folder_id = NULL, updated_at = ?, is_dirty = 1 WHERE folder_id = ?",
                arguments: [nowMs(), id])
        }
    }

    // MARK: - Bookmarks

    func bookmarks() -> [BookmarkWithVerses] {
        (try? dbQueue.read { db in
            let rows = try BookmarkRow
                .filter(Column("deleted_at") == nil)
                .order(Column("created_at").desc)
                .fetchAll(db)
            return try rows.map { row in
                let verseIds = try BookmarkVerseRow
                    .filter(Column("bookmark_id") == row.id)
                    .fetchAll(db)
                    .map(\.verse_id)
                return BookmarkWithVerses(bookmark: row.toDomain(), verseIds: verseIds)
            }
        }) ?? []
    }

    func saveBookmark(_ bookmark: Bookmark, verseIds: [String]) {
        dbWrite { db in
            try BookmarkRow.from(bookmark).save(db)
            try db.execute(sql: "DELETE FROM bookmark_verses WHERE bookmark_id = ?",
                           arguments: [bookmark.id])
            for verseId in verseIds {
                try BookmarkVerseRow(bookmark_id: bookmark.id, verse_id: verseId).insert(db)
            }
        }
    }

    func deleteBookmark(id: String) {
        dbWrite { db in
            try db.execute(
                sql: "UPDATE bookmarks SET deleted_at = ?, updated_at = ?, is_dirty = 1 WHERE id = ?",
                arguments: [nowMs(), nowMs(), id])
        }
    }

    // MARK: - Helpers

    /// Wraps dbQueue.write with error logging.
    /// Errors are logged in DEBUG and swallowed in Release — write failures are
    /// non-recoverable in v1 (no user-facing error UI yet), but should never be silent
    /// in development.
    @discardableResult
    private func dbWrite<T>(_ updates: @escaping (Database) throws -> T) -> T? {
        do {
            return try dbQueue.write(updates)
        } catch {
            #if DEBUG
            assertionFailure("⚠️ GRDBUserDataStore write failed: \(error)")
            #else
            print("⚠️ GRDBUserDataStore write failed: \(error)")
            #endif
            return nil
        }
    }

}

// MARK: - Date ↔ ms helpers (file-private, nonisolated — pure computation)

private nonisolated func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

private nonisolated func dateToMs(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

private nonisolated func msToDate(_ ms: Int64) -> Date {
    Date(timeIntervalSince1970: Double(ms) / 1000)
}
