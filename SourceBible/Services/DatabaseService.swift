// DatabaseService.swift
// SourceBible
//
// Thin wrapper around the bundled SQLite3 database.
// All heavy work happens on a background queue; callers receive results on the main thread.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Ukrainian book metadata

private struct BookMeta {
    let name: String
    let short: String
    let testament: Testament
}

// Full Ukrainian book names keyed by OSIS ID
private let bookMeta: [String: BookMeta] = [
    "GEN": BookMeta(name: "Буття",              short: "Бут",  testament: .old),
    "EXO": BookMeta(name: "Вихід",              short: "Вих",  testament: .old),
    "LEV": BookMeta(name: "Левит",              short: "Лев",  testament: .old),
    "NUM": BookMeta(name: "Числа",              short: "Чис",  testament: .old),
    "DEU": BookMeta(name: "Второзаконня",       short: "Втор", testament: .old),
    "JOS": BookMeta(name: "Ісуса Навина",       short: "Нав",  testament: .old),
    "JDG": BookMeta(name: "Суддів",             short: "Суд",  testament: .old),
    "RUT": BookMeta(name: "Рут",                short: "Рут",  testament: .old),
    "1SA": BookMeta(name: "1-а Самуїлова",      short: "1Сам", testament: .old),
    "2SA": BookMeta(name: "2-а Самуїлова",      short: "2Сам", testament: .old),
    "1KI": BookMeta(name: "1-а Царів",          short: "1Цар", testament: .old),
    "2KI": BookMeta(name: "2-а Царів",          short: "2Цар", testament: .old),
    "1CH": BookMeta(name: "1-а Хронік",         short: "1Хр",  testament: .old),
    "2CH": BookMeta(name: "2-а Хронік",         short: "2Хр",  testament: .old),
    "EZR": BookMeta(name: "Ездра",              short: "Езд",  testament: .old),
    "NEH": BookMeta(name: "Неємія",             short: "Неєм", testament: .old),
    "EST": BookMeta(name: "Естер",              short: "Ест",  testament: .old),
    "JOB": BookMeta(name: "Йов",                short: "Йов",  testament: .old),
    "PSA": BookMeta(name: "Псалми",             short: "Пс",   testament: .old),
    "PRO": BookMeta(name: "Приповісті",         short: "Пр",   testament: .old),
    "ECC": BookMeta(name: "Екклезіяст",         short: "Еккл", testament: .old),
    "SNG": BookMeta(name: "Пісня пісень",       short: "Піс",  testament: .old),
    "ISA": BookMeta(name: "Ісая",               short: "Іс",   testament: .old),
    "JER": BookMeta(name: "Єремія",             short: "Єр",   testament: .old),
    "LAM": BookMeta(name: "Плач Єремії",        short: "Плач", testament: .old),
    "EZK": BookMeta(name: "Єзекіїль",           short: "Єз",   testament: .old),
    "DAN": BookMeta(name: "Даниїл",             short: "Дан",  testament: .old),
    "HOS": BookMeta(name: "Осія",               short: "Ос",   testament: .old),
    "JOL": BookMeta(name: "Йоїл",               short: "Йоїл", testament: .old),
    "AMO": BookMeta(name: "Амос",               short: "Ам",   testament: .old),
    "OBA": BookMeta(name: "Авдій",              short: "Авд",  testament: .old),
    "JON": BookMeta(name: "Йона",               short: "Йон",  testament: .old),
    "MIC": BookMeta(name: "Михей",              short: "Мих",  testament: .old),
    "NAM": BookMeta(name: "Наум",               short: "Наум", testament: .old),
    "HAB": BookMeta(name: "Авакум",             short: "Авак", testament: .old),
    "ZEP": BookMeta(name: "Софонія",            short: "Соф",  testament: .old),
    "HAG": BookMeta(name: "Огій",               short: "Ог",   testament: .old),
    "ZEC": BookMeta(name: "Захарія",            short: "Зах",  testament: .old),
    "MAL": BookMeta(name: "Малахія",            short: "Мал",  testament: .old),
    "MAT": BookMeta(name: "Матвія",             short: "Мт",   testament: .new),
    "MRK": BookMeta(name: "Марка",              short: "Мр",   testament: .new),
    "LUK": BookMeta(name: "Луки",               short: "Лк",   testament: .new),
    "JHN": BookMeta(name: "Івана",              short: "Ів",   testament: .new),
    "ACT": BookMeta(name: "Дії",                short: "Дії",  testament: .new),
    "ROM": BookMeta(name: "Римлян",             short: "Рим",  testament: .new),
    "1CO": BookMeta(name: "1-а Коринтян",       short: "1Кор", testament: .new),
    "2CO": BookMeta(name: "2-а Коринтян",       short: "2Кор", testament: .new),
    "GAL": BookMeta(name: "Галатян",            short: "Гал",  testament: .new),
    "EPH": BookMeta(name: "Ефесян",             short: "Еф",   testament: .new),
    "PHP": BookMeta(name: "Филип'ян",           short: "Флп",  testament: .new),
    "COL": BookMeta(name: "Колосян",            short: "Кол",  testament: .new),
    "1TH": BookMeta(name: "1-а Солунян",        short: "1Сол", testament: .new),
    "2TH": BookMeta(name: "2-а Солунян",        short: "2Сол", testament: .new),
    "1TI": BookMeta(name: "1-а Тимофія",        short: "1Тим", testament: .new),
    "2TI": BookMeta(name: "2-а Тимофія",        short: "2Тим", testament: .new),
    "TIT": BookMeta(name: "Тита",               short: "Тит",  testament: .new),
    "PHM": BookMeta(name: "Филимона",           short: "Флм",  testament: .new),
    "HEB": BookMeta(name: "Євреїв",             short: "Євр",  testament: .new),
    "JAS": BookMeta(name: "Якова",              short: "Як",   testament: .new),
    "1PE": BookMeta(name: "1-а Петра",          short: "1Пет", testament: .new),
    "2PE": BookMeta(name: "2-а Петра",          short: "2Пет", testament: .new),
    "1JN": BookMeta(name: "1-а Івана",          short: "1Ів",  testament: .new),
    "2JN": BookMeta(name: "2-а Івана",          short: "2Ів",  testament: .new),
    "3JN": BookMeta(name: "3-я Івана",          short: "3Ів",  testament: .new),
    "JUD": BookMeta(name: "Юди",                short: "Юд",   testament: .new),
    "REV": BookMeta(name: "Об'явлення",         short: "Одкр", testament: .new),
]

