// StrongsModels.swift
// SourceBible
//
// Моделі лексичного шару: Strong's лексикон, конкорданс, коментарі.
// Відокремлено від BibleModels.swift (core reading) для чіткого розділення доменів.

import Foundation

// MARK: - Strong's Lexicon

struct StrongsEntry: Identifiable {
    let id: String
    let originalWord: String
    let transliteration: String // academic xlit (openscriptures): rēʾšiyṯ
    let xlitSimple: String      // simplified xlit (STEPBible): reshit  ← primary display
    let pronunciation: String
    let partOfSpeech: String
    let shortDefinition: String
    let semanticRange: [String]
    let fullDefinition: String  // BDB / Abbott-Smith (STEPBible)
    var concordance: [ConcordanceEntry]  // kept for DEBUG/Preview only; not used in production UI
    var totalCount: Int = 0              // true occurrence count across the whole Bible
    var bookGroups: [BookUsageGroup] = [] // per-book breakdown for WordUsageView
}

// MARK: - Book Usage Group

/// Aggregated concordance data for one Bible book.
/// Used in WordUsageView to render the per-book breakdown.
struct BookUsageGroup: Identifiable {
    /// Stable identifier: the OSIS book ID (e.g. "PSA").
    let id: String
    let bookId: String
    let bookName: String          // localized full name from BibleBookNames
    let count: Int                // distinct verses in this book that contain the word
    let example: ConcordanceEntry // first occurrence in the book (v1); v1.5 → rhetorical_weight-based
}

// MARK: - Concordance

struct ConcordanceEntry: Identifiable {
    let id: String
    let reference: String
    let text: String           // stripped, display-ready
    let rawText: String        // raw KJV markup, used for keyword highlighting
    let bookId: String
    let chapter: Int
    let verse: Int

    /// True when the preferred translation had no text for this verse and the fallback was used.
    let isFallback: Bool

    /// Convenience init — omits rawText and isFallback (used in sample/preview data).
    init(id: String, reference: String, text: String, rawText: String = "",
         isFallback: Bool = false, bookId: String, chapter: Int, verse: Int) {
        self.id         = id
        self.reference  = reference
        self.text       = text
        self.rawText    = rawText
        self.isFallback = isFallback
        self.bookId     = bookId
        self.chapter    = chapter
        self.verse      = verse
    }
}

// MARK: - Commentary

struct Theologian: Identifiable {
    let id: String
    /// Localization key — e.g. "theologian.calvin.name".
    /// Views use Text(LocalizedStringKey(nameKey)) so SwiftUI's environment locale
    /// always picks the right language, bypassing String(localized:) which in
    /// Swift 6 / iOS 26 may not go through the LocalizedBundle swizzle.
    let nameKey:  String
    let eraKey:   String
    let styleKey: String
    let imageName: String
}

struct Commentary: Identifiable {
    let id: String
    let theologian: Theologian
    let verseId: String
    let text: String
}

/// A single commentary section as returned by DatabaseService.loadCommentary.
/// Preserves authorial range metadata so the UI can display "Verses 8–15" headers.
struct CommentarySection {
    let text: String
    let startChapter: Int
    let startVerse: Int
    let endChapter: Int
    let endVerse: Int

    /// Human-readable verse range label, e.g. "Verse 7" or "Verses 8–15".
    var verseRangeLabel: String {
        if startChapter == endChapter && startVerse == endVerse {
            return "Verse \(startVerse)"
        } else if startChapter == endChapter {
            return "Verses \(startVerse)–\(endVerse)"
        } else {
            // Cross-chapter range (rare in Henry, present in Owen)
            return "Verses \(startChapter):\(startVerse)–\(endChapter):\(endVerse)"
        }
    }
}

