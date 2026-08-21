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
        // One extra query for the whole chapter (see loadFootnotes) — cheap, and it means a
        // tap on a † never hits the DB while the reader is scrolling.
        let footnotes = loadFootnotes(bookId: bookId, chapter: chapter, translation: translation)

        query(sql, bindings: [translation, bookId, chapter]) { stmt in
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            let rawText  = string(stmt, 1)
            let id       = "\(bookId)|\(chapter)|\(verseNum)"
            let parsed   = VerseParser.parse(verseId: id, rawText: rawText)
            verses.append(BibleVerse(id: id, bookId: bookId, chapter: chapter,
                                     number: verseNum, text: parsed.plainText,
                                     words: [], parsed: parsed,
                                     footnotes: footnotes[id] ?? [:]))
        }
        return verses
    }

    /// Translator footnotes for a whole chapter: verseId → (marker → plain text).
    ///
    /// One query per chapter, not per verse: the notes are sparse (UBIO has 1 329 anchors in
    /// the entire Bible, RST 100) and a chapter's worth is a handful of short rows — median
    /// note length is 42 characters. Loading them with the chapter means tapping a † never
    /// touches the DB.
    ///
    /// `marker` matches the `<f>…</f>` anchor text in `verse.text` verbatim (`[2]`), which is
    /// what `VerseParser` stores as `VerseSegment.footnoteAnchorId`.
    ///
    /// Only UBIO and RST carry these. KJV's `<n>…</n>` notes are a DIFFERENT mechanism —
    /// inline in the verse text, no anchor, parsed into `ParsedVerse.footnotes` — and are not
    /// in this table.
    func loadFootnotes(bookId: String, chapter: Int,
                       translation: String) -> [String: [String: String]] {
        guard isAvailable else { return [:] }
        var result: [String: [String: String]] = [:]
        // Ключ — `(chapter_from, verse_from)`, і це не спрощення, а вимір (2026-08-08):
        // із 1 312 приміток 69 охоплюють кілька віршів і 3 — кілька глав, але **в усіх 72
        // анкер `<f>` стоїть саме у verse_from**. Тобто діапазон описує, скільки тексту
        // примітка пояснює, а не де вона причеплена.
        // ⛔ Не «виправляти» на пошук за діапазоном: це причепило б одну примітку до всіх
        // віршів проміжку, і хрестик з'явився б там, де в тексті анкера немає.
        let sql = """
            SELECT verse_from, marker, text FROM footnote
            WHERE translation = ? AND book_id = ? AND chapter_from = ?
            """
        query(sql, bindings: [translation, bookId, chapter]) { stmt in
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            let marker   = string(stmt, 1)
            let text     = string(stmt, 2).strippingFootnoteHTML()
            guard !marker.isEmpty, !text.isEmpty else { return }
            result["\(bookId)|\(chapter)|\(verseNum)", default: [:]][marker] = text
        }
        return result
    }

    /// Плоский текст одного вірша для показу — паралельні переклади й картки закладок.
    ///
    /// Читає `text_clean`, а не `text` + зняття розмітки в рантаймі (ADR-034).
    ///
    /// ⛔ Тут до 2026-08-08 лишався `VerseParser.stripTags(text)` — останній рантайм-стрипер
    /// у кодовій базі. Він не був битим (`VerseParser` завжди був правильний), але робив
    /// інваріант ADR-034 неправдою і давав видиму розбіжність: парсер навмисно показує †
    /// на місці `<f>`, а колонка його викидає, тож ОДИН І ТОЙ САМИЙ вірш мав хрестик у
    /// паралельних і не мав у крос-рефах. Тепер усі поверхні плоского тексту читають одну
    /// колонку.
    ///
    /// `COALESCE` не потрібен: колонка `NOT NULL` (`build_db.py`, схема `verse`).
    func loadVerseText(bookId: String, chapter: Int, verse: Int, translation: String) -> String? {
        guard isAvailable else { return nil }
        var result: String?
        let sql = """
            SELECT text_clean FROM verse
            WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?
            """
        query(sql, bindings: [translation, bookId, chapter, verse]) { stmt in
            result = string(stmt, 0)
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

        // ⛔ bug-046 — визначення, що насправді належить БАЗОВОМУ номеру, не можна
        // показувати як власне визначення підзапису. H2617a — це חֶסֶד II «ганьба»
        // (Лев 20:17, Прип 14:34), а база несе «kindness», тобто ПРОТИЛЕЖНЕ значення,
        // подане як факт. Заміряно 2026-08-19: 444 підзаписи, 5 947 вживань.
        //
        // Гасимо тут, у єдиному джерелі, щоб усі споживачі поводились однаково.
        // Порожньо чесніше за правдоподібний хибний текст: користувач бачить, що даних
        // немає, замість читати чуже значення (CLAUDE.md: «Порожньо + fallback чесніше,
        // ніж збережена помилка»).
        //
        // ⛔ НЕ «лагодити» це зсувом суфіксів Macula→TBESH. Перевірено на корпусі:
        // зсув виграє 82 випадки, програє 41, у 265 із 388 сигналу немає. Правильні
        // дані в TBESH існують (H2617b = «shame»), але зіставлення двох схем нумерації —
        // куроване рішення, а не формула (пор. ADR-028, який відкинув евристичну verse_map).
        if let e = entry, StrongsDefinitionTrust.isUntrusted(id) {
            entry = StrongsEntry(
                id: e.id,
                originalWord: e.originalWord,
                transliteration: e.transliteration,
                xlitSimple: e.xlitSimple,
                pronunciation: e.pronunciation,
                partOfSpeech: e.partOfSpeech,
                shortDefinition: "",
                semanticRange: [],
                fullDefinition: "",
                concordance: []
            )
        }

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
        if let e = entry, e.fullDefinition.isEmpty, baseId != id,
           !StrongsDefinitionTrust.isUntrusted(id) {
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
    //
    // ⛔ ВИДАЛЕНО (ADR-034). Тут був `stripBibleMarkup(_:)` — рантайм-зняття розмітки для
    // концордансу, крос-рефів, паралельних перекладів і сніпета пошуку.
    //
    // Не відроджувати. Плоский текст вірша для показу має ОДНЕ джерело — `verse.text_clean`,
    // побудований на збірці. Друга реалізація тих самих правил у Swift розійшлася з
    // Python-боком і роками показувала чуже: 261 вірш просочував СЛОВО з багатономерного
    // тега (`<S>8147, Joshua82</S>` → «…are like two, Joshua fawns…»), 1 330 показували
    // маркер виноски `[2]` як текст. Рідер при цьому був правильний (він іде через
    // `VerseParser`), тому дефект і не помічали.
    //
    // Якщо новій поверхні потрібен текст вірша — `SELECT text_clean`, а не `text` + strip.
    // `text` лишається джерелом для парсера (структура, тапи по словах).

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

        // ⛔ bug-045 — group by the EXACT `strongs_id`. Do NOT strip the suffix here.
        //
        // The suffix is part of the lexeme's identity, not decoration: in `word`,
        // H2617 = hesed I "faithful love" (245 occurrences) and H2617a = hesed II
        // "disgrace" (2: Lev 20:17, Prov 14:34) are DIFFERENT WORDS. Stripping merged
        // them, so Usage for "lovingkindness" listed "it is a wicked thing".
        // Measured 2026-08-18: 169 972 occurrences sit on 1 008 suffixed ids, and the
        // pattern is always one dominant sense plus crumbs — H871 = 1 (a town) vs
        // H871a = 15 539 (the preposition b-). Stripping on H871 would have returned
        // 15 539 hits for a place name.
        //
        // Suffix stripping stays legitimate in exactly ONE place: the bridge from a
        // TAGGED TRANSLATION segment (which writes bare numbers, `<S>2617</S>`) to a
        // Macula word — `ReaderViewModel.resolvedMaculaBase`. `loadStrongs` keeps the
        // requested id on the returned entry (`id: e.id`), so what arrives here is
        // always the full Macula id.
        //
        // ⛔ Do NOT "improve" this by merging variants that share a lemma or a
        // definition: bug-046 measured the sub-entry definitions to be unreliable
        // (558 of 1 008 carry the base entry's short_def), so such a rule would
        // silently merge hesed back together.
        //
        // Sub-entries that Macula split off the SAME word are re-joined through the
        // generated `StrongsMergeMap` (bug-045, buckets A+B): merge only when the
        // `word.lemma` sets are IDENTICAL and the `word.gloss` sets OVERLAP.
        // H835/H835a (אַשְׁרֵי — one word, split by tagging) merge; H2617/H2617a
        // (hesed I "faithful love" vs hesed II "disgrace") do NOT, because their
        // glosses are disjoint. Anything absent from the map matches exactly.
        // ⛔ Regenerate after any DB rebuild: python3 scripts/build_strongs_merge_map.py
        let mergeIds = StrongsMergeMap.expand(strongsId)
        let idPlaceholders = Array(repeating: "?", count: mergeIds.count).joined(separator: ", ")

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
                CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback,
                -- Display text comes from the DB, not from a runtime strip (ADR-034).
                -- `text` is still selected above because the Strong's highlighting in
                -- WordTabContent needs the MARKUP (it walks segments); the two are not
                -- interchangeable — one is for reading, one is for structure.
                COALESCE(v.text_clean, v_fb.text_clean) AS resolved_clean
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
            WHERE w.strongs_id IN (\(idPlaceholders))
            ORDER BY w.book_id, w.chapter, w.verse
            LIMIT ?
            """
        var concordanceBindings: [Any] = [translation, fallbackTranslation,
                                          translation, fallbackTranslation]
        concordanceBindings.append(contentsOf: mergeIds)
        concordanceBindings.append(limit)
        query(sql, bindings: concordanceBindings) { stmt in
            let bookId      = string(stmt, 0)
            // cols 1–2 = w.chapter / w.verse (original numbering) — not used for display
            let chapter      = Int(sqlite3_column_int(stmt, 3))   // display_chapter
            let displayVerse = Int(sqlite3_column_int(stmt, 4))   // display_verse
            let rawText     = optString(stmt, 5) ?? ""
            let text        = optString(stmt, 7) ?? ""   // resolved_clean — ADR-034
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
    /// - Parameter strongsId: The EXACT Macula Strong's ID, sub-entry suffix included
    ///   (e.g. "H835a"). Matched verbatim — H835 and H835a are different lexemes and are
    ///   counted separately (bug-045). See the note in the body before changing this.
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

        // Same rule as loadConcordance — see the bug-045 note there, including the
        // StrongsMergeMap re-join for sub-entries Macula split off the same word.
        let mergeIds = StrongsMergeMap.expand(strongsId)
        let idPlaceholders = Array(repeating: "?", count: mergeIds.count).joined(separator: ", ")
        let strongsFilter = "w.strongs_id IN (\(idPlaceholders))"

        // --- Query A: total word token count across the whole Bible ---
        // COUNT(*) counts every word token — consistent with the standard reference count
        // (e.g. יהוה = 6512 tokens, not 5515 distinct verses that contain it).
        var total = 0
        let totalSQL = """
            SELECT COUNT(*)
            FROM word w
            WHERE \(strongsFilter)
            """
        query(totalSQL, bindings: mergeIds) { stmt in
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
        query(groupSQL, bindings: mergeIds) { stmt in
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
                   CASE WHEN v.text IS NULL AND v_fb.text IS NOT NULL THEN 1 ELSE 0 END AS is_fallback,
                   -- Display text from the DB (ADR-034); `text` above stays for the
                   -- Strong's-highlighting path, which needs the markup.
                   COALESCE(v.text_clean, v_fb.text_clean) AS resolved_clean
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
            var cleanText      = ""
            var isFallback     = false

            var exampleBindings: [Any] = [
                translation, fallbackTranslation, translation, fallbackTranslation,
                row.bookId, row.chapter, row.verse
            ]
            exampleBindings.append(contentsOf: mergeIds)
            query(exampleSQL, bindings: exampleBindings) { stmt in
                displayChapter = Int(sqlite3_column_int(stmt, 0))
                displayVerse   = Int(sqlite3_column_int(stmt, 1))
                rawText        = optString(stmt, 2) ?? ""
                isFallback     = sqlite3_column_int(stmt, 3) != 0
                cleanText      = optString(stmt, 4) ?? ""   // resolved_clean — ADR-034
            }

            // Skip if no verse text found in either translation.
            let text = cleanText
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
    /// Display-ready text of one verse.
    ///
    /// Reads `text_clean`, not `text` (ADR-034): the markup-free copy is built once at DB
    /// build time, so nothing here strips anything at runtime. Its only caller is the
    /// cross-reference list, which shows plain text and never needs the tags.
    private func verseText(bookId: String, chapter: Int, verse: Int,
                           translation: String) -> String? {
        var text: String?
        let sql = """
            SELECT text_clean FROM verse
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

    /// Verse text in other translations, aligned through `verse_org` (ADR-028).
    ///
    /// Parallel translations are a CROSS-TRANSLATION surface: the reader's verse NUMBER
    /// means nothing in a translation with another versification scheme. The identity
    /// lookup this replaced (one `loadVerseText` per translation, bug-036) showed the
    /// NEIGHBOURING verse — measured on the shipped DB: 2 705 KJV verses wrong in the
    /// RST row, 3 367 in the UBIO row, and Psalms wrong by a whole chapter in both
    /// (RST and UBIO Psalters are LXX-numbered). Where the number does not exist in the
    /// target at all, `compactMap` silently dropped the row (KJV HOS 13:16 → RST 14:1).
    ///
    /// Two curated hops — the same pair the Original pill and cross-references use:
    /// reader verse → original (Macula) ref → that target translation's own verse.
    ///
    /// - Returns: text per translation id. A translation is ABSENT from the result when it
    ///   has no verse for this original ref — an honest gap instead of a wrong verse.
    /// - Fallbacks: no `verse_org` row at all (DB predates ADR-028) or an explicit
    ///   "no original" mapping (`org_*` NULL — 32 verses corpus-wide) → identity, i.e.
    ///   the old behaviour for exactly those verses and nothing else.
    /// - N:M: `orgRef`/`translationRef` take the first row of a curated ordering.
    ///   Measured: no verse in the DB maps to >1 original, and only 2–3 originals per
    ///   translation are split across two verses, so the first row is the whole story.
    func loadParallelVerseTexts(bookId: String, chapter: Int, verse: Int,
                                source: String, targets: [String]) -> [String: String] {
        guard isAvailable else { return [:] }

        let (sawRows, org) = orgRef(bookId: bookId, chapter: chapter, verse: verse,
                                   translation: source)

        /// Same book/chapter/verse in `translation` — the reader's own row and the
        /// pre-`verse_org` fallback.
        func identityText(_ translation: String) -> String? {
            verseText(bookId: bookId, chapter: chapter, verse: verse, translation: translation)
        }

        var out: [String: String] = [:]
        for target in targets {
            // The reader's own translation needs no hop; neither does a verse we cannot
            // hop from (no mapping row, or no original counterpart).
            if target == source || !sawRows || org == nil {
                if let text = identityText(target) { out[target] = text }
                continue
            }
            guard let org,
                  let ref = translationRef(orgBookId: org.bookId, orgChapter: org.chapter,
                                           orgVerse: org.verse, translation: target),
                  let text = verseText(bookId: ref.bookId, chapter: ref.chapter,
                                       verse: ref.verse, translation: target)
            else { continue }
            out[target] = text
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

            // `verseText` already returns `text_clean` — no runtime strip (ADR-034).
            let text       = readerText ?? fbText ?? ""
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

    /// Returns the set of commentary source names that have a NON-EMPTY section
    /// actually covering the given verse — not merely the same book. A source may
    /// have sections elsewhere in the book but a coverage gap (or a blank section) at
    /// this verse; Calvin's modules are patchy (ADR-027). Offering such a source opened
    /// an empty detail page (bug-016), so the picker filters on this per-verse set.
    func commentarySourcesAvailable(bookId: String, chapter: Int, verse: Int) -> Set<String> {
        guard isAvailable else { return [] }
        var sources = Set<String>()
        let sql = """
            SELECT DISTINCT c.source
            FROM comments c
            JOIN comment_verses cv ON cv.comment_id = c.id
            WHERE cv.book_id = ? AND cv.chapter = ? AND cv.verse = ?
              AND c.text IS NOT NULL
              AND TRIM(c.text, char(32) || char(9) || char(10) || char(13)) <> ''
            """
        query(sql, bindings: [bookId, chapter, verse]) { stmt in
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
              AND c.text IS NOT NULL
              AND TRIM(c.text, char(32) || char(9) || char(10) || char(13)) <> ''
            ORDER BY c.id
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
    /// A phrase requires the indexed tokens to be ADJACENT, so `verse_fts` must be built
    /// over `verse.text_clean` (markup-free) and never over the raw `verse.text`: inline
    /// `<S>1234</S>` tokenizes to `S | 1234 | S` between two real words and silently kills
    /// every multi-word query while single words keep working — that asymmetry is exactly
    /// what made bug-035 read as "multi-word search is broken". See ADR-008, amendment
    /// 2026-08-06.
    ///
    /// Results come back in CANONICAL order — book → chapter → verse (ADR-008,
    /// amendment 2026-08-07). BM25 (`ORDER BY rank`) was dropped: in a corpus where all
    /// 31k verses share one genre, relevance degenerates into verse length, so the reader
    /// got an order they could not reconstruct (a query for "Душа" opened Pr 13:4, then
    /// Ez 18:4, then Lev 7:27, then Pr 19:15 again).
    ///
    /// ⛔ Book order is PER-TRANSLATION (`book_name.sort_order`), NOT `book.num`. RST puts
    /// 21 books elsewhere — the catholic epistles (Jas, 1–2 Pe, 1–3 Jn, Jud) come BEFORE
    /// the Pauline ones, per the Synodal tradition. `book.num` would hand an RST reader the
    /// Protestant order, i.e. search would contradict the reader within the same
    /// translation (ADR-018).
    ///
    /// ⛔ `LEFT JOIN` + `COALESCE`, never `INNER JOIN`: an inner join would silently DROP
    /// results for any (book, translation) pair missing a `book_name` row. Coverage is
    /// complete today (66 × 5, zero orphan verses) but the schema does not guarantee it,
    /// and a vanished book is a worse defect than a wrong order.
    ///
    /// Faster than the ranked version, not slower — BM25 has to be computed per match,
    /// `sort_order` only read (measured: `"the"*` KJV 63.7 → 47.4 ms; the same query at
    /// OFFSET 2000, i.e. deep infinite scroll, 83.7 → 33.5 ms). The old
    /// `verse_fts.rowid` tiebreak is gone: (book, chapter, verse) is unique within a
    /// translation, so pagination is deterministic by construction.
    ///
    /// The highlight() function returns the full verse text with matched tokens wrapped
    /// in ❮…❯ so the UI can highlight them.
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
            JOIN book b ON b.id = v.book_id
            LEFT JOIN book_name bn ON bn.book_id = v.book_id
                                  AND bn.translation_id = v.translation
            WHERE verse_fts MATCH ?
              AND v.translation = ?
              \(bookClause)
            ORDER BY COALESCE(bn.sort_order, b.num - 1), v.chapter, v.verse
            LIMIT ? OFFSET ?
            """
        query(sql, bindings: bindings) { stmt in
            let bookId  = string(stmt, 0)
            let chapter = Int(sqlite3_column_int(stmt, 1))
            let verse   = Int(sqlite3_column_int(stmt, 2))
            // highlight() reads verse_fts column 0 = `verse.text_clean`, which is
            // markup-free by the build invariant (bug-035). No runtime strip: the guard that
            // used to sit here was removed with the rest of the runtime stripper (ADR-034).
            // If a stale DB ever slips in, markup shows up in snippets — visible and
            // self-diagnosing, unlike a guard that quietly papers over a broken build.
            let snip    = string(stmt, 3)
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

    /// Words from `search_terms` matching a lowercase prefix (≥1 char), ordered by frequency,
    /// restricted to ONE language. GLOB keeps the prefix scan index-friendly (the plan stays
    /// `SEARCH search_terms USING PRIMARY KEY (term>? AND term<?)`). Terms are stored
    /// lowercase → the caller's prefix is lowercased here.
    ///
    /// `lang` is `translation.language` (`en`/`ru`/`uk`) — see `languageForTranslation`.
    /// Before ADR-008 amendment 2026-08-07 the dictionary was SHARED across all five
    /// translations, and that produced two defects the user hit directly:
    ///   `се*` → себе, себя, сердце, серед, сего, серце — Russian and Ukrainian interleaved;
    ///   and suggestions that led to ZERO results, because the term came from RST while
    ///   `searchByText` filters `AND v.translation = ?` and searched UBIO. Suggestions and
    ///   search were running over different sets.
    ///
    /// Keyed by LANGUAGE, not translation: KJV/ASV/NASB would otherwise get three nearly
    /// identical English dictionaries, while the actual mixing is between languages. Adding
    /// German or Spanish now needs no change here — the new translation brings its own
    /// language and splits itself off.
    ///
    /// Filtering by language is also FASTER, not a tax: `lang` cuts candidates BEFORE the
    /// `ORDER BY freq` temp b-tree, which is the only part of this query that can lag
    /// (measured: `а*` 0.335 → 0.113 ms; long prefixes are within noise either way).
    ///
    /// An unknown/empty `lang` returns [] rather than falling back to every language —
    /// silence beats a suggestion list from the wrong alphabet.
    func suggestTerms(prefix: String, lang: String, limit: Int = 8) -> [String] {
        guard isAvailable, prefix.count >= 1, !lang.isEmpty else { return [] }
        var terms: [String] = []
        query("""
              SELECT term FROM search_terms
              WHERE term GLOB ? AND lang = ?
              ORDER BY freq DESC LIMIT ?
              """,
              bindings: [prefix.lowercased() + "*", lang, limit]) { stmt in
            terms.append(string(stmt, 0))
        }
        return terms
    }

    /// `translation.language` for a translation id ("UBIO" → "uk"). Empty when unknown —
    /// callers treat that as "no suggestions" (see `suggestTerms`).
    func languageForTranslation(_ id: String) -> String {
        guard isAvailable else { return "" }
        var lang = ""
        query("SELECT language FROM translation WHERE id = ?", bindings: [id]) { stmt in
            lang = string(stmt, 0)
        }
        return lang
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
    ///
    /// The quoted form makes this a PHRASE query — a deliberate trade: word order is
    /// enforced, so "тени долиною" must NOT match a verse reading "долиною … тени".
    /// `NEAR()` would loosen that and was rejected for it (ADR-008, amendment 2026-08-06);
    /// the cost of keeping phrases is that the index may carry no markup tokens.
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

