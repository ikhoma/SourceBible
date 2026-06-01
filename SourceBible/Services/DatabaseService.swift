// DatabaseService.swift
// SourceBible
//
// Thin wrapper around the bundled SQLite3 database.
// All heavy work happens on a background queue; callers receive results on the main thread.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - DatabaseService
// Book names and short abbreviations are provided by BibleBookNames (locale-aware).
// DatabaseService no longer maintains its own bookMeta dictionary.

final class DatabaseService: @unchecked Sendable {

    static let shared = DatabaseService()

    /// Translation used as a fallback when the selected translation has no text for a verse.
    /// Change this constant if the fallback policy should change globally.
    static let defaultFallbackTranslation = "KJV"

    // nonisolated(unsafe): OpaquePointer не є Sendable, але db доступна лише
    // з одного потоку (singleton + deinit). Swift 6 вимагає явного маркування.
    nonisolated(unsafe) private var db: OpaquePointer?

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
            // Locale-aware names from BibleBookNames (single source of truth).
            // Changing the app language and re-loading books produces correct names
            // automatically — the root .id(appLanguage) re-render triggers a full reload.
            books.append(BibleBook(
                id:          id,
                name:        BibleBookNames.full(for: id),
                nameShort:   BibleBookNames.short(for: id),
                testament:   BibleBookNames.testament(for: id),
                chapterCount: chapters
            ))
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
                   w.syntax_role, w.greek, w.greek_strong,
                   w.after_char
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
            let afterChar   = optString(stmt, 10)  // Macula trailing char (maqaf ־, sof pasuq ׃, etc.)
            words.append(BibleWord(id: id, text: surface, strongsId: strongsId,
                                   morphology: morph, gloss: gloss,
                                   xlitSimple: xlitLex, xlit: xlitCtx,
                                   syntaxRole: syntaxRole, greek: greek, greekStrong: greekStrong,
                                   afterChar: afterChar))
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

    /// Thin wrapper kept for call-site backward compatibility.
    /// Canonical logic lives in String+BibleMarkup.swift → String.strippingBibleMarkup().
    static func stripBibleMarkup(_ raw: String) -> String {
        raw.strippingBibleMarkup()
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

        // Three LEFT JOINs: verse_map reverse-lookup (macula→trans) for each translation,
        // then verse join using the translated verse number.
        // This fixes versification mismatches (e.g. Psalm headings counted as verse 1 in MT
        // but not in KJV/RST), preventing wrong verses from appearing in concordance.
        // COALESCE on vm.trans_verse falls back to w.verse for chapters with identity mapping
        // (verse_map only stores non-identity rows).
        let sql = """
            SELECT DISTINCT
                w.book_id, w.chapter, w.verse,
                COALESCE(vm.trans_verse,    w.verse) AS display_verse,
                COALESCE(v.text, v_fb.text) AS resolved_text,
                CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM word w
            LEFT JOIN verse_map vm    ON vm.translation   = ?
                                     AND vm.book_id       = w.book_id
                                     AND vm.chapter       = w.chapter
                                     AND vm.macula_verse  = w.verse
            LEFT JOIN verse_map vm_fb ON vm_fb.translation   = ?
                                     AND vm_fb.book_id      = w.book_id
                                     AND vm_fb.chapter      = w.chapter
                                     AND vm_fb.macula_verse = w.verse
            LEFT JOIN verse v    ON v.book_id    = w.book_id
                                AND v.chapter    = w.chapter
                                AND v.verse      = COALESCE(vm.trans_verse, w.verse)
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id = w.book_id
                                AND v_fb.chapter = w.chapter
                                AND v_fb.verse   = COALESCE(vm_fb.trans_verse, w.verse)
                                AND v_fb.translation = ?
            WHERE (w.strongs_id = ?
               OR (w.strongs_id GLOB ? || '[a-z]'
                   AND length(w.strongs_id) = length(?) + 1))
            ORDER BY w.book_id, w.chapter, w.verse
            LIMIT ?
            """
        query(sql, bindings: [translation, fallbackTranslation,
                              translation, fallbackTranslation,
                              base, base, base, limit]) { stmt in
            let bookId      = string(stmt, 0)
            let chapter     = Int(sqlite3_column_int(stmt, 1))
            // col 2 = w.verse (Macula) — not used for display
            let displayVerse = Int(sqlite3_column_int(stmt, 3))
            let rawText     = optString(stmt, 4) ?? ""
            let text        = DatabaseService.stripBibleMarkup(rawText)
            let isFallback  = sqlite3_column_int(stmt, 5) != 0
            // Skip entries where neither translation has verse text.
            guard !text.isEmpty else { return }
            let short = BibleBookNames.short(for: bookId)
            let ref   = "\(short) \(chapter):\(displayVerse)"
            let id    = "\(bookId)|\(chapter)|\(displayVerse)"
            entries.append(ConcordanceEntry(id: id, reference: ref, text: text, rawText: rawText,
                                            isFallback: isFallback,
                                            bookId: bookId, chapter: chapter, verse: displayVerse))
        }
        return entries
    }

