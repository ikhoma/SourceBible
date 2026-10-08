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
        case .old: return NSLocalizedString("testament.old", comment: "")
        case .new: return NSLocalizedString("testament.new", comment: "")
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
    /// Примітки перекладача для цього вірша: маркер (`[2]`) → готовий до показу текст.
    /// Заповнює `DatabaseService.loadChapter` із таблиці `footnote` (ASV/UBIO/RST).
    ///
    /// Порожній словник — нормальний стан: у KJV/NASB цих приміток немає взагалі, а
    /// в UBIO 6.9% анкерів (92 з 1 329) не мають рядка в `footnote`. Рідер малює знак
    /// ЛИШЕ там, де запис є (`VerseTextView`), інакше тап відкривав би порожнечу.
    ///
    /// ⛔ bug-061: кожне перебудування `BibleVerse(...)` (ReaderViewModel) МУСИТЬ передавати
    /// `footnotes` і `footnoteLabels` далі — поле має дефолт `[:]`, тож пропуск компілюється
    /// мовчки, і виноски зникають у всіх перекладах.
    var footnotes: [String: String] = [:]
    /// Літера знака виноски: маркер (`[2]`) → `"a"`, `"b"`… Нумерація в межах ГЛАВИ, у порядку
    /// читання (вірш, потім позиція якоря у вірші); після `z` — `aa`, `ab`… (ASV: до 35 на главу).
    /// Заповнює `DatabaseService.loadChapter`; лише для маркерів, що мають текст у `footnotes`.
    var footnoteLabels: [String: String] = [:]
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
    let lexicalClass: String?   // Macula TSV `class`: noun/verb/adj/adv/prep/cj/pron/ij/intj/art/ptcl/rel/num
    let slot: Int?              // Macula !N group position; tokens sharing same slot = one display word
    let xlitSlot: String?       // BibleHub combined slot translit (root token only; nil on helpers + Greek)

    // ADR-040: already-decoded morphology fields straight from the Macula TSV
    // (MorphologyDecoder is a lookup layer over these, not a positional parser
    // of `morphology`). All nullable — populated only where the field applies.
    let person: String?         // both languages: first/second/third
    let gender: String?         // both languages: masculine/feminine/neuter/common/both
    let number: String?         // both languages: singular/plural/dual
    let grCase: String?         // Greek `case`: nominative/genitive/dative/accusative/vocative
    let tense: String?          // Greek `tense`: aorist/present/imperfect/future/perfect/pluperfect
    let voice: String?          // Greek `voice`: active/passive/middle/middlepassive
    let mood: String?           // Greek `mood`: indicative/imperative/subjunctive/optative/participle/infinitive
    let degree: String?         // Greek `degree`: comparative/superlative
    let grType: String?         // Greek `type`: pronoun/article subtype (demonstrative/personal/relative/…)
    let stem: String?           // Hebrew `stem` (binyan): qal/niphal/piel/pual/hiphil/hophal/hithpael/peal/…
    let morphType: String?      // Hebrew `type` (renamed from verb_type — not verb-only): qatal/wayyiqtol/common/…
    let state: String?          // Hebrew `state`: absolute/construct/determined
    let pos: String?            // Hebrew `pos` (finer than lexicalClass, e.g. pron→suffix): noun/verb/suffix/…
    let lang: String?           // Hebrew `lang`: H=Hebrew, A=Aramaic — NOT the `language` (hbo/grc) distinction above

    init(id: String, text: String, strongsId: String? = nil,
         morphology: String? = nil, gloss: String? = nil,
         xlitSimple: String? = nil, xlit: String? = nil,
         syntaxRole: String? = nil, greek: String? = nil, greekStrong: String? = nil,
         afterChar: String? = nil, lexicalClass: String? = nil,
         slot: Int? = nil, xlitSlot: String? = nil,
         person: String? = nil, gender: String? = nil, number: String? = nil,
         grCase: String? = nil, tense: String? = nil, voice: String? = nil,
         mood: String? = nil, degree: String? = nil, grType: String? = nil,
         stem: String? = nil, morphType: String? = nil, state: String? = nil,
         pos: String? = nil, lang: String? = nil) {
        self.id = id; self.text = text; self.strongsId = strongsId
        self.morphology = morphology; self.gloss = gloss
        self.xlitSimple = xlitSimple; self.xlit = xlit
        self.syntaxRole = syntaxRole; self.greek = greek; self.greekStrong = greekStrong
        self.afterChar = afterChar; self.lexicalClass = lexicalClass
        self.slot = slot; self.xlitSlot = xlitSlot
        self.person = person; self.gender = gender; self.number = number
        self.grCase = grCase; self.tense = tense; self.voice = voice
        self.mood = mood; self.degree = degree; self.grType = grType
        self.stem = stem; self.morphType = morphType; self.state = state
        self.pos = pos; self.lang = lang
    }

    /// Best transliteration for display (Hebrew-aware):
    /// BibleHub combined slot translit → Macula occurrence xlit → TBESH lemma xlit
    var bestXlit: String? { xlitSlot ?? xlit ?? xlitSimple }

    /// Surface form as it appears in the text, including any trailing connector.
    /// Use this for display in Original tab; use `text` for Strong's lookup and search.
    var displayText: String { text + (afterChar ?? "") }
}

