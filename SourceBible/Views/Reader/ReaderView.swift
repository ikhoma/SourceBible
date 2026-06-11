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

    // Tracks which detent the verse sheet is resting at.
    // Updated only when the sheet *settles* at a detent (not during drag),
    // so the background layout doesn't re-evaluate on every animation frame.
    @State private var selectedDetent: PresentationDetent = .medium

    // True when the book cover should be shown (chapter 1 of any book, not hidden).
    private var showsBookCover: Bool {
        !hideBookCovers && vm.currentChapter == 1
    }

    // Inset to add at the bottom of the scroll view when the verse sheet is open.
    //
    // Goal: anchor:.bottom lands verse.bottom exactly 6 pt above the sheet top (T).
    //
    // Uses the selected detent (medium/large) rather than the live sheet height so
    // that the background layout only recalculates when the sheet *settles*, not on
    // every drag frame. This eliminates the per-frame layout loop that caused lag.
    //
    // At .large detent the sheet covers the whole screen; no extra inset is needed.
    //
    // @MainActor is required because UIApplication is strictly @MainActor under Swift 6.
    @MainActor private var verseSheetReservedHeight: CGFloat {
        guard selectedDetent != .large else { return 0 }
        let scene       = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let bottomInset = scene?.windows.first?.safeAreaInsets.bottom ?? 34
        let screenH     = scene?.screen.bounds.height ?? 874
        // iOS allocates exactly screenH * 0.5 to the medium-detent sheet content view,
        // so sheetH = screenH / 2 (not minus safeTop). The old fallback used
        // (screenH - safeTop) / 2 which was ~30 pt too small on Face ID devices.
        let sheetH      = screenH / 2.0
        // safeAreaInset stacks on top of the scroll view's existing home-indicator
        // contentInset (= bottomInset). Subtract it twice to avoid a +34 pt shift.
        //   insetH = sheetH − 2·bottomInset + 6
        return max(0, sheetH - 2 * bottomInset + 6)
    }

    // Height of the medium detent — used for the gesture-blocking overlay.
    @MainActor private var mediumDetentHeight: CGFloat {
        let scene   = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let screenH = scene?.screen.bounds.height ?? 874
        return screenH / 2.0
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
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)
                            // When the sheet is open keep a small margin above the sheet;
                            // when closed use the original generous bottom padding.
                            .padding(.bottom, sheetOpen ? 16 : 100)
                        }
                        // Reserve space equal to the medium-detent sheet height so the
                        // scroll view treats the visible-above-sheet area as its viewport.
                        // .bottom anchor then lands the selected verse flush above the sheet.
                        //
                        // Always returns a concrete Color view (no conditional ViewBuilder) to
                        // avoid type-inference ambiguity with iOS 26 safeAreaInset overloads.
                        // Height is 0 when the sheet is closed, so there is no visible effect.
                        .safeAreaInset(edge: .bottom, spacing: nil) {
                            Color.clear.frame(height: sheetOpen ? verseSheetReservedHeight : 0)
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
                            let anchor: UnitPoint = sheetOpen ? .bottom : .center
                            // Defer one RunLoop tick so safeAreaInset is committed to
                            // the UIScrollView before scrollTo uses the extra room.
                            DispatchQueue.main.async {
                                withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) }
                            }
                        }
                        // Re-anchor scroll when the detent changes (medium ↔ large).
                        // Fires only when the user releases the drag, not on every frame.
                        .onChange(of: selectedDetent) { _, newDetent in
                            guard let id = vm.selectedVerse?.id,
                                  vm.activeSheet == .verse else { return }
                            let anchor: UnitPoint = newDetent == .large ? .center : .bottom
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: anchor)
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
                    EdgeSwipeNavigator(
                        onPrevChapter: { vm.prevChapter() },
                        onNextChapter: { vm.nextChapter() }
                    )
                    .ignoresSafeArea()

                    // Gesture-blocking overlay for the sheet-covered region.
                    //
                    // Problem: presentationBackgroundInteraction(.enabled) forwards touch
                    // events from the sheet to the background view hierarchy. When the user
                    // swipes DOWN inside the sheet's internal ScrollView (to collapse/dismiss),
                    // that same gesture leaks to the background ScrollView and scrolls it.
                    //
                    // Fix: place a transparent, hit-testable view over the sheet-covered area.
                    // It sits above the ScrollView in the ZStack, so background hit-testing
                    // stops here instead of reaching the ScrollView. No gesture handlers are
                    // attached — it simply absorbs the leaked touch.
                    //
                    // Coverage: vm.verseSheetHeight (content) + 40 pt (home indicator +
                    // a small buffer) gives the full sheet-top-to-screen-bottom area.
                    // The visible area above the sheet top is NOT covered, so intentional
                    // background scrolling while the sheet is open still works.
                    if vm.activeSheet == .verse {
                        let coverHeight = mediumDetentHeight + 40
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(height: coverHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { vm.prevChapter() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(vm.currentChapter <= 1)

                    Button { vm.nextChapter() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(vm.currentChapter >= vm.currentBook.chapterCount)
                }

                ToolbarItem(placement: .navigationBarLeading) {
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
        }
        // Single sheet slot for all presentations — avoids "only one sheet supported" warning
        .sheet(item: $vm.activeSheet, onDismiss: { vm.clearWordSelection(); selectedDetent = .medium }) { sheet in
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
                            .presentationDetents([.medium, .large], selection: $selectedDetent)
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                            .presentationSizing(.page)
                    } else {
                        VerseBottomSheetView(verse: verse)
                            .environmentObject(vm)
                            .environmentObject(notesVM)
                            .environmentObject(bookmarksVM)
                            .environmentObject(router)
                            .presentationDetents([.medium, .large], selection: $selectedDetent)
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

