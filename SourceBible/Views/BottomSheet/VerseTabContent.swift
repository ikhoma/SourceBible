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

    @State private var refs: [CrossReference] = []
    @State private var parallels: [VerseTranslation] = []

    var body: some View {
        Group {
            switch pill {
            case .crossRefs:    CrossRefsView(refs: refs)
            case .translations: TranslationsView(parallels: parallels)
            case .original:     OriginalWordsView().environmentObject(vm)
            case .commentaries: CommentariesView(verseId: verse.id)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .onAppear        { loadData() }
        .onChange(of: verse.id)                 { loadData() }
        .onChange(of: vm.currentTranslation.id) { loadData() }
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

// MARK: - Cross Refs

struct CrossRefsView: View {
    let refs: [CrossReference]

    var body: some View {
        PillSection(title: "verse.section.cross_refs") {
            if refs.isEmpty {
                Text("verse.cross_refs.empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(refs) { ref in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.targetReference)
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
                        if ref.targetText.isEmpty {
                            Text("verse.text_unavailable")
                                .font(.callout).foregroundStyle(.tertiary).italic()
                        } else {
                            Text(ref.targetText)
                                .font(.callout).lineSpacing(3)
                        }
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
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
                        Text(vt.text)
                            .font(.callout).lineSpacing(3)
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

    /// Always read from vm.selectedVerse so we get words after lazy load,
    /// not a stale snapshot from the moment the sheet opened.
    private var words: [BibleWord] {
        (vm.selectedVerse?.words ?? []).filter { $0.strongsId != nil }
    }

    var body: some View {
        PillSection(title: "verse.section.original") {
            if words.isEmpty {
                Text("verse.original.empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(words) { word in
                        WordCard(
                            word: word,
                            isSelected: vm.selectedWord?.id == word.id
                        ) {
                            if let verse = vm.selectedVerse {
                                vm.tapWord(word, in: verse)
                            }
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
    @State private var selectedTheologian: Theologian? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        PillSection(title: "verse.section.commentaries") {
            ForEach(Theologian.all) { t in
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
                            // Text + Text concatenation deprecated in iOS 26; use interpolation.
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
        .sheet(item: $selectedTheologian) { t in
            NavigationStack {
                CommentaryDetailView(theologian: t, verseId: verseId)
            }
        }
    }
}

// MARK: - Commentary Detail

struct CommentaryDetailView: View {
    let theologian: Theologian
    let verseId: String
    var body: some View {
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
                Text("verse.commentary.placeholder")
                    .font(.body).lineSpacing(6).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(LocalizedStringKey(theologian.nameKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}
