// DatabaseService.swift
// SourceBible
//
// Thin wrapper around the bundled SQLite3 database.
// All heavy work happens on a background queue; callers receive results on the main thread.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Display normalization (TBESH symbols)
// TBESH lemma transliteration uses "." as a syllable separator (e.g. "e.rets"),
// while our surface transliteration uses "-" (e.g. "ḥep̄-ṣōw"). For visual
// consistency we render lemma xlit with "-" too.
// TBESH short glosses use ":" to introduce a sense elaboration and "/" to list
// alternatives (e.g. "land: country/planet"). We render ":" as a middle dot and
// "/" as a comma for a cleaner reading style ("land · country, planet").
// These are read-time DISPLAY transforms only — raw DB values stay canonical.
private func normalizeXlitForDisplay(_ s: String) -> String {
    s.replacingOccurrences(of: ".", with: "-")
}

private func normalizeGlossForDisplay(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s*:\s*"#, with: " · ", options: .regularExpression)
     .replacingOccurrences(of: #"\s*/\s*"#, with: ", ", options: .regularExpression)
     .trimmingCharacters(in: .whitespaces)
}

// MARK: - DatabaseService
// Book names and short abbreviations are provided by BibleBookNames (locale-aware).
// DatabaseService no longer maintains its own bookMeta dictionary.

final class DatabaseService: @unchecked Sendable {

    static let shared = DatabaseService()

    /// Translation used as a fallback when the selected translation has no text for a verse.
    /// Change this constant if the fallback policy should change globally.
    static let defaultFallbackTranslation = "KJV"

    /// Versification scheme the `cross_reference` table is numbered in.
    /// OpenBible.info cross-references use KJV numbering for both endpoints
    /// (`from_verse` and `to_verse`), so every cross-ref lookup must translate
    /// between the reader's translation and this scheme via `verse_org` (ADR-028):
    /// reader → original → KJV on the source side, KJV → original → reader on the
    /// target side. Both hops are curated and cross-chapter capable.
    static let crossRefVersification = "KJV"

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

    // MARK: - Book names (translation-native)

    /// Loads translation-native book names and display order.
    /// Returns a map of bookId → (longName, shortName, sortOrder).
    func loadBookNames(for translationId: String) -> [String: (long: String, short: String, order: Int)] {
        var result: [String: (long: String, short: String, order: Int)] = [:]
        let sql = """
            SELECT book_id, long_name, short_name, sort_order
            FROM book_name WHERE translation_id = ?
            ORDER BY sort_order
            """
        query(sql, bindings: [translationId]) { stmt in
            let id    = string(stmt, 0)
            let long  = string(stmt, 1)
            let short = string(stmt, 2)
            let order = Int(sqlite3_column_int(stmt, 3))
            result[id] = (long, short, order)
        }
        return result
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

    /// Load Strong's base numbers from NASB markup for a single verse.
    /// Returns the set of numeric strings extracted from <S>NNN</S> tags.
    /// Used by ReaderViewModel to gate clickability in the Original pill regardless
    /// of which translation the user is currently reading.
    func loadNASBStrongs(bookId: String, chapter: Int, verse: Int) -> Set<String> {
        guard isAvailable else { return [] }
        var result = Set<String>()
        let sql = "SELECT text FROM verse WHERE translation = 'NASB' AND book_id = ? AND chapter = ? AND verse = ?"
        query(sql, bindings: [bookId, chapter, verse]) { stmt in
            let raw = string(stmt, 0)
            // Extract all <S>NNN</S> tags
            var search = raw[raw.startIndex...]
            while let open = search.range(of: "<S>"),
                  let close = search[open.upperBound...].range(of: "</S>") {
                let num = String(search[open.upperBound..<close.lowerBound])
                if !num.isEmpty { result.insert(num) }
                search = search[close.upperBound...]
            }
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
            SELECT w.id, w.surface, w.strongs_id, w.morph,
                   COALESCE(w.gloss_display, w.gloss_macula, w.gloss) AS display_gloss,
                   COALESCE(NULLIF(s.transliteration,''), '') AS xlit_lex,
                   w.xlit AS xlit_ctx,
                   w.syntax_role, w.greek, w.greek_strong,
                   w.after_char, w.lexical_class,
                   w.slot, w.xlit_slot
            FROM word w
            LEFT JOIN strongs s ON w.strongs_id = s.id
            WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
            ORDER BY w.position
            """
        query(sql, bindings: [bookId, chapter, verse]) { stmt in
            let id           = string(stmt, 0)
            let surface      = string(stmt, 1)
            let strongsId    = optString(stmt, 2)
            let morph        = optString(stmt, 3)
            let gloss        = optString(stmt, 4)   // Macula contextual gloss
            let xlitLex      = optString(stmt, 5)   // TBESH lemma xlit
            let xlitCtx      = optString(stmt, 6)   // Macula occurrence xlit
            let syntaxRole   = optString(stmt, 7)   // Macula syntactic role
            let greek        = optString(stmt, 8)   // LXX Greek word
            let greekStrong  = optString(stmt, 9)   // LXX Greek Strong's
            let afterChar    = optString(stmt, 10)  // Macula trailing char (maqaf ־, sof pasuq ׃, etc.)
            let lexicalClass = optString(stmt, 11)  // Macula lexical class (noun/verb/ij/intj/…)
            let slot         = optInt(stmt, 12)     // Macula !N group position (nil for Greek)
            let xlitSlot     = optString(stmt, 13)  // BibleHub combined slot translit (root token only)
            words.append(BibleWord(id: id, text: surface, strongsId: strongsId,
                                   morphology: morph, gloss: gloss,
                                   xlitSimple: xlitLex.map(normalizeXlitForDisplay), xlit: xlitCtx,
                                   syntaxRole: syntaxRole, greek: greek, greekStrong: greekStrong,
                                   afterChar: afterChar, lexicalClass: lexicalClass,
                                   slot: slot, xlitSlot: xlitSlot))
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
            SELECT id, original, transliteration, xlit_simple,
                   pronunciation, part_of_speech, short_def, long_def
            FROM strongs WHERE id = ?
            """

        func buildEntry(from stmt: OpaquePointer) -> StrongsEntry {
            let sid        = string(stmt, 0)
            let original   = string(stmt, 1)
            let xlit       = string(stmt, 2)   // academic: rēʾšîyṯ (openscriptures)
            let xlitSimple = string(stmt, 3)   // simplified: reshit (TBESH)
            let pron       = string(stmt, 4)
            let pos        = string(stmt, 5)
            let shortDef   = string(stmt, 6)
            let longDef    = string(stmt, 7)
            // semanticRange is derived from the RAW gloss (split on ";" / ",") before
            // display normalization, so alternative senses stay intact as separate chips.
            let semanticRange = shortDef
                .components(separatedBy: CharacterSet(charactersIn: ";,"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { String($0) }
            return StrongsEntry(
                id: sid,
                originalWord: original,
                transliteration: xlit.isEmpty ? xlitSimple : xlit,
                xlitSimple: normalizeXlitForDisplay(xlitSimple.isEmpty ? xlit : xlitSimple),
                pronunciation: pron,
                partOfSpeech: pos,
                shortDefinition: normalizeGlossForDisplay(shortDef),
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

        // Reverse verse_org lookup (original→translation, ADR-028) for each translation,
        // then verse join using the translated chapter AND verse — the word table is
        // numbered in the original (Macula) scheme, and the curated mapping is
        // cross-chapter capable (RST Psalter = original chapter − 1, Dan 3/4, …),
        // which the old same-chapter mapping-table JOIN could not express.
        // COALESCE falls back to identity when verse_org has no row for this verse
        // (DB predates the table, or the translation has no counterpart — the text
        // join then comes up empty and the fallback translation is shown instead).
        let sql = """
            SELECT DISTINCT
                w.book_id, w.chapter, w.verse,
                COALESCE(vo.chapter, w.chapter) AS display_chapter,
                COALESCE(vo.verse,   w.verse)   AS display_verse,
                COALESCE(v.text, v_fb.text) AS resolved_text,
                CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM word w
            LEFT JOIN verse_org vo    ON vo.translation    = ?
                                     AND vo.org_book_id    = w.book_id
                                     AND vo.org_chapter    = w.chapter
                                     AND vo.org_verse      = w.verse
            LEFT JOIN verse_org vo_fb ON vo_fb.translation = ?
                                     AND vo_fb.org_book_id = w.book_id
                                     AND vo_fb.org_chapter = w.chapter
                                     AND vo_fb.org_verse   = w.verse
            LEFT JOIN verse v    ON v.book_id    = w.book_id
                                AND v.chapter    = COALESCE(vo.chapter, w.chapter)
                                AND v.verse      = COALESCE(vo.verse, w.verse)
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id = w.book_id
                                AND v_fb.chapter = COALESCE(vo_fb.chapter, w.chapter)
                                AND v_fb.verse   = COALESCE(vo_fb.verse, w.verse)
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
            // cols 1–2 = w.chapter / w.verse (original numbering) — not used for display
            let chapter      = Int(sqlite3_column_int(stmt, 3))   // display_chapter
            let displayVerse = Int(sqlite3_column_int(stmt, 4))   // display_verse
            let rawText     = optString(stmt, 5) ?? ""
            let text        = DatabaseService.stripBibleMarkup(rawText)
            let isFallback  = sqlite3_column_int(stmt, 6) != 0
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

    // MARK: - Book Usage Groups (per-book concordance for ConcordanceView)

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
        fallbackTranslation: String = DatabaseService.defaultFallbackTranslation,
        bookShortNames: [String: String] = [:],
        bookLongNames:  [String: String] = [:]
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
        // Reuses the same reverse verse_org JOIN pattern as loadConcordance to handle
        // versification mismatches (Psalm headings, cross-chapter shifts — ADR-028).
        let exampleSQL = """
            SELECT COALESCE(vo.chapter, w.chapter) AS display_chapter,
                   COALESCE(vo.verse,   w.verse)   AS display_verse,
                   COALESCE(v.text, v_fb.text)     AS resolved_text,
                   CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback
            FROM word w
            LEFT JOIN verse_org vo    ON vo.translation    = ?
                                     AND vo.org_book_id    = w.book_id
                                     AND vo.org_chapter    = w.chapter
                                     AND vo.org_verse      = w.verse
            LEFT JOIN verse_org vo_fb ON vo_fb.translation = ?
                                     AND vo_fb.org_book_id = w.book_id
                                     AND vo_fb.org_chapter = w.chapter
                                     AND vo_fb.org_verse   = w.verse
            LEFT JOIN verse v    ON v.book_id     = w.book_id
                                AND v.chapter     = COALESCE(vo.chapter, w.chapter)
                                AND v.verse       = COALESCE(vo.verse, w.verse)
                                AND v.translation = ?
            LEFT JOIN verse v_fb ON v_fb.book_id  = w.book_id
                                AND v_fb.chapter  = COALESCE(vo_fb.chapter, w.chapter)
                                AND v_fb.verse    = COALESCE(vo_fb.verse, w.verse)
                                AND v_fb.translation = ?
            WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
              AND \(strongsFilter)
            LIMIT 1
            """

        var groups: [BookUsageGroup] = []
        for row in bookRows {
            var displayChapter = row.chapter
            var displayVerse   = row.verse
            var rawText        = ""
            var isFallback     = false

            query(exampleSQL, bindings: [
                translation, fallbackTranslation, translation, fallbackTranslation,
                row.bookId, row.chapter, row.verse,
                base, base, base
            ]) { stmt in
                displayChapter = Int(sqlite3_column_int(stmt, 0))
                displayVerse   = Int(sqlite3_column_int(stmt, 1))
                rawText        = optString(stmt, 2) ?? ""
                isFallback     = sqlite3_column_int(stmt, 3) != 0
            }

            // Skip if no verse text found in either translation.
            let text = DatabaseService.stripBibleMarkup(rawText)
            guard !text.isEmpty else { continue }

            let short   = bookShortNames[row.bookId] ?? BibleBookNames.short(for: row.bookId)
            let ref     = "\(short) \(displayChapter):\(displayVerse)"
            let entryId = "\(row.bookId)|\(displayChapter)|\(displayVerse)"
            let example = ConcordanceEntry(id: entryId, reference: ref,
                                           text: text, rawText: rawText,
                                           isFallback: isFallback,
                                           bookId: row.bookId, chapter: displayChapter, verse: displayVerse)

            groups.append(BookUsageGroup(
                id:       row.bookId,
                bookId:   row.bookId,
                bookName: bookLongNames[row.bookId] ?? BibleBookNames.full(for: row.bookId),
                count:    row.count,
                example:  example
            ))
        }

        return (total, groups)
    }

    // MARK: - Versification hops (verse_org, ADR-028)

    /// Forward hop: first original-language (Macula) ref a translation verse maps to.
    ///
    /// - Returns: `sawRows == false` → the DB predates `verse_org`; callers keep
    ///   identity (the old behavior for that verse). `org == nil` with `sawRows` →
    ///   the verse explicitly has no original-text counterpart (org_* NULL, e.g.
    ///   RST ROM 16:24 or KJV NEH 7:68). N:M merges: rows are ordered by
    ///   (org_chapter, org_verse) and the first non-NULL is taken.
    private func orgRef(bookId: String, chapter: Int, verse: Int, translation: String)
        -> (sawRows: Bool, org: (bookId: String, chapter: Int, verse: Int)?) {
        var sawRows = false
        var org: (String, Int, Int)?
        let sql = """
            SELECT org_book_id, org_chapter, org_verse FROM verse_org
            WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?
            ORDER BY org_chapter, org_verse
            """
        query(sql, bindings: [translation, bookId, chapter, verse]) { stmt in
            sawRows = true
            if org == nil,
               let ob = optString(stmt, 0),
               let oc = optInt(stmt, 1),
               let ov = optInt(stmt, 2) {
                org = (ob, oc, ov)
            }
        }
        return (sawRows, org)
    }

    /// Reverse hop: which verse of `translation` carries a given original (Macula)
    /// ref. `nil` when the translation has no verse for that original — a gap or a
    /// merge asymmetry (e.g. no RST verse maps to Heb PSA 90:6; RST 89:6 covers 90:5).
    /// N:M merges: rows are ordered by (chapter, verse) and the first is taken.
    private func translationRef(orgBookId: String, orgChapter: Int, orgVerse: Int,
                                translation: String)
        -> (bookId: String, chapter: Int, verse: Int)? {
        var result: (String, Int, Int)?
        let sql = """
            SELECT book_id, chapter, verse FROM verse_org
            WHERE translation = ? AND org_book_id = ? AND org_chapter = ? AND org_verse = ?
            ORDER BY chapter, verse
            """
        query(sql, bindings: [translation, orgBookId, orgChapter, orgVerse]) { stmt in
            if result == nil {
                result = (string(stmt, 0),
                          Int(sqlite3_column_int(stmt, 1)),
                          Int(sqlite3_column_int(stmt, 2)))
            }
        }
        return result
    }

    /// Single verse text lookup (raw markup, unstripped). nil when absent.
    private func verseText(bookId: String, chapter: Int, verse: Int,
                           translation: String) -> String? {
        var text: String?
        let sql = """
            SELECT text FROM verse
            WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?
            """
        query(sql, bindings: [translation, bookId, chapter, verse]) { stmt in
            if text == nil { text = optString(stmt, 0) }
        }
        return text
    }

    /// Original-language (Macula) words for a translation verse, via `verse_org` (ADR-028).
    ///
    /// Supersedes the old heuristic verse-mapping (`findBestMaculaVerse`) for the Original pill.
    /// `verse_org` is total and testament-agnostic, so this handles what the old Int-based
    /// path could not: cross-CHAPTER shifts (RST Psalter = Hebrew+1, 1Chr 6, Daniel 6,
    /// Isa 64), cross-testament (NT → Macula Greek), and merged N:M verses.
    ///
    /// Returns [] for an explicit "no original" mapping (org_* NULL) — e.g. KJV/NASB
    /// NEH 7:68 (horses) or RST ROM 16:24 (grace): verses absent from the critical
    /// Hebrew/Greek text. The Original pill then shows its empty state, not a wrong verse.
    ///
    /// Transition safety: if no `verse_org` row exists (DB not yet rebuilt with the table),
    /// falls back to identity (same book/chapter/verse) — the old behavior for that verse.
    func loadOriginalWords(bookId: String, chapter: Int, verse: Int,
                           translation: String) -> [BibleWord] {
        guard isAvailable else {
            return loadWords(bookId: bookId, chapter: chapter, verse: verse)
        }
        var refs: [(String, Int, Int)] = []
        var sawRow = false
        let sql = """
            SELECT org_book_id, org_chapter, org_verse FROM verse_org
            WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?
            ORDER BY org_chapter, org_verse
            """
        query(sql, bindings: [translation, bookId, chapter, verse]) { stmt in
            sawRow = true
            if let ob = optString(stmt, 0),
               let oc = optInt(stmt, 1),
               let ov = optInt(stmt, 2) {
                refs.append((ob, oc, ov))
            }
        }
        // No row at all → DB predates verse_org; keep old identity behavior for this verse.
        if !sawRow {
            return loadWords(bookId: bookId, chapter: chapter, verse: verse)
        }
        // Row(s) present. All-NULL org ⇒ "no original" ⇒ [] (correct empty state).
        var out: [BibleWord] = []
        for (ob, oc, ov) in refs {
            out += loadWords(bookId: ob, chapter: oc, verse: ov)
        }
        return out
    }

    // MARK: - Cross References

    func loadCrossReferences(bookId: String, chapter: Int, verse: Int,
                             translation: String,
                             fallbackTranslation: String = DatabaseService.defaultFallbackTranslation,
                             bookShortNames: [String: String] = [:]) -> [CrossReference] {
        guard isAvailable else { return [] }
        var refs: [CrossReference] = []

        let xrefVsn = DatabaseService.crossRefVersification

        // SOURCE SIDE: cross_reference endpoints are KJV-numbered, but the reader's
        // ref arrives in `translation` numbering. Route reader → original → KJV
        // through verse_org. Both hops are curated and cross-chapter capable, so a
        // reader in RST Psalm 50 correctly reads the KJV Psalm 51 row — the old
        // same-chapter conversion read someone else's cross-refs (or none).
        // nil → the verse has an original but KJV has no verse for it (e.g. RST Psalm
        // superscriptions): no valid cross-ref row exists, so show none — per the
        // ADR-028 rule "empty, not a neighbor's data".
        guard let src = crossRefSourceRef(bookId: bookId, chapter: chapter, verse: verse,
                                          translation: translation, xrefVsn: xrefVsn)
        else { return [] }

        // Raw target rows, KJV-numbered, highest-voted first.
        struct RawTarget { let book: String; let chapter: Int; let verse: Int }
        var raw: [RawTarget] = []
        let sql = """
            SELECT to_book, to_chapter, to_verse FROM cross_reference
            WHERE from_book = ? AND from_chapter = ? AND from_verse = ?
            ORDER BY votes DESC
            """
        query(sql, bindings: [src.bookId, src.chapter, src.verse]) { stmt in
            raw.append(RawTarget(book: string(stmt, 0),
                                 chapter: Int(sqlite3_column_int(stmt, 1)),
                                 verse: Int(sqlite3_column_int(stmt, 2))))
        }

        // TARGET SIDE: re-express each KJV target in the reader's versification
        // (KJV → original → reader), so the printed reference, the text and the tap
        // target all speak the reader's numbering — including cross-chapter shifts.
        for target in raw {
            let (display, fallbackOnly) = resolveXrefTarget(
                book: target.book, chapter: target.chapter, verse: target.verse,
                translation: translation, xrefVsn: xrefVsn)

            let readerText: String? = fallbackOnly ? nil :
                verseText(bookId: display.bookId, chapter: display.chapter,
                          verse: display.verse, translation: translation)
            let fbText: String? = readerText != nil ? nil :
                verseText(bookId: target.book, chapter: target.chapter,
                          verse: target.verse, translation: fallbackTranslation)

            let text       = DatabaseService.stripBibleMarkup(readerText ?? fbText ?? "")
            let isFallback = readerText == nil && fbText != nil
            let short      = bookShortNames[display.bookId] ?? BibleBookNames.short(for: display.bookId)
            let ref        = "\(short) \(display.chapter):\(display.verse)"
            let id         = "\(display.bookId)|\(display.chapter)|\(display.verse)"
            refs.append(CrossReference(id: id, targetReference: ref, targetText: text,
                                       bookId: display.bookId, chapter: display.chapter,
                                       verse: display.verse, isFallback: isFallback))
        }
        return refs
    }

    /// Reader's verse re-expressed in the cross-ref versification (KJV numbering).
    ///
    /// Identity when: reader already IS the cross-ref scheme; the DB predates
    /// `verse_org`; or the verse has no original counterpart (org NULL — raw KJV
    /// numbers stay valid there by convention). Fast path: when the same numbers
    /// carry the same original in both schemes, skip the reverse lookup entirely.
    ///
    /// `nil` when the verse HAS an original but the cross-ref scheme has no verse
    /// for it (e.g. RST Psalm superscriptions — unnumbered in KJV): there is no
    /// valid cross_reference row, and falling back to raw numbers would surface a
    /// DIFFERENT verse's cross-refs.
    private func crossRefSourceRef(bookId: String, chapter: Int, verse: Int,
                                   translation: String, xrefVsn: String)
        -> (bookId: String, chapter: Int, verse: Int)? {
        guard translation != xrefVsn else { return (bookId, chapter, verse) }
        let (sawRows, orgOpt) = orgRef(bookId: bookId, chapter: chapter, verse: verse,
                                       translation: translation)
        guard sawRows, let org = orgOpt else { return (bookId, chapter, verse) }
        let (sawX, orgX) = orgRef(bookId: bookId, chapter: chapter, verse: verse,
                                  translation: xrefVsn)
        if sawX, let ox = orgX, ox == org { return (bookId, chapter, verse) }
        return translationRef(orgBookId: org.bookId, orgChapter: org.chapter,
                              orgVerse: org.verse, translation: xrefVsn)
    }

    /// A KJV-numbered cross-ref target re-expressed in the reader's versification.
    ///
    /// - Returns: `display` — the ref to print/navigate; `fallbackOnly == true` means
    ///   the reader's translation has NO verse for that original (merge gap, e.g. no
    ///   RST verse maps to Heb PSA 90:6). The display then keeps the raw KJV numbers
    ///   and the caller must take text from the fallback translation only — joining
    ///   the reader's text at raw numbers would show a DIFFERENT verse's text (the
    ///   old verse-shift bug this migration removes).
    private func resolveXrefTarget(book: String, chapter: Int, verse: Int,
                                   translation: String, xrefVsn: String)
        -> (display: (bookId: String, chapter: Int, verse: Int), fallbackOnly: Bool) {
        guard translation != xrefVsn else { return ((book, chapter, verse), false) }
        let (sawRaw, orgRawOpt) = orgRef(bookId: book, chapter: chapter, verse: verse,
                                         translation: xrefVsn)
        guard sawRaw, let orgRaw = orgRawOpt else { return ((book, chapter, verse), false) }
        // Fast path: same numbers already carry the same original in the reader's
        // translation — the vast majority of rows; avoids the reverse lookup.
        let (sawT, orgT) = orgRef(bookId: book, chapter: chapter, verse: verse,
                                  translation: translation)
        if sawT, let ot = orgT, ot == orgRaw { return ((book, chapter, verse), false) }
        if let reader = translationRef(orgBookId: orgRaw.bookId, orgChapter: orgRaw.chapter,
                                       orgVerse: orgRaw.verse, translation: translation) {
            return (reader, false)
        }
        return ((book, chapter, verse), true)
    }

    // MARK: - Commentary

    /// Returns the set of commentary source names that have at least one
    /// section for the given book (e.g. {"Calvin", "Henry"}).
    /// Used to hide theologians with no coverage for the current book.
    func commentarySourcesAvailable(bookId: String) -> Set<String> {
        guard isAvailable else { return [] }
        var sources = Set<String>()
        query("SELECT DISTINCT source FROM comments WHERE book_id = ?",
              bindings: [bookId]) { stmt in
            sources.insert(string(stmt, 0))
        }
        return sources
    }

    /// Loads a commentary section for a specific verse.
    /// Uses a two-table join: comment_verses (lookup index) → comments (full text).
    /// One commentary section may cover multiple verses; the full section is returned
    /// regardless of which verse triggered the lookup.
    /// Returns nil when no commentary exists for the requested verse.
    func loadCommentary(bookId: String, chapter: Int, verse: Int, source: String = "Calvin") -> CommentarySection? {
        guard isAvailable else { return nil }
        var result: CommentarySection?
        let sql = """
            SELECT c.text, c.start_chapter, c.start_verse, c.end_chapter, c.end_verse
            FROM comments c
            JOIN comment_verses cv ON cv.comment_id = c.id
            WHERE cv.book_id = ? AND cv.chapter = ? AND cv.verse = ?
              AND c.source = ?
            LIMIT 1
            """
        query(sql, bindings: [bookId, chapter, verse, source]) { stmt in
            result = CommentarySection(
                text:         self.string(stmt, 0),
                startChapter: Int(sqlite3_column_int(stmt, 1)),
                startVerse:   Int(sqlite3_column_int(stmt, 2)),
                endChapter:   Int(sqlite3_column_int(stmt, 3)),
                endVerse:     Int(sqlite3_column_int(stmt, 4))
            )
        }
        return result
    }

    // MARK: - Search

    /// Full-text search across verse translations using the FTS5 `verse_fts` index.
    ///
    /// The query is wrapped in quotes and a `*` suffix so it works as a phrase-prefix match:
    ///   "love" → MATCH '"love"*'  finds "love", "loved", "lovely" etc.
    ///   "God is" → MATCH '"God is"*' finds exact phrase prefix.
    ///
    /// Results are ranked by FTS5 BM25 relevance (rowid tiebreak keeps LIMIT/OFFSET
    /// pagination deterministic — BM25 rank ties would otherwise reshuffle between
    /// pages). The highlight() function returns the full verse text with matched
    /// tokens wrapped in ❮…❯ so the UI can highlight them.
    ///
    /// `bookIds` (optional) restricts results to a set of books — used by the search
    /// Testament/Book filters. `limit`/`offset` page through the full result set.
    func searchByText(query rawQuery: String, translation: String,
                      bookIds: [String]? = nil,
                      limit: Int = 50, offset: Int = 0,
                      bookShortNames: [String: String] = [:]) -> [SearchResult] {
        guard isAvailable else { return [] }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [SearchResult] = []
        let ftsExpr = makeFTSQuery(trimmed)

        var bindings: [Any] = [ftsExpr, translation]
        let bookClause = makeBookFilterClause(bookIds, appendingTo: &bindings)
        bindings.append(limit)
        bindings.append(offset)

        // highlight(verse_fts, col=0, open, close) — full verse text, matches wrapped in ❮…❯
        let sql = """
            SELECT v.book_id, v.chapter, v.verse,
                   highlight(verse_fts, 0, '❮', '❯') AS snip
            FROM verse_fts
            JOIN verse v ON v.rowid = verse_fts.rowid
            WHERE verse_fts MATCH ?
              AND v.translation = ?
              \(bookClause)
            ORDER BY rank, verse_fts.rowid
            LIMIT ? OFFSET ?
            """
        query(sql, bindings: bindings) { stmt in
            let bookId  = string(stmt, 0)
            let chapter = Int(sqlite3_column_int(stmt, 1))
            let verse   = Int(sqlite3_column_int(stmt, 2))
            // FTS5 snippet() returns raw verse text including <S>N</S> markup.
            // Strip markup before storing — ❮…❯ highlight markers use non-ASCII
            // angle brackets (U+276E/U+276F) so strippingBibleMarkup() leaves them intact.
            let snip    = string(stmt, 3).strippingBibleMarkup()
            results.append(SearchResult(
                id: "\(bookId)|\(chapter)|\(verse)",
                reference: makeRef(bookId, chapter, verse, bookShortNames),
                snippet: snip
            ))
        }
        return results
    }

    /// Total number of matches for a search query (before pagination).
    /// Same MATCH + translation + optional book filter as `searchByText`.
    func searchResultCount(query rawQuery: String, translation: String,
                           bookIds: [String]? = nil) -> Int {
        guard isAvailable else { return 0 }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }

        var bindings: [Any] = [makeFTSQuery(trimmed), translation]
        let bookClause = makeBookFilterClause(bookIds, appendingTo: &bindings)

        var count = 0
        let sql = """
            SELECT COUNT(*)
            FROM verse_fts
            JOIN verse v ON v.rowid = verse_fts.rowid
            WHERE verse_fts MATCH ?
              AND v.translation = ?
              \(bookClause)
            """
        query(sql, bindings: bindings) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    /// Per-book match counts for a search query, ordered by count descending
    /// (YouVersion-style Book filter: books with the most hits first).
    /// Not restricted by book filter — the Book sheet always shows the full spread.
    func searchBookCounts(query rawQuery: String, translation: String) -> [SearchBookCount] {
        guard isAvailable else { return [] }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var counts: [SearchBookCount] = []
        let sql = """
            SELECT v.book_id, COUNT(*) AS cnt
            FROM verse_fts
            JOIN verse v ON v.rowid = verse_fts.rowid
            WHERE verse_fts MATCH ?
              AND v.translation = ?
            GROUP BY v.book_id
            ORDER BY cnt DESC
            """
        query(sql, bindings: [makeFTSQuery(trimmed), translation]) { stmt in
            counts.append(SearchBookCount(
                bookId: string(stmt, 0),
                count:  Int(sqlite3_column_int(stmt, 1))
            ))
        }
        return counts
    }

    // MARK: Autocomplete suggestions

    /// Words from `search_terms` matching a lowercase prefix (≥1 char), ordered by frequency.
    /// Uses GLOB for index-friendly prefix scan. Terms stored lowercase → caller must lowercase input.
    func suggestTerms(prefix: String, limit: Int = 8) -> [String] {
        guard isAvailable, prefix.count >= 1 else { return [] }
        var terms: [String] = []
        query("SELECT term FROM search_terms WHERE term GLOB ? ORDER BY freq DESC LIMIT ?",
              bindings: [prefix.lowercased() + "*", limit]) { stmt in
            terms.append(string(stmt, 0))
        }
        return terms
    }

    // MARK: Private search helpers

    /// Builds an optional `AND v.book_id IN (?,…)` clause for the search book filter.
    /// Appends the book ids to `bindings`; returns "" when no filter is active.
    private func makeBookFilterClause(_ bookIds: [String]?,
                                      appendingTo bindings: inout [Any]) -> String {
        guard let bookIds, !bookIds.isEmpty else { return "" }
        bindings.append(contentsOf: bookIds)
        let placeholders = Array(repeating: "?", count: bookIds.count).joined(separator: ",")
        return "AND v.book_id IN (\(placeholders))"
    }

    /// Builds a safe FTS5 MATCH expression with prefix matching.
    /// Phrase (multi-word) and single-word inputs both handled; quotes are escaped.
    private func makeFTSQuery(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
    }

    /// Short reference string — "Бут 1:1" — uses translation-native short name when provided.
    private func makeRef(_ bookId: String, _ chapter: Int, _ verse: Int,
                         _ bookShortNames: [String: String] = [:]) -> String {
        let short = bookShortNames[bookId] ?? BibleBookNames.short(for: bookId)
        return "\(short) \(chapter):\(verse)"
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

    /// Read a nullable INTEGER column.
    func optInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, col))
    }
}

