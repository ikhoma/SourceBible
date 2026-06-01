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
                     ? LocalizedStringKey(MorphKey.emptyNoData)
                     : LocalizedStringKey(MorphKey.emptyTapHint))
                    .font(.callout).foregroundStyle(.secondary).padding(20)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
    }
}

// MARK: - Word Sub Tab

enum WordSubTab: CaseIterable {
    case meaning, usage
    // Return the raw localization key so SwiftUI resolves it through Bundle.main
    // (swizzled to LocalizedBundle), matching the VersePill.label pattern.
    // Do NOT pre-resolve with String(localized:) — that bypasses the swizzle.
    var label: LocalizedStringKey {
        self == .meaning
            ? LocalizedStringKey(MorphKey.tabMeaning)
            : LocalizedStringKey(MorphKey.tabUsage)
    }
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

        // Normalize separators: DB stores BDB content with either <br> or \n.
        // Replace <br> with \n first so we can split uniformly on \n.
        let normalized = raw.replacingOccurrences(of: "<br>", with: "\n",
                                                   options: .caseInsensitive)

        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Filter empties and the leading ": keyword" sense-label lines (STEPBible artefact —
            // these are short English glosses like ": man" or ": went/go[away]" that precede
            // the actual numbered BDB entries and don't add meaning for the user).
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

        // Fallback: if no numbered entries matched (e.g. short gloss like "counsel, advice, purpose"),
        // present the content as a single flat definition so something always renders.
        if sections.isEmpty {
            let flat = lines.joined(separator: "; ")
            let cleaned = cleanDef(flat)
            if !cleaned.isEmpty {
                sections.append(LexiconSection(stemName: "", definitions: [cleaned]))
            }
        }

        return sections
    }
}

// MARK: - Word Meaning

struct WordMeaningView: View {
    let entry: StrongsEntry
    @EnvironmentObject var vm: ReaderViewModel

    private let t: TranslationProvider = BundleTranslationProvider()

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
                    // Header shows the LEMMA form (entry.originalWord), so use the LEMMA xlit.
                    // Surface-form xlit (vm.selectedWord?.xlit) is shown in contextSection below.
                    let xlit: String = !entry.xlitSimple.isEmpty
                        ? entry.xlitSimple
                        : entry.transliteration
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
        let ref   = "\(BibleBookNames.short(for: vm.currentBook.id)) \(ch):\(v)"

