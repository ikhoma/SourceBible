// VerseBottomSheetView.swift
// SourceBible
//
// Контейнер bottom sheet: шапка, mode tabs, pills row, action bar.
// Вміст вкладок — у VerseTabContent.swift та WordTabContent.swift.

import SwiftUI

struct VerseBottomSheetView: View {

    /// Kept only as a fallback for Xcode Previews.
    /// At runtime the view always reads vm.selectedVerse so navigation updates propagate correctly.
    private let fallbackVerse: BibleVerse
    @EnvironmentObject var vm:          ReaderViewModel
    @EnvironmentObject var notesVM:     NotesViewModel
    @EnvironmentObject var bookmarksVM: BookmarksViewModel
    @EnvironmentObject var router:      AppNavigationRouter

    /// Lifted here so the selected pill survives switching to/from word mode.
    @State private var versePill: VersePill = .crossRefs
    @State private var wordSubTab: WordSubTab = .meaning
    @Namespace private var pillNS
    /// Controls which note editor sheet is open on top of this bottom sheet.
    @State private var activeEditor: ActiveEditor? = nil
    /// Shows the highlight color picker confirmation dialog.
    @State private var showColorPicker: Bool = false

    private enum ActiveEditor: Identifiable {
        case note(NoteWithBlocks)
        var id: String {
            switch self {
            case .note(let n): return "note-\(n.note.id)"
            }
        }
    }

    init(verse: BibleVerse) {
        self.fallbackVerse = verse
    }

    private var verse: BibleVerse {
        vm.selectedVerse ?? fallbackVerse
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            modeTabs
            pillsRow        // fixed — does not scroll vertically
            Divider()
            ScrollView {   // only content scrolls
                if vm.bottomSheetMode == .verse {
                    VerseTabView(verse: verse, pill: versePill).environmentObject(vm)
                } else {
                    WordTabView(subTab: wordSubTab).environmentObject(vm)
                }
            }
            // Changing id recreates the ScrollView → scroll position always resets to top
            .id(vm.bottomSheetMode == .verse ? "verse-\(versePill)" : "word-\(wordSubTab)")
            // Reserve space so last content item isn't hidden under the floating pill
            .contentMargins(.bottom, 64, for: .scrollContent)
        }
        .overlay {
            VStack(spacing: 0) {
                Spacer()
                actionBar
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(UIColor.systemBackground))
        // Single editor sheet slot — avoids "only one sheet" warning
        .sheet(item: $activeEditor) { editor in
            switch editor {
            case .note(let note):
                NoteEditorView(noteWithBlocks: note)
                    .environmentObject(notesVM)
                    .environmentObject(router)
                    .presentationDetents([.large])
                    .onDisappear {
                        notesVM.isEditorPresented = false
                        notesVM.refresh()
                    }
            }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if vm.bottomSheetMode == .word {
                    // selectedWordDisplayText is a resolved String (from DB); falls back to localized key
                    if let wordText = vm.selectedWordDisplayText {
                        Text(wordText).font(.title2).bold()
                    } else {
                        Text("sheet.mode.word").font(.title2).bold()
                    }
                } else {
                    Text("\(BibleBookNames.short(for: vm.currentBook.id)) \(verse.chapter):\(verse.number)")
                        .font(.title2).bold()
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    if vm.bottomSheetMode == .verse { vm.navigateToPreviousVerse() }
                    else { vm.navigateToPreviousWord() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .disabled(isPrevDisabled)

                Button {
                    if vm.bottomSheetMode == .verse { vm.navigateToNextVerse() }
                    else { vm.navigateToNextWord() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .disabled(isNextDisabled)
            }
            .modifier(CapsuleNavGroupStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var isPrevDisabled: Bool {
        if vm.bottomSheetMode == .verse {
            return vm.verses.first?.id == verse.id
        } else {
            guard let w = vm.selectedWord else { return true }
            return vm.translationOrderedClickableWords.first?.id == w.id
        }
    }

    private var isNextDisabled: Bool {
        if vm.bottomSheetMode == .verse {
            return vm.verses.last?.id == verse.id
        } else {
            guard let w = vm.selectedWord else { return true }
            return vm.translationOrderedClickableWords.last?.id == w.id
        }
    }

    // MARK: - Mode Tabs

    private var modeTabs: some View {
        Picker("", selection: $vm.bottomSheetMode) {
            Text("sheet.mode.verse").tag(BottomSheetMode.verse)
            Text("sheet.mode.word").tag(BottomSheetMode.word)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .onChange(of: vm.bottomSheetMode) { _, newMode in
            guard newMode == .word else { return }
            vm.autoSelectFirstWordIfNeeded()
        }
    }

    // MARK: - Pills Row

    private var pillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if vm.bottomSheetMode == .verse {
                    ForEach(VersePill.allCases, id: \.self) { p in
                        pillBtn(p.label, isActive: versePill == p) {
                            withAnimation(.bouncy(duration: 0.3)) { versePill = p }
                        }
                    }
                } else {
                    ForEach(WordSubTab.allCases, id: \.self) { t in
                        pillBtn(t.label, isActive: wordSubTab == t) {
                            withAnimation(.bouncy(duration: 0.3)) { wordSubTab = t }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10).padding(.bottom, 12)
    }

    private func pillBtn(_ label: LocalizedStringKey, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(isActive ? Color(UIColor.systemBackground) : Color(UIColor.label))
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color(UIColor.label))
                            .matchedGeometryEffect(id: "pill-bg", in: pillNS)
                    }
                }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            iconActionBtn(icon: "highlighter",
                          isActive: vm.isCurrentVerseHighlighted,
                          color: vm.currentVerseHighlightColor?.color ?? .yellow) {
                showColorPicker = true
            }
            .confirmationDialog(Text("action.highlight_color_title"),
                                isPresented: $showColorPicker, titleVisibility: .visible) {
                ForEach(HighlightColor.allCases, id: \.self) { hColor in
                    Button(hColor.label) { vm.setHighlightColor(hColor, for: verse) }
                }
                if vm.isCurrentVerseHighlighted {
                    Button("action.remove_highlight", role: .destructive) {
                        vm.removeHighlight(for: verse)
                    }
                }
                Button("action.cancel", role: .cancel) {}
            }

            iconActionBtn(icon: "note.text", isActive: false, color: .blue) {
                let note = notesVM.openNewNote(attachedTo: verse, translation: vm.currentTranslation.id)
                activeEditor = .note(note)
            }

            iconActionBtn(icon: "bookmark",
                          isActive: bookmarksVM.isBookmarked(verseId: verse.id),
                          color: .blue) {
                bookmarksVM.toggleBookmark(verseId: verse.id)
            }

            ShareLink(item: VerseShareFormatter.format(
                verse: verse,
                bookName: vm.translationBookNames[verse.bookId]?.long
                    ?? BibleBookNames.full(for: verse.bookId),
                translationId: vm.currentTranslation.id
            )) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func iconActionBtn(icon: String, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .symbolVariant(.fill)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? color : .primary)
                .frame(width: 52, height: 44)
        }
    }
}

#Preview {
    @MainActor in
    let store = InMemoryUserDataStore()
    let auth  = LocalAuthService.shared
    VerseBottomSheetView(verse: BibleVerse.sampleVerses[0])
        .environmentObject(ReaderViewModel(store: store))
        .environmentObject(NotesViewModel(store: store, authService: auth))
        .environmentObject(BookmarksViewModel(store: store, authService: auth))
        .environmentObject(AppNavigationRouter())
}
