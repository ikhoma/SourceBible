// ReaderView.swift
// SourceBible

import SwiftUI

struct ReaderView: View {

    @EnvironmentObject var vm:          ReaderViewModel
    @EnvironmentObject var notesVM:     NotesViewModel
    @EnvironmentObject var bookmarksVM: BookmarksViewModel
    @EnvironmentObject var router:      AppNavigationRouter

    // Drives re-evaluation of Text(vm.chapterTitle) when locale changes.
    // chapterTitle now uses translationBookNames (published), so it re-evaluates
    // automatically on translation switch. The locale dependency is still needed
    // for BibleBookNames fallback paths (cross-refs, notes, etc.).
    @Environment(\.locale) private var locale
    @AppStorage("hideBookCovers") private var hideBookCovers = true

    // MARK: - Study Mode geometry (spec-study-mode-redesign.md R1–R3)
    //
    // In Study Mode (vm.activeSheet == .verse) the selected verse is pinned
    // 16 pt below the toolbar, reader scrolling is disabled, and the sheet's
    // single .height detent is computed so its top edge sits ~8 pt below the
    // pinned verse. Only the sheet's internal content scrolls.
    //
    // The geometry state (pinnedVerseHeight / readerContainerHeight /
    // studySheetHeight) lives in ReaderViewModel, and the detent itself is
    // applied INSIDE VerseBottomSheetView. Rationale: presentation-modifier
    // arguments captured in the .sheet content closure here go STALE — the
    // closure is not re-evaluated when the presenter's @State changes — so a
    // detent set in this file never resized the already-open sheet. The
    // sheet's own body re-renders on every vm change, so modifiers applied
    // there stay live. ReaderView only MEASURES and writes into the VM.

