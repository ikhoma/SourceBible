// VerseTabContent.swift
// SourceBible
//
// Вміст вкладки "Вірш" у VerseBottomSheetView.
// Типи: VerseTabView · VersePill · PillSection · CrossRefsView ·
//       TranslationsView · OriginalWordsView · CommentariesView · CommentaryDetailView
//
// Shared helpers (internal — доступні WordTabContent у тому ж таргеті):
//   PillSection, sectionHeader(_:)

import SwiftUI

// MARK: - Verse Tab

struct VerseTabView: View {

    let verse: BibleVerse
    let pill: VersePill
    @EnvironmentObject var vm: ReaderViewModel
    @Environment(\.sessionTracker) private var tracker

    @State private var refs: [CrossReference] = []
    @State private var parallels: [VerseTranslation] = []

    var body: some View {
        Group {
            switch pill {
            case .crossRefs:
                CrossRefsView(refs: refs)
                    .onAppear { tracker.recordFeatureUse(.crossReference) }
            case .translations:
                TranslationsView(parallels: parallels)
                    .onAppear { tracker.recordFeatureUse(.parallelTranslation) }
            case .original:
                OriginalWordsView().environmentObject(vm)
                    .onAppear { tracker.recordFeatureUse(.original) }
            case .commentaries:
                CommentariesView(verseId: verse.id)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .onAppear        { loadData() }
        .onChange(of: verse.id)                 { _, _ in loadData() }
        .onChange(of: vm.currentTranslation.id) { _, _ in loadData() }
    }

    private func loadData() {
        refs      = vm.loadCrossReferences()
        parallels = vm.loadParallelVerses()
    }
}

// MARK: - Verse Pill

enum VersePill: CaseIterable {
    case crossRefs, translations, original, commentaries
    // LocalizedStringKey so Text(p.label) responds to .environment(\.locale)
    var label: LocalizedStringKey {
        switch self {
        case .crossRefs:    return "verse.pill.cross_refs"
        case .translations: return "verse.pill.translations"
        case .original:     return "verse.pill.original"
        case .commentaries: return "verse.pill.commentaries"
        }
    }
}

// MARK: - Pill Section Container
// Single source of truth for header + content spacing across all pill views.
// Internal (not private) so WordTabContent can reuse it.

struct PillSection<Content: View>: View {
    // Stored as AnyView so we can support both LocalizedStringKey (static keys)
    // and String (pre-formatted runtime strings like "Used 5 times") without a
    // localization lookup for the latter.
    private let headerView: AnyView
    @ViewBuilder let content: () -> Content

    /// Use for static localized section titles passed as string literals.
    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.headerView = AnyView(sectionHeader(title))
        self.content = content
    }

    /// Use for dynamically-composed strings that are already localized
    /// (e.g. built with String(format:…)). Uses Text(verbatim:) to skip lookup.
    /// NOTE: Use `verbatimTitle:` label explicitly so string literals always resolve to
    /// the LocalizedStringKey overload above (Swift prefers String for bare literals).
    init(verbatimTitle title: String, @ViewBuilder content: @escaping () -> Content) {
        self.headerView = AnyView(
            Text(verbatim: title)
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
        )
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            content()
        }
        // Full-width anchor prevents the VStack from shrinking to content width
        // in the empty-state (narrow text), which would mis-center the section
        // header relative to where it sits when content fills the panel.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared section header
// Internal — used by PillSection init(title: LocalizedStringKey).

func sectionHeader(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
}

// MARK: - Reference Label
// Single source of truth for scripture-place labels ("Book Chapter:Verse")
// in cards across cross-refs and word-usage. Internal so WordTabContent reuses it.

struct ReferenceLabel: View {
    private let text: Text

    init(_ string: String) { self.text = Text(string) }
    init(_ key: LocalizedStringKey) { self.text = Text(key) }

    var body: some View {
        text
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
    }
}

// MARK: - Cross Refs

struct CrossRefsView: View {
    let refs: [CrossReference]

    @EnvironmentObject private var vm: ReaderViewModel
    @EnvironmentObject private var router: AppNavigationRouter

    var body: some View {
        if refs.isEmpty {
            // Full-height centered empty state — Spacers need the container to
            // have a defined height, which .containerRelativeFrame provides by
            // sizing against the scroll view's visible frame (iOS 17+).
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "link")
                    .font(.system(size: 48)).foregroundStyle(.quaternary)
                VStack(spacing: 4) {
                    Text("verse.cross_refs.empty")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 200)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame([.vertical])
        } else {
            PillSection(title: "verse.section.cross_refs") {
                ForEach(refs) { ref in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            ReferenceLabel(ref.targetReference)
                            // bug-007: never print the fallback (English) text next to
                            // the active translation. Versification is resolved in
                            // DatabaseService.loadCrossReferences, so isFallback here
                            // means the translation genuinely has no text for the verse
                            // — show the placeholder rather than silently mixing languages.
                            if ref.targetText.isEmpty || ref.isFallback {
                                Text("verse.text_unavailable")
                                    .font(.callout).foregroundStyle(.tertiary).italic()
                            } else {
                                Text(ref.targetText)
                                    .font(.callout)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // ADR-024: use followCrossReference (direct VM call, pushes back stack)
                        // instead of router.requestNavigation (cross-tab hop, not needed here).
                        vm.followCrossReference(to: "\(ref.bookId)|\(ref.chapter)|\(ref.verse)")
                    }
                    .padding(.bottom, 8)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Translations

struct TranslationsView: View {
    let parallels: [VerseTranslation]

    var body: some View {
        PillSection(title: "verse.section.translations") {
            if parallels.isEmpty {
                Text("verse.translations.empty")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(parallels) { vt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vt.translation.name)
                            .font(.footnote).fontWeight(.semibold).foregroundStyle(.primary)
                        Text(vt.text)
                            .font(.callout)
                    }
                    .padding(.bottom, 8)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Original Words

struct OriginalWordsView: View {
    @EnvironmentObject var vm: ReaderViewModel

    /// All Macula tokens for the verse (raw; use `displayWords` for rendering).
    private var words: [BibleWord] {
        vm.selectedVerse?.words ?? []
    }

    private var sectionTitleKey: LocalizedStringKey {
        vm.currentBook.testament == .old
            ? "verse.section.original.hebrew"
            : "verse.section.original.greek"
    }

    // MARK: – Slot combining

    // NOTE: a `helperStrongs` allow-list used to live here and was used to pick each slot's
    // root token as "the first token whose Strong's is not in the list". It has been removed,
    // not extended, and it should not come back. Derived from Psalm 1, it was missing לְ
    // (H3807a) and מִן (H4480) — so for ~21K words the leading PREPOSITION was selected as the
    // head, and every such word opened the lexicon on the preposition instead of the noun
    // (8.5% of all Hebrew words; e.g. Gen 1:5 לָאוֹר reported H3807a "Preposition" not H216
    // "light"). It also mislabeled H1930a as לְ, which it is not. Head selection is now
    // derived from morphology — see `headToken(of:)`. Keep it that way.

    /// The head (root) token of a slot — the word the reader is actually tapping.
    ///
    /// Hebrew builds a slot as `[proclitics…] HEAD [enclitics…]`: inseparable prepositions,
    /// the article and the waw attach to the FRONT, pronominal suffixes to the BACK. So the
    /// head is the last token that is not an enclitic.
    ///
    /// Enclitic = pronominal suffix (Macula `morph` begins with `S`, e.g. `Sp3ms`) or an
    /// enclitic particle (`class == "x"`). This is why we key on morphology rather than on a
    /// Strong's allow-list: `pron` alone is ambiguous — `Sp3ms` is a suffix and never a head,
    /// while `Pp3ms` (independent pronoun, e.g. וְהוּא) IS the head. `class` alone is ambiguous
    /// too — proclitic לְ and standalone בֵּין are both `prep` with `morph == "R"`.
    ///
    /// Validated against BSB's independent Strong's assignment over 274,474 slots:
    /// first-non-helper (old) 9.20% wrong → this rule 1.75%, of which 0.81% are single-token
    /// slots where Macula and BSB simply disagree lexically (H7473 vs H7462 for רֹעֶה).
    /// True alignment error: 0.94%. See ADR-020.
    private static func headToken(of tokens: [BibleWord]) -> BibleWord {
        tokens.last(where: { !isEnclitic($0) }) ?? tokens[tokens.count - 1]
    }

    private static func isEnclitic(_ word: BibleWord) -> Bool {
        if word.lexicalClass == "x" { return true }               // enclitic particle
        return word.morphology?.hasPrefix("S") ?? false           // pronominal suffix
    }

    /// Words grouped by Macula slot → one display row per Hebrew word.
    /// Greek verses (slot == nil for all tokens) are returned unchanged.
    private var displayWords: [BibleWord] {
        guard !words.isEmpty, words.first?.slot != nil else { return words }

        // Group consecutive tokens that share the same slot value
        var groups: [[BibleWord]] = []
        var current: [BibleWord] = []
        var currentSlot: Int? = nil

        for word in words {
            guard let s = word.slot else {
                // Safety fallback: a token with no slot stands alone
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

        // Merge each group into one representative BibleWord
        return groups.map { tokens in
            guard tokens.count > 1 else { return tokens[0] }
            // Head = last non-enclitic token (carries Strong's, xlit, tap target).
            // NOT "first non-helper" — that picked the leading preposition. See headToken(of:).
            let root = Self.headToken(of: tokens)
            // Combined surface: concatenate each token's displayText (already includes afterChar)
            let surface   = tokens.map(\.displayText).joined()
            let gloss     = tokens.compactMap(\.gloss).filter { !$0.isEmpty }.joined(separator: " ")
            let morphology = tokens.compactMap(\.morphology).filter { !$0.isEmpty }.joined(separator: "·")
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
                // word, e.g. "lā-’ō-wr"), so read it from whichever token in the slot carries
                // it — NOT from the head. build_db.py currently writes it onto the token IT
                // considers the root, which is the leading preposition (same stale rule this
                // view just stopped using). Reading `root.xlitSlot` would therefore find nil
                // on the noun and silently downgrade the display to the bare token xlit
                // ("’ō-wr"). Once build_db.py adopts headToken's rule this still holds.
                xlitSlot: tokens.compactMap(\.xlitSlot).first
            )
        }
    }

    // MARK: – Body

    var body: some View {
        // Compute the clickable-id set ONCE per body evaluation. `clickableWordIDs`
        // rebuilds the whole verseWordSegmentPairs mapping on each access, so calling
        // vm.isClickable(word) per row was O(words²·segments) on every re-render.
        let clickableIDs = vm.clickableWordIDs
        return PillSection(title: sectionTitleKey) {
            if displayWords.isEmpty {
                Text("verse.original.empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayWords.enumerated()), id: \.element.id) { i, word in
                        WordRow(
                            word: word,
                            isSelected: vm.selectedWord?.id == word.id,
                            isClickable: clickableIDs.contains(word.id)
                        ) {
                            if let verse = vm.selectedVerse {
                                vm.tapWord(word, in: verse)
                            }
                        }
                        if i < displayWords.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Commentaries

struct CommentariesView: View {
    let verseId: String
    @Environment(\.colorTheme) private var colorTheme
    @State private var selectedTheologian: Theologian? = nil
    @State private var availableSources: Set<String> = []

    /// Book ID parsed from verseId "BOOK|chapter|verse"
    private var bookId: String {
        String(verseId.split(separator: "|").first ?? "")
    }

    /// (bookId, chapter, verse) parsed from verseId "BOOK|chapter|verse".
    private var verseComponents: (bookId: String, chapter: Int, verse: Int)? {
        let parts = verseId.split(separator: "|")
        guard parts.count == 3, let ch = Int(parts[1]), let vs = Int(parts[2]) else { return nil }
        return (String(parts[0]), ch, vs)
    }

    /// bug-016: only show theologians that have a NON-EMPTY section for THIS verse —
    /// not merely somewhere in the book. Calvin's modules are patchy (ADR-027), so a
    /// book-level check offered him on verses he does not cover, opening an empty page.
    private var visibleTheologians: [Theologian] {
        Theologian.all.filter { availableSources.contains($0.id.capitalized) }
    }

    var body: some View {
        Group {
            if visibleTheologians.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    VStack(spacing: 4) {
                        Text("verse.commentary.unavailable")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 200)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .containerRelativeFrame([.vertical])
            } else {
                PillSection(title: "verse.section.commentaries") {
                    ForEach(visibleTheologians) { t in
                    Button {
                        selectedTheologian = t
                    } label: {
                        HStack(spacing: 10) {
                            Image(t.imageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(t.nameKey))
                                    .font(.callout).fontWeight(.medium).foregroundStyle(.primary)
                                Text("\(Text(LocalizedStringKey(t.eraKey))) · \(Text(LocalizedStringKey(t.styleKey)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                    .foregroundStyle(.primary)
                    Divider()
                }
            }
        }
        }
        .task(id: verseId) {
            if let vc = verseComponents {
                availableSources = DatabaseService.shared.commentarySourcesAvailable(
                    bookId: vc.bookId, chapter: vc.chapter, verse: vc.verse)
            } else {
                // Unparseable verseId — fall back to book-level so we never hide everything.
                availableSources = DatabaseService.shared.commentarySourcesAvailable(bookId: bookId)
            }
        }
        .sheet(item: $selectedTheologian) { t in
            NavigationStack {
                CommentaryDetailView(theologian: t, verseId: verseId)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // Консистентний X-close для всіх sheet-ів (SheetCloseButton)
                            SheetCloseButton { selectedTheologian = nil }
                        }
                    }
            }
            // The stacked commentary sheet defaults to the system sheet surface
            // (white / systemBackground), which ignored the theme — it stayed cold
            // white under Incunable. presentationBackground paints the sheet itself
            // (not the content), so it also covers the area behind the nav bar and
            // the safe-area insets, matching VerseBottomSheetView's sheetBackground.
            .presentationBackground(colorTheme.sheetBackground)
        }
    }
}

// MARK: - Commentary Detail

struct CommentaryDetailView: View {
    let theologian: Theologian
    let verseId: String
    @Environment(\.sessionTracker) private var tracker
    @EnvironmentObject private var readerVM: ReaderViewModel

    /// Parsed from verseId "BOOK|chapter|verse"
    private var verseComponents: (bookId: String, chapter: Int, verse: Int)? {
        let parts = verseId.split(separator: "|")
        guard parts.count == 3,
              let ch = Int(parts[1]),
              let vs = Int(parts[2]) else { return nil }
        return (String(parts[0]), ch, vs)
    }

    /// "Ps 1:3 — J. Calvin" or "Ps 1:1–3 — J. Calvin" once the section is loaded.
    private var detailTitle: String {
        guard let vc = verseComponents else { return theologian.shortName }
        let book = readerVM.shortBookName(for: vc.bookId)
        let ref: String
        if let sec = section {
            if sec.startChapter == sec.endChapter {
                if sec.startVerse == sec.endVerse {
                    ref = "\(book) \(sec.startChapter):\(sec.startVerse)"
                } else {
                    ref = "\(book) \(sec.startChapter):\(sec.startVerse)–\(sec.endVerse)"
                }
            } else {
                ref = "\(book) \(sec.startChapter):\(sec.startVerse)–\(sec.endChapter):\(sec.endVerse)"
            }
        } else {
            ref = "\(book) \(vc.chapter):\(vc.verse)"
        }
        return "\(ref) — \(theologian.shortName)"
    }

    @State private var section: CommentarySection? = nil
    @State private var isLoaded = false

    var body: some View {
        Group {
            if !isLoaded {
                // Loading spinner — centered in the full sheet
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sec = section {
                // Has commentary — scrollable page with theologian header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(theologian.imageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(theologian.nameKey)).font(.headline)
                                Text("\(Text(LocalizedStringKey(theologian.eraKey))) · \(Text(LocalizedStringKey(theologian.styleKey)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        // Use UITextView for commentary body — SwiftUI Text() silently
                        // fails to render very large strings (Owen sections can exceed
                        // 230,000 characters). UITextView handles arbitrary length text.
                        CommentaryTextView(text: sec.text)
                    }
                    .padding(20)
                }
            } else {
                // No commentary for this verse — full-screen centered empty state
                VStack(spacing: 16) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    VStack(spacing: 4) {
                        Text("verse.commentary.unavailable")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tracker.recordFeatureUse(.commentary) }
        .task(id: verseId) {
            await loadCommentary()
        }
    }

    @MainActor
    private func loadCommentary() async {
        isLoaded = false
        section = nil
        defer { isLoaded = true }  // always mark loaded, even if guard/early-return fires
        guard let vc = verseComponents else { return }
        section = DatabaseService.shared.loadCommentary(
            bookId: vc.bookId, chapter: vc.chapter, verse: vc.verse,
            source: theologian.id.capitalized  // "Calvin", "Henry", etc.
        )
    }
}

// MARK: - CommentaryTextView

/// Paragraph-split commentary renderer.
///
/// SwiftUI `Text` silently fails on very large strings — Owen's Heb 1:1-2
/// is ~231,000 characters, which SwiftUI can't lay out in a single pass.
/// Splitting on paragraph breaks and rendering each chunk as a separate `Text`
/// keeps individual views small while `LazyVStack` defers off-screen rendering,
/// making it performant for any commentary length.
private struct CommentaryTextView: View {
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.body)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
