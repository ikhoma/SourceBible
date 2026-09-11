// WordTabContent.swift
// SourceBible
//
// Вміст вкладки "Слово" у VerseBottomSheetView.
// Типи: WordTabView · WordSubTab · WordMeaningView · ConcordanceView ·
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
                    ConcordanceView(entry: entry)
                }
            } else if vm.selectedWord == nil, vm.selectedSegment == nil,
                      vm.translationLacksStrongsMapping {
                // Strong's-less translation (UBIO/Ohienko): nothing to tap in the
                // translation text — explain why and ask for support instead of
                // showing a dead-end hint. Words remain reachable via the Original
                // pill (cheat mode, ADR-016 amendment).
                WordMappingSupportView()
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

// MARK: - Word Mapping Support CTA

/// Shown in the Word tab when the displayed translation has no Strong's tagging
/// (e.g. UBIO/Ohienko). Explains that word-level mapping is a substantial effort
/// and routes to the donation screen.
private struct WordMappingSupportView: View {
    @Environment(\.colorTheme) private var colorTheme
    @State private var showDonation = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)
                .padding(.top, 12)

            Text("word.mapping.support.title")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("word.mapping.support.body")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showDonation = true
            } label: {
                Text("word.mapping.support.cta")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .legacyCapsuleButton()
            .controlSize(.large)
            .tint(.appBlue)
            .padding(.top, 6)

            Text("word.mapping.support.hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .sheet(isPresented: $showDonation) {
            NavigationStack {
                DonationView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // Консистентний X-close для всіх sheet-ів (SheetCloseButton)
                            SheetCloseButton { showDonation = false }
                        }
                    }
            }
        }
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
    /// Abbott-Smith outline (Greek TBESG). Non-empty ⇒ `definitions` is empty and
    /// the view renders these as an indented outline WITHOUT auto-numbering
    /// (the numbering — "1.", "(a)", "(α)" — is part of the source text).
    var outline: [LexiconLine] = []
}

/// One line of an Abbott-Smith outline with its indent level.
struct LexiconLine: Identifiable {
    let id = UUID()
    let text: String
    let indent: Int   // 0 = intro / "1." senses, 1 = "(a)" sub-points, 2 = "(α)" deeper
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

        // Abbott-Smith (Greek TBESG): BDB "1)" patterns don't match — the source marks
        // hierarchy with literal "__" at sub-entry starts ("__1.", "__(a)", "__(α)").
        // Previously this fell into the flat fallback below, which joined all lines
        // with "; " — destroying the outline and leaving ";;" + "__" artefacts inline.
        if sections.isEmpty, normalized.contains("__") {
            let outline = parseAbbottSmith(normalized)
            if !outline.isEmpty {
                return [LexiconSection(stemName: "", definitions: [], outline: outline)]
            }
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

    // MARK: Abbott-Smith (TBESG) outline

    /// Parses an Abbott-Smith definition into outline lines. In the source, each
    /// nested sub-entry begins with "__" (after a <br> → \n from the DB build):
    /// "__1." / "__2." = numbered senses, "__(a)" = sub-points, "__(α)" = deeper.
    /// Real newlines are preserved; indent is derived from the marker shape.
    private static func parseAbbottSmith(_ normalized: String) -> [LexiconLine] {
        // Safety net: if a "__" marker survived mid-line (no <br> before it in the
        // source), force it onto its own line before splitting.
        let broken = normalized.replacingOccurrences(of: "__", with: "\n__")

        var result: [LexiconLine] = []
        for rawLine in broken.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Same ": gloss" prefix-line artefact as the BDB path.
            guard !line.isEmpty, !line.hasPrefix(":") else { continue }

            var isMarked = false
            while line.hasPrefix("_") {
                line = String(line.dropFirst())
                isMarked = true
            }

            line = cleanDef(line)
            // Source doubles like ";;" read as noise once the outline is restored.
            line = line.replacingOccurrences(of: ";;", with: ";")
            guard !line.isEmpty else { continue }

            result.append(LexiconLine(text: line,
                                      indent: indentLevel(for: line, marked: isMarked)))
        }
        return result
    }