    // True when the book cover should be shown (chapter 1 of any book, not hidden).
    private var showsBookCover: Bool {
        !hideBookCovers && vm.currentChapter == 1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color("appBackground").ignoresSafeArea()
                if vm.isLoading {
                    ProgressView(LocalizedStringKey("reader.loading"))
                } else if let error = vm.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("reader.retry") { vm.loadChapter() }.buttonStyle(.bordered)
                    }.padding()
                } else {
                    ScrollViewReader { proxy in

                        let sheetOpen = vm.activeSheet == .verse
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {

                                if vm.currentChapter == 1 {
                                    if showsBookCover {
                                        // Full-bleed book cover extending behind the nav bar.
                                        // Negative padding cancels VStack's own insets so
                                        // the cover reaches flush to the scroll view's top edge.
                                        BookCoverView(
                                            bookId: vm.currentBook.id,
                                            bookName: vm.translationBookNames[vm.currentBook.id]?.long
                                                ?? BibleBookNames.full(for: vm.currentBook.id),
                                            chapterCount: vm.currentBook.chapterCount
                                        )
                                        .padding(.top, -12)
                                        .padding(.horizontal, -16)
                                        .padding(.bottom, 20)
                                    } else {
                                        // Cover hidden: regular Large Title (original layout)
                                        Text(vm.translationBookNames[vm.currentBook.id]?.long
                                             ?? BibleBookNames.full(for: vm.currentBook.id))
                                            .font(.largeTitle)
                                            .bold()
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.bottom, 16)
                                    }
                                }

                                Text(vm.chapterHeading)
                                    .font(.title)
                                    .bold()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 16)

                                ForEach(vm.verses) { verse in
                                    VerseRowView(
                                        verse: verse,
                                        translationId: vm.currentTranslation.id,
                                        isSelected: vm.selectedVerse?.id == verse.id
                                                    && vm.activeSheet == .verse,
                                        selectedSegment: vm.selectedVerse?.id == verse.id
                                                    ? vm.selectedSegment : nil,
                                        onVerseTap: { vm.tapVerse(verse) },
                                        onWordTap:  { seg in vm.tapWord(seg, in: verse) }
                                    )
                                    .id(verse.id)
                                    // Measure EVERY row unconditionally (R3): heights land in
                                    // vm.verseRowHeights, and vm.pinnedVerseHeight is a lookup
                                    // for the selected id. Unlike the previous conditional
                                    // background, this never depends on a freshly-inserted view
                                    // firing its initial geometry callback when selection moves.
                                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                                        guard newHeight > 0,
                                              abs((vm.verseRowHeights[verse.id] ?? 0) - newHeight) > 0.5
                                        else { return }
                                        // Defer the published write one tick: the callback runs
                                        // during the layout pass, and synchronous objectWillChange
                                        // writes for many rows at once can be dropped/ignored
                                        // ("Publishing changes from within view updates").
                                        let id = verse.id
                                        Task { @MainActor in
                                            vm.verseRowHeights[id] = newHeight
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)
                            // When the sheet is open keep a small margin above the sheet;
                            // when closed use the original generous bottom padding.
                            .padding(.bottom, sheetOpen ? 16 : 100)
                        }
                        // R2: Study Mode locks user scrolling. Programmatic
                        // proxy.scrollTo(...) still works — required for chevron
                        // navigation to re-anchor the newly selected verse.
                        .scrollDisabled(sheetOpen)
                        // R1: top inset in Study Mode so anchor:.top lands the pinned
                        // verse TEXT exactly 16 pt below the nav bar (6 pt inset +
                        // 10 pt internal row padding — see pinnedTopInset doc).
                        //
                        // spacing MUST be 0: `nil` means "system default spacing"
                        // (~16 pt) between the inset view and the content, which
                        // silently pushed the pinned verse that much lower.
                        //
                        // Always returns a concrete Color view (no conditional ViewBuilder) to
                        // avoid type-inference ambiguity with iOS 26 safeAreaInset overloads.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear.frame(height: sheetOpen ? ReaderViewModel.pinnedTopInset : 0)
                        }
                        // R3: reserve the sheet-covered area so anchor:.top can pin ANY
                        // verse (including the chapter's last ones) to the top. The
                        // effective viewport above the sheet ≈ pinned verse + gap.
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: sheetOpen ? vm.studySheetHeight : 0)
                        }
                        // Observes verseScrollTrigger (not selectedVerse.id) so that
                        // re-tapping the already-selected verse still re-scrolls it
                        // above the sheet if the user has manually scrolled away.
                        .onChange(of: vm.verseScrollTrigger) { _, _ in
                            guard let id = vm.selectedVerse?.id else { return }
                            // Choose animation based on what triggered the verse change:
                            //   .tap     → .snappy spring — direct manipulation feel.
                            //   .chevron → .easeInOut    — calm sequential traversal.
                            let intent = vm.verseScrollIntent
                            vm.verseScrollIntent = .tap   // reset for next interaction
                            let animation: Animation = intent == .chevron
                                ? .easeInOut(duration: 0.32)
                                : .snappy
                            // Study Mode pins the verse top 16 pt below the nav bar
                            // (anchor .top within the inset viewport — R1).
                            let anchor: UnitPoint = sheetOpen ? .top : .center
                            // Defer one RunLoop tick so safeAreaInset is committed to
                            // the UIScrollView before scrollTo uses the extra room.
                            DispatchQueue.main.async {
                                withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) }
                            }
                            // Re-assert the anchor after the sheet presentation /
                            // detent / inset animations settle — the first pass can
                            // compute against stale geometry and land the verse a
                            // few points low. No-ops when already in place.
                            if sheetOpen {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        proxy.scrollTo(id, anchor: anchor)
                                    }
                                }
                            }
                        }
                        // Reset scroll position to top on every chapter change.
                        .id(vm.currentChapter)
                        // Only extend behind the nav bar when the genesis header image
                        // is present. Other chapters must render below the nav bar as normal.
                        .ignoresSafeAreaIf(showsBookCover, edges: .top)
                    }

                    // Edge swipe gesture for chapter navigation.
                    // UIScreenEdgePanGestureRecognizer fires from the hardware screen
                    // edge regardless of UITextView hit-testing, so it works over all content.
                    // Chapter change is a no-op in Study Mode (product decision N1) —
                    // the user must exit to the reader first.
                    EdgeSwipeNavigator(
                        onPrevChapter: { if vm.activeSheet != .verse { vm.prevChapter() } },
                        onNextChapter: { if vm.activeSheet != .verse { vm.nextChapter() } }
                    )
                    .ignoresSafeArea()

                    // Note: the old gesture-blocking overlay is gone (R2). Background
                    // scrolling is now disabled via .scrollDisabled, and the sheet no
                    // longer forwards touches (presentationBackgroundInteraction removed),
                    // so there is no swipe leak to absorb.

                    // 🐞 TEMP DEBUG — remove before merge.
                    // Live readout of the Study Mode geometry pipeline. If the
                    // sheet is mis-sized, a screenshot of these numbers shows
                    // exactly which stage broke:
                    //   rows == 0      → row measurement never fires
                    //   verse == 0     → selectedVerse lookup misses the dict
                    //   cont == 0      → container measurement never fires
                    //   sheet == cont/2 → pre-measurement fallback is active
                    // Doubles as a build canary: no red digits = stale build.
                    if vm.activeSheet == .verse {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("rows \(vm.verseRowHeights.count)")
                            Text("verse \(Int(vm.pinnedVerseHeight))")
                            Text("cont \(Int(vm.readerContainerHeight))")
                            Text("sheet \(Int(vm.studySheetHeight))")
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding(4)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                    }
                }
            }
            // Track the reader content area height for studySheetHeight (R3).
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                vm.readerContainerHeight = newHeight
            }
            .navigationBarTitleDisplayMode(.inline)
            // Also inject the desired sheet height from the PRESENTING
            // hierarchy: presented sheets inherit this environment live, and
            // it is unclear whether CustomPresentationDetent's Context reads
            // the presenter's or the content's environment — cover both.
            .environment(\.studySheetHeight, vm.studySheetHeight)
            .toolbar {
                // R5: trailing <> chevrons retarget by state —
                //   Reader:                  prev/next chapter
                //   Study Mode (Verse tab):  prev/next verse  (no cross-chapter, N2)
                //   Study Mode (Word tab):   prev/next word
                // Disabled state reads vm.navPrevDisabled / vm.navNextDisabled —
                // the single source of truth shared with the (removed) sheet chevrons.
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        if vm.activeSheet == .verse {
                            if vm.bottomSheetMode == .verse { vm.navigateToPreviousVerse() }
                            else { vm.navigateToPreviousWord() }
                        } else {
                            vm.prevChapter()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(vm.activeSheet == .verse
                              ? vm.navPrevDisabled
                              : vm.currentChapter <= 1)
                    .accessibilityLabel(Text(prevChevronA11yKey))

                    Button {
                        if vm.activeSheet == .verse {
                            if vm.bottomSheetMode == .verse { vm.navigateToNextVerse() }
                            else { vm.navigateToNextWord() }
                        } else {
                            vm.nextChapter()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(vm.activeSheet == .verse
                              ? vm.navNextDisabled
                              : vm.currentChapter >= vm.currentBook.chapterCount)
                    .accessibilityLabel(Text(nextChevronA11yKey))
                }

                // R4: leading item morphs in place between the book+translation
                // pickers (reader) and the Back button (Study Mode).
                ToolbarItem(placement: .navigationBarLeading) {
                    leadingToolbarContent
                }
            }
        }
        // Single sheet slot for all presentations — avoids "only one sheet supported" warning
        .sheet(item: $vm.activeSheet, onDismiss: {
            // R7: shared exit path for Back button and header drag-down.
            // (verseRowHeights stays valid — next entry sizes correctly at once.)
            vm.clearWordSelection()
        }) { sheet in
            switch sheet {
            case .bookPicker:
                BookChapterPickerView().environmentObject(vm)
            case .translationPicker:
                TranslationPickerView().environmentObject(vm)
                    .presentationDetents([.medium])
            case .verse:
                // R3: the dynamic .height detent is applied INSIDE
                // VerseBottomSheetView (its body re-renders on vm changes;
                // anything passed here goes stale — see geometry note above).
                // Only the static presentation modifiers stay here.
                //
                // presentationBackgroundInteraction(.enabled) is here ONLY to kill
                // the system dimming/shadow over the background (it was covering
                // the pinned verse). The background reader is still locked via
                // .scrollDisabled, so the old swipe-leak problem cannot return.
                if let verse = vm.selectedVerse {
                    if #available(iOS 18.0, *) {
                        VerseBottomSheetView(verse: verse)
                            .environmentObject(vm)
                            .environmentObject(notesVM)
                            .environmentObject(bookmarksVM)
                            .environmentObject(router)
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled)
                            .presentationSizing(.page)
                    } else {
                        VerseBottomSheetView(verse: verse)
                            .environmentObject(vm)
                            .environmentObject(notesVM)
                            .environmentObject(bookmarksVM)
                            .environmentObject(router)
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar content (R4/R5)

    /// Dynamic accessibility label for the leading (prev) toolbar chevron.
    private var prevChevronA11yKey: LocalizedStringKey {
        if vm.activeSheet == .verse {
            return vm.bottomSheetMode == .verse ? "a11y.nav.prev_verse" : "a11y.nav.prev_word"
        }
        return "a11y.nav.prev_chapter"
    }

    /// Dynamic accessibility label for the trailing (next) toolbar chevron.
    private var nextChevronA11yKey: LocalizedStringKey {
        if vm.activeSheet == .verse {
            return vm.bottomSheetMode == .verse ? "a11y.nav.next_verse" : "a11y.nav.next_word"
        }
        return "a11y.nav.next_chapter"
    }

    /// R4: in-place morph between the book+translation pickers and the Back button.
    ///
    /// Implementation note (research, 2026-06): iOS 26's toolbar morphing APIs
    /// (matchedTransitionSource + navigationTransition) are designed for
    /// screen-to-screen / sheet-from-button transitions, not for swapping the
    /// content of a toolbar item in place. matchedGeometryEffect inside toolbars
    /// is unreliable (both views coexist during the transition → broken frames).
    /// The robust in-place morph is a single ToolbarItem whose content swaps with
    /// a spring-animated transition — on iOS 26 the surrounding glass capsule is
    /// preserved by the system and morphs automatically; no manual glass (CLAUDE.md).
    @ViewBuilder
    private var leadingToolbarContent: some View {
        ZStack {
            if vm.activeSheet == .verse {
                morphing(backButton)
            } else {
                morphing(pickerGroup)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: vm.activeSheet == .verse)
    }

    /// iOS 17+: blurReplace gives the closest "morph in place" feel;
    /// pre-17 (not shipped) falls back to a plain fade.
    @ViewBuilder
    private func morphing<V: View>(_ view: V) -> some View {
        if #available(iOS 17.0, *) {
            view.transition(.blurReplace)
        } else {
            view.transition(.opacity)
        }
    }

    /// Study Mode Back button — exits to the reader (R7).
    private var backButton: some View {
        Button {
            vm.activeSheet = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                Text("studymode.back")
                    .font(.headline)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(Text("studymode.back"))
    }

    /// Reader-mode book + translation pickers (unchanged behavior).
    private var pickerGroup: some View {
        HStack(spacing: 8) {
            Button { vm.isBookPickerPresented = true } label: {
                HStack(spacing: 4) {
                    Text(vm.chapterTitle)
                        .font(.headline).foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                }
            }
            Button { vm.isTranslationPickerPresented = true } label: {
                HStack(spacing: 4) {
                    Text(vm.currentTranslation.id)
                        .font(.headline).foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Verse Row

struct VerseRowView: View {
    let verse: BibleVerse
    var translationId: String = ""
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
                    .id("\(verse.id)-\(translationId)-\(verse.highlightColor ?? "none")")
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
                                .fill(Color("appBackground"))
                                .padding(.leading, 2)
                            ConcentricRectangle()
                                .fill(Color.blue.opacity(0.1))
                                .padding(.leading, 2)
                        }
                        .containerShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        // iOS 17–25: три шари вручну
                        // 1) синій (акцент-смужка) → 2) grouped bg (ховає синій) → 3) синій тінт
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.blue)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color("appBackground"))
                                .padding(.leading, 2)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.1))
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
                        Text(languageLabel(for: t.language)).font(.caption).foregroundStyle(.secondary)
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

    private func languageLabel(for code: String) -> LocalizedStringKey {
        switch code {
        case "uk": return "lang.ukrainian"
        case "ru": return "lang.russian"
        default:   return "lang.english"
        }
    }
}

// MARK: - Conditional ignoresSafeArea helper

private extension View {
    /// Applies `.ignoresSafeArea(edges:)` only when `condition` is true.
    /// Used to extend the scroll view behind the nav bar only on chapters
    /// that have a full-bleed header image.
    @ViewBuilder
    func ignoresSafeAreaIf(_ condition: Bool, edges: Edge.Set) -> some View {
        if condition {
            self.ignoresSafeArea(edges: edges)
        } else {
            self
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

