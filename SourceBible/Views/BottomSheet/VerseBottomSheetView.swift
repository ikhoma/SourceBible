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
    @Environment(\.colorTheme) private var colorTheme

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

    /// Identity of WHAT the scrollable area is showing — the SUBJECT, not just the tab.
    ///
    /// bug-039 / bug-040: this key used to carry only the pill / sub-tab, so switching
    /// pills reset the scroll but moving to another WORD (chevrons, long-press) or another
    /// VERSE (chevrons) did not — the reader landed mid-article, scrolled to where the
    /// previous word's entry happened to be. `currentTranslation` belongs here for the same
    /// reason: `VerseTabContent` reloads its data on that change (`onChange(of:)`), so the
    /// content is new and the old offset is just as wrong.
    ///
    /// ⛔ Adding a data source that reloads this area? Put its identity here too — otherwise
    /// the content changes under a stale scroll offset and the bug is back.
    private var scrollSubjectId: String {
        let subject: String = vm.bottomSheetMode == .verse
            ? "verse-\(versePill)-\(verse.id)"
            : "word-\(wordSubTab)-\(vm.selectedWord?.id ?? vm.selectedSegment?.id.uuidString ?? "none")"
        return "\(subject)-\(vm.currentTranslation.id)"
    }

    var body: some View {
        let _ = DebugTiming.mark("VerseBottomSheetView.body EVALUATED")
        return VStack(spacing: 0) {
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
            .id(scrollSubjectId)
        }
        .background(colorTheme.sheetBackground)
        // R3: constant detent SET — the system re-resolves StudySheetDetent's
        // height from the environment value below on presentation updates,
        // which is the reliable channel for resizing an open sheet
        // (replacing a [.height(x)] set proved a no-op on device).
        //
        // ⚠️ INTENTIONAL DUAL MECHANISM — DO NOT "simplify" by deleting one path
        // without testing on a real device first.
        // The sheet height is driven by BOTH the SwiftUI custom detent
        // (StudySheetDetent, fed by \.studySheetHeight) AND the UIKit-level
        // StudySheetDetentApplier below. Each alone proved unreliable on device
        // during the Study Mode redesign, so both are kept and they agree on the
        // same height. This is a known redundancy (code review #3, 2026-06-17),
        // left in deliberately because it works. If you ever collapse it to one
        // path, verify the open sheet still resizes per-verse on a physical
        // device, not just the simulator.
        .presentationDetents([.custom(StudySheetDetent.self)])
        .environment(\.studySheetHeight, vm.studySheetHeight)
        // UIKit-level driver: sets sheet.detents directly with the desired
        // height on every change (SwiftUI's own detent updates proved
        // unreliable on device — see StudySheetDetentApplier).
        .background(
            StudySheetDetentApplier(height: vm.studySheetHeight)
                .frame(width: 0, height: 0)
        )
        // Default interactive dismiss: swipe down anywhere on the sheet chrome
        // (or from the top of the content) closes Study Mode, same as the Back
        // button. The old custom drag-only-from-header zone was unreliable
        // ("1 of 5 tries"); the system gesture is the expected behaviour.
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
                    Text("\(vm.currentBookShortName) \(verse.chapter):\(verse.number)")
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
                    Label {
                        Text("highlight.color.none")
                    } icon: {
                        // Hollow ring (no fill) for "No Highlight". "circle" is the
                        // stroke-only system symbol; tint with UIColor.label (Labels
                        // Primary) so the outline adapts to light/dark mode. Resolve
                        // via .alwaysOriginal so UIMenu doesn't re-tint it monochrome,
                        // matching the colored-dot rows below.
                        if let ring = UIImage(systemName: "circle")?
                            .withTintColor(.label, renderingMode: .alwaysOriginal) {
                            Image(uiImage: ring)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Color(UIColor.label))
                        }
                    }
                    .tag(HighlightColor?.none)
                }
                Section {
                    ForEach(HighlightColor.pickerCases, id: \.self) { c in
                        Label {
                            Text(c.label)
                        } icon: {
                            // .alwaysOriginal keeps the dot colored inside the menu
                            // (template symbols are re-tinted monochrome by UIMenu).
                            // "circle.fill" is a guaranteed system symbol, but resolve it
                            // safely anyway — fall back to a SwiftUI-tinted dot rather than
                            // force-unwrap (code review #5).
                            if let dot = UIImage(systemName: "circle.fill")?
                                .withTintColor(c.dotUIColor, renderingMode: .alwaysOriginal) {
                                Image(uiImage: dot)
                            } else {
                                Image(systemName: "circle.fill").foregroundStyle(c.color)
                            }
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
                .foregroundStyle(isActive ? colorTheme.sheetBackground : Color(UIColor.label))
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

#if DEBUG
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
#endif
