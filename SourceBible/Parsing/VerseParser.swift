// VerseParser.swift
// SourceBible
//
// Pipeline: Raw MyBible text → [Token] → ParsedVerse
//
// Теги що обробляються:
//   <t>  / </t>   — обгортка тексту (ігноруємо, парсимо вміст)
//   <J>  / </J>   — слова Ісуса (червоний колір)
//   <i>  / </i>   — курсив (додані перекладачем слова)
//   <e>  / </e>   — emphasis / цитата зі Старого Заповіту
//   <S>N</S>       — Strong's номер, прив'язується до ПОПЕРЕДНЬОГО сегмента
//   <n>…</n>       — текст виноски перекладача
//   <f>…</f>       — маркер позиції виноски в тексті
//   <br/>          — перенос рядка (поезія)
//   <pb/>          — початок абзацу (paragraph break)
//   ???            — невідомі теги — ігноруємо тег, зберігаємо вміст (fault-tolerant)

import Foundation

// MARK: - Token

private enum Token {
    case text(String)
    case open(tag: String)
    case close(tag: String)
    case selfClose(tag: String)
}

// MARK: - Tokenizer

private struct Tokenizer {
    private let input: String
    private var index: String.Index

    init(_ input: String) {
        self.input = input
        self.index = input.startIndex
    }

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        var buf = ""

        while index < input.endIndex {
            if input[index] == "<" {
                if !buf.isEmpty { tokens.append(.text(buf)); buf = "" }
                tokens.append(scanTag())
            } else {
                buf.append(input[index])
                input.formIndex(after: &index)
            }
        }
        if !buf.isEmpty { tokens.append(.text(buf)) }
        return tokens
    }

    private mutating func scanTag() -> Token {
        input.formIndex(after: &index)          // skip '<'
        var content = ""
        while index < input.endIndex && input[index] != ">" {
            content.append(input[index])
            input.formIndex(after: &index)
        }
        if index < input.endIndex { input.formIndex(after: &index) }   // skip '>'

        let raw = content.trimmingCharacters(in: .whitespaces)

        if raw.hasPrefix("/") {
            return .close(tag: String(raw.dropFirst()).lowercased())
        }
        // Self-closing: explicit /> or known self-closing tags
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        if raw.hasSuffix("/") || name == "br" || name == "pb" {
            return .selfClose(tag: name)
        }
        return .open(tag: name)
    }
}

// MARK: - VerseParser

struct VerseParser {

    // MARK: Public API

    static func parse(verseId: String, rawText: String) -> ParsedVerse {
        var p = VerseParser(verseId: verseId)
        var tokenizer = Tokenizer(rawText)
        let tokens = tokenizer.tokenize()
        p.process(tokens)
        return p.result()
    }

    /// Швидкий утиліт для стрипінгу тегів без повного парсингу (напр. для паралельних перекладів)
    static func stripTags(_ raw: String) -> String {
        parse(verseId: "", rawText: raw).plainText
    }

    // MARK: State

    private let verseId: String
    private var segments: [VerseSegment] = []
    private var footnotes: [ParsedFootnote] = []

    // Style stack — підтримує вкладення (напр. <J><i>text</i></J>)
    private var styleStack: [String] = []

    // Буфери для збору вмісту тегів
    private var strongsBuffer  = ""
    private var footnoteBuffer = ""
    private var anchorBuffer   = ""

    // Стани
    private var insideS = false
    private var insideN = false
    private var insideF = false

    private var pendingAnchorId: String? = nil
    private var footnoteCounter = 0

    // Відстеження позиції в plainText
    private var plainTextOffset = 0

    // MARK: Processing

    private mutating func process(_ tokens: [Token]) {
        for token in tokens {
            switch token {
            case .text(let s):      handleText(s)
            case .open(let tag):    handleOpen(tag)
            case .close(let tag):   handleClose(tag)
            case .selfClose(let t): handleSelfClose(t)
            }
        }
    }

