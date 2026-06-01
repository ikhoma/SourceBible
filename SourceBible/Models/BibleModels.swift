// BibleModels.swift
// SourceBible

import Foundation

// MARK: - Bible Structure

struct BibleBook: Identifiable, Hashable {
    let id: String
    let name: String
    let nameShort: String
    let testament: Testament
    let chapterCount: Int
}

enum Testament: String, CaseIterable {
    case old = "Старий Заповіт"
    case new = "Новий Заповіт"

    /// Localized display name. Use this in UI — do NOT use rawValue for display.
    /// rawValues are stored in the DB and must not change.
    var localizedName: String {
        switch self {
        case .old: return String(localized: "testament.old")
        case .new: return String(localized: "testament.new")
        }
    }
}

struct BibleChapter: Identifiable {
    let id: String
    let bookId: String
    let number: Int
    var verses: [BibleVerse]
}

struct BibleVerse: Identifiable {
    let id: String
    let bookId: String
    let chapter: Int
    let number: Int
    let text: String        // plain text без тегів (для пошуку/індексу)
    var words: [BibleWord]
    /// rawValue of HighlightColor, or nil if not highlighted.
    /// Stored as a String to avoid a circular import; resolve via HighlightColor.from(_:).
    var highlightColor: String? = nil
    var parsed: ParsedVerse? = nil  // nil тільки для sample data без парсингу
}

// Manual Hashable — exclude `parsed` and `words` (expensive, not needed for equality)
extension BibleVerse: Hashable {
    static func == (lhs: BibleVerse, rhs: BibleVerse) -> Bool {
        lhs.id == rhs.id && lhs.highlightColor == rhs.highlightColor
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(highlightColor)
    }
}

// MARK: - Parsed Verse

/// Структурований результат парсингу сирого тексту вірша з MyBible тегами.
/// Tokenizer → Parser → ParsedVerse → Renderer (VerseTextView)
struct ParsedVerse {
    let verseId: String
    let segments: [VerseSegment]
    let footnotes: [ParsedFootnote]

    /// Чистий текст без тегів — для пошуку та передачі в BibleVerse.text
    var plainText: String {
        segments
            .filter { !$0.isLineBreak && !$0.isParagraphBreak && !$0.text.isEmpty }
            .map(\.text)
            .joined()
    }
}

/// Один смисловий відрізок тексту вірша зі стилем і семантикою.
struct VerseSegment: Identifiable {
    let id: UUID
    let text: String
    var styles: SegmentStyle
    var strongs: [String]           // e.g. ["H835"] або ["H8384","H5929"] для compound
    var footnoteAnchorId: String?   // non-nil для <f>[1]</f> — текст порожній, це лише маркер
    var isLineBreak: Bool           // <br/>
    var isParagraphBreak: Bool      // <pb/> — невидимий, позначає початок абзацу
    var characterOffset: Int        // зміщення у plainText (для Macula alignment, future)

    init(
        text: String,
        styles: SegmentStyle = .plain,
        strongs: [String] = [],
        footnoteAnchorId: String? = nil,
        isLineBreak: Bool = false,
        isParagraphBreak: Bool = false,
        characterOffset: Int = 0
    ) {
        self.id = UUID()
        self.text = text
        self.styles = styles
        self.strongs = strongs
        self.footnoteAnchorId = footnoteAnchorId
        self.isLineBreak = isLineBreak
        self.isParagraphBreak = isParagraphBreak
        self.characterOffset = characterOffset
    }
}

struct SegmentStyle: OptionSet {
    let rawValue: Int
    static let plain      = SegmentStyle([])
    static let jesusWords = SegmentStyle(rawValue: 1 << 0)  // <J> — слова Ісуса
    static let italic     = SegmentStyle(rawValue: 1 << 1)  // <i> — додані перекладачем
    static let emphasis   = SegmentStyle(rawValue: 1 << 2)  // <e> — цитата / виділення
}

// MARK: - Parsed Footnote