    /// Indent from the marker shape: "1." senses stay at the top level (like the
    /// intro), latin "(a)" one step in, greek "(α)" two. Unrecognized markers
    /// default to one step (they are always sub-entries of something).
    private static func indentLevel(for line: String, marked: Bool) -> Int {
        guard marked else { return 0 }
        if line.range(of: #"^\d+\."#,     options: .regularExpression) != nil { return 0 }
        if line.range(of: #"^\([a-z]\)"#, options: .regularExpression) != nil { return 1 }
        if line.range(of: #"^\([α-ω]\)"#, options: .regularExpression) != nil { return 2 }
        return 1
    }
}


// MARK: - Word Meaning

struct WordMeaningView: View {
    let entry: StrongsEntry
    @EnvironmentObject var vm: ReaderViewModel
    @Environment(\.sessionTracker) private var tracker

    /// Dedup: track the last entry.id we fired recordFeatureUse for, so
    /// navigating to a new word fires once but recompose of the same entry
    /// does not inflate the counter (Slice 3 §E).
    @State private var lastTrackedEntryId: String = ""

    private let t: TranslationProvider = BundleTranslationProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(t.string(for: MorphKey.sectionLemma), topPadding: 0)
            headerSection
            if let word = vm.selectedWord {
                contextSection(word)
                morphologySection(word: word)
            }
            lexicalSection
            if let word = vm.selectedWord,
               let greek = word.greek, !greek.isEmpty {
                greekSection(word)
            }
        }
        .padding(.bottom, 20)
        // Dedup: fire once per unique entry.id (chevron nav changes the entry → new fire).
        // .onAppear handles the initial display; .onChange handles subsequent word navigations
        // while the view stays mounted (no teardown between chevron taps).
        .onAppear {
            if lastTrackedEntryId != entry.id {
                lastTrackedEntryId = entry.id
                tracker.recordFeatureUse(.lexicon)
            }
        }
        .onChange(of: entry.id) { _, newId in
            if lastTrackedEntryId != newId {
                lastTrackedEntryId = newId
                tracker.recordFeatureUse(.lexicon)
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.originalWord)
                        .font(.title3)
                    // Header shows the LEMMA form (entry.originalWord), so use the LEMMA xlit.
                    // Surface-form xlit (vm.selectedWord?.xlit) is shown in contextSection below.
                    let xlit: String = !entry.xlitSimple.isEmpty
                        ? entry.xlitSimple
                        : entry.transliteration
                    if !xlit.isEmpty {
                        Text(xlit)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.shortDefinition.isEmpty {
                    Text(entry.shortDefinition)
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else if StrongsDefinitionTrust.isUntrusted(entry.id) {
                    // bug-046: визначення цього підзапису в базі належить базовому
                    // номеру й може означати протилежне. Показуємо чесну порожнечу,
                    // а не чужий текст. Лема, транслітерація й морфологія — дані
                    // Macula, вони справні й лишаються на місці.
                    Text("word.definition.unavailable")
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
        // Match section title→content rhythm: 4pt label bottom + 10pt here = 14pt,
        // same as InfoGroup's first-row top inset used by the other sections.
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // MARK: Form in context

    private func contextSection(_ word: BibleWord) -> some View {
        let parts = word.id.split(separator: "|")
        let ch    = parts.count > 1 ? String(parts[1]) : ""
        let v     = parts.count > 2 ? String(parts[2]) : ""
        let ref   = "\(vm.currentBookShortName) \(ch):\(v)"

        var rows: [(String, String, Bool)] = [(t.string(for: MorphKey.rowWord), word.text, true)]
        // Use bestXlit: BibleHub combined slot translit → Macula occurrence xlit → TBESH lemma xlit.
        // xlitSlot covers suffix-combined words like ḥep̄-ṣōw; falls back to per-token xlit/lemma.
        if let xlit = word.bestXlit, !xlit.isEmpty {
            rows.append((t.string(for: MorphKey.rowTransliteration), xlit, false))
        }
        // ADR-040 (рішення 2026-09-11): «Склад слова» переїхав сюди з секції
        // «Морфологія» — композиція («прийм. + ім.») описує КОНКРЕТНИЙ запис
        // слова в ЦЬОМУ вірші (Macula-слот !N — угруповання per-occurrence,
        // та сама лема деінде може стояти без приліпленого прийменника чи
        // артикля), а не граматичну категорію голови слота.
        if let morph = word.morphology {
            let comp = MorphologyDecoder.composition(morph, lexicalClass: word.lexicalClass, using: t)
            if !comp.isEmpty {
                rows.append((t.string(for: MorphKey.rowComposition), comp, false))
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel(t.string(for: MorphKey.sectionFormInContext, ref))
            InfoGroup(rows: rows)
        }
    }

    // MARK: Morphology

    private func morphologyRows(word: BibleWord, decoded: FullMorphology) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = []
        // «Склад слова» переїхав у contextSection() (ADR-040, рішення 2026-09-11) —
        // тут лишаються лише граматичні категорії ГОЛОВИ слота.
        if !decoded.partOfSpeech.isEmpty    { rows.append((t.string(for: MorphKey.rowPartOfSpeech),    decoded.partOfSpeech,    false)) }
        if !decoded.stem.isEmpty            { rows.append((t.string(for: MorphKey.rowStem),            decoded.stem,            false)) }
        if !decoded.aspect.isEmpty          { rows.append((t.string(for: MorphKey.rowAspect),          decoded.aspect,          false)) }
        if !decoded.grCase.isEmpty          { rows.append((t.string(for: MorphKey.rowCase),            decoded.grCase,          false)) }
        if !decoded.tense.isEmpty           { rows.append((t.string(for: MorphKey.rowTense),           decoded.tense,           false)) }
        if !decoded.voice.isEmpty           { rows.append((t.string(for: MorphKey.rowVoice),           decoded.voice,           false)) }
        if !decoded.mood.isEmpty            { rows.append((t.string(for: MorphKey.rowMood),            decoded.mood,            false)) }
        if !decoded.nonFiniteForm.isEmpty   { rows.append((t.string(for: MorphKey.rowNonFiniteForm),   decoded.nonFiniteForm,   false)) }
        if !decoded.degree.isEmpty          { rows.append((t.string(for: MorphKey.rowDegree),          decoded.degree,          false)) }
        if !decoded.grammaticalForm.isEmpty { rows.append((t.string(for: MorphKey.rowGrammaticalForm), decoded.grammaticalForm, false)) }
        if let role = word.syntaxRole, let label = syntaxRoleLabel(role) {
            rows.append((t.string(for: MorphKey.rowSyntaxRole), label, false))
        }
        return rows
    }

    @ViewBuilder
    private func morphologySection(word: BibleWord) -> some View {
        if let decoded = MorphologyDecoder.decodeFull(word, using: t) {
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

    /// Порядок секцій лексикону + яку з них позначити як форму з вірша (ADR-033).
    ///
    /// Стаття BDB двошарова: `1)` — злитий заголовок кореня (склейка глос УСІХ порід),
    /// `1a)/1b)` — самі породи. У порядку джерела заголовок іде першим і найпомітнішим,
    /// тож для Ніфаля `נִדְמוּ` («народ знищено») зверху світилось активне «destroy».
    /// Це illegitimate totality transfer: приписати формі весь діапазон кореня.
    ///
    /// ⛔ FAIL-SAFE. Будь-яка невизначеність → повертаємо ЯК Є, нічого не ховаючи:
    /// немає розбору, не дієслово, у статті немає порід, або породи цієї форми в BDB
    /// немає (рідкісні Polel/Pilpel). Краще зайвий рядок, ніж порожній екран.
    ///
    /// Це функція від `(entry, selectedWord)`, а НЕ збережений стан — інакше перехід
    /// по чевронах міняв би слово, а позначка лишалась би від попереднього.
    private func rankedLexicon(_ sections: [LexiconSection]) -> (sections: [LexiconSection], markedId: UUID?) {
        guard let word = vm.selectedWord,
              let stem = MorphologyDecoder.canonicalHebrewStem(word)
        else { return (sections, nil) }

        let named = sections.filter { !$0.stemName.isEmpty }
        guard !named.isEmpty,
              let hit = named.firstIndex(where: { Self.normalizedStem($0.stemName) == stem })
        else { return (sections, nil) }

        var ordered = named
        let match = ordered.remove(at: hit)
        ordered.insert(match, at: 0)
        // Злитий заголовок кореня вже відсіяно фільтром `named` — він єдиний,
        // хто приходить без імені перед іменованими секціями.
        return (ordered, match.id)
    }

    /// «Niphal», «Niph.», «NIPHAL » → «niphal». BDB не гарантує єдиного написання.
    private static func normalizedStem(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    @ViewBuilder
    private var lexicalSection: some View {
        let ranked = rankedLexicon(LexiconParser.parse(entry.fullDefinition))
        let sections = ranked.sections
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel(t.string(for: MorphKey.sectionLexical))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { si, sec in
                        VStack(alignment: .leading, spacing: 0) {
                            if !sec.stemName.isEmpty {
                                // Сам розбір («Niphal perfect 3cp») тут НЕ дублюємо —
                                // він уже стоїть у секції «Морфологія» вище.
                                Text(sec.id == ranked.markedId
                                     ? "\(sec.stemName) (\(t.string(for: MorphKey.stemFormInVerse)))"
                                     : sec.stemName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 10).padding(.bottom, 4)
                            }
                            // Abbott-Smith outline (Greek): indented lines, source's own
                            // numbering ("1.", "(a)", "(α)") — no auto-numbers, no row
                            // separators (it's one entry's outline, not a list of senses).
                            if !sec.outline.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(sec.outline) { line in
                                        Text(line.text)
                                            .font(.callout)
                                            .lineSpacing(3)
                                            .padding(.leading, CGFloat(line.indent) * 16)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            ForEach(Array(sec.definitions.enumerated()), id: \.offset) { i, def in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(i + 1). \(def)")
                                        .font(.callout)
                                        .lineSpacing(3)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10)
                                if i < sec.definitions.count - 1 {
                                    Rectangle()
                                        .fill(Color(UIColor.separator))
                                        .frame(height: 0.5)
                                }
                            }
                        }
                        if si < sections.count - 1 {
                            Rectangle()
                                .fill(Color(UIColor.separator))
                                .frame(height: 0.5)
                        }
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

    private func sectionLabel(_ title: String, topPadding: CGFloat = 20) -> some View {
        Text(title.uppercased())
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.top, topPadding).padding(.bottom, 4).padding(.horizontal, 2)
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
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(row.1)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .environment(\.layoutDirection, row.2 ? .rightToLeft : .leftToRight)
                }
                .padding(.vertical, 10)
                if i < rows.count - 1 {
                    Rectangle()
                        .fill(Color(UIColor.separator))
                        .frame(height: 0.5)
                }
            }
        }
    }
}

// MARK: - Word Usage

struct ConcordanceView: View {
    let entry: StrongsEntry
    @EnvironmentObject private var vm:     ReaderViewModel
    @Environment(\.sessionTracker) private var tracker
    // Мова інтерфейсу для plural-правил (bug-041), не системна.
    @Environment(\.locale) private var locale

    var body: some View {
        // bug-041: було `String(format:)` без plural-правил — «2 випадків» замість «2 випадки».
        // Ключ тепер має plural-варіації, а локаль передається ЯВНО: swizzle підміняє бандл,
        // але не `Locale.current`, тож без неї CLDR узяв би англійські правила (заміряно).
        let totalLabel = String(
            format: NSLocalizedString(MorphKey.usageTotalCount, comment: ""),
            locale: locale,
            entry.totalCount
        )
        return PillSection(verbatimTitle: totalLabel) {
            // Usage data loads lazily HERE (not in loadStrongs) — see loadUsageIfNeeded.
            // Until it lands, show a spinner instead of a false "no data" flash.
            // The bookGroups check keeps DEBUG previews (pre-populated samples) working.
            if !entry.usageLoaded && entry.bookGroups.isEmpty {
                HStack { Spacer(); ProgressView().padding(.vertical, 16); Spacer() }
            } else if entry.bookGroups.isEmpty {
                Text(LocalizedStringKey(MorphKey.emptyNoData))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            } else {
                // ⛔ Рядок НЕ клікабельний — навмисно (2026-08-02).
                // Раніше тап перекидав на вірш-приклад, але афордансу не було
                // (ні шеврона, ні кольору посилання, ні press-стану), тож дію
                // знаходили випадково — і вона ще й стирала cross-ref back stack
                // (йшла через `.fresh`), тобто «‹ Назад» зникала. Читалось як
                // «застосунок сам кудись поїхав».
                //
                // Прибрано, а не полагоджено, бо очікування від рядка інше:
                // «покажи всі N входжень у цій книзі», а не «стрибни на один
                // приклад». N буває і 5, і 500 — це власний екран зі списком і
                // фільтрами (stacked sheet у стилі Пошуку), а не один тап.
                // → майбутнє, `spec-word-usage-redesign.md`.
                ForEach(entry.bookGroups) { group in
                    BookUsageRow(group: group, strongsId: entry.id)
                    Divider()
                }
            }
        }
        .padding(.bottom, 16)
        .onAppear {
            tracker.recordFeatureUse(.concordance)
            vm.loadUsageIfNeeded()
        }
        // Chevron word-nav replaces the entry while this view stays mounted —
        // onAppear won't refire, so reload on the id change. Filling the usage
        // fields keeps the same entry.id, so this doesn't loop.
        .onChange(of: entry.id) { _, _ in
            vm.loadUsageIfNeeded()
        }
    }
}

// MARK: - Book Usage Row

private struct BookUsageRow: View {
    let group: BookUsageGroup
    let strongsId: String
    // Мова інтерфейсу для plural-правил (bug-041), не системна.
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // "Genesis 1:1" — full book name + chapter:verse of the example
                ReferenceLabel("\(group.bookName) \(group.example.chapter):\(group.example.verse)")
                Spacer(minLength: 8)
                // "1 Occurrence in this Book" / "5 Occurrences in this Book"
                // Локаль явно — див. bug-041: `localizedStringWithFormat` бере системну.
                Text(String(
                    format: NSLocalizedString(MorphKey.usageBookCount, comment: ""),
                    locale: locale,
                    group.count
                ))
                .font(.footnote)
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

    // bug-008/009: stripKJVSegment preserves leading/trailing spaces because the
    // source encodes inter-word spacing as a *leading* space on each segment.
    // That is correct BETWEEN segments, but at the edges of the verse it leaks out
    // as a stray indent — visible as inconsistent leading spaces in the Usage list
    // (a verse whose first segment starts with a space renders indented, one that
    // doesn't renders flush). Trim the outer edges only; inner spacing is untouched.
    if !segments.isEmpty {
        segments[0].text = String(
            segments[0].text.drop(while: { $0 == " " })
        )
        let lastIdx = segments.count - 1
        while segments[lastIdx].text.hasSuffix(" ") {
            segments[lastIdx].text.removeLast()
        }
        segments.removeAll { $0.text.isEmpty }
    }

    // Render: highlight any segment whose number set contains our target.
    var result = AttributedString()
    for seg in segments {
        if seg.numbers.contains(baseNum) {
            var attr = AttributedString(seg.text)
            attr.foregroundColor = Color.appBlue
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
    /// «артикль + іменник» для складеного слова; порожній рядок для однослівного.
    var composition: String = ""
    // ADR-040: грецькі категорії — порожній рядок, якщо не застосовується
    // (не грецька) чи значення поза відомим набором.
    var grCase: String = ""
    var tense: String = ""
    var voice: String = ""
    var mood: String = ""
    var degree: String = ""
    /// participle/infinitive — окремо від `mood` (це не спосіб дієслова).
    var nonFiniteForm: String = ""
}

enum MorphologyDecoder {

    // MARK: Слот із кількох морфем

    /// Розділювач морфем у склеєному коді слота.
    /// Ставиться у `VerseTabContent.displayWords`, коли токени зі спільним
    /// Macula-слотом зливаються в одне відображуване слово:
    /// `הַדַּעַת` → `Td·Ncfsa` (артикль + іменник).
    private static let morphemeSeparator: Character = "·"

    /// Індекс голови слота — останньої морфеми, що НЕ є займенниковим суфіксом.
    ///
    /// Те саме правило, що й `headToken(of:)` у `VerseTabContent` (ADR-020):
    /// іврит будує слот як `[проклітики…] ГОЛОВА [енклітики…]`, тож голова —
    /// остання не-енклітика. Енклітика в коді = префікс `S` (`Sp3ms`).
    private static func headIndex(_ parts: [String]) -> Int {
        parts.lastIndex(where: { !$0.hasPrefix("S") }) ?? parts.count - 1
    }

    /// Голова слота — код, який і треба розбирати «повністю».
    ///
    /// ⛔ БУЛО: `decodeFull` брав `code.first` і для складеного слова розбирав
    /// ПРОКЛІТИКУ. Для `Td·Ncfsa` це артикль: гілка `case "T"` не виставляє
    /// `grammaticalForm` взагалі, а `lexicalClass` потім перезаписував частину
    /// мови на «іменник» — і саме це перекриття ховало проблему. Наслідок:
    /// у складених слів мовчки зникали рід/число/стан, а в дієслів — порода.
    static func headMorpheme(_ code: String) -> String {
        let parts = code.split(separator: morphemeSeparator).map(String.init)
        guard parts.count > 1 else { return code }
        return parts[headIndex(parts)]
    }

    /// Склад слова словами: «артикль + іменник», «сполучник + прийменник + іменник».
    ///
    /// Свідомо НЕ нотація BibleHub (`Art | N-fs`). Вона компактна, але потребує
    /// знання скорочень, і читач без підготовки її просто прогортає. Мета
    /// застосунку — зменшувати розрив між академізмом і розумінням, тож склад
    /// проговорюється тими самими словами, якими ми вже називаємо частини мови.
    ///
    /// Порожній рядок, якщо морфема одна: показувати «іменник» як «склад» безглуздо.
    static func composition(
        _ code: String,
        lexicalClass: String? = nil,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> String {
        let parts = code.split(separator: morphemeSeparator).map(String.init)
        guard parts.count > 1 else { return "" }
        let head = headIndex(parts)
        let labels = parts.enumerated().compactMap { i, part -> String? in
            // lexicalClass описує ГОЛОВУ слота — до афіксів його прикладати не можна,
            // інакше артикль назветься іменником.
            shortLabel(part, lexicalClass: i == head ? lexicalClass : nil, using: t)
        }
        return labels.count > 1 ? labels.joined(separator: " + ") : ""
    }

    /// Скорочений підпис частини мови для ОДНІЄЇ морфеми.
    ///
    /// ⛔ Окремий набір ключів (`morph.pos.short.*`), а не обрізання повних назв:
    /// «Означений артикль» → «арт.» не виводиться алгоритмічно, а українські
    /// скорочення мають власну традицію («дієсл.», «прийм.»), яку не вгадати
    /// правилом. Повні назви лишаються у вкладці «Слово».
    private static func shortLabel(
        _ code: String,
        lexicalClass: String?,
        using t: TranslationProvider
    ) -> String? {
        if let cls = lexicalClass, let key = shortKeyForClass(cls) {
            return t.string(for: key)
        }
        guard let key = shortKeyForCode(code) else { return nil }
        return t.string(for: key)
    }

    private static func shortKeyForClass(_ cls: String) -> String? {
        switch cls {
        case "noun":        return MorphKey.posShortNoun
        case "verb":        return MorphKey.posShortVerb
        case "adj", "num":  return MorphKey.posShortAdjective
        case "adv":         return MorphKey.posShortAdverb
        case "prep":        return MorphKey.posShortPreposition
        case "cj", "conj":  return MorphKey.posShortConjunction
        case "pron":        return MorphKey.posShortPronoun
        case "ij", "intj":  return MorphKey.posShortInterjection
        case "art", "det":  return MorphKey.posShortArticle
        case "ptcl":        return MorphKey.posShortParticle
        case "rel":         return MorphKey.posShortRelPronoun
        default:            return nil   // om / x / невідоме → падаємо на код морфеми
        }
    }

    private static func shortKeyForCode(_ code: String) -> String? {
        // Грецькі коди («N-NSM», «V-PAI-3S») сюди не пускаємо: там розкладка
        // інша, і збіг першої літери був би випадковим. Для грецької працює
        // гілка з `lexicalClass` вище.
        guard !code.contains("-") else { return nil }
        let ch = Array(code)
        guard let first = ch.first else { return nil }
        switch first {
        case "N": return MorphKey.posShortNoun
        case "V": return MorphKey.posShortVerb
        case "A": return MorphKey.posShortAdjective
        case "R": return MorphKey.posShortPreposition
        case "C": return MorphKey.posShortConjunction
        case "D": return MorphKey.posShortAdverb
        case "P": return MorphKey.posShortPronoun
        case "I": return MorphKey.posShortInterjection
        case "T":
            guard ch.count > 1 else { return MorphKey.posShortParticle }
            switch ch[1] {
            case "d": return MorphKey.posShortArticle
            case "r": return MorphKey.posShortRelPronoun
            case "n": return MorphKey.posShortNegParticle
            case "i": return MorphKey.posShortInterrogative
            default:  return MorphKey.posShortParticle
            }
        case "S":
            guard ch.count > 1 else { return MorphKey.posShortSuffix }
            switch ch[1] {
            case "p": return MorphKey.posShortPronSuffix
            case "d": return MorphKey.posShortDirObjSuffix
            default:  return MorphKey.posShortSuffix
            }
        default: return nil
        }
    }

    // MARK: Lexical class → POS label

    /// Maps Macula TSV `class` values to localized POS strings.
    /// Returns nil for unknown/unrecognised class values so the morph-derived
    /// partOfSpeech remains untouched.
    static func lexicalClassLabel(
        _ cls: String,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> String? {
        switch cls {
        case "noun":  return t.string(for: MorphKey.posNoun)
        case "verb":  return t.string(for: MorphKey.posVerb)
        case "adj":   return t.string(for: MorphKey.posAdjective)
        case "adv":   return t.string(for: MorphKey.posAdverb)
        case "prep":  return t.string(for: MorphKey.posPreposition)
        case "cj":    return t.string(for: MorphKey.posConjunction)
        case "conj":  return t.string(for: MorphKey.posConjunction)  // Greek alias
        case "pron":  return t.string(for: MorphKey.posPronoun)
        case "ij", "intj": return t.string(for: MorphKey.posInterjection)
        case "art":   return t.string(for: MorphKey.posArticle)
        case "ptcl":  return t.string(for: MorphKey.posParticle)
        case "rel":   return t.string(for: MorphKey.posRelPronoun)
        case "det":   return t.string(for: MorphKey.posArticle)      // Greek determiner
        case "num":   return t.string(for: MorphKey.posAdjective)    // numeral → adjective bucket
        case "om", "x": return nil  // object marker / suffix — let morph code handle
        default:      return nil
        }
    }


    // MARK: Full decode (for WordMeaningView detail)

    static func decodeFull(
        _ word: BibleWord,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> FullMorphology? {
        guard let code = word.morphology, !code.isEmpty else { return nil }
        // Для складеного слота розбираємо ГОЛОВУ, а не першу морфему — інакше
        // весь розбір походить від проклітики (див. `headMorpheme`).
        //
        // ADR-040: граматичні поля (особа/рід/число/відмінок/час/стан/спосіб/
        // порода/тип/…) уже прийшли з колонок `word`, заповнених для ГОЛОВИ
        // слота ще у `VerseTabContent.displayWords` — тут лишається розібрати
        // ЛИШЕ частину мови (і її підтип) із самого коду, бо код і далі є
        // джерелом правди для підтипу POS (артикль/присвійна частка/суфікс…),
        // а не для граматичних категорій.
        let head = headMorpheme(code)
        var m = FullMorphology()

        if head.contains("-") {
            // Грецький SBLGNT-код (дефісний, напр. "V-FAI-3S"). Частина мови —
            // з коду (пласка мапа `greekPartOfSpeech`, бо `class`/`type` не
            // розрізняють зворотний/взаємний/особовий займенник — усі три
            // мають однаковий `class='pron'`, див. знахідку 4 в ADR-040).
            // Решта категорій — з колонок, без жодного парсингу сегментів.
            let posStr = head.components(separatedBy: "-").first ?? head
            m.partOfSpeech = greekPartOfSpeech(posStr, t: t) ?? ""

            let person = word.person.flatMap { personValueLabel($0, t: t) }
            let gender = word.gender.flatMap { genderValueLabel($0, t: t) }
            let number = word.number.flatMap { numberValueLabel($0, t: t) }
            m.grammaticalForm = [person, gender, number].compactMap { $0 }.joined(separator: " ")

            if let raw = word.grCase { m.grCase = caseValueLabel(raw, t: t) ?? "" }
            if let raw = word.tense  { m.tense  = tenseValueLabel(raw, t: t) ?? "" }
            if let raw = word.voice  { m.voice  = voiceValueLabel(raw, t: t) ?? "" }
            if let raw = word.degree { m.degree = degreeValueLabel(raw, t: t) ?? "" }
            // `mood` розводиться на два рядки (ADR-040, рецензія Opus): 4
            // справжні способи (дійсний/наказовий/умовний/бажальний) →
            // «Спосіб»; дієприкметник/інфінітив — не спосіб дієслова, а
            // окрема неособова форма → «Неособова форма».
            if let raw = word.mood {
                if let label = moodValueLabel(raw, t: t) {
                    m.mood = label
                } else if let label = nonFiniteFormLabel(raw, t: t) {
                    m.nonFiniteForm = label
                }
            }
        } else {
            let chars = Array(head)
            if let first = chars.first {
                switch first {
                case "V": m.partOfSpeech = t.string(for: MorphKey.posVerb)
                case "N": m.partOfSpeech = t.string(for: MorphKey.posNoun)
                case "A": m.partOfSpeech = t.string(for: MorphKey.posAdjective)
                case "T": m.partOfSpeech = chars.count > 1 ? particleLabel(chars[1], t: t) : t.string(for: MorphKey.posParticle)
                case "R": m.partOfSpeech = t.string(for: MorphKey.posPreposition)
                case "C": m.partOfSpeech = t.string(for: MorphKey.posConjunction)
                case "P": m.partOfSpeech = t.string(for: MorphKey.posPronoun)
                case "D": m.partOfSpeech = t.string(for: MorphKey.posAdverb)
                case "I": m.partOfSpeech = t.string(for: MorphKey.posInterjection)
                case "S": m.partOfSpeech = chars.count > 1 ? suffixLabel(chars[1], t: t) : t.string(for: MorphKey.posPronSuffix)
                default: break
                }
            }

            if let raw = word.stem, let label = hebrewStemLabel(raw, t: t) { m.stem = label }
            // «Тип» (було «Форма» — рішення 2026-09-11, збіг із «Форма у
            // [вірш]»). Лише 11 дієслівних значень `morph_type`; іменникові й
            // займенникові підтипи (common/proper/pronominal/…) імпортовані,
            // але в UI v1 не показуються (ADR-040, знахідка 5).
            if let raw = word.morphType, let label = hebrewAspectLabel(raw, t: t) { m.aspect = label }

            let person = word.person.flatMap { personValueLabel($0, t: t) }
            let gender = word.gender.flatMap { genderValueLabel($0, t: t) }
            let number = word.number.flatMap { numberValueLabel($0, t: t) }
            let state  = word.state.flatMap  { stateValueLabel($0, t: t) }
            m.grammaticalForm = [person, gender, number, state].compactMap { $0 }.joined(separator: " ")
        }

        // lexical_class — авторитетне джерело POS, застосовується останнім і
        // перекриває розбір коду вище. Напр. H835a: код 'Ncmpc' → «Іменник»,
        // але class='ij' → «Вигук».
        if let cls = word.lexicalClass, let posLabel = lexicalClassLabel(cls, using: t) {
            m.partOfSpeech = posLabel
        }
        m.composition = composition(code, lexicalClass: word.lexicalClass, using: t)
        return m
    }

    private static func suffixLabel(_ c: Character, t: TranslationProvider) -> String {
        switch c {
        case "p": return t.string(for: MorphKey.posPronSuffix)
        case "d": return t.string(for: MorphKey.posDirObjSuffix)
        default:  return t.string(for: MorphKey.posSuffix)
        }
    }

    /// Канонічна АНГЛІЙСЬКА назва породи — ключ звірки з підписами секцій BDB
    /// (ADR-033). Бере значення напряму з колонки `word.stem` (уже англійське
    /// слово з Macula TSV — "niphal", "hithpael", "qal passive"…) замість
    /// парсингу другого символу стисненого коду. ADR-040 закриває цим одразу
    /// два баги: (1) розширює покриття з 8 до 34 порід/арам. еквівалентів —
    /// раніше рідкісні породи (Polel, Pilpel, Hithpolel, …) мовчки повертали
    /// nil; (2) для складеного гебрайського слота (`C·Vqp3ms`) стара функція
    /// парсила ПЕРШИЙ символ склеєного рядка (проклітику) й теж повертала
    /// nil — тепер `word.stem` завжди належить голові слота (заповнено ще у
    /// `VerseTabContent.displayWords`), тож складені слоти більше не губляться.
    ///
    /// nil для невербальних слотів (`word.stem` порожній). Пробіл у
    /// "qal passive" прибирається — `normalizedStem(_:)` у WordMeaningView
    /// порівнює обидві сторони без пробілів і крапок.
    static func canonicalHebrewStem(_ word: BibleWord) -> String? {
        word.stem?.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private static func hebrewStemLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "qal":         return t.string(for: MorphKey.stemQal)
        case "niphal":      return t.string(for: MorphKey.stemNiphal)
        case "piel":        return t.string(for: MorphKey.stemPiel)
        case "pual":        return t.string(for: MorphKey.stemPual)
        case "hiphil":      return t.string(for: MorphKey.stemHiphil)
        case "hophal":      return t.string(for: MorphKey.stemHophal)
        case "hithpael":    return t.string(for: MorphKey.stemHithpael)
        case "poel":        return t.string(for: MorphKey.stemPoel)
        case "peal":        return t.string(for: MorphKey.stemPeal)
        case "peil":        return t.string(for: MorphKey.stemPeil)
        case "pael":        return t.string(for: MorphKey.stemPael)
        case "haphel":      return t.string(for: MorphKey.stemHaphel)
        case "aphel":       return t.string(for: MorphKey.stemAphel)
        case "shaphel":     return t.string(for: MorphKey.stemShaphel)
        case "saphel":      return t.string(for: MorphKey.stemSaphel)
        case "hithpaal":    return t.string(for: MorphKey.stemHithpaal)
        case "ithpaal":     return t.string(for: MorphKey.stemIthpaal)
        case "hithpeel":    return t.string(for: MorphKey.stemHithpeel)
        case "ithpeel":     return t.string(for: MorphKey.stemIthpeel)
        case "ithpoel":     return t.string(for: MorphKey.stemIthpoel)
        case "hishtaphel":  return t.string(for: MorphKey.stemHishtaphel)
        case "nithpael":    return t.string(for: MorphKey.stemNithpael)
        case "hithpolel":   return t.string(for: MorphKey.stemHithpolel)
        case "hithpalpel":  return t.string(for: MorphKey.stemHithpalpel)
        case "polel":       return t.string(for: MorphKey.stemPolel)
        case "polal":       return t.string(for: MorphKey.stemPolal)
        case "polpal":      return t.string(for: MorphKey.stemPolpal)
        case "pilpel":      return t.string(for: MorphKey.stemPilpel)
        case "pilel":       return t.string(for: MorphKey.stemPilel)
        case "palel":       return t.string(for: MorphKey.stemPalel)
        case "pealal":      return t.string(for: MorphKey.stemPealal)
        case "poal":        return t.string(for: MorphKey.stemPoal)
        case "pulal":       return t.string(for: MorphKey.stemPulal)
        case "qal passive": return t.string(for: MorphKey.stemQalPassive)
        default:            return nil   // сентинели unknown:* вже None з build_db.py
        }
    }

    /// «Тип» (гебр. `morph_type`) — лише 11 дієслівно-релевантних значень.
    /// Решта (`common`/`proper`/`pronominal`/`definite article`/… — та сама
    /// колонка, значення для іменників/часток) імпортовані, але в UI v1 не
    /// показуються (ADR-040, знахідка 5): недостатньо цінності для
    /// богословського читання, можна додати пізніше без нової збірки.
    private static func hebrewAspectLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "qatal":                  return t.string(for: MorphKey.aspectPerfect)
        case "yiqtol":                 return t.string(for: MorphKey.aspectImperfect)
        case "wayyiqtol":              return t.string(for: MorphKey.aspectWayyiqtol)
        case "weqatal":                return t.string(for: MorphKey.aspectWeqatal)
        case "jussive":                return t.string(for: MorphKey.aspectJussive)
        case "cohortative":            return t.string(for: MorphKey.aspectCohortative)
        case "imperative":             return t.string(for: MorphKey.aspectImperative)
        case "participle active":      return t.string(for: MorphKey.aspectParticipleActive)
        case "participle passive":     return t.string(for: MorphKey.aspectParticiplePassive)
        case "infinitive absolute":    return t.string(for: MorphKey.aspectInfAbsolute)
        case "infinitive construct":   return t.string(for: MorphKey.aspectInfConstruct)
        default:                       return nil
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

    // MARK: Значення граматичних категорій → підпис (обидві мови, спільні поля)

    private static func personValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "first":  return t.string(for: MorphKey.person1)
        case "second": return t.string(for: MorphKey.person2)
        case "third":  return t.string(for: MorphKey.person3)
        default:       return nil
        }
    }

    private static func genderValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "masculine":       return t.string(for: MorphKey.genderMasculine)
        case "feminine":        return t.string(for: MorphKey.genderFeminine)
        case "common", "both":  return t.string(for: MorphKey.genderCommon)
        case "neuter":          return t.string(for: MorphKey.genderNeuter)
        default:                return nil
        }
    }

    private static func numberValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "singular": return t.string(for: MorphKey.numberSingular)
        case "plural":   return t.string(for: MorphKey.numberPlural)
        case "dual":     return t.string(for: MorphKey.numberDual)
        default:         return nil
        }
    }

    private static func stateValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "absolute":   return t.string(for: MorphKey.stateAbsolute)
        case "construct":  return t.string(for: MorphKey.stateConstruct)
        case "determined": return t.string(for: MorphKey.stateDetermined)
        default:           return nil
        }
    }

    // MARK: Значення граматичних категорій → підпис (лише грецька)

    private static func caseValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "nominative": return t.string(for: MorphKey.caseNominative)
        case "genitive":   return t.string(for: MorphKey.caseGenitive)
        case "dative":     return t.string(for: MorphKey.caseDative)
        case "accusative": return t.string(for: MorphKey.caseAccusative)
        case "vocative":   return t.string(for: MorphKey.caseVocative)
        default:           return nil
        }
    }

    private static func tenseValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "aorist":      return t.string(for: MorphKey.tenseAorist)
        case "present":     return t.string(for: MorphKey.tensePresent)
        case "imperfect":   return t.string(for: MorphKey.tenseImperfect)
        case "future":      return t.string(for: MorphKey.tenseFuture)
        case "perfect":     return t.string(for: MorphKey.tensePerfect)
        case "pluperfect":  return t.string(for: MorphKey.tensePluperfect)
        default:            return nil
        }
    }

    private static func voiceValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "active":         return t.string(for: MorphKey.voiceActive)
        case "middle":         return t.string(for: MorphKey.voiceMiddle)
        case "passive":        return t.string(for: MorphKey.voicePassive)
        case "middlepassive":  return t.string(for: MorphKey.voiceMiddlePassive)
        default:               return nil
        }
    }

    /// Лише 4 справжні способи. `participle`/`infinitive` — див.
    /// `nonFiniteFormLabel` нижче: це неособова форма, не спосіб дієслова.
    private static func moodValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "indicative":  return t.string(for: MorphKey.moodIndicative)
        case "imperative":  return t.string(for: MorphKey.moodImperative)
        case "subjunctive": return t.string(for: MorphKey.moodSubjunctive)
        case "optative":    return t.string(for: MorphKey.moodOptative)
        default:            return nil
        }
    }

    private static func nonFiniteFormLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "participle": return t.string(for: MorphKey.nonFiniteParticiple)
        case "infinitive": return t.string(for: MorphKey.nonFiniteInfinitive)
        default:            return nil
        }
    }

    private static func degreeValueLabel(_ raw: String, t: TranslationProvider) -> String? {
        switch raw {
        case "comparative": return t.string(for: MorphKey.degreeComparative)
        case "superlative": return t.string(for: MorphKey.degreeSuperlative)
        default:             return nil
        }
    }

    // MARK: Short decode (for WordCard — Оригінал pill)

    static func decode(
        _ word: BibleWord,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> String? {
        guard let code = word.morphology, !code.isEmpty else { return nil }
        // Складене слово показує СКЛАД («арт. + ім.»), а не саму лише частину
        // мови голови. «Іменник» для הַדַּעַת приховує, що артикль узагалі є —
        // і що номер Стронга поруч стосується лише кореня.
        let composed = composition(code, lexicalClass: word.lexicalClass, using: t)
        if !composed.isEmpty { return composed }

        // Одноморфемне слово — ТОЙ САМИЙ скорочений підпис, що й у складі.
        // Інакше список читався б у двох регістрах одразу: «Дієслово» в одному
        // рядку і «арт. + ім.» у сусідньому.
        if let short = shortLabel(code, lexicalClass: word.lexicalClass, using: t) {
            return short
        }

        // Останній рубіж: підпису-скорочення для цього коду немає. Беремо
        // повну назву й гасимо лише регістр першої літери, щоб рядок лишався
        // однорідним.
        return decodeOne(word, using: t).map(lowercasedFirst)
    }

    /// «Дієслово» → «дієслово». Тільки перша літера: решта може бути власною
    /// назвою породи («Niphal»), і повний `lowercased()` її б зіпсував.
    private static func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).lowercased() + s.dropFirst()
    }

    /// Розбір ОДНІЄЇ морфеми — фолбек, коли ні `composition`, ні `shortLabel`
    /// нічого не дали (лишається практично мертвою гілкою: `lexicalClass`
    /// покриває майже всі реальні випадки, див. знахідки ADR-040). ADR-040:
    /// граматичні категорії — з колонок `word`, лише частина мови — з коду.
    fileprivate static func decodeOne(
        _ word: BibleWord,
        using t: TranslationProvider = BundleTranslationProvider()
    ) -> String? {
        guard let code = word.morphology, !code.isEmpty else { return nil }
        var parts: [String] = []

        if code.contains("-") {
            let posStr = code.components(separatedBy: "-").first ?? code
            guard let posLabel = greekPartOfSpeech(posStr, t: t) else { return nil }
            parts.append(posLabel)
            if let raw = word.number, let label = numberValueLabel(raw, t: t) { parts.append(label) }
        } else {
            guard let first = code.first else { return nil }
            switch first {
            case "N": parts.append(t.string(for: MorphKey.posNoun))
            case "V": parts.append(t.string(for: MorphKey.posVerb))
            case "A": parts.append(t.string(for: MorphKey.posAdjective))
            case "T":
                let chars = Array(code)
                parts.append(chars.count > 1 ? particleLabel(chars[1], t: t) : t.string(for: MorphKey.posParticle))
            case "R": parts.append(t.string(for: MorphKey.posPreposition))
            case "C": parts.append(t.string(for: MorphKey.posConjunction))
            case "P": parts.append(t.string(for: MorphKey.posPronoun))
            case "D": parts.append(t.string(for: MorphKey.posAdverb))
            case "I": parts.append(t.string(for: MorphKey.posInterjection))
            case "S": parts.append(t.string(for: MorphKey.posPronSuffix))
            default: return nil
            }
            if first == "V", let raw = word.stem, let label = hebrewStemLabel(raw, t: t) {
                parts.append(label)
            }
            if (first == "N" || first == "A"), let raw = word.number, raw != "singular",
               let label = numberValueLabel(raw, t: t) {
                parts.append(label)
            }
        }

        // lexicalClass — авторитетне джерело POS, як і в decodeFull (напр.
        // грецьке G3326 без дефіса, де морф-розбір неоднозначний).
        if let cls = word.lexicalClass, let posLabel = lexicalClassLabel(cls, using: t) {
            return posLabel
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Грецька частина мови з коду (bug-053) — пласка мапа, без парсингу
    // сегментів. `class`/`gr_type` НЕ розрізняють зворотний/взаємний/
    // особовий займенник (усі три — `class='pron'`), тож код лишається
    // джерелом підтипу POS. Виміряно на корпусі 2026-09-05/09-11: 22 реальні
    // префікси (ADR-040 називає їх 21 — уточнено під час реалізації).
    private static func greekPartOfSpeech(_ posStr: String, t: TranslationProvider) -> String? {
        switch posStr.uppercased() {
        case "N":    return t.string(for: MorphKey.posNoun)
        case "V":    return t.string(for: MorphKey.posVerb)
        case "A":    return t.string(for: MorphKey.posAdjective)
        case "ADV":  return t.string(for: MorphKey.posAdverb)
        case "CONJ": return t.string(for: MorphKey.posConjunction)
        case "INJ":  return t.string(for: MorphKey.posInterjection)
        case "P":    return t.string(for: MorphKey.posPersonalPronoun)      // fix bug-053: НЕ прийменник
        case "PREP": return t.string(for: MorphKey.posPreposition)
        case "T":    return t.string(for: MorphKey.posArticle)
        case "PRT":  return t.string(for: MorphKey.posParticle)
        case "D":    return t.string(for: MorphKey.posDemonstrativePronoun)
        case "R":    return t.string(for: MorphKey.posRelPronoun)
        case "I":    return t.string(for: MorphKey.posInterrogativePronoun)
        case "X":    return t.string(for: MorphKey.posIndefinitePronoun)
        case "F":    return t.string(for: MorphKey.posReflexivePronoun)
        case "S":    return t.string(for: MorphKey.posPossessivePronoun)
        case "K":    return t.string(for: MorphKey.posCorrelativePronoun)
        case "Q":    return t.string(for: MorphKey.posCorrelativePronoun)
        case "C":    return t.string(for: MorphKey.posReciprocalPronoun)
        case "HEB":  return t.string(for: MorphKey.posHebrewTerm)
        case "ARAM": return t.string(for: MorphKey.posAramaicTerm)
        case "COND": return t.string(for: MorphKey.posConjunction)
        default:     return nil
        }
    }
}

// MARK: - Word Row

/// Flat list row displayed in OriginalWordsView for each word in a verse.
/// Clickable rows (isClickable: true) navigate to Word/Meaning detail on tap.
/// Non-clickable rows (particles, articles) display basic info only — no tap, no chevron.
struct WordRow: View {
    let word: BibleWord
    let isSelected: Bool
    let isClickable: Bool
    let onTap: () -> Void

    private let t: TranslationProvider = BundleTranslationProvider()

    var body: some View {
        if isClickable {
            Button(action: onTap) {
                rowContent(showChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(showChevron: false)
        }
    }

    private var morphLabel: String? {
        MorphologyDecoder.decode(word, using: t)
    }

    private func rowContent(showChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                // Top line: Hebrew/Greek text · xlit · Strong's badge · morph
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.displayText)
                        .font(.title3)
                        .foregroundStyle(.primary)

                    if let xlit = word.bestXlit, !xlit.isEmpty {
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

                    // Морфологія лишається в тому ж рядку — і для однослівних, і для
                    // складених. Окремий рядок «лише для складених» (спроба 2026-08-03)
                    // давав рвану висоту рядків у списку.
                    //
                    // `fixedSize(vertical:)` дозволяє САМІЙ морфології перенестись на
                    // наступний рядок, коли складу забагато («спол. + дієсл. + займ.
                    // суф.»), замість обрізання. Перший рядок при цьому лишається на
                    // спільній базовій лінії з івритом і транслітерацією — переноситься
                    // тільки хвіст.
                    if let label = morphLabel {
                        Text(label)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Bottom line: gloss — show for all words that have one, clickable or not
                if let gloss = word.gloss, !gloss.isEmpty {
                    Text(gloss)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }

            Spacer(minLength: 8)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

