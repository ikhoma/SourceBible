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
    @Environment(\.sessionTracker) private var sessionTracker
    @AppStorage("hideBookCovers") private var hideBookCovers = false
    // Red-letter (Jesus' words) rendering — off by default; toggled in Settings ▸ Appearance.
    @AppStorage("redLetters") private var redLetters = false

    // MARK: - Study Mode geometry (spec-study-mode-redesign.md R1–R3)
    //
    // In Study Mode (vm.activeSheet == .verse) the selected verse is pinned
    // 16 pt below the toolbar, reader scrolling is disabled, and the sheet
    // is sized so its top edge sits ~8 pt below the pinned verse. Only the
    // sheet's internal content scrolls.
    //
    // Geometry state (pinnedTopAnchorY / pinnedVerseHeight / studySheetHeight)
    // lives in ReaderViewModel; the height is applied INSIDE VerseBottomSheetView via
    // StudySheetDetentApplier (UIKit). Rationale: presentation-modifier
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
                // Read the REAL navigation-bar bottom from UIKit. The floating toolbar
                // does not reduce the SwiftUI safe area, so this is the only reliable
                // source for "where the toolbar ends" — the pin target keys off it.
                NavBarBottomReader { y in
                    if abs(vm.toolbarBottomY - y) > 0.5 { vm.toolbarBottomY = y }
                }
                .allowsHitTesting(false)
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
                                        // Book cover as in-flow content: negative padding
                                        // cancels the VStack's own insets so the cover sits
                                        // flush at the scroll's top edge (just below the
                                        // toolbar) and scrolls away normally when a verse pins.
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
                                        // Gate the word highlight on the sheet being open, not just
                                        // on selectedSegment. selectedSegment is only cleared in the
                                        // sheet's onDismiss, which fires when the dismiss ANIMATION
                                        // COMPLETES — so on the Back button (full slide-down) the blue
                                        // word lingered for the whole animation. Tying it to activeSheet
                                        // clears it the instant Back sets activeSheet = nil (frame one),
                                        // matching the drag-dismiss feel. onDismiss still tidies the
                                        // underlying selectedSegment state.
                                        selectedSegment: (vm.activeSheet == .verse
                                                          && vm.selectedVerse?.id == verse.id)
                                                    ? vm.selectedSegment : nil,
                                        redLetters: redLetters,
                                        onVerseTap: { vm.tapVerse(verse) },
                                        onWordTap:  { seg in vm.tapWord(seg, in: verse) }
                                    )
                                    .id(verse.id)
                                    // Measure EVERY row's INTRINSIC height (stable; unaffected
                                    // by scroll) into a per-id store. Done for all rows, not
                                    // just the selected one: onGeometryChange does NOT re-fire
                                    // when a row becomes selected (its height is unchanged), so
                                    // a selection-gated measurement never updated on tap — which
                                    // is why the sheet didn't adapt. The selected verse's height
                                    // is then a reliable lookup (vm.pinnedVerseHeight).
                                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                        vm.setVerseHeight(height, for: verse.id)
                                    }
                                    // Atomic Study-Mode scroll driver: installed as the SELECTED
                                    // verse's background, so its frame == the verse's frame. It
                                    // reads its own global top AND the scroll offset in one layout
                                    // pass (no cross-layer skew) and sets the exact contentOffset.
                                    // Recreated on every focus → fires for first-tap AND re-select.
                                    .background {
                                        if vm.selectedVerse?.id == verse.id && vm.activeSheet == .verse {
                                            StudyPinView(
                                                trigger: vm.verseScrollTrigger,
                                                anchorY: vm.pinnedTopAnchorY,
                                                active: true
                                            )
                                        }
                                    }
                                }

                                // On Study-Mode exit, clamp an over-scrolled offset (left over
                                // from pinning the last verse) so there's no empty gap below it.
                                StudyScrollClamper(active: sheetOpen)
                                    .frame(width: 0, height: 0)
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
                        // No Study-Mode TOP inset: StudyPinView positions the verse via
                        // contentOffset, and the content above the topmost verse (book cover
                        // when covers-on, chapter heading when covers-off) already gives the
                        // headroom to reach pinnedTopAnchorY. A toggled top inset was the
                        // original entry jerk; a constant one made the first verse's short
                        // scroll feel like it braked. See ADR-021.
                        //
                        // R3: reserve enough scroll room BELOW the pin that the verse can
                        // pin ANY verse — including the chapter's last, which have no content
                        // beneath them. This is studyScrollRoom (the whole area below the pin),
                        // NOT studySheetHeight: the sheet is sized separately via the detent,
                        // and tying the inset to the sheet height left the last verses short
                        // of room to reach the top. Surplus room is invisible (scroll locked,
                        // behind the sheet).
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: sheetOpen ? vm.studyScrollRoom : 0)
                        }
                        // Observes verseScrollTrigger (not selectedVerse.id) so that
                        // re-tapping the already-selected verse still re-scrolls it
                        // above the sheet if the user has manually scrolled away.
                        .onChange(of: vm.verseScrollTrigger) { _, _ in
                            guard let id = vm.selectedVerse?.id else { return }
                            vm.verseScrollIntent = .tap   // reset for next interaction
                            // Study-Mode positioning is handled atomically by StudyPinView (the
                            // selected verse's background). The SwiftUI proxy is kept only for the
                            // reader-mode (non-study) re-scroll path.
                            guard !sheetOpen else { return }
                            DispatchQueue.main.async {
                                withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                        // Reset scroll position to top on every book OR chapter change.
                        // Keyed on book+chapter (not chapter alone): switching books that
                        // both open at chapter 1 keeps the same chapter number, so a
                        // chapter-only id would reuse the scroll view and inherit the
                        // previous book's scroll offset.
                        .id("\(vm.currentBook.id)-\(vm.currentChapter)")
                        // Cover bleeds behind the status bar + toolbar (immersive) yet is
                        // still ordinary in-flow content that scrolls away when a verse pins.
                        // Tied to showsBookCover ONLY (never sheetOpen) so it does NOT toggle
                        // on Study Mode entry — the toggle was the source of the black band /
                        // mis-position. The Study-Mode top inset above self-adjusts (it measures
                        // the scroll content origin), so the pinned verse lands `sheetGap` below
                        // the real toolbar in BOTH cases. (`[]` = ignore nothing.)
                        .ignoresSafeArea(edges: showsBookCover ? .top : [])
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
                }
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
            // (pinnedTopAnchorY / pinnedVerseHeight stay as sane initial values for
            // the next entry; both are re-measured as soon as the verse re-anchors.)
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
                //
                // ✅ INTENTIONAL — DO NOT remove or restrict (e.g. .enabled(upThrough:)).
                // This is by design (code review #7, 2026-06-17): restricting it brings
                // back the background dimming that overlapped the pinned verse — the exact
                // bug this replaced. It is unbounded on purpose. The only side effect is
                // that taps in the area ABOVE the sheet still reach the reader (verified
                // acceptable: re-tapping a visible verse just re-pins it). Leave as-is.
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
        // Wire the live sessionTracker into the VM so navigation methods can
        // increment session counters. Cannot be done at VM init time because
        // Environment is not available then.
        .task {
            vm.sessionTracker = sessionTracker
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
    var redLetters: Bool = false
    var onVerseTap: () -> Void
    var onWordTap: (VerseSegment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Verse number
                Text("\(verse.number)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.appBlue : Color(UIColor.tertiaryLabel))
                    .frame(width: 24, alignment: .trailing)
                    .padding(.top, 12)

                // Verse text — UITextView renderer when parsed; plain Text fallback
                if let parsed = verse.parsed {
                    VerseTextView(
                        parsed: parsed,
                        highlightColor: verse.highlightColor,
                        selectedSegment: selectedSegment,
                        redLetters: redLetters,
                        onVerseTap: onVerseTap,
                        onWordTap: onWordTap
                    )
                    // redLetters in the id() forces the base attributed string to rebuild
                    // (with/without the red Jesus-words color) when the setting is toggled.
                    .id("\(verse.id)-\(translationId)-\(verse.highlightColor ?? "none")-\(redLetters ? "rl" : "nrl")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                } else {
                    Text(verse.text)
                        .font(.body)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
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
                            RoundedRectangle(cornerRadius: 12).fill(Color.appBlue)
                            ConcentricRectangle()
                                .fill(Color("appBackground"))
                                .padding(.leading, 2)
                            ConcentricRectangle()
                                .fill(Color.appBlue.opacity(0.1))
                                .padding(.leading, 2)
                        }
                        .containerShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        // iOS 17–25: три шари вручну
                        // 1) синій (акцент-смужка) → 2) grouped bg (ховає синій) → 3) синій тінт
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.appBlue)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color("appBackground"))
                                .padding(.leading, 2)
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.appBlue.opacity(0.1))
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
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
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

// MARK: - Navigation bar bottom reader (UIKit ground truth)

/// Reports the global (window) Y of the navigation bar's BOTTOM edge.
/// The iOS 26 floating toolbar does not reduce the SwiftUI safe area, so a
/// GeometryReader can't see it — reading the real `UINavigationBar` frame is the
/// only reliable source for "where the toolbar ends".
private struct NavBarBottomReader: UIViewControllerRepresentable {
    let onResolve: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> Proxy { Proxy() }
    func updateUIViewController(_ proxy: Proxy, context: Context) {
        proxy.onResolve = onResolve
        proxy.resolve()
    }

    final class Proxy: UIViewController {
        var onResolve: ((CGFloat) -> Void)?

        override func loadView() {
            let v = UIView()
            v.backgroundColor = .clear
            v.isUserInteractionEnabled = false
            view = v
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            resolve()
        }

        // MARK: iOS 26 ghost-padding workaround
        //
        // iOS 26-only framework bug (Apple DevForums "Ghost Padding on
        // NavigationBarPlatterContainer", thread 803481): on interface rotation the
        // navigation bar's private platter container keeps a stale LEADING inset.
        // Rotating back to portrait leaves it stuck (and it accumulates with repeated
        // rotations), which pushes the whole reader content to the right with a black
        // band on the left. There is no Apple fix and no official workaround.
        //
        // Mitigation: after the rotation transition completes, force the navigation bar
        // (and its container subtree) to re-run layout from scratch. Deferred one
        // run-loop tick so it lands AFTER the system's own (buggy) post-rotation pass,
        // letting the clean pass settle the inset. Side-effect-free — only invalidates
        // and re-lays-out existing views, never mutates margins or frames directly.
        // iOS 18 is unaffected by the bug and is left completely untouched.
        override func viewWillTransition(to size: CGSize,
                                         with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            guard #available(iOS 26, *) else { return }
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let nav = self?.navigationController?.navigationBar else { return }
                    nav.invalidateIntrinsicContentSize()
                    nav.setNeedsLayout()
                    nav.subviews.forEach { $0.setNeedsLayout() }
                    nav.superview?.setNeedsLayout()
                    nav.layoutIfNeeded()
                    nav.superview?.layoutIfNeeded()
                    self?.resolve()
                }
            }
        }

        func resolve() {
            guard let nav = navigationController?.navigationBar,
                  let window = view.window else { return }
            let maxY = nav.convert(nav.bounds, to: window).maxY
            if maxY > 0 { onResolve?(maxY) }
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

