// RenderingOccurrenceLoader.swift
// SourceBible
//
// ADR-041: усі входження слова для аркуша «усі входження» — ПОЗА головним потоком.
// Для καί (G2532) у KJV це 8 624 рядки з повним текстом віршів (~2,8 МБ), і синхронний
// запит на MainActor пригальмовував відкриття аркуша (code review 2026-10-06).
//
// Власне read-only з'єднання, а не `DatabaseService.shared`: його хендл відкритий з
// SQLITE_OPEN_NOMUTEX і однопотоковий (див. DatabasePrewarm.swift), тож запит з
// фонового потоку перегонив би запити головного. Actor серіалізує доступ до свого
// хендла; `immutable=1` — той самий бандловий файл, без блокувань і WAL.

import Foundation
import SQLite3

actor RenderingOccurrenceLoader {

    static let shared = RenderingOccurrenceLoader()

    private var db: OpaquePointer?
    private var opened = false
    /// Колонка `hl` з'явилась пізніше за таблицю (див. DatabaseService.hasRenderingHighlight).
    private var hasHighlight = false
    private var hasTable = false

    // Без deinit: singleton живе весь процес, хендл закриває ОС (як DatabaseService.shared).

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif
        guard let url = Bundle.main.url(forResource: "sourcebible", withExtension: "db") else { return }
        let uri = "file://\(url.path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            print("⚠️ RenderingOccurrenceLoader: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            db = nil
            return
        }
        hasTable = exists("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'word_rendering'")
        hasHighlight = hasTable
            && exists("SELECT 1 FROM pragma_table_info('word_rendering') WHERE name = 'hl'")
    }

    private func exists(_ sql: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Усі входження слова в перекладі, з передачею кожного. Канонічний порядок:
    /// книга → глава → вірш → сегмент. `verse_key` — вірш ПЕРЕКЛАДУ (build-скрипт іде
    /// по віршах перекладу), тож verse_org тут не потрібен. Порожньо на старій базі.
    /// - Parameter strongsKey: канонічний ключ групи (`StrongsMergeMap.canonical`) —
    ///   рахує викликач: мапа MainActor-ізольована.
    func load(strongsKey key: String, translation: String) -> [RenderingOccurrence] {
        openIfNeeded()
        guard db != nil, hasTable else { return [] }
        let sql = """
            SELECT w.rendering_id, b.id,
                   (w.verse_key / 1000) % 1000 AS ch,
                   w.verse_key % 1000          AS vs,
                   w.seg_ord, v.text, \(hasHighlight ? "w.hl" : "NULL")
            FROM word_rendering w
            JOIN book  b ON b.num = w.verse_key / 1000000
            JOIN verse v ON v.translation = w.translation
                        AND v.book_id     = b.id
                        AND v.chapter     = (w.verse_key / 1000) % 1000
                        AND v.verse       = w.verse_key % 1000
            WHERE w.translation = ? AND w.strongs_key = ?
            ORDER BY w.verse_key, w.seg_ord
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ RenderingOccurrenceLoader prepare: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, translation, -1, transient)
        sqlite3_bind_text(stmt, 2, key, -1, transient)

        func text(_ col: Int32) -> String? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }

        var out: [RenderingOccurrence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rid = Int(sqlite3_column_int(stmt, 0))
            let bookId = text(1) ?? ""
            let ch  = Int(sqlite3_column_int(stmt, 2))
            let vs  = Int(sqlite3_column_int(stmt, 3))
            let ord = Int(sqlite3_column_int(stmt, 4))
            out.append(RenderingOccurrence(
                // rendering_id у ключі: один сегмент буває з двома передачами
                // (KJV Вих 22:13 «torn in pieces», H2963 ×2 в одному сегменті).
                id: "\(bookId)|\(ch)|\(vs)|\(ord)|\(rid)",
                renderingId: rid,
                bookId: bookId, chapter: ch, verse: vs, segOrd: ord,
                rawText: text(5) ?? "",
                highlight: text(6)
            ))
        }
        return out
    }
}
