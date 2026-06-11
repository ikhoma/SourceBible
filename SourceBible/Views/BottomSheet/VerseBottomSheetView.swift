// VerseBottomSheetView.swift
// SourceBible
//
// Контейнер bottom sheet (Study Mode): шапка з контекстним меню, mode tabs, pills row.
// Вміст вкладок — у VerseTabContent.swift та WordTabContent.swift.
//
// Study Mode redesign (spec-study-mode-redesign.md R6):
//   • Header-шеврони prev/next видалені — навігація живе у toolbar рідера (R5).
//   • Нижня actionBar видалена — всі дії (highlight/note/bookmark/share)
//     перенесені в контекстне меню (ellipsis) у шапці.

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

    /// Drag-down on the non-scrolling top block exits Study Mode (R7).
    /// System interactive dismiss is disabled, so this is the only drag exit.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 15, coordinateSpace: .local)
            .onEnded { value in
                guard value.translation.height > 40,
                      value.translation.height > abs(value.translation.width)
                else { return }
                vm.activeSheet = nil
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The header row is the drag-to-close zone (plus the grabber strip
            // overlay below). modeTabs and pillsRow are excluded on purpose:
            // the segmented control and the horizontal ScrollView swallow
            // vertical drags, making dismissal feel broken from there.
            sheetHeader
                .contentShape(Rectangle())
                .simultaneousGesture(dismissDragGesture)
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
        }
        .background(Color("sheetBackground"))
        // Grabber strip: drag-to-close also works from the very top of the
        // sheet (where the system drag indicator is drawn).
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 24)
                .contentShape(Rectangle())
                .simultaneousGesture(dismissDragGesture)
        }
        // R3: constant detent SET — the system re-resolves StudySheetDetent's
        // height from the environment value below on presentation updates,
        // which is the reliable channel for resizing an open sheet
        // (replacing a [.height(x)] set proved a no-op on device).
        .presentationDetents([.custom(StudySheetDetent.self)])
        .environment(\.studySheetHeight, vm.studySheetHeight)
        // Belt-and-suspenders: force UIKit to re-resolve the detent whenever
        // the desired height changes (SwiftUI alone proved lazy on device).
        .background(
            StudySheetDetentInvalidator(height: vm.studySheetHeight)
                .frame(width: 0, height: 0)
        )
        // Dismiss only from the header / grabber zone (gestures above) or the
        // toolbar Back button. Without this, a downward scroll in the content
        // randomly dragged the whole sheet (R7 fine-tune).
        .interactiveDismissDisabled(true)
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

            contextMenu
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - Context Menu (R6)

    /// Ellipsis capsule button with all verse actions.
    /// Standard iOS 26 menu layout:
    ///   • top row — 3 main actions (Note / Bookmark / Share) as a horizontal
    ///     ControlGroup (system "medium element size" row with icon + label);
    ///   • section below — the highlight palette as an inline checklist
    ///     (None first, then the 5 colors — R8).
    private var contextMenu: some View {
        Menu {
            ControlGroup {
                Button {
                    let note = notesVM.openNewNote(attachedTo: verse, translation: vm.currentTranslation.id)
                    activeEditor = .note(note)
                } label: {
                    Label("action.note", systemImage: "note.text")
                }

                Button {
                    bookmarksVM.toggleBookmark(verseId: verse.id)
                } label: {
                    if bookmarksVM.isBookmarked(verseId: verse.id) {
                        Label("action.bookmark", systemImage: "bookmark.fill")
                    } else {
                        Label("action.bookmark", systemImage: "bookmark")
                    }
                }

                ShareLink(item: VerseShareFormatter.format(
                    verse: verse,
                    bookName: vm.translationBookNames[verse.bookId]?.long
                        ?? BibleBookNames.full(for: verse.bookId),
                    translationId: vm.currentTranslation.id
                )) {
                    Label("action.share", systemImage: "square.and.arrow.up")
                }
            }

            // Highlight checklist (R8). An inline Picker inside a Menu renders as
            // a native checklist section; the Section split draws the separator
            // between None and the colors. Legacy highlights (yellow/green) are
            // not in pickerCases → the selection matches no tag → no checkmark
            // anywhere, and choosing a new color overwrites (edge case 5).
            Picker("action.highlight", selection: highlightSelection) {
                Section {
                    Text("highlight.color.none").tag(HighlightColor?.none)
                }
                Section {
                    ForEach(HighlightColor.pickerCases, id: \.self) { c in
                        Label {
                            Text(c.label)
                        } icon: {
                            // .alwaysOriginal keeps the dot colored inside the menu
                            // (template symbols are re-tinted monochrome by UIMenu).
                            Image(uiImage: UIImage(systemName: "circle.fill")!
                                .withTintColor(c.dotUIColor, renderingMode: .alwaysOriginal))
                        }
                        .tag(HighlightColor?.some(c))
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .modifier(CapsuleNavGroupStyle())
        .accessibilityLabel(Text("sheet.menu.a11y"))
    }

    /// nil = no highlight (None). Setting nil removes the highlight.
    /// Getter returns the stored color even when it's a legacy case — see highlightPicker doc.
    private var highlightSelection: Binding<HighlightColor?> {
        Binding(
            get: { vm.currentVerseHighlightColor },
            set: { newValue in
                if let color = newValue {
                    vm.setHighlightColor(color, for: verse)
                } else {
                    vm.removeHighlight(for: verse)
                }
            }
        )
    }

    // MARK: - Mode Tabs

    private var modeTabs: some View {
        Picker("", selection: $vm.bottomSheetMode) {
            Text("sheet.mode.verse").tag(BottomSheetMode.verse)
            Text("sheet.mode.word").tag(BottomSheetMode.word)
        }
        .pickerStyle(.segmented)
        .onAppear {
            UISegmentedControl.appearance().setTitleTextAttributes(
                [.font: UIFont.systemFont(ofSize: 13, weight: .medium)], for: .normal)
            UISegmentedControl.appearance().setTitleTextAttributes(
                [.font: UIFont.systemFont(ofSize: 13, weight: .medium)], for: .selected)
        }
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
                .foregroundStyle(isActive ? Color("sheetBackground") : Color(UIColor.label))
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color(UIColor.label))
                            .matchedGeometryEffect(id: "pill-bg", in: pillNS)
                    }
                }
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