// MARK: - DatabaseService

final class DatabaseService: @unchecked Sendable {

    static let shared = DatabaseService()

    /// Translation used as a fallback when the selected translation has no text for a verse.
    /// Change this constant if the fallback policy should change globally.
    static let defaultFallbackTranslation = "KJV"

    private var db: OpaquePointer?

    private init() {
        #if DEBUG
        // Skip file I/O entirely in Xcode Previews — use sample data fallback
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif
        guard let url = Bundle.main.url(forResource: "sourcebible", withExtension: "db") else {
            print("⚠️ DatabaseService: sourcebible.db not found in bundle. Using sample data.")
            return
        }
        // `immutable=1` tells SQLite the file will never change while the app runs.
        // This bypasses all file locking and WAL/SHM creation — required for bundle DBs
        // on iOS where the Resources directory is read-only at the OS level.
        let uri = "file://\(url.path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(uri, &db, flags, nil) != SQLITE_OK {
            print("⚠️ DatabaseService: \(dbError())")
            db = nil
        } else {
            sqlite3_exec(db, "PRAGMA cache_size=-8000;", nil, nil, nil)
            print("✓ DatabaseService: database opened at \(url.lastPathComponent)")
        }
    }

    deinit { if db != nil { sqlite3_close(db) } }

    var isAvailable: Bool { db != nil }

    // MARK: - Books

    func loadBooks() -> [BibleBook] {
        guard isAvailable else {
            #if DEBUG
            return BibleBook.sampleBooks
            #else
            return []
            #endif
        }
        var books: [BibleBook] = []
        let sql = "SELECT id, num, chapters FROM book ORDER BY num"
        query(sql) { stmt in
            let id       = string(stmt, 0)
            let chapters = Int(sqlite3_column_int(stmt, 2))
            if let meta = bookMeta[id] {
                books.append(BibleBook(id: id, name: meta.name, nameShort: meta.short,
                                       testament: meta.testament, chapterCount: chapters))
            }
        }
        return books
    }

    // MARK: - Translations

    func loadTranslations() -> [Translation] {
        guard isAvailable else { return [Translation.kjv] }
        var translations: [Translation] = []
        query("SELECT id, name, language FROM translation ORDER BY id") { stmt in
            translations.append(Translation(
                id:       string(stmt, 0),
                name:     string(stmt, 1),
                language: string(stmt, 2)
            ))
        }
        return translations
    }

    // MARK: - Verses

    /// Load all verses for a chapter in a given translation.
    /// Words are NOT populated here — load them separately with loadWords().
    func loadChapter(bookId: String, chapter: Int, translation: String) -> [BibleVerse] {
        guard isAvailable else {
            #if DEBUG
            return chapter == 1 && bookId == "PSA" ? BibleVerse.sampleVerses : []
            #else
            return []
            #endif
        }
        var verses: [BibleVerse] = []
        let sql = """
            SELECT verse, text FROM verse
            WHERE translation = ? AND book_id = ? AND chapter = ?
            ORDER BY verse
            """
        query(sql, bindings: [translation, bookId, chapter]) { stmt in
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            let rawText  = string(stmt, 1)
            let id       = "\(bookId)|\(chapter)|\(verseNum)"
            let parsed   = VerseParser.parse(verseId: id, rawText: rawText)
            verses.append(BibleVerse(id: id, bookId: bookId, chapter: chapter,
                                     number: verseNum, text: parsed.plainText,
                                     words: [], parsed: parsed))
        }
        return verses
    }

    /// Load the text of a single verse (for parallel translations tab).
    func loadVerseText(bookId: String, chapter: Int, verse: Int, translation: String) -> String? {
        guard isAvailable else { return nil }
        var result: String?
        let sql = "SELECT text FROM verse WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?"
        query(sql, bindings: [translation, bookId, chapter, verse]) { stmt in
            let rawText = string(stmt, 0)
            result = VerseParser.stripTags(rawText)
        }
        return result
    }

    // MARK: - Words (Macula)

    /// Load original-language words for a verse.
    func loadWords(bookId: String, chapter: Int, verse: Int) -> [BibleWord] {
        guard isAvailable else {
            #if DEBUG
            return BibleVerse.sampleVerses.first(where: {
                $0.bookId == bookId && $0.chapter == chapter && $0.number == verse
            })?.words ?? []
            #else
            return []
            #endif
        }
        var words: [BibleWord] = []
        // gloss_macula: occurrence-specific gloss from Macula (e.g. "he.walks" for הָלַךְ in Ps 1:1)
        // xlit (word.xlit): occurrence-specific transliteration from Macula (e.g. "hālaḵə")
        // xlit_lex: lemma transliteration from TBESH via strongs.transliteration (e.g. "ha.lakh")
        let sql = """
            SELECT w.id, w.surface, w.strongs_id, w.morph, w.gloss_macula,
                   COALESCE(NULLIF(s.transliteration,''), '') AS xlit_lex,
                   w.xlit AS xlit_ctx,
                   w.syntax_role, w.greek, w.greek_strong
            FROM word w
            LEFT JOIN strongs s ON w.strongs_id = s.id
            WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
            ORDER BY w.position
            """
        query(sql, bindings: [bookId, chapter, verse]) { stmt in
            let id          = string(stmt, 0)
            let surface     = string(stmt, 1)
            let strongsId   = optString(stmt, 2)
            let morph       = optString(stmt, 3)
            let gloss       = optString(stmt, 4)   // Macula contextual gloss
            let xlitLex     = optString(stmt, 5)   // TBESH lemma xlit
            let xlitCtx     = optString(stmt, 6)   // Macula occurrence xlit
            let syntaxRole  = optString(stmt, 7)   // Macula syntactic role
            let greek       = optString(stmt, 8)   // LXX Greek word
            let greekStrong = optString(stmt, 9)   // LXX Greek Strong's
            words.append(BibleWord(id: id, text: surface, strongsId: strongsId,
                                   morphology: morph, gloss: gloss,
                                   xlitSimple: xlitLex, xlit: xlitCtx,
                                   syntaxRole: syntaxRole, greek: greek, greekStrong: greekStrong))
        }
        return words
    }

    // MARK: - Strong's Lexicon

    func loadStrongs(id: String) -> StrongsEntry? {
        guard isAvailable else {
            #if DEBUG
            return id == "H835" ? StrongsEntry.sample : nil
            #else
            return nil
            #endif
        }

        // Sub-entry IDs (e.g. H835a, H3887a) share root lexeme data with their base entry
        // (H835, H3887). If the sub-entry has no long_def, fall back to the base entry's
        // definition so users always see lexical content.
        // Base ID = strip trailing lowercase letter(s) from the numeric part.
        let baseId: String = {
            var s = id
            while let last = s.last, last.isLetter && last.isLowercase, s.count > 1 {
                // Only strip if there's a digit before the trailing letter
                let beforeLast = s.index(before: s.endIndex)
                let charBeforeLast = s[s.index(before: beforeLast)]
                if charBeforeLast.isNumber {
                    s = String(s.dropLast())
                } else { break }
            }
            return s
        }()

        let sql = """
            SELECT id, original, transliteration,
                   pronunciation, part_of_speech, short_def, long_def
            FROM strongs WHERE id = ?
            """

        func buildEntry(from stmt: OpaquePointer) -> StrongsEntry {
            let sid        = string(stmt, 0)
            let original   = string(stmt, 1)
            let xlitSimple = string(stmt, 2)
            let pron       = string(stmt, 3)
            let pos        = string(stmt, 4)
            let shortDef   = string(stmt, 5)
            let longDef    = string(stmt, 6)
            let semanticRange = shortDef
                .components(separatedBy: CharacterSet(charactersIn: ";,"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { String($0) }
            return StrongsEntry(
                id: sid,
                originalWord: original,
                transliteration: xlitSimple,
                xlitSimple: xlitSimple,
                pronunciation: pron,
                partOfSpeech: pos,
                shortDefinition: shortDef,
                semanticRange: semanticRange,
                fullDefinition: longDef,
                concordance: []
            )
        }

        var entry: StrongsEntry?
        query(sql, bindings: [id]) { stmt in entry = buildEntry(from: stmt) }

        // If the sub-entry has no long_def, try to fall back to the base entry's definition.
        // SAFETY CHECK: only fall back when the sub-entry and base entry share the same
        // first Hebrew/Greek character — i.e. they are true lexical variants of the same root.
        //
        // In the extended Strong's numbering some particles/prefixes are assigned IDs in the
        // same numeric range as unrelated words:
        //   H1886 = Dothan (city),  H1886a = הַ (definite article) — UNRELATED
        //   H871  = Atharim (route), H871a  = בְּ (preposition)    — UNRELATED
        //   H835  = אֶשֶׁר (happiness), H835a = אַשְׁרֵי (blessed)  — related ✓
        //   H3887 = לוּץ (scorn),  H3887a = לֵצִים (scorners)      — related ✓
        // Comparing first character reliably distinguishes these cases.
        if let e = entry, e.fullDefinition.isEmpty, baseId != id {
            var baseEntry: StrongsEntry?
            query(sql, bindings: [baseId]) { stmt in baseEntry = buildEntry(from: stmt) }
            if let b = baseEntry, !b.fullDefinition.isEmpty {
                // Verify same root: both original words must start with the same character.
                let subFirst  = e.originalWord.unicodeScalars.first
                let baseFirst = b.originalWord.unicodeScalars.first
                let sameRoot  = subFirst != nil && baseFirst != nil && subFirst == baseFirst
                if sameRoot {
                    entry = StrongsEntry(
                        id: e.id,
                        originalWord: e.originalWord.isEmpty ? b.originalWord : e.originalWord,
                        transliteration: e.transliteration.isEmpty ? b.transliteration : e.transliteration,
                        xlitSimple: e.xlitSimple.isEmpty ? b.xlitSimple : e.xlitSimple,
                        pronunciation: e.pronunciation.isEmpty ? b.pronunciation : e.pronunciation,
                        partOfSpeech: e.partOfSpeech.isEmpty ? b.partOfSpeech : e.partOfSpeech,
                        shortDefinition: e.shortDefinition.isEmpty ? b.shortDefinition : e.shortDefinition,
                        semanticRange: e.semanticRange.isEmpty ? b.semanticRange : e.semanticRange,
                        fullDefinition: b.fullDefinition,
                        concordance: []
                    )
                }
            }
        }

        return entry
    }

    // MARK: - Bible Text Markup Cleaner

    /// Strips inline Bible markup from raw verse text.
    ///
    /// Rules:
    ///   <S>NUMBER</S>  — Strong's refs    → removed entirely
    ///   <n>text</n>    — translator notes → content kept in (parentheses)
    ///   <i>…</i>       — italics          → tags stripped, text kept
    ///   <br/> <pb/>    — breaks           → replaced with space
    ///   all other tags                    → tags stripped, content kept
    static func stripBibleMarkup(_ raw: String) -> String {
        var s = raw

        // 1. Strong's: <S>digits</S> → remove entirely (tag + number)
        s = s.replacingOccurrences(of: #"<S>\d+</S>"#,
                                   with: "",
                                   options: .regularExpression)

        // 2. Footnotes: <n>content</n> → (content)
        s = s.replacingOccurrences(of: #"<n>(.*?)</n>"#,
                                   with: "($1)",
                                   options: .regularExpression)

        // 3. Void elements: <br/> <pb/> → space
        s = s.replacingOccurrences(of: #"<(br|pb)\s*/>"#,
                                   with: " ",
                                   options: [.regularExpression, .caseInsensitive])

        // 4. All remaining tags → strip, keep content
        s = s.replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "",
                                   options: .regularExpression)

        // 5. Collapse multiple spaces
        s = s.replacingOccurrences(of: #" {2,}"#,
                                   with: " ",
                                   options: .regularExpression)

        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Concordance (all verses for a Strong's number)

    func loadConcordance(strongsId: String,
                         translation: String,
                         fallbackTranslation: String = DatabaseService.defaultFallbackTranslation,
                         limit: Int = 50) -> [ConcordanceEntry] {
        guard isAvailable else {
            #if DEBUG
            return StrongsEntry.sample.concordance
            #else
            return []
            #endif
        }
        var entries: [ConcordanceEntry] = []

        // Strip a trailing letter suffix so H835a and H835 both resolve to the
        // same base and we match all Macula sub-entries (H835, H835a, H835b …).
        let base: String = {
            guard let last = strongsId.last, last.isLetter,
                  let prev = strongsId.dropLast().last, prev.isNumber
            else { return strongsId }
            return String(strongsId.dropLast())
        }()

        // Two LEFT JOINs: preferred translation first, fallback second.
        // COALESCE picks preferred when available; is_fallback flags when fallback was used.
        let sql = """
            SELECT DISTINCT
                w.book_id, w.chapter, w.verse,
                COALESCE(v.text, v_fb.text) AS resolved_text,
                CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM word w
            LEFT JOIN verse v    ON v.book_id    = w.book_id
                                AND v.chapter    = w.chapter
                                AND v.verse      = w.verse
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id = w.book_id
                                AND v_fb.chapter = w.chapter
                                AND v_fb.verse   = w.verse
                                AND v_fb.translation = ?
            WHERE (w.strongs_id = ?
               OR (w.strongs_id GLOB ? || '[a-z]'
                   AND length(w.strongs_id) = length(?) + 1))
            ORDER BY w.book_id, w.chapter, w.verse
            LIMIT ?
            """
        query(sql, bindings: [translation, fallbackTranslation, base, base, base, limit]) { stmt in
            let bookId     = string(stmt, 0)
            let chapter    = Int(sqlite3_column_int(stmt, 1))
            let verse      = Int(sqlite3_column_int(stmt, 2))
            let rawText    = optString(stmt, 3) ?? ""
            let text       = DatabaseService.stripBibleMarkup(rawText)
            let isFallback = sqlite3_column_int(stmt, 4) != 0
            let short      = bookMeta[bookId]?.short ?? bookId
            let ref        = "\(short) \(chapter):\(verse)"
            let id         = "\(bookId)|\(chapter)|\(verse)"
            entries.append(ConcordanceEntry(id: id, reference: ref, text: text, rawText: rawText,
                                            isFallback: isFallback,
                                            bookId: bookId, chapter: chapter, verse: verse))
        }
        return entries
    }

    // MARK: - Verse Map (versification)

    /// Returns the Macula (MT) verse number for a given translation verse,
    /// or nil when the chapter has no registered offset (identity mapping assumed).
    ///
    /// The verse_map table is populated at DB build time by build_verse_map.py
    /// using Strong's-overlap alignment across all translation/chapter combos
    /// where verse counts differ between the translation and the Macula word table.
    func findMaculaVerse(bookId: String, chapter: Int,
                         translationVerse: Int, translation: String) -> Int? {
        guard isAvailable else { return nil }
        var result: Int?
        let sql = """
            SELECT macula_verse FROM verse_map
            WHERE translation = ? AND book_id = ? AND chapter = ? AND trans_verse = ?
            """
        query(sql, bindings: [translation, bookId, chapter, translationVerse]) { stmt in
            result = Int(sqlite3_column_int(stmt, 0))
        }
        return result
    }

    // MARK: - Cross References

    func loadCrossReferences(bookId: String, chapter: Int, verse: Int,
                             translation: String,
                             fallbackTranslation: String = DatabaseService.defaultFallbackTranslation) -> [CrossReference] {
        guard isAvailable else { return [] }
        var refs: [CrossReference] = []

        // Two LEFT JOINs: preferred translation first, fallback second.
        // COALESCE picks preferred when available; is_fallback flags when fallback was used.
        let sql = """
            SELECT xr.to_book, xr.to_chapter, xr.to_verse, xr.votes,
                   COALESCE(v.text, v_fb.text) AS resolved_text,
                   CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM cross_reference xr
            LEFT JOIN verse v    ON v.book_id    = xr.to_book
                                AND v.chapter    = xr.to_chapter
                                AND v.verse      = xr.to_verse
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id = xr.to_book
                                AND v_fb.chapter = xr.to_chapter
                                AND v_fb.verse   = xr.to_verse
                                AND v_fb.translation = ?
            WHERE xr.from_book = ? AND xr.from_chapter = ? AND xr.from_verse = ?
            ORDER BY xr.votes DESC
            """
        query(sql, bindings: [translation, fallbackTranslation, bookId, chapter, verse]) { stmt in
            let toBook     = string(stmt, 0)
            let toChapter  = Int(sqlite3_column_int(stmt, 1))
            let toVerse    = Int(sqlite3_column_int(stmt, 2))
            let text       = DatabaseService.stripBibleMarkup(optString(stmt, 4) ?? "")
            let isFallback = sqlite3_column_int(stmt, 5) != 0
            let short      = bookMeta[toBook]?.short ?? toBook
            let ref        = "\(short) \(toChapter):\(toVerse)"
            let id         = "\(toBook)|\(toChapter)|\(toVerse)"
            refs.append(CrossReference(id: id, targetReference: ref, targetText: text,
                                       bookId: toBook, chapter: toChapter, verse: toVerse,
                                       isFallback: isFallback))
        }
        return refs
    }
}

// MARK: - SQLite helpers (private)

private extension DatabaseService {

    func dbError() -> String {
        guard let db else { return "no database" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Execute a SELECT query synchronously.
    /// `bindings` may contain String, Int, or Double.
    func query(_ sql: String, bindings: [Any] = [], row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ DB prepare error: \(dbError()) — \(sql)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let s as String:  sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int:     sqlite3_bind_int(stmt, idx, Int32(n))
            case let d as Double:  sqlite3_bind_double(stmt, idx, d)
            default: break
            }
        }

        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
    }

    /// Read a non-null TEXT column (returns "" if NULL).
    func string(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    /// Read a nullable TEXT column.
    func optString(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }
}