    private mutating func handleText(_ raw: String) {
        // Truly empty (zero-length) strings are ignored; whitespace-only strings are NOT.
        // Dropping whitespace-only text nodes was the source of missing spaces between
        // tagged words, e.g. RST "сказал<S>3004</S> <i>Бог</i>" → "сказалБог".
        // The space between </S> and <i> is a whitespace-only text node that must be
        // preserved as a segment so the rendered text reads "сказал Бог".
        guard !raw.isEmpty else { return }

        if insideS { strongsBuffer  += raw; return }
        if insideN { footnoteBuffer += raw; return }
        if insideF { anchorBuffer   += raw; return }

        let seg = VerseSegment(
            text: raw,
            styles: currentStyles,
            characterOffset: plainTextOffset
        )
        plainTextOffset += raw.utf16.count
        segments.append(seg)
    }

    private mutating func handleOpen(_ tag: String) {
        switch tag {
        case "t":                   break   // текстова обгортка — просто входимо
        case "j", "i", "e":        styleStack.append(tag)
        case "s":                   insideS = true; strongsBuffer = ""
        case "n":                   insideN = true; footnoteBuffer = ""
        case "f":                   insideF = true; anchorBuffer = ""
        default:                    break   // невідомий тег — fault-tolerant, пропускаємо
        }
    }

    private mutating func handleClose(_ tag: String) {
        switch tag {
        case "t":
            break

        case "j", "i", "e":
            // Прибираємо останнє входження зі стеку (fault-tolerant для неправильного порядку)
            if let idx = styleStack.lastIndex(of: tag) { styleStack.remove(at: idx) }

        case "s":
            insideS = false
            let ids = parseStrongsIds(strongsBuffer)
            // Прив'язуємо Strong's до ПОПЕРЕДНЬОГО текстового сегмента
            if !ids.isEmpty, let lastIdx = lastTextSegmentIndex() {
                attachStrongs(ids, toSegmentAt: lastIdx)
            }
            strongsBuffer = ""

        case "n":
            insideN = false
            let anchorId = pendingAnchorId ?? "auto_\(footnoteCounter)"
            footnoteCounter += 1
            pendingAnchorId = nil
            footnotes.append(ParsedFootnote(
                id: anchorId,
                rawText: footnoteBuffer,
                kind: classifyFootnote(footnoteBuffer)
            ))
            footnoteBuffer = ""

        case "f":
            insideF = false
            let anchorId = anchorBuffer.trimmingCharacters(in: .whitespaces)
            pendingAnchorId = anchorId
            // Вставляємо невидимий сегмент-маркер у позицію тексту
            segments.append(VerseSegment(
                text: "",
                styles: currentStyles,
                footnoteAnchorId: anchorId,
                characterOffset: plainTextOffset
            ))
            anchorBuffer = ""

        default:
            break
        }
    }

    private mutating func handleSelfClose(_ tag: String) {
        switch tag {
        case "br":
            segments.append(VerseSegment(text: "\n", isLineBreak: true))
        case "pb":
            segments.append(VerseSegment(text: "", isParagraphBreak: true))
        default:
            break
        }
    }

    // MARK: Helpers

    private var currentStyles: SegmentStyle {
        var s = SegmentStyle.plain
        for tag in styleStack {
            switch tag {
            case "j": s.insert(.jesusWords)
            case "i": s.insert(.italic)
            case "e": s.insert(.emphasis)
            default: break
            }
        }
        return s
    }

    /// Індекс останнього сегмента з непорожнім *значущим* текстом (для прив'язки Strong's).
    /// Пропускає whitespace-only сегменти (міжтегові пробіли), щоб Strong's прив'язувався
    /// до реального слова, а не до пробілу між тегами.
    /// Роздільники, які НЕ належать слову, навіть якщо лексер приліпив їх до
    /// його текстового вузла.
    ///
    /// Набір явний, а не `.punctuationCharacters`: у той клас входять апостроф і
    /// дефіс, а вони бувають частиною самого слова («'tis», «Beth-el»), і зрізати
    /// їх означало б відкусити початок слова замість сміття перед ним.
    private static let leadingSeparators = CharacterSet(charactersIn: ",.;:!?…—–()[]\"“”«»")
        .union(.whitespacesAndNewlines)