struct ParsedFootnote: Identifiable {
    let id: String          // anchor id: "[1]", "[2]", або "auto_0", "auto_1"
    let rawText: String     // вихідний текст <n>…</n>
    let kind: FootnoteKind
}

enum FootnoteKind {
    case alternateTranslation(word: String, alternatives: [String])
    // "ungodly: or, wicked" → word: "ungodly", alternatives: ["wicked"]

    case hebrewGreekNote(word: String, original: String)
    // "wither: Heb. fade" → word: "wither", original: "fade"

    case translatorNote(String)
    case postscript(String)         // довгі нотатки в кінці книги
    case unknown(String)            // fallback — зберігаємо, але не інтерпретуємо
}

// MARK: - Word & Strong's

struct BibleWord: Identifiable, Hashable {
    let id: String
    let text: String
    let strongsId: String?
    let morphology: String?
    let gloss: String?          // Macula contextual gloss (e.g. "he.walks")
    let xlitSimple: String?     // TBESH lemma transliteration (e.g. "ha.lakh")
    let xlit: String?           // Macula occurrence xlit (e.g. "hālaḵə")
    let syntaxRole: String?     // Macula syntactic role: v=predicate, s=subject, o=object…
    let greek: String?          // LXX Greek surface form (e.g. "ἐπορεύθη")
    let greekStrong: String?    // LXX Greek Strong's number (e.g. "G4198")
    let afterChar: String?      // trailing char from Macula `after` attr (e.g. "־" maqaf, "׃" sof pasuq)

    init(id: String, text: String, strongsId: String? = nil,
         morphology: String? = nil, gloss: String? = nil,
         xlitSimple: String? = nil, xlit: String? = nil,
         syntaxRole: String? = nil, greek: String? = nil, greekStrong: String? = nil,
         afterChar: String? = nil) {
        self.id = id; self.text = text; self.strongsId = strongsId
        self.morphology = morphology; self.gloss = gloss
        self.xlitSimple = xlitSimple; self.xlit = xlit
        self.syntaxRole = syntaxRole; self.greek = greek; self.greekStrong = greekStrong
        self.afterChar = afterChar
    }

    /// Best available transliteration: occurrence-specific first, lemma fallback.
    var displayXlit: String? { xlit ?? xlitSimple }

    /// Surface form as it appears in the text, including any trailing connector.
    /// Use this for display in Original tab; use `text` for Strong's lookup and search.
    var displayText: String { text + (afterChar ?? "") }
}

// StrongsEntry, ConcordanceEntry → Models/StrongsModels.swift
// Theologian, Commentary       → Models/StrongsModels.swift
// Highlight, Note, Bookmark…   → Models/UserDataModels.swift
// Translation, VerseTranslation, CrossReference → залишились нижче (core reading)

// MARK: - Translations

struct Translation: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
}

extension Translation {
    // Populated at runtime from the database via DatabaseService.loadTranslations()
    static let kjv = Translation(id: "KJV", name: "King James Version", language: "en")
    static let defaultTranslation = Translation.kjv
}

struct VerseTranslation: Identifiable {
    let id: String
    let translation: Translation
    let text: String
}

// MARK: - Cross References

struct CrossReference: Identifiable {
    let id: String
    let targetReference: String
    let targetText: String
    let bookId: String
    let chapter: Int
    let verse: Int
    /// True when the preferred translation had no text for this verse and the fallback was used.
    let isFallback: Bool
}

// MARK: - Sample / Preview Data
// Доступні тільки в DEBUG builds — для Xcode Previews і fallback без БД.

