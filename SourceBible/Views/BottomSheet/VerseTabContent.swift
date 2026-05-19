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
    var label: String {
        switch self {
        case .crossRefs:    return "Перехресні"
        case .translations: return "Переклади"
        case .original:     return "Оригінал"
        case .commentaries: return "Коментарі"
        }
    }
}

// MARK: - Pill Section Container
// Single source of truth for header + content spacing across all pill views.
// Internal (not private) so WordTabContent can reuse it.

struct PillSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)
            content()
        }
    }
}

// MARK: - Shared section header
// Internal — used by PillSection, WordMeaningView, WordUsageView.

func sectionHeader(_ text: String) -> some View {
    Text(text)
        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
}

// MARK: - Cross Refs

struct CrossRefsView: View {
    let refs: [CrossReference]

    var body: some View {
        PillSection(title: "Перехресні посилання") {
            if refs.isEmpty {
                Text("Немає перехресних посилань для цього вірша")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(refs) { ref in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.targetReference)
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
                        if ref.targetText.isEmpty {
                            Text("Текст недоступний")
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
        PillSection(title: "Переклади") {
            if parallels.isEmpty {
                Text("Немає доступних перекладів")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(parallels) { vt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vt.translation.name)
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
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
        PillSection(title: "Оригінальні слова") {
            if words.isEmpty {
                Text("Дані оригінальної мови недоступні")
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

    var body: some View {
        PillSection(title: "Коментарі") {
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
                            Text(t.name).font(.callout).fontWeight(.medium).foregroundStyle(.primary)
                            Text("\(t.era) · \(t.style)").font(.caption).foregroundStyle(.secondary)
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
                        Text(theologian.name).font(.headline)
                        Text("\(theologian.era) · \(theologian.style)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Коментар буде завантажений з public domain бази даних (Кальвін, Генрі, Сперджен).")
                    .font(.body).lineSpacing(6).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(theologian.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