    /// Прив'язує Strong's до попереднього текстового сегмента, ВІДРІЗАВШИ провідні
    /// роздільники в окремий, НЕ позначений сегмент.
    ///
    /// Навіщо. Розмітка KJV прив'язує номер до текстового вузла між тегами, а вузол
    /// починається там, де скінчився попередній `</S>`. Для складеного івритського
    /// слова (וְהַנָּבִיא = «and the prophet») вузол виходить `", and the prophet"` —
    /// разом із комою, що відділяє його від попередньої фрази. Далі ця кома
    /// підсвічувалась у вірші й потрапляла в заголовок шіта: «, and the prophet».
    ///
    /// Кома належить реченню, а не слову, тож у підсвітку їй не місце.
    ///
    /// Сегмент не «чиститься», а РОЗБИВАЄТЬСЯ: роздільники лишаються окремим
    /// сегментом без Strong's. Текст вірша від цього не змінюється ні на символ —
    /// змінюється лише те, що саме підсвічується.
    private mutating func attachStrongs(_ ids: [String], toSegmentAt index: Int) {
        let segment = segments[index]
        let scalars = Array(segment.text.unicodeScalars)
        var leadCount = scalars.prefix { Self.leadingSeparators.contains($0) }.count
        // ASV `man<S>5100</S>'s brother<S>80</S>`: присвійне «'s» належить ПОПЕРЕДНЬОМУ
        // слову, а лексер приліпив його до вузла «brother» — підсвічувалось «'s brother».
        // Відрізаємо разом із роздільниками (тест паритету — scripts/tests).
        if scalars.count > leadCount + 2,
           scalars[leadCount] == "'" || scalars[leadCount] == "\u{2019}",
           scalars[leadCount + 1] == "s" || scalars[leadCount + 1] == "S",
           Self.leadingSeparators.contains(scalars[leadCount + 2]) {
            leadCount += 2
            leadCount += scalars.dropFirst(leadCount).prefix { Self.leadingSeparators.contains($0) }.count
        }
        let leadText = String(String.UnicodeScalarView(scalars.prefix(leadCount)))

        // Нема чого відрізати, або сегмент — суцільні роздільники (тоді відрізання
        // лишило б Strong's без тексту взагалі).
        //
        // bug-055: ДОДАВАТИ, а не присвоювати. Одне слово перекладу буває відповідником
        // КІЛЬКОХ слів оригіналу, і переклад ставить теги підряд на той самий вузол:
        // KJV «longsuffering<S>750</S> <S>639</S>» (אֶרֶךְ אַפַּיִם), RST НЗ
        // «Бог<S>2316</S><S>3588</S>» (ὁ θεός — артикль, якого в російській немає).
        // Присвоєння лишало тільки ОСТАННІЙ номер: «Бог»/«возлюбил» відкривали артикль ὁ,
        // а θεός/ἀγαπάω не мали пари в «Оригіналі» (RST: 23 317 таких місць, KJV: 4 031).
        // Порядок зберігається — перший номер лишається першим, тож `tapWord`
        // (перша пара сегмента) відкриває головне слово, а не артикль.
        guard !leadText.isEmpty, leadText.count < segment.text.count else {
            segments[index].strongs += ids
            return
        }

        let wordText = String(segment.text.dropFirst(leadText.count))
        segments[index] = VerseSegment(
            text: leadText,
            styles: segment.styles,
            characterOffset: segment.characterOffset
        )
        segments.insert(
            VerseSegment(
                text: wordText,
                styles: segment.styles,
                strongs: ids,
                characterOffset: segment.characterOffset + leadText.utf16.count
            ),
            at: index + 1
        )
    }