// MARK: - Slot merging (bug-054)

extension BibleWord {
    /// Words grouped by shared Macula `slot` -> one composed word per Hebrew slot, e.g.
    /// the article + the noun -> one merged word with joined morphology ("Td.Ncbsa") and
    /// joined gloss ("the light"). Greek verses (no `slot` on any token) pass through
    /// unchanged.
    ///
    /// bug-054: this merge used to live ONLY inside `OriginalWordsView.displayWords` (a
    /// SwiftUI View in VerseTabContent.swift), so every OTHER consumer of "the current
    /// word" -- long-press in the verse text, chevron word navigation, auto-select-first-
    /// word -- read raw un-merged Macula tokens straight from `verse.words` and silently
    /// regressed to single-morpheme display for compound slots: no "composition" row, and
    /// the surface form itself missing its proclitic/enclitic. Moved here as the single
    /// source of truth so every entry path into Word/Meaning shares it -- see
    /// `ReaderViewModel.tapWord(_ segment:)`, `wordNavSequence`, `autoSelectFirstWordIfNeeded`.
    static func slotMerged(_ words: [BibleWord]) -> [BibleWord] {
        slotGroups(words).map(mergeSlotGroup)
    }

    /// Maps every raw token's `id` to the composed word its slot merges into (itself, for a
    /// single-token slot or a Greek verse). Use this to "upgrade" one specific raw token --
    /// e.g. one already matched to a translation segment by Strong's number -- to the full
    /// composed slot it belongs to, without re-deriving which slot that is.
    static func slotMergedLookup(_ words: [BibleWord]) -> [String: BibleWord] {
        var lookup: [String: BibleWord] = [:]
        for group in slotGroups(words) {
            let merged = mergeSlotGroup(group)
            for token in group { lookup[token.id] = merged }
        }
        return lookup
    }

