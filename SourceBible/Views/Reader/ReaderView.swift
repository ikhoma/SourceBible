// ReaderView.swift
// SourceBible

import SwiftUI

struct ReaderView: View {

    @EnvironmentObject var vm:          ReaderViewModel
    @EnvironmentObject var notesVM:     NotesViewModel
    @EnvironmentObject var bookmarksVM: BookmarksViewModel
    @EnvironmentObject var router:      AppNavigationRouter

    // Drives re-evaluation of Text(vm.chapterTitle) when locale changes.
    // chapterTitle calls BibleBookNames.short(for:) which reads UserDefaults at call
    // time — correct value is available immediately, but SwiftUI only re-evaluates
    // body when one of its observed dependencies changes. Without this, the toolbar
    // book-name button keeps the previous locale's abbreviation until the user taps it.
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if vm.isLoading {
                    ProgressView(LocalizedStringKey("reader.loading"))
                } else if let error = vm.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("reader.retry") { vm.loadChapter() }.buttonStyle(.bordered)
                    }.padding()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(vm.verses) { verse in
                                    VerseRowView(
                                        verse: verse,
                                        isSelected: vm.selectedVerse?.id == verse.id
                                                    && vm.activeSheet == .verse,
                                        selectedSegment: vm.selectedVerse?.id == verse.id
                                                    ? vm.selectedSegment : nil,
                                        onVerseTap: { vm.tapVerse(verse) },
                                        onWordTap:  { seg in vm.tapWord(seg, in: verse) }
                                    )
                                    .id(verse.id)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 100)
                        }
                        .onChange(of: vm.selectedVerse?.id) { _, newId in
                            guard let id = newId else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        Button { vm.isBookPickerPresented = true } label: {
                            HStack(spacing: 4) {
                                Text(vm.chapterTitle)
                                    .font(.headline).foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button { vm.isTranslationPickerPresented = true } label: {
                            HStack(spacing: 4) {
                                Text(vm.currentTranslation.id)
                                    .font(.headline).foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        // Single sheet slot for all presentations — avoids "only one sheet supported" warning
        .sheet(item: $vm.activeSheet) { sheet in
            switch sheet {
            case .bookPicker:
                BookChapterPickerView().environmentObject(vm)
            case .translationPicker:
                TranslationPickerView().environmentObject(vm)
                    .presentationDetents([.medium])
            case .verse:
                if let verse = vm.selectedVerse {
                    if #available(iOS 18.0, *) {
                        VerseBottomSheetView(verse: verse)
                            .environmentObject(vm)
                            .environmentObject(notesVM)
                            .environmentObject(bookmarksVM)
                            .environmentObject(router)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                            .presentationSizing(.page)
                    } else {
                        VerseBottomSheetView(verse: verse)
                            .environmentObject(vm)
                            .environmentObject(notesVM)
                            .environmentObject(bookmarksVM)
                            .environmentObject(router)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    }
                }
            }
        }
    }
}

// MARK: - Verse Row

struct VerseRowView: View {
    let verse: BibleVerse
    var isSelected: Bool = false
    var selectedSegment: VerseSegment? = nil
    var onVerseTap: () -> Void
    var onWordTap: (VerseSegment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Verse number
                Text("\(verse.number)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.blue : Color(UIColor.tertiaryLabel))
                    .frame(width: 24, alignment: .trailing)
                    .padding(.top, 10)

                // Verse text — UITextView renderer when parsed; plain Text fallback
                if let parsed = verse.parsed {
                    VerseTextView(
                        parsed: parsed,
                        highlightColor: verse.highlightColor,
                        selectedSegment: selectedSegment,
                        onVerseTap: onVerseTap,
                        onWordTap: onWordTap
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.trailing, 12)
                } else {
                    Text(verse.text)
                        .font(.body)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.trailing, 12)
                        .background(verse.highlightColor.map {
                            HighlightColor.from($0).color.opacity(0.22)
                        } ?? Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onVerseTap)
                }
            }
            .background {
                if isSelected {
                    if #available(iOS 26, *) {
                        // iOS 26: ConcentricRectangle автоматично рахує inner radius
                        // containerShape(r=12) → ConcentricRectangle з padding 2pt → inner r=10
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.blue)
                            ConcentricRectangle()
                                .fill(Color(UIColor.systemGroupedBackground))
                                .padding(.leading, 2)
                            ConcentricRectangle()
                                .fill(Color.blue.opacity(0.06))
                                .padding(.leading, 2)
                        }
                        .containerShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        // iOS 17–25: три шари вручну
                        // 1) синій (акцент-смужка) → 2) grouped bg (ховає синій) → 3) синій тінт
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.blue)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(UIColor.systemGroupedBackground))
                                .padding(.leading, 2)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.06))
                                .padding(.leading, 2)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isSelected ? 12 : 0))

        }
    }
}

// MARK: - Translation Picker

struct TranslationPickerView: View {
    @EnvironmentObject var vm: ReaderViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(vm.availableTranslations) { t in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.body)
                        Text(t.language == "uk" ? "lang.ukrainian" : "lang.english").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.currentTranslation.id == t.id {
                        Image(systemName: "checkmark").foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.selectTranslation(t); dismiss() }
            }
            .navigationTitle("reader.translation_picker.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    @MainActor in
    let store = InMemoryUserDataStore()
    let auth  = LocalAuthService.shared
    ReaderView()
        .environmentObject(ReaderViewModel(store: store))
        .environmentObject(NotesViewModel(store: store, authService: auth))
        .environmentObject(BookmarksViewModel(store: store, authService: auth))
}

