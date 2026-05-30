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

    // True when the Genesis chapter 1 full-bleed header image is visible.
    private var showsGenesisHeader: Bool {
        vm.currentBook.id == "GEN" && vm.currentChapter == 1
    }

    // Inset to add at the bottom of the scroll view when the verse sheet is open.
    //
    // Goal: anchor:.bottom lands verse.bottom exactly 6 pt above the sheet top (T).
    //
    // SwiftUI's safeAreaInset stacks ON TOP of the scroll view's existing home-indicator
    // contentInset (bottomInset ≈ 34 pt). The scrollTo anchor sees the combined total:
    //
    //   verse.bottom = (H − bottomInset) − (bottomInset + insetH)
    //
    // Setting that equal to T − 6 and solving:
    //
    //   insetH = sheetH − 2·bottomInset + 6
    //
    // The fallback (used on the very first tap before onGeometryChange fires) estimates
    // the medium-detent height as (screenH − safeTop) / 2, accurate to a few pt.
    //
    // @MainActor is required because UIApplication is strictly @MainActor under Swift 6
    // strict concurrency. The property is only ever called from body (also @MainActor).
    @MainActor private var verseSheetReservedHeight: CGFloat {
        let scene       = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let bottomInset = scene?.windows.first?.safeAreaInsets.bottom ?? 34
        // Use the measured sheet height once available; fall back to the medium-detent
        // formula (screenH - safeTop) / 2 for the very first tap before the sheet appears.
        // This is accurate to within a few pt on all current Face ID devices.
        let sheetH: CGFloat
        if vm.verseSheetHeight > 0 {
            sheetH = vm.verseSheetHeight
        } else {
            let screenH = scene?.screen.bounds.height ?? 852
            let safeTop = scene?.windows.first?.safeAreaInsets.top ?? 59
            sheetH = (screenH - safeTop) / 2.0
        }
        // safeAreaInset stacks on top of the scroll view's existing home-indicator
        // contentInset (= bottomInset). The anchor calculation sees both, so we must
        // subtract bottomInset twice to avoid an accidental +34 pt shift.
        // Net formula:  total_inset = bottomInset + insetH  →  we solve for insetH:
        //   (H − bottomInset) − (bottomInset + insetH) = T − 6
        //   insetH = sheetH − 2·bottomInset + 6
        return max(0, sheetH - 2 * bottomInset + 6)
    }

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
                        let sheetOpen = vm.activeSheet == .verse
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {

                                if vm.currentChapter == 1 {
                                    if showsGenesisHeader {
                                        // Full-bleed header that extends behind the nav bar and
                                        // status bar. Color.clear holds the layout height; the
                                        // background image uses ignoresSafeArea to reach all the
                                        // way to the top of the screen.
                                        Color.clear
                                            .frame(height: 260)
                                            .frame(maxWidth: .infinity)
                                            .background(alignment: .top) {
                                                Image("genesis_header")
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(maxWidth: .infinity)
                                                    .blendMode(.multiply)
                                                    .ignoresSafeArea(edges: .top)
                                            }
                                            // Negate the LazyVStack's own padding so the image
                                            // fills flush to the scroll view's top edge.
                                            .padding(.top, -12)
                                            .padding(.horizontal, -20)
                                            .padding(.bottom, 20)
                                    }

                                    Text(BibleBookNames.full(for: vm.currentBook.id))
                                        .font(.largeTitle)
                                        .bold()
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.bottom, 8)
                                }

                                Text(vm.chapterHeading)
                                    .font(.title2)
                                    .bold()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 8)

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
                        // Fine-correction scroll: fires when the sheet height is first
                        // measured (0 → actual). Covers the case where the initial scroll
                        // used the fallback insetH before the sheet settled.
                        .onChange(of: vm.verseSheetHeight) { oldH, newH in
                            guard oldH <= 0, newH > 0 else { return }
                            guard let id = vm.selectedVerse?.id,
                                  vm.activeSheet == .verse else { return }
                            // Fine-correction: short easeOut, not spring — this is an
                            // invisible nudge, not a user gesture. No snap needed.
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                        // Reset scroll position to top on every chapter change.
                        .id(vm.currentChapter)
                        // Only extend behind the nav bar when the genesis header image
                        // is present. Other chapters must render below the nav bar as normal.
                        .ignoresSafeAreaIf(showsGenesisHeader, edges: .top)
                        .gesture(
                            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                                .onEnded { value in
                                    // Only respond to mostly-horizontal swipes
                                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                                    if value.translation.width < 0 {
                                        vm.nextChapter()   // swipe left  → next
                                    } else {
                                        vm.prevChapter()   // swipe right → prev
                                    }
                                }
                        )
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
                                .fill(Color(UIColor.systemGroupedBackground))
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