        var rows: [(String, String, Bool)] = [(t.string(for: MorphKey.rowWord), word.text, true)]
        // Use displayXlit (xlit ?? xlitSimple): prefers Macula occurrence xlit when available,
        // falls back to TBESH lemma xlit so the row is never silently empty.
        if let xlit = word.displayXlit, !xlit.isEmpty {
            rows.append((t.string(for: MorphKey.rowTransliteration), xlit, false))
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel(t.string(for: MorphKey.sectionFormInContext, ref))
            InfoGroup(rows: rows)
        }
    }

    // MARK: Morphology

    private func morphologyRows(word: BibleWord, decoded: FullMorphology) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = []
        if !decoded.partOfSpeech.isEmpty    { rows.append((t.string(for: MorphKey.rowPartOfSpeech),    decoded.partOfSpeech,    false)) }
        if !decoded.stem.isEmpty            { rows.append((t.string(for: MorphKey.rowStem),            decoded.stem,            false)) }
        if !decoded.aspect.isEmpty          { rows.append((t.string(for: MorphKey.rowAspect),          decoded.aspect,          false)) }
        if !decoded.grammaticalForm.isEmpty { rows.append((t.string(for: MorphKey.rowGrammaticalForm), decoded.grammaticalForm, false)) }
        if let role = word.syntaxRole, let label = syntaxRoleLabel(role) {
            rows.append((t.string(for: MorphKey.rowSyntaxRole), label, false))
        }
        return rows
    }

    @ViewBuilder
    private func morphologySection(word: BibleWord, morph: String) -> some View {
        if let decoded = MorphologyDecoder.decodeFull(morph, using: t) {
            let rows = morphologyRows(word: word, decoded: decoded)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel(t.string(for: MorphKey.sectionMorphology))
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
                sectionLabel(t.string(for: MorphKey.sectionLexical))
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
        if let g = word.greek, !g.isEmpty      { rows.append((t.string(for: MorphKey.rowWord),    g,  false)) }
        if let gs = word.greekStrong, !gs.isEmpty { rows.append((t.string(for: MorphKey.rowStrongs), gs, false)) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel(t.string(for: MorphKey.sectionGreekEquiv))
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
        case "v":   return t.string(for: MorphKey.syntaxPredicate)
        case "p":   return t.string(for: MorphKey.syntaxPredicateNominal)
        case "s":   return t.string(for: MorphKey.syntaxSubject)
        case "o":   return t.string(for: MorphKey.syntaxObject)
        case "c":   return t.string(for: MorphKey.syntaxCircumstance)
        case "adv": return t.string(for: MorphKey.syntaxAdverb)
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
    @EnvironmentObject private var router: AppNavigationRouter

    var body: some View {
        let totalLabel = String(
            format: NSLocalizedString(MorphKey.usageTotalCount, comment: ""),
            entry.totalCount
        )
        return PillSection(verbatimTitle: totalLabel) {
            if entry.bookGroups.isEmpty {
                Text(LocalizedStringKey(MorphKey.emptyNoData))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            } else {
                ForEach(entry.bookGroups) { group in
                    BookUsageRow(group: group, strongsId: entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            router.pendingVerseId = group.example.id
                        }
                    Divider()
                }
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Book Usage Row

private struct BookUsageRow: View {
    let group: BookUsageGroup
    let strongsId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // "Genesis 1:1" — full book name + chapter:verse of the example
                Text("\(group.bookName) \(group.example.chapter):\(group.example.verse)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
                Spacer(minLength: 8)
                // "1 Occurrence in this Book" / "5 Occurrences in this Book"
                Text(String.localizedStringWithFormat(
                    NSLocalizedString(MorphKey.usageBookCount, comment: ""),
                    group.count
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
            Text(highlightedVerseText(raw: group.example.rawText,
                                      fallback: group.example.text,
                                      strongsId: strongsId))
                .font(.callout)
                .lineSpacing(3)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - KJV Keyword Highlighting

/// Builds an AttributedString from a raw KJV verse (with `<S>N</S>` markup), highlighting
/// every text segment whose Strong's tag(s) include the numeric base of `strongsId`.
/// Falls back to plain `fallback` text when `raw` is empty (sample/preview data).
///
/// Handles consecutive Strong's tags (`word<S>H1</S><S>H2</S>`): all numbers after
/// the same text segment are collected into one set before deciding whether to highlight.
/// Previously, if the match was the 2nd or 3rd consecutive tag, segRaw was empty and the
/// word was never highlighted.
private func highlightedVerseText(raw: String, fallback: String, strongsId: String) -> AttributedString {
    guard !raw.isEmpty else { return AttributedString(fallback) }

    let numChars = strongsId.drop(while: { !$0.isNumber })
    let baseNum  = String(numChars.prefix(while: { $0.isNumber }))
    guard !baseNum.isEmpty else { return AttributedString(fallback) }

    guard let tagPattern = try? NSRegularExpression(pattern: #"<S>(\d+[a-z]?)</S>"#) else {
        return AttributedString(fallback)
    }
    let matches = tagPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))

    // Build a flat list of (textSegment, strongsNumber) pairs, then group by segment:
    // consecutive tags with an empty text gap all belong to the preceding non-empty segment.
    struct TaggedSegment {
        var text: String        // cleaned display text
        var numbers: Set<String>
    }
    var segments: [TaggedSegment] = []
    var cursor = raw.startIndex

    for match in matches {
        guard let tagRange = Range(match.range,       in: raw),
              let numRange = Range(match.range(at: 1), in: raw) else { continue }

        let segRaw  = String(raw[cursor..<tagRange.lowerBound])
        let segText = stripKJVSegment(segRaw)
        let num     = String(raw[numRange].prefix(while: { $0.isNumber }))
        cursor = tagRange.upperBound

        if segText.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty gap between consecutive tags → associate this number with the
            // previous segment (same surface word, multiple lexemes).
            if !segments.isEmpty {
                segments[segments.count - 1].numbers.insert(num)
            }
            // Edge case: consecutive tags at very start with no preceding text — skip.
        } else {
            segments.append(TaggedSegment(text: segText, numbers: [num]))
        }
    }

    // Trailing text after the last tag (no associated Strong's number).
    if cursor < raw.endIndex {
        let trailing = stripKJVSegment(String(raw[cursor...]))
        if !trailing.isEmpty {
            segments.append(TaggedSegment(text: trailing, numbers: []))
        }
    }

    // Render: highlight any segment whose number set contains our target.
    var result = AttributedString()
    for seg in segments {
        if seg.numbers.contains(baseNum) {
            var attr = AttributedString(seg.text)
            attr.backgroundColor = Color.wordHighlight
            result += attr
        } else {
            result += AttributedString(seg.text)
        }
    }

    return result.characters.isEmpty ? AttributedString(fallback) : result
}

/// Strips all non-Strong's markup from a single KJV text chunk while preserving
/// leading/trailing spaces, which serve as word separators when chunks are concatenated.
///
/// Uses `strippingBibleMarkupKeepingSpaces()` — NOT `strippingBibleMarkup()`.
/// The trimming variant removes the leading space that KJV source encodes before each
/// word, causing words to run together ("lodgedround aboutthe") when segments are joined.
private func stripKJVSegment(_ s: String) -> String {
    s.strippingBibleMarkupKeepingSpaces()
}

// MARK: - Morphology Decoder

/// Decodes Macula Hebrew (OSHB) and Greek (SBLGNT) morphology codes into readable labels.
/// All string output goes through TranslationProvider — zero hardcoded language strings here.
///
/// Hebrew codes in the DB have NO language prefix: "Ncmpa", "Vqp3ms", "Td", "R", "C"
/// Greek codes use dashes: "N-NSM", "V-PAI-3S", "CONJ", "ADV"
struct FullMorphology {
    var partOfSpeech: String = ""
    var stem: String = ""
    var aspect: String = ""
    var grammaticalForm: String = ""
}

enum MorphologyDecoder {

    // MARK: Full decode (for WordMeaningView detail)

    static func decodeFull(
        _ code: String,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> FullMorphology? {
        guard !code.isEmpty else { return nil }
        let ch = Array(code)
        guard let first = ch.first else { return nil }
        var m = FullMorphology()

        switch first {
        case "V":
            m.partOfSpeech = t.string(for: MorphKey.posVerb)
            if ch.count > 1 { m.stem   = hebrewStem(ch[1], t: t) }
            if ch.count > 2 { m.aspect = hebrewAspect(ch[2], t: t) }
            if ch.count > 5 {
                let p = personLabel(ch[3], t: t)
                let g = genderLabel(ch[4], t: t)
                let n = numberLabel(ch[5], t: t)
                m.grammaticalForm = [p, g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "N":
            m.partOfSpeech = t.string(for: MorphKey.posNoun)
            if ch.count > 4 {
                let g = genderLabel(ch[2], t: t)
                let n = numberLabel(ch[3], t: t)
                let s = stateLabel(ch[4], t: t)
                m.grammaticalForm = [g, n, s].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "A":
            m.partOfSpeech = t.string(for: MorphKey.posAdjective)
            if ch.count > 4 {
                let g = genderLabel(ch[2], t: t)
                let n = numberLabel(ch[3], t: t)
                m.grammaticalForm = [g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        case "T":
            m.partOfSpeech = ch.count > 1 ? particleLabel(ch[1], t: t) : t.string(for: MorphKey.posParticle)
        case "R": m.partOfSpeech = t.string(for: MorphKey.posPreposition)
        case "C": m.partOfSpeech = t.string(for: MorphKey.posConjunction)
        case "P": m.partOfSpeech = t.string(for: MorphKey.posPronoun)
        case "D": m.partOfSpeech = t.string(for: MorphKey.posAdverb)
        case "I": m.partOfSpeech = t.string(for: MorphKey.posInterjection)
        case "S":
            m.partOfSpeech = ch.count > 1 ? suffixLabel(ch[1], t: t) : t.string(for: MorphKey.posPronSuffix)
            if ch.count > 4 {
                let p = personLabel(ch[2], t: t)
                let g = genderLabel(ch[3], t: t)
                let n = numberLabel(ch[4], t: t)
                m.grammaticalForm = [p, g, n].filter { !$0.isEmpty }.joined(separator: " ")
            }
        default: return nil
        }
        return m
    }

    private static func suffixLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "p": return t.string(for: MorphKey.posPronSuffix)
        case "d": return t.string(for: MorphKey.posDirObjSuffix)
        default:  return t.string(for: MorphKey.posSuffix)
        }
    }

    private static func hebrewStem(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "q": return t.string(for: MorphKey.stemQal)
        case "N": return t.string(for: MorphKey.stemNiphal)
        case "p": return t.string(for: MorphKey.stemPiel)
        case "P": return t.string(for: MorphKey.stemPual)
        case "h": return t.string(for: MorphKey.stemHiphil)
        case "H": return t.string(for: MorphKey.stemHophal)
        case "t": return t.string(for: MorphKey.stemHithpael)
        case "D": return t.string(for: MorphKey.stemPoel)
        default:  return String(c)
        }
    }

    private static func hebrewAspect(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "p": return t.string(for: MorphKey.aspectPerfect)
        case "i": return t.string(for: MorphKey.aspectImperfect)
        case "w": return t.string(for: MorphKey.aspectWayyiqtol)
        case "j": return t.string(for: MorphKey.aspectJussive)
        case "c": return t.string(for: MorphKey.aspectCohortative)
        case "v": return t.string(for: MorphKey.aspectImperative)
        case "r": return t.string(for: MorphKey.aspectParticipleActive)
        case "s": return t.string(for: MorphKey.aspectParticiplePassive)
        case "a": return t.string(for: MorphKey.aspectInfAbsolute)
        case "A": return t.string(for: MorphKey.aspectInfConstruct)
        default:  return ""
        }
    }

    private static func particleLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "d": return t.string(for: MorphKey.posArticle)
        case "r": return t.string(for: MorphKey.posRelPronoun)
        case "n": return t.string(for: MorphKey.posNegParticle)
        case "i": return t.string(for: MorphKey.posInterrogative)
        default:  return t.string(for: MorphKey.posParticle)
        }
    }

    private static func personLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "1": return t.string(for: MorphKey.person1)
        case "2": return t.string(for: MorphKey.person2)
        case "3": return t.string(for: MorphKey.person3)
        default:  return ""
        }
    }

    private static func genderLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "m": return t.string(for: MorphKey.genderMasculine)
        case "f": return t.string(for: MorphKey.genderFeminine)
        case "c", "b": return t.string(for: MorphKey.genderCommon)
        default:  return ""
        }
    }

    private static func numberLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "s": return t.string(for: MorphKey.numberSingular)
        case "p": return t.string(for: MorphKey.numberPlural)
        case "d": return t.string(for: MorphKey.numberDual)
        default:  return ""
        }
    }

    private static func stateLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "a": return t.string(for: MorphKey.stateAbsolute)
        case "c": return t.string(for: MorphKey.stateConstruct)
        case "d": return t.string(for: MorphKey.stateDetermined)
        default:  return ""
        }
    }

    // MARK: Short decode (for WordCard — Оригінал pill)

    static func decode(
        _ code: String,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> String? {
        guard !code.isEmpty else { return nil }
        return code.contains("-") ? decodeGreek(code, t: t) : decodeHebrew(code, t: t)
    }

    // MARK: Hebrew (OSHB, no language prefix)
    private static func decodeHebrew(_ code: String, t: TranslationProvider) -> String? {
        let chars = Array(code)
        guard let first = chars.first else { return nil }
        var parts: [String] = []

        switch first {
        case "N":
            parts.append(t.string(for: MorphKey.posNoun))
            if chars.count > 3 {
                switch chars[3] {
                case "p": parts.append(t.string(for: MorphKey.numberPlural))
                case "d": parts.append(t.string(for: MorphKey.numberDual))
                default: break
                }
            }
        case "V":
            parts.append(t.string(for: MorphKey.posVerb))
            if chars.count > 1 {
                switch chars[1] {
                case "q": parts.append("Qal")
                case "N": parts.append("Niphal")   // fix: was "n" — OSHB uses uppercase N
                case "p": parts.append("Piel")
                case "P": parts.append("Pual")     // fix: was "u" — OSHB uses uppercase P
                case "h": parts.append("Hiphil")
                case "H": parts.append("Hophal")   // fix: was "o" — OSHB uses uppercase H
                case "t": parts.append("Hithp.")
                default: break
                }
            }
        case "A":
            parts.append(t.string(for: MorphKey.posAdjective))
            if chars.count > 3 {
                switch chars[3] {
                case "p": parts.append(t.string(for: MorphKey.numberPlural))
                case "d": parts.append(t.string(for: MorphKey.numberDual))
                default: break
                }
            }
        case "T":
            if chars.count > 1 {
                switch chars[1] {
                case "d": parts.append(t.string(for: MorphKey.posArticle))
                case "r": parts.append(t.string(for: MorphKey.posRelPronoun))
                case "n": parts.append(t.string(for: MorphKey.posNegParticle))
                case "i": parts.append(t.string(for: MorphKey.posInterrogative))
                default:  parts.append(t.string(for: MorphKey.posParticle))
                }
            } else {
                parts.append(t.string(for: MorphKey.posParticle))
            }
        case "R": parts.append(t.string(for: MorphKey.posPreposition))
        case "C": parts.append(t.string(for: MorphKey.posConjunction))
        case "P": parts.append(t.string(for: MorphKey.posPronoun))
        case "D": parts.append(t.string(for: MorphKey.posAdverb))
        case "I": parts.append(t.string(for: MorphKey.posInterjection))
        case "S": parts.append(t.string(for: MorphKey.posPronSuffix))
        default: return nil
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Greek (SBLGNT, dash-separated)
    private static func decodeGreek(_ code: String, t: TranslationProvider) -> String? {
        let segs = code.components(separatedBy: "-")
        guard let posStr = segs.first else { return nil }
        var parts: [String] = []

        switch posStr.uppercased() {
        case "N":    parts.append(t.string(for: MorphKey.posNoun))
        case "V":    parts.append(t.string(for: MorphKey.posVerb))
        case "A":    parts.append(t.string(for: MorphKey.posAdjective))
        case "P":    parts.append(t.string(for: MorphKey.posPreposition))
        case "ADV":  parts.append(t.string(for: MorphKey.posAdverb))
        case "CONJ": parts.append(t.string(for: MorphKey.posConjunction))
        case "PRON": parts.append(t.string(for: MorphKey.posPronoun))
        case "ART":  parts.append(t.string(for: MorphKey.posArticle))
        case "PART": parts.append(t.string(for: MorphKey.posParticle))
        case "INJ":  parts.append(t.string(for: MorphKey.posInterjection))
        default:     return nil
        }

        if segs.count > 1 {
            let cng = Array(segs[1].uppercased())
            if cng.count > 1 {
                switch cng[1] {
                case "P": parts.append(t.string(for: MorphKey.numberPlural))
                default: break
                }
            }
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Word Row

/// Flat list row displayed in OriginalWordsView for each word in a verse.
/// Tapping the entire row navigates to Word/Meaning detail.
struct WordRow: View {
    let word: BibleWord
    let isSelected: Bool
    let onTap: () -> Void

    private let t: TranslationProvider = BundleTranslationProvider()

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    // Top line: Hebrew text · xlit · Strong's badge · morph
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(word.displayText)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.primary)

                        if let xlit = word.displayXlit, !xlit.isEmpty {
                            Text(xlit)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let sid = word.strongsId {
                            Text(sid)
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(UIColor.secondarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        if let morph = word.morphology,
                           let label = MorphologyDecoder.decode(morph, using: t) {
                            Text(label)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Bottom line: gloss / meaning
                    if let gloss = word.gloss, !gloss.isEmpty {
                        Text(gloss)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