    private func lastTextSegmentIndex() -> Int? {
        segments.indices.reversed().first { !segments[$0].isLineBreak
                                         && !segments[$0].isParagraphBreak
                                         && !segments[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "835" → ["H835"]   "8384, 5929" → ["H8384","H5929"]   "G976" → ["G976"]
    private func parseStrongsIds(_ raw: String) -> [String] {
        raw.split(separator: ",")
           .compactMap { part -> String? in
               let s = part.trimmingCharacters(in: .whitespaces)
               guard !s.isEmpty else { return nil }
               // Вже є префікс H/G
               if s.first?.isLetter == true { return s.uppercased() }
               // Тільки число — додаємо префікс за заміщенням (буде уточнено у Renderer)
               return "S\(s)"  // S = невизначено; Renderer додасть H/G за testament
           }
    }

    // MARK: Footnote classification

    private func classifyFootnote(_ raw: String) -> FootnoteKind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // "word: or, alt1, alt2"
        if let range = trimmed.range(of: ": or,") {
            let word = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let alts = String(trimmed[range.upperBound...])
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .alternateTranslation(word: word, alternatives: alts)
        }
        // "word: Heb. original" / "word: Gr. original"
        if trimmed.contains("Heb.") || trimmed.contains("Gr.") {
            let parts = trimmed.components(separatedBy: ": ")
            if parts.count >= 2 {
                let word     = parts[0].trimmingCharacters(in: .whitespaces)
                let original = parts[1]
                    .replacingOccurrences(of: "Heb. ", with: "")
                    .replacingOccurrences(of: "Gr. ",  with: "")
                    .trimmingCharacters(in: .whitespaces)
                return .hebrewGreekNote(word: word, original: original)
            }
        }
        // Довга кінцева нотатка книги (> 100 символів)
        if trimmed.count > 100 { return .postscript(trimmed) }

        return .translatorNote(trimmed)
    }

    private func result() -> ParsedVerse {
        ParsedVerse(verseId: verseId,
                    segments: Self.droppingSpaceBeforePunctuation(segments),
                    footnotes: footnotes)
    }

    /// bug-056: KJV «God-ward<S>4136</S> <S>430</S>, that» — пробіл між двома тегами
    /// лишається окремим сегментом, і читанка показувала «God-ward , that» (1 073 вірші
    /// KJV) або подвійний пробіл «which  thou» (2 605 віршів KJV, 3 ASV). Сегмент із
    /// самих пробілів прибираємо, якщо він ЗАЙВИЙ: наступний видимий текст починається
    /// з розділового знака чи пробілу, або попередній уже закінчується пробілом.
    /// Єдиний пробіл між словами лишається (RST «сказал<S>3004</S> <i>Бог</i>» — див. handleText).
    /// Сегменти з Strong's не зачіпаються, тож `seg_ord` (ADR-041) не зсувається.
    /// Порт: `scripts/build_word_rendering.py` → `drop_space_before_punct`.
    static func droppingSpaceBeforePunctuation(_ segs: [VerseSegment]) -> [VerseSegment] {
        var out: [VerseSegment] = []
        out.reserveCapacity(segs.count)
        for (i, seg) in segs.enumerated() {
            let blank = seg.strongs.isEmpty && seg.footnoteAnchorId == nil
                && !seg.isLineBreak && !seg.isParagraphBreak
                && !seg.text.isEmpty && seg.text.allSatisfy { $0 == " " }
            if blank {
                let nextFirst = segs[(i + 1)...].first(where: { !$0.text.isEmpty })?.text.first
                let prevLast  = out.last(where: { !$0.text.isEmpty })?.text.last
                if let ch = nextFirst, ",.;:!?) ".contains(ch) { continue }
                if prevLast == " " { continue }
            }
            out.append(seg)
        }
        return out
    }

    private init(verseId: String) { self.verseId = verseId }
}