    /// Groups consecutive tokens sharing the same Macula `slot` value into one array per
    /// slot. A token with no slot stands alone (safety fallback). A verse whose FIRST token
    /// has no slot (Greek -- `slot` is Hebrew-only) is assumed to have none anywhere, and
    /// returns one singleton group per token unchanged -- same assumption `displayWords`
    /// made before this was moved here.
    private static func slotGroups(_ words: [BibleWord]) -> [[BibleWord]] {
        guard !words.isEmpty, words.first?.slot != nil else { return words.map { [$0] } }

        var groups: [[BibleWord]] = []
        var current: [BibleWord] = []
        var currentSlot: Int? = nil

        for word in words {
            guard let s = word.slot else {
                if !current.isEmpty { groups.append(current); current = [] }
                groups.append([word])
                currentSlot = nil
                continue
            }
            if s != currentSlot {
                if !current.isEmpty { groups.append(current) }
                current = [word]
                currentSlot = s
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // NOTE: a `helperStrongs` allow-list used to live here and was used to pick each slot's
    // root token as "the first token whose Strong's is not in the list". It has been removed,
    // not extended, and it should not come back. Derived from Psalm 1, it was missing the
    // preposition (H3807a) and (H4480) -- so for ~21K words the leading PREPOSITION was
    // selected as the head, and every such word opened the lexicon on the preposition
    // instead of the noun (8.5% of all Hebrew words; e.g. Gen 1:5 reported H3807a
    // "Preposition" not H216 "light"). It also mislabeled H1930a as the preposition, which
    // it is not. Head selection is now derived from morphology -- see `headToken(of:)`.
    // Keep it that way.

    /// The head (root) token of a slot -- the word the reader is actually tapping.
    ///
    /// Hebrew builds a slot as `[proclitics...] HEAD [enclitics...]`: inseparable
    /// prepositions, the article and the waw attach to the FRONT, pronominal suffixes to
    /// the BACK. So the head is the last token that is not an enclitic.
    ///
    /// Enclitic = pronominal suffix (Macula `morph` begins with `S`, e.g. `Sp3ms`) or an
    /// enclitic particle (`class == "x"`). This is why we key on morphology rather than on a
    /// Strong's allow-list: `pron` alone is ambiguous -- `Sp3ms` is a suffix and never a
    /// head, while `Pp3ms` (independent pronoun) IS the head. `class` alone is ambiguous
    /// too -- a proclitic preposition and a standalone preposition are both `prep` with
    /// `morph == "R"`.
    ///
    /// Validated against BSB's independent Strong's assignment over 274,474 slots:
    /// first-non-helper (old) 9.20% wrong -> this rule 1.75%, of which 0.81% are
    /// single-token slots where Macula and BSB simply disagree lexically. True alignment
    /// error: 0.94%. See ADR-020.
    private static func headToken(of tokens: [BibleWord]) -> BibleWord {
        tokens.last(where: { !isEnclitic($0) }) ?? tokens[tokens.count - 1]
    }

    private static func isEnclitic(_ word: BibleWord) -> Bool {
        if word.lexicalClass == "x" { return true }               // enclitic particle
        return word.morphology?.hasPrefix("S") ?? false           // pronominal suffix
    }

    /// Merge one slot's tokens into a single representative BibleWord.
    private static func mergeSlotGroup(_ tokens: [BibleWord]) -> BibleWord {
        guard tokens.count > 1 else { return tokens[0] }
        // Head = last non-enclitic token (carries Strong's, xlit, tap target).
        // NOT "first non-helper" -- that picked the leading preposition. See headToken(of:).
        let root = headToken(of: tokens)
        // Combined surface: concatenate each token's displayText (already includes afterChar)
        let surface    = tokens.map(\.displayText).joined()
        let gloss      = tokens.compactMap(\.gloss).filter { !$0.isEmpty }.joined(separator: " ")
        let morphology = tokens.compactMap(\.morphology).filter { !$0.isEmpty }.joined(separator: "\u{00B7}")
        return BibleWord(
            id: root.id,
            text: surface,
            strongsId: root.strongsId,
            morphology: morphology.isEmpty ? nil : morphology,
            gloss: gloss.isEmpty ? nil : gloss,
            xlitSimple: root.xlitSimple,
            xlit: root.xlit,
            syntaxRole: root.syntaxRole,
            greek: root.greek,
            greekStrong: root.greekStrong,
            afterChar: nil,          // already baked into `surface` via displayText join
            lexicalClass: root.lexicalClass,
            slot: root.slot,
            // NB: xlit_slot is a SLOT-level value (the combined translit of the whole
            // word), so any token in the slot that carries it carries the same string.
            // build_db.py writes it to EVERY non-helper token of the slot and skips helper
            // morphemes, so those keep their own short xlit. compactMap therefore drops
            // the helper nils and .first lands on a real value.
            xlitSlot: tokens.compactMap(\.xlitSlot).first,
            // ADR-040: taken from `root` (the head token), never re-derived from the
            // joined `morphology` string above -- these come straight from the head
            // token's own DB row, so composite Hebrew slots get correct values instead of
            // being unparseable.
            person: root.person, gender: root.gender, number: root.number,
            grCase: root.grCase, tense: root.tense, voice: root.voice,
            mood: root.mood, degree: root.degree, grType: root.grType,
            stem: root.stem, morphType: root.morphType, state: root.state,
            pos: root.pos, lang: root.lang
        )
    }
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