#if DEBUG
extension BibleBook {
    static let sampleBooks: [BibleBook] = [
        BibleBook(id: "GEN", name: "Буття",       nameShort: "Бут", testament: .old, chapterCount: 50),
        BibleBook(id: "EXO", name: "Вихід",       nameShort: "Вих", testament: .old, chapterCount: 40),
        BibleBook(id: "PSA", name: "Псалми",      nameShort: "Пс",  testament: .old, chapterCount: 150),
        BibleBook(id: "PRO", name: "Приповісті",  nameShort: "Пр",  testament: .old, chapterCount: 31),
        BibleBook(id: "ISA", name: "Ісая",        nameShort: "Іс",  testament: .old, chapterCount: 66),
        BibleBook(id: "MAT", name: "Матвія",      nameShort: "Мт",  testament: .new, chapterCount: 28),
        BibleBook(id: "JHN", name: "Івана",       nameShort: "Ів",  testament: .new, chapterCount: 21),
        BibleBook(id: "ROM", name: "Римлян",      nameShort: "Рим", testament: .new, chapterCount: 16),
        BibleBook(id: "PHP", name: "Филип'ян",    nameShort: "Флп", testament: .new, chapterCount: 4),
    ]
}

extension BibleVerse {
    static let sampleVerses: [BibleVerse] = [
        BibleVerse(
            id: "PSA|1|1", bookId: "PSA", chapter: 1, number: 1,
            text: "Блаженний муж, що не ходить на раду нечестивих, і на дорозі грішних не стоїть, і на сидінні блюзнірів не сидить,",
            words: [
                BibleWord(id: "PSA|1|1|1", text: "Блаженний", strongsId: "H835",  morphology: "HAa",    gloss: "blessed"),
                BibleWord(id: "PSA|1|1|2", text: "муж",       strongsId: "H376",  morphology: "HNcmsa", gloss: "man"),
                BibleWord(id: "PSA|1|1|3", text: "що",        strongsId: nil,     morphology: nil,      gloss: nil),
                BibleWord(id: "PSA|1|1|4", text: "не",        strongsId: nil,     morphology: nil,      gloss: nil),
                BibleWord(id: "PSA|1|1|5", text: "ходить",    strongsId: "H1980", morphology: "HVqp3ms",gloss: "walk"),
            ]
        ),
        BibleVerse(
            id: "PSA|1|2", bookId: "PSA", chapter: 1, number: 2,
            text: "а в законі Господнім воля його, і про закон Його він роздумує вдень і вночі.",
            words: [
                BibleWord(id: "PSA|1|2|1", text: "законі",    strongsId: "H8451", morphology: "HNcmsa", gloss: "law"),
                BibleWord(id: "PSA|1|2|2", text: "Господнім", strongsId: "H3068", morphology: "HNpm",   gloss: "LORD"),
                BibleWord(id: "PSA|1|2|3", text: "воля",      strongsId: "H2656", morphology: "HNcfsc", gloss: "delight"),
            ]
        ),
        BibleVerse(
            id: "PSA|1|3", bookId: "PSA", chapter: 1, number: 3,
            text: "І буде він, як дерево, посаджене над потоками вод, що дає плід свій у свій час, і листя якого не в'яне, — і все, що він чинить, щаститиме.",
            words: [],
            highlightColor: "yellow"
        ),
        BibleVerse(
            id: "PSA|1|4", bookId: "PSA", chapter: 1, number: 4,
            text: "Нечестиві — не так; вони, як полова, що її вітер розвіває.",
            words: []
        ),
        BibleVerse(
            id: "PSA|1|5", bookId: "PSA", chapter: 1, number: 5,
            text: "Тому нечестиві не встоять на суді, ані грішники — у зборах праведних.",
            words: []
        ),
        BibleVerse(
            id: "PSA|1|6", bookId: "PSA", chapter: 1, number: 6,
            text: "Бо Господь знає путь праведних, а путь нечестивих загине.",
            words: [
                BibleWord(id: "PSA|1|6|1", text: "Господь", strongsId: "H3068", morphology: "HNpm",    gloss: "LORD"),
                BibleWord(id: "PSA|1|6|2", text: "знає",    strongsId: "H3045", morphology: "HVqp3ms", gloss: "knows"),
                BibleWord(id: "PSA|1|6|3", text: "путь",    strongsId: "H1870", morphology: "HNcmsa",  gloss: "way"),
            ]
        ),
    ]
}
#endif

// StrongsEntry.sample → Models/StrongsModels.swift