    // MARK: - Book Usage Groups (per-book concordance for WordUsageView)

    /// Returns the true total occurrence count across the whole Bible plus a
    /// per-book breakdown (count + first-occurrence example verse) for a Strong's ID.
    ///
    /// - Parameter strongsId: Raw Strong's ID including any sub-entry suffix (e.g. "H835a").
    ///   The method strips the suffix internally so H835 and H835a are treated as the same root.
    /// - Returns: A tuple of the total distinct-verse count and an array of BookUsageGroup,
    ///   one per Bible book that contains the word, sorted in canonical order.
    func loadBookUsageGroups(
        strongsId: String,
        translation: String,
        fallbackTranslation: String = DatabaseService.defaultFallbackTranslation
    ) -> (total: Int, groups: [BookUsageGroup]) {
        guard isAvailable else {
            #if DEBUG
            return (StrongsEntry.sample.totalCount, StrongsEntry.sample.bookGroups)
            #else
            return (0, [])
            #endif
        }

        // Strip trailing letter suffix: H835a → H835 (same logic as loadConcordance).
        let base: String = {
            guard let last = strongsId.last, last.isLetter,
                  let prev = strongsId.dropLast().last, prev.isNumber
            else { return strongsId }
            return String(strongsId.dropLast())
        }()

        let strongsFilter = "(w.strongs_id = ? OR (w.strongs_id GLOB ? || '[a-z]' AND length(w.strongs_id) = length(?) + 1))"

        // --- Query A: total word token count across the whole Bible ---
        // COUNT(*) counts every word token — consistent with the standard reference count
        // (e.g. יהוה = 6512 tokens, not 5515 distinct verses that contain it).
        var total = 0
        let totalSQL = """
            SELECT COUNT(*)
            FROM word w
            WHERE \(strongsFilter)
            """
        query(totalSQL, bindings: [base, base, base]) { stmt in
            total = Int(sqlite3_column_int(stmt, 0))
        }

        // --- Query B: per-book token count + first-occurrence key ---
        // COUNT(*) for tokens (consistent with total). JOIN book for canonical ordering
        // (ORDER BY w.book_id would sort OSIS IDs alphabetically: 1CH < 1KGS < 1SAM…).
        // Encodes first (chapter, verse) as chapter*1000+verse so MIN() picks the
        // earliest occurrence. Safe: max chapter=150, max verse=176 → 150176.
        struct BookRow { let bookId: String; let count: Int; let chapter: Int; let verse: Int }
        var bookRows: [BookRow] = []
        let groupSQL = """
            SELECT w.book_id,
                   COUNT(*)                       AS book_count,
                   MIN(w.chapter * 1000 + w.verse) AS first_cv
            FROM word w
            JOIN book b ON b.id = w.book_id
            WHERE \(strongsFilter)
            GROUP BY w.book_id
            ORDER BY b.num
            """
        query(groupSQL, bindings: [base, base, base]) { stmt in
            let bookId  = string(stmt, 0)
            let count   = Int(sqlite3_column_int(stmt, 1))
            let firstCV = Int(sqlite3_column_int(stmt, 2))
            let chapter = firstCV / 1000
            let verse   = firstCV % 1000
            bookRows.append(BookRow(bookId: bookId, count: count, chapter: chapter, verse: verse))
        }

        // --- Query C: verse text for first occurrence per book ---
        // Reuses the same verse_map JOIN pattern as loadConcordance to handle
        // versification mismatches (e.g. Psalm headings in MT vs KJV/RST).
        let exampleSQL = """
            SELECT COALESCE(vm.trans_verse, w.verse) AS display_verse,
                   COALESCE(v.text, v_fb.text)       AS resolved_text,
                   CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM word w
            LEFT JOIN verse_map vm    ON vm.translation    = ?
                                     AND vm.book_id        = w.book_id
                                     AND vm.chapter        = w.chapter
                                     AND vm.macula_verse   = w.verse
            LEFT JOIN verse_map vm_fb ON vm_fb.translation = ?
                                     AND vm_fb.book_id     = w.book_id
                                     AND vm_fb.chapter     = w.chapter
                                     AND vm_fb.macula_verse = w.verse
            LEFT JOIN verse v    ON v.book_id     = w.book_id
                                AND v.chapter     = w.chapter
                                AND v.verse       = COALESCE(vm.trans_verse, w.verse)
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id  = w.book_id
                                AND v_fb.chapter  = w.chapter
                                AND v_fb.verse    = COALESCE(vm_fb.trans_verse, w.verse)
                                AND v_fb.translation = ?
            WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
              AND \(strongsFilter)
            LIMIT 1
            """

        var groups: [BookUsageGroup] = []
        for row in bookRows {
            var displayVerse = row.verse
            var rawText      = ""
            var isFallback   = false

            query(exampleSQL, bindings: [
                translation, fallbackTranslation, translation, fallbackTranslation,
                row.bookId, row.chapter, row.verse,
                base, base, base
            ]) { stmt in
                displayVerse = Int(sqlite3_column_int(stmt, 0))
                rawText      = optString(stmt, 1) ?? ""
                isFallback   = sqlite3_column_int(stmt, 2) != 0
            }

            // Skip if no verse text found in either translation.
            let text = DatabaseService.stripBibleMarkup(rawText)
            guard !text.isEmpty else { continue }

            let short   = BibleBookNames.short(for: row.bookId)
            let ref     = "\(short) \(row.chapter):\(displayVerse)"
            let entryId = "\(row.bookId)|\(row.chapter)|\(displayVerse)"
            let example = ConcordanceEntry(id: entryId, reference: ref,
                                           text: text, rawText: rawText,
                                           isFallback: isFallback,
                                           bookId: row.bookId, chapter: row.chapter, verse: displayVerse)

            groups.append(BookUsageGroup(
                id:       row.bookId,
                bookId:   row.bookId,
                bookName: BibleBookNames.full(for: row.bookId),
                count:    row.count,
                example:  example
            ))
        }

        return (total, groups)
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
            let short      = BibleBookNames.short(for: toBook)
            let ref        = "\(short) \(toChapter):\(toVerse)"
            let id         = "\(toBook)|\(toChapter)|\(toVerse)"
            refs.append(CrossReference(id: id, targetReference: ref, targetText: text,
                                       bookId: toBook, chapter: toChapter, verse: toVerse,
                                       isFallback: isFallback))
        }
        return refs
    }

    // MARK: - Search

    /// Full-text search across verse translations using the FTS5 `verse_fts` index.
    ///
    /// The query is wrapped in quotes and a `*` suffix so it works as a phrase-prefix match:
    ///   "love" → MATCH '"love"*'  finds "love", "loved", "lovely" etc.
    ///   "God is" → MATCH '"God is"*' finds exact phrase prefix.
    ///
    /// Results are ranked by FTS5 BM25 relevance. The snippet() function marks
    /// matched tokens with ❮…❯ so the UI can highlight them.
    func searchByText(query rawQuery: String, translation: String, limit: Int = 150) -> [SearchResult] {
        guard isAvailable else { return [] }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [SearchResult] = []
        let ftsExpr = makeFTSQuery(trimmed)

        // snippet(verse_fts, col=0, open, close, ellipsis, numTokens=12)
        let sql = """
            SELECT v.book_id, v.chapter, v.verse,
                   snippet(verse_fts, 0, '❮', '❯', '…', 12) AS snip
            FROM verse_fts
            JOIN verse v ON v.rowid = verse_fts.rowid
            WHERE verse_fts MATCH ?
              AND v.translation = ?
            ORDER BY rank
            LIMIT ?
            """
        query(sql, bindings: [ftsExpr, translation, limit]) { stmt in
            let bookId  = string(stmt, 0)
            let chapter = Int(sqlite3_column_int(stmt, 1))
            let verse   = Int(sqlite3_column_int(stmt, 2))
            // FTS5 snippet() returns raw verse text including <S>N</S> markup.
            // Strip markup before storing — ❮…❯ highlight markers use non-ASCII
            // angle brackets (U+276E/U+276F) so strippingBibleMarkup() leaves them intact.
            let snip    = string(stmt, 3).strippingBibleMarkup()
            results.append(SearchResult(
                id: "\(bookId)|\(chapter)|\(verse)",
                reference: makeRef(bookId, chapter, verse),
                snippet: snip
            ))
        }
        return results
    }

    // MARK: Autocomplete suggestions

    /// Words from `search_terms` matching a lowercase prefix (≥2 chars), ordered by frequency.
    /// Uses GLOB for index-friendly prefix scan. Terms stored lowercase → caller must lowercase input.
    func suggestTerms(prefix: String, limit: Int = 8) -> [String] {
        guard isAvailable, prefix.count >= 2 else { return [] }
        var terms: [String] = []
        query("SELECT term FROM search_terms WHERE term GLOB ? ORDER BY freq DESC LIMIT ?",
              bindings: [prefix.lowercased() + "*", limit]) { stmt in
            terms.append(string(stmt, 0))
        }
        return terms
    }

    // MARK: Private search helpers

    /// Builds a safe FTS5 MATCH expression with prefix matching.
    /// Phrase (multi-word) and single-word inputs both handled; quotes are escaped.
    private func makeFTSQuery(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
    }

    /// Short reference string — "Бут 1:1" — via BibleBookNames (locale-aware, single source of truth).
    private func makeRef(_ bookId: String, _ chapter: Int, _ verse: Int) -> String {
        "\(BibleBookNames.short(for: bookId)) \(chapter):\(verse)"
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

