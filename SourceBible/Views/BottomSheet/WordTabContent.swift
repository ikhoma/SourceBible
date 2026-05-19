// WordTabContent.swift
// SourceBible
//
// Вміст вкладки "Слово" у VerseBottomSheetView.
// Типи: WordTabView · WordSubTab · WordMeaningView · WordUsageView ·
//       WordCard · MorphologyDecoder
// Helpers: highlightedVerseText(_:fallback:strongsId:) · stripKJVSegment(_:)

import SwiftUI

// MARK: - Word Tab

struct WordTabView: View {

    let subTab: WordSubTab
    @EnvironmentObject var vm: ReaderViewModel

    var body: some View {
        Group {
            if vm.isLoadingStrongs {
                HStack { Spacer(); ProgressView().padding(.top, 40); Spacer() }
            } else if let entry = vm.strongsEntry {
                if subTab == .meaning {
                    WordMeaningView(entry: entry)
                } else {
                    WordUsageView(entry: entry)
                }
            } else {
                Text(vm.selectedWord != nil || vm.selectedSegment != nil
                     ? "Дані мови недоступні для цього слова"
                     : "Натисніть на слово для вивчення")
                    .font(.callout).foregroundStyle(.secondary).padding(20)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
    }
}

// MARK: - Word Sub Tab

enum WordSubTab: CaseIterable {
    case meaning, usage
    var label: String { self == .meaning ? "Значення" : "Вживання" }
}

// MARK: - Lexicon Parser

struct LexiconSection: Identifiable {
    let id = UUID()
    let stemName: String      // "Qal", "Piel", etc. (empty = flat / no stems)
    let definitions: [String]
}

enum LexiconParser {

    /// Strips inline markup from a definition string, keeping readable content.
    /// Handles: <ref="...">text</ref> → text, <i>text</i> → text, <BR> → space,
    /// and any other stray tags.
    private static func cleanDef(_ s: String) -> String {
        var r = s
        // <ref="...">visible text</ref> → visible text
        r = r.replacingOccurrences(of: #"<ref[^>]*>(.*?)</ref>"#,
                                   with: "$1", options: .regularExpression)
        // <i>text</i> → text
        r = r.replacingOccurrences(of: #"</?i>"#,
                                   with: "", options: .regularExpression)
        // <BR> (uppercase variant)
        r = r.replacingOccurrences(of: #"<BR\s*/?>"#,
                                   with: " ", options: [.regularExpression, .caseInsensitive])
        // any remaining unknown tags
        r = r.replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "", options: .regularExpression)
        // collapse extra spaces
        r = r.replacingOccurrences(of: #" {2,}"#,
                                   with: " ", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ raw: String) -> [LexiconSection] {
        guard !raw.isEmpty else { return [] }

        let lines = raw
            .components(separatedBy: "<br>")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(":") }

        // Patterns
        let stemRE = try? NSRegularExpression(pattern: #"^\d+[a-z]\)\s+\(([^)]+)\)"#)
        let subRE  = try? NSRegularExpression(pattern: #"^\d+[a-z]\d+\)\s+(.+)"#)
        let topRE  = try? NSRegularExpression(pattern: #"^\d+\)\s+(.+)"#)

        func extract(_ re: NSRegularExpression?, group: Int, from s: String) -> String? {
            let r = NSRange(s.startIndex..., in: s)
            guard let m = re?.firstMatch(in: s, range: r),
                  let gr = Range(m.range(at: group), in: s) else { return nil }
            return String(s[gr])
        }

        var sections: [LexiconSection] = []
        var currentStem = ""
        var currentDefs: [String] = []
        var hasStems = false

        for line in lines {
            if let name = extract(stemRE, group: 1, from: line) {
                if !currentDefs.isEmpty {
                    sections.append(LexiconSection(stemName: currentStem, definitions: currentDefs))
                }
                currentStem = name; currentDefs = []; hasStems = true
            } else if let def = extract(subRE, group: 1, from: line) {
                currentDefs.append(cleanDef(def))
            } else if !hasStems, let def = extract(topRE, group: 1, from: line) {
                currentDefs.append(cleanDef(def))
            }
        }
        if !currentDefs.isEmpty {
            sections.append(LexiconSection(stemName: currentStem, definitions: currentDefs))
        }
        return sections
    }
}

// MARK: - Word Meaning

struct WordMeaningView: View {
    let entry: StrongsEntry
    @EnvironmentObject var vm: ReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            if let word = vm.selectedWord {
                contextSection(word)
                if let morph = word.morphology {
                    morphologySection(word: word, morph: morph)
                }
            }
            lexicalSection
            if let word = vm.selectedWord,
               let greek = word.greek, !greek.isEmpty {
                greekSection(word)
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.originalWord)
                        .font(.system(size: 30, weight: .light))
                    // Priority: (1) Macula contextual xlit (always correct for this word form),
                    // (2) TBESH lemma xlitSimple, (3) academic transliteration as last resort.
                    let xlit: String = {
                        if let ctxXlit = vm.selectedWord?.xlit, !ctxXlit.isEmpty { return ctxXlit }
                        if !entry.xlitSimple.isEmpty { return entry.xlitSimple }
                        return entry.transliteration
                    }()
                    if !xlit.isEmpty {
                        Text(xlit)
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.shortDefinition.isEmpty {
                    Text(entry.shortDefinition)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(entry.id)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(UIColor.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 16)
    }

    // MARK: Form in context

    private func contextSection(_ word: BibleWord) -> some View {
        let parts = word.id.split(separator: "|")
        let ch    = parts.count > 1 ? String(parts[1]) : ""
        let v     = parts.count > 2 ? String(parts[2]) : ""
        let ref   = "\(vm.currentBook.nameShort) \(ch):\(v)"

        var rows: [(String, String, Bool)] = [("Слово", word.text, true)]
        if let xlit = word.xlit, !xlit.isEmpty {
            rows.append(("Транслітерація", xlit, false))
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Форма у \(ref)")
            InfoGroup(rows: rows)
        }
    }

    // MARK: Morphology

    private func morphologyRows(word: BibleWord, decoded: FullMorphology) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = []
        if !decoded.partOfSpeech.isEmpty    { rows.append(("Частина мови",      decoded.partOfSpeech,    false)) }
        if !decoded.stem.isEmpty            { rows.append(("Основа (Біньян)",   decoded.stem,            false)) }
        if !decoded.aspect.isEmpty          { rows.append(("Час / Вид",         decoded.aspect,          false)) }
        if !decoded.grammaticalForm.isEmpty { rows.append(("Граматична форма",  decoded.grammaticalForm, false)) }
        if let role = word.syntaxRole, let label = syntaxRoleLabel(role) {
            rows.append(("Синтаксична роль", label, false))
        }
        return rows
    }

    @ViewBuilder
    private func morphologySection(word: BibleWord, morph: String) -> some View {
        if let decoded = MorphologyDecoder.decodeFull(morph) {
            let rows = morphologyRows(word: word, decoded: decoded)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Морфологія")
                    InfoGroup(rows: rows)
                }
            }
        }
    }

    // MARK: Lexical meaning

    @ViewBuilder
    private var lexicalSection: some View {
        let sections = LexiconParser.parse(entry.fullDefinition)
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Лексичне значення")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sections) { sec in
                        VStack(alignment: .leading, spacing: 0) {
                            if !sec.stemName.isEmpty {
                                Text(sec.stemName)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .clipShape(Capsule())
                                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(sec.definitions.enumerated()), id: \.offset) { i, def in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(i + 1).")
                                            .font(.callout).foregroundStyle(.tertiary)
                                            .frame(width: 22, alignment: .trailing)
                                        Text(def)
                                            .font(.callout)
                                            .lineSpacing(3)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    if i < sec.definitions.count - 1 {
                                        Divider().padding(.leading, 44)
                                    }
                                }
                            }
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    // MARK: Greek equivalent

    private func greekSection(_ word: BibleWord) -> some View {
        var rows: [(String, String, Bool)] = []
        if let g = word.greek, !g.isEmpty     { rows.append(("Слово", g, false)) }
        if let gs = word.greekStrong, !gs.isEmpty { rows.append(("Strong's", gs, false)) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Грецький еквівалент (LXX)")
            InfoGroup(rows: rows)
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .kerning(0.4)
            .padding(.top, 20).padding(.bottom, 8).padding(.horizontal, 2)
    }

    private func syntaxRoleLabel(_ role: String) -> String? {
        switch role {
        case "v":   return "Присудок"
        case "p":   return "Присудок (іменний)"
        case "s":   return "Підмет"
        case "o":   return "Додаток"
        case "c":   return "Обставина"
        case "adv": return "Прислівник"
        default:    return nil
        }
    }
}

// MARK: - Info Group (iOS-style grouped rows)

private struct InfoGroup: View {
    /// (label, value, isValueHebrew)
    let rows: [(String, String, Bool)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.callout).fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(row.1)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .environment(\.layoutDirection, row.2 ? .rightToLeft : .leftToRight)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                if i < rows.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Word Usage

struct WordUsageView: View {
    let entry: StrongsEntry
    var body: some View {
        PillSection(title: "\(entry.concordance.count) входжень у Біблії") {
            ForEach(entry.concordance) { ref in
                VStack(alignment: .leading, spacing: 6) {
                    Text(ref.reference).font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
                    Text(highlightedVerseText(raw: ref.rawText, fallback: ref.text, strongsId: entry.id))
                        .font(.callout).lineSpacing(3)
                }
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture {}
                Divider()
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - KJV Keyword Highlighting

/// Builds an AttributedString from a raw KJV verse (with `<S>N</S>` markup), highlighting
/// every text segment whose Strong's tag matches the numeric base of `strongsId`.
/// Falls back to plain `fallback` text when `raw` is empty (sample/preview data).
private func highlightedVerseText(raw: String, fallback: String, strongsId: String) -> AttributedString {
    guard !raw.isEmpty else { return AttributedString(fallback) }

    let numChars = strongsId.drop(while: { !$0.isNumber })
    let baseNum  = String(numChars.prefix(while: { $0.isNumber }))
    guard !baseNum.isEmpty else { return AttributedString(fallback) }

    guard let tagPattern = try? NSRegularExpression(pattern: #"<S>(\d+[a-z]?)</S>"#) else {
        return AttributedString(fallback)
    }
    let matches = tagPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))

    var result = AttributedString()
    var cursor = raw.startIndex

    for match in matches {
        guard let tagRange = Range(match.range,      in: raw),
              let numRange = Range(match.range(at: 1), in: raw) else { continue }

        let segRaw   = String(raw[cursor..<tagRange.lowerBound])
        let segClean = stripKJVSegment(segRaw)
        let numBase  = String(raw[numRange].prefix(while: { $0.isNumber }))

        if numBase == baseNum, !segClean.trimmingCharacters(in: .whitespaces).isEmpty {
            var attr = AttributedString(segClean)
            attr.backgroundColor = Color.blue.opacity(0.06)
            result += attr
        } else {
            result += AttributedString(segClean)
        }
        cursor = tagRange.upperBound
    }

    if cursor < raw.endIndex {
        result += AttributedString(stripKJVSegment(String(raw[cursor...])))
    }

    return result
}

/// Strips all non-Strong's markup from a KJV text segment.
private func stripKJVSegment(_ s: String) -> String {
    var r = s
    r = r.replacingOccurrences(of: #"<n>(.*?)</n>"#,      with: "($1)", options: .regularExpression)
    r = r.replacingOccurrences(of: #"<(br|pb)\s*/>"#,     with: " ",    options: [.regularExpression, .caseInsensitive])
    r = r.replacingOccurrences(of: #"<[^>]+>"#,           with: "",     options: .regularExpression)
    r = r.replacingOccurrences(of: #" {2,}"#,             with: " ",    options: .regularExpression)
    return r
}

// MARK: - Morphology Decoder

/// Decodes Macula Hebrew (OSHB) and Greek (SBLGNT) morphology codes into readable labels.
///
/// Hebrew codes in the DB have NO language prefix: "Ncmpa", "Vqp3ms", "Td", "R", "C"
/// Greek codes use dashes: "N-NSM", "V-PAI-3S", "CONJ", "ADV"
struct FullMorphology {
    var partOfSpeech: String = ""
    var stem: String = ""         // e.g. "Qal — basic active"
    var aspect: String = ""       // e.g. "Perfect (qatal)"
    var grammaticalForm: String = "" // e.g. "3rd masculine singular"
}

enum MorphologyDecoder {

    // MARK: Full decode (for WordMeaningView detail)

    static func decodeFull(_ code: String) -> FullMorphology? {
        guard !code.isEmpty else { return nil }
        let ch = Array(code)
        guard let first = ch.first else { return nil }
        var m = FullMorphology()

        switch first {
        case "V":
            m.partOfSpeech = "Дієслово"
            if ch.count > 1 { m.stem   = hebrewStem(ch[1]) }
            if ch.count > 2 { m.aspect = hebrewAspect(ch[2]) }
            if ch.count > 5 {
                let p = personLabel(ch[3])
                let g = genderLabel(ch[4])
                let n = numberLabel(ch[5])
                m.grammaticalForm = [p, g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "N":
            m.partOfSpeech = "Іменник"
            if ch.count > 4 {
                let g = genderLabel(ch[2])
                let n = numberLabel(ch[3])
                let s = stateLabel(ch[4])
                m.grammaticalForm = [g, n, s].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "A":
            m.partOfSpeech = "Прикметник"
            if ch.count > 4 {
                let g = genderLabel(ch[2])
                let n = numberLabel(ch[3])
                m.grammaticalForm = [g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "T":
            m.partOfSpeech = ch.count > 1 ? particleLabel(ch[1]) : "Частка"
        case "R": m.partOfSpeech = "Прийменник"
        case "C": m.partOfSpeech = "Сполучник"
        case "P": m.partOfSpeech = "Займенник"
        case "D": m.partOfSpeech = "Прислівник"
        case "I": m.partOfSpeech = "Вигук"
        case "S":
            // Pronominal suffix: Sp<person><gender><number>  e.g. Sp3fs, Sp2ms
            m.partOfSpeech = ch.count > 1 ? suffixLabel(ch[1]) : "Займенниковий суфікс"
            if ch.count > 4 {
                let p = personLabel(ch[2])
                let g = genderLabel(ch[3])
                let n = numberLabel(ch[4])
                m.grammaticalForm = [p, g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        default:  return nil
        }
        return m
    }

    private static func suffixLabel(_ c: Character) -> String {
        switch c {
        case "p": return "Займенниковий суфікс"
        case "d": return "Прямий об'єкт суфікс"
        default:  return "Суфікс"
        }
    }

    private static func hebrewStem(_ c: Character) -> String {
        switch c {
        case "q": return "Qal — проста активна"
        case "N": return "Niphal — пасивна/рефлексивна"
        case "p": return "Piel — інтенсивна активна"
        case "P": return "Pual — інтенсивна пасивна"
        case "h": return "Hiphil — каузативна активна"
        case "H": return "Hophal — каузативна пасивна"
        case "t": return "Hithpael — рефлексивна"
        case "D": return "Poel"
        default:  return String(c)
        }
    }

    private static func hebrewAspect(_ c: Character) -> String {
        switch c {
        case "p": return "Досконалий (qatal)"
        case "i": return "Недосконалий (yiqtol)"
        case "w": return "Wayyiqtol (послідовний)"
        case "j": return "Юссив"
        case "c": return "Когортатив"
        case "v": return "Імператив"
        case "r": return "Дієприкметник (активний)"
        case "s": return "Дієприкметник (пасивний)"
        case "a": return "Інфінітив абсолютний"
        case "A": return "Інфінітив конструктус"
        default:  return ""
        }
    }

    private static func particleLabel(_ c: Character) -> String {
        switch c {
        case "d": return "Означений артикль"
        case "r": return "Відносний займенник"
        case "n": return "Заперечна частка"
        case "i": return "Питальна частка"
        default:  return "Частка"
        }
    }

    private static func personLabel(_ c: Character) -> String {
        switch c {
        case "1": return "1-а особа"
        case "2": return "2-а особа"
        case "3": return "3-я особа"
        default:  return ""
        }
    }

    private static func genderLabel(_ c: Character) -> String {
        switch c {
        case "m": return "чол. р."
        case "f": return "жін. р."
        case "c", "b": return "заг. р."
        default:  return ""
        }
    }

    private static func numberLabel(_ c: Character) -> String {
        switch c {
        case "s": return "одн."
        case "p": return "мн."
        case "d": return "двоїна"
        default:  return ""
        }
    }

    private static func stateLabel(_ c: Character) -> String {
        switch c {
        case "a": return "абсолютний"
        case "c": return "конструктус"
        case "d": return "визначений"
        default:  return ""
        }
    }

    static func decode(_ code: String) -> String? {
        guard !code.isEmpty else { return nil }
        return code.contains("-") ? decodeGreek(code) : decodeHebrew(code)
    }

    // MARK: Hebrew (OSHB, no language prefix)
    private static func decodeHebrew(_ code: String) -> String? {
        let chars = Array(code)
        guard let first = chars.first else { return nil }
        var parts: [String] = []

        switch first {
        case "N":
            parts.append("Noun")
            if chars.count > 3 {
                switch chars[3] {
                case "p": parts.append("pl.")
                case "d": parts.append("dual")
                default: break
                }
            }
        case "V":
            parts.append("Verb")
            if chars.count > 1 {
                switch chars[1] {
                case "q": parts.append("Qal")
                case "n": parts.append("Niphal")
                case "p": parts.append("Piel")
                case "u": parts.append("Pual")
                case "h": parts.append("Hiphil")
                case "o": parts.append("Hophal")
                case "t": parts.append("Hithp.")
                default: break
                }
            }
        case "A":
            parts.append("Adj.")
            if chars.count > 3 {
                switch chars[3] {
                case "p": parts.append("pl.")
                case "d": parts.append("dual")
                default: break
                }
            }
        case "T":
            if chars.count > 1 {
                switch chars[1] {
                case "d": parts.append("Article")
                case "r": parts.append("Rel. Pron.")
                case "n": parts.append("Neg.")
                case "i": parts.append("Interrog.")
                default:  parts.append("Particle")
                }
            } else {
                parts.append("Particle")
            }
        case "R": parts.append("Prep.")
        case "C": parts.append("Conj.")
        case "P": parts.append("Pron.")
        case "D": parts.append("Adv.")
        case "I": parts.append("Interj.")
        case "S": parts.append("Займ. суф.")
        default: return nil
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Greek (SBLGNT, dash-separated)
    private static func decodeGreek(_ code: String) -> String? {
        let segs = code.components(separatedBy: "-")
        guard let posStr = segs.first else { return nil }
        var parts: [String] = []

        switch posStr.uppercased() {
        case "N":    parts.append("Noun")
        case "V":    parts.append("Verb")
        case "A":    parts.append("Adj.")
        case "P":    parts.append("Prep.")
        case "ADV":  parts.append("Adv.")
        case "CONJ": parts.append("Conj.")
        case "PRON": parts.append("Pron.")
        case "ART":  parts.append("Article")
        case "PART": parts.append("Particle")
        case "INJ":  parts.append("Interj.")
        default:     return nil
        }

        if segs.count > 1 {
            let cng = Array(segs[1].uppercased())
            if cng.count > 1 {
                switch cng[1] {
                case "P": parts.append("pl.")
                default: break
                }
            }
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Word Card

/// Card displayed in OriginalWordsView for each word in a verse.
/// Only the Strong's badge on the right triggers onTap → switches to word mode.
struct WordCard: View {
    let word: BibleWord
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            VStack(alignment: .leading, spacing: 4) {
                Text(word.text)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.primary)

                // displayXlit: contextual (Macula) first, lexical (TBESH) fallback
                if let xlit = word.displayXlit, !xlit.isEmpty {
                    Text(xlit)
                        .font(.callout).foregroundStyle(.secondary)
                } else if let gloss = word.gloss, !gloss.isEmpty {
                    Text(gloss)
                        .font(.callout).foregroundStyle(.secondary)
                }

                if word.displayXlit?.isEmpty == false,
                   let gloss = word.gloss, !gloss.isEmpty {
                    Text(gloss)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let morph = word.morphology,
                   let label = MorphologyDecoder.decode(morph) {
                    Text(label)
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let sid = word.strongsId {
                VStack {
                    Button(action: onTap) {
                        Text(sid)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isSelected
                                        ? Color(UIColor.label)
                                        : Color(UIColor.secondarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