extension Theologian {
    // Must be `var`, not `let`, so that language switching (Bundle.main swizzle + .id re-render)
    // causes SwiftUI to re-evaluate these computed values and pick up translated name/era/style keys.
    // `let` constants are captured at struct init time and never update — see ADR-007.
    static var calvin: Theologian { Theologian(
        id: "calvin",
        nameKey:  "theologian.calvin.name",
        eraKey:   "theologian.calvin.era",
        styleKey: "theologian.calvin.style",
        imageName: "calvin"
    ) }
    static var henry: Theologian { Theologian(
        id: "henry",
        nameKey:  "theologian.henry.name",
        eraKey:   "theologian.henry.era",
        styleKey: "theologian.henry.style",
        imageName: "henry"
    ) }
    static var spurgeon: Theologian { Theologian(
        id: "spurgeon",
        nameKey:  "theologian.spurgeon.name",
        eraKey:   "theologian.spurgeon.era",
        styleKey: "theologian.spurgeon.style",
        imageName: "spurgeon"
    ) }
    static var owen: Theologian { Theologian(
        id: "owen",
        nameKey:  "theologian.owen.name",
        eraKey:   "theologian.owen.era",
        styleKey: "theologian.owen.style",
        imageName: "owen"
    ) }
    static var all: [Theologian] { [calvin, henry, spurgeon, owen] }
}

// MARK: - Sample / Preview Data
// Доступні тільки в DEBUG builds.

#if DEBUG
extension StrongsEntry {
    static let sample = StrongsEntry(
        id: "H835",
        originalWord: "אֶשֶׁר",
        transliteration: "ʾešer",
        xlitSimple: "esher",
        pronunciation: "'e-šer",
        partOfSpeech: "noun",
        shortDefinition: "happy, blessed",
        semanticRange: ["happy", "blessed", "happiness", "prosperity"],
        fullDefinition: "BDB: אֶשֶׁר noun masculine happiness, blessedness. Used chiefly in the formula אַשְׁרֵי (the blessedness of...), opening wisdom psalms and beatitudes. Denotes not a subjective feeling but an objective state of flourishing recognized by the community.",
        concordance: [
            ConcordanceEntry(id: "PSA|1|1",  reference: "Псалом 1:1",  text: "Блаженний муж, що не ходить...",        bookId: "PSA", chapter: 1,  verse: 1),
            ConcordanceEntry(id: "PSA|2|12", reference: "Псалом 2:12", text: "Блаженні всі, що надіються на нього.",   bookId: "PSA", chapter: 2,  verse: 12),
            ConcordanceEntry(id: "PSA|32|1", reference: "Псалом 32:1", text: "Блаженний, кому прощено провину...",     bookId: "PSA", chapter: 32, verse: 1),
            ConcordanceEntry(id: "PSA|41|1", reference: "Псалом 41:1", text: "Блаженний, хто думає про бідного...",    bookId: "PSA", chapter: 41, verse: 1),
        ],
        totalCount: 45,
        bookGroups: [
            BookUsageGroup(
                id: "GEN", bookId: "GEN", bookName: "Genesis", count: 4,
                example: ConcordanceEntry(id: "GEN|30|13", reference: "Gen 30:13",
                    text: "Happy am I! For daughters will call me blessed.", bookId: "GEN", chapter: 30, verse: 13)),
            BookUsageGroup(
                id: "PSA", bookId: "PSA", bookName: "Psalms", count: 26,
                example: ConcordanceEntry(id: "PSA|1|1", reference: "Ps 1:1",
                    text: "Blessed is the man who walks not in the counsel of the wicked...", bookId: "PSA", chapter: 1, verse: 1)),
            BookUsageGroup(
                id: "PRO", bookId: "PRO", bookName: "Proverbs", count: 8,
                example: ConcordanceEntry(id: "PRO|3|13", reference: "Prov 3:13",
                    text: "Blessed is the one who finds wisdom, and the one who gets understanding.", bookId: "PRO", chapter: 3, verse: 13)),
        ]
    )
}
#endif
