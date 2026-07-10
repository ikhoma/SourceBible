// ReaderViewModel.swift
// SourceBible

import Foundation
import Combine
import UIKit   // UIWindowScene — bottom safe-area inset for studySheetHeight

@MainActor
class ReaderViewModel: ObservableObject {

    // MARK: - Published State

    // Placeholder until init() Task loads real books from DB.
    // Uses BibleBookNames so the placeholder respects the active locale even before DB loads.
    @Published var currentBook: BibleBook = BibleBook(
        id: "GEN",
        name:      BibleBookNames.full(for: "GEN"),
        nameShort: BibleBookNames.short(for: "GEN"),
        testament: .old,
        chapterCount: 50
    )
    @Published var currentChapter: Int = 1
    @Published var currentTranslation: Translation = .defaultTranslation

    @Published var verses: [BibleVerse] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // Bottom Sheet
    @Published var selectedVerse: BibleVerse? = nil
    @Published var selectedWord: BibleWord? = nil
    @Published var selectedSegment: VerseSegment? = nil // segment from VerseTextView long press
    @Published var bottomSheetMode: BottomSheetMode = .verse

    /// Set by navigateToPreviousVerse / navigateToNextVerse before changing selectedVerse.
    /// ReaderView reads this to choose the scroll animation:
    ///   .tap      → .snappy spring (direct manipulation feel)
    ///   .chevron  → .easeInOut    (sequential traversal feel)
    /// Reset to .tap after each scroll so taps always get the spring.
    var verseScrollIntent: VerseScrollIntent = .tap

    /// Incremented on every tapVerse() call and every chevron navigation, even when
    /// selectedVerse.id is unchanged (re-tap of the same verse).
    /// ReaderView observes this instead of selectedVerse.id so re-tapping a verse
    /// always re-scrolls it back above the sheet if the user has scrolled away.
    @Published var verseScrollTrigger: Int = 0


    // Pickers — use a single sheet slot to avoid "only one sheet supported" warning
    @Published var activeSheet: ActiveSheet? = nil

    var isBookPickerPresented: Bool {
        get { activeSheet == .bookPicker }
        set { activeSheet = newValue ? .bookPicker : nil }
    }
    var isTranslationPickerPresented: Bool {
        get { activeSheet == .translationPicker }
        set { activeSheet = newValue ? .translationPicker : nil }
    }
    var isBottomSheetPresented: Bool {
        get { activeSheet == .verse }
        set { activeSheet = newValue ? .verse : nil }
    }

    // Strong's
    @Published var strongsEntry: StrongsEntry? = nil
    @Published var isLoadingStrongs: Bool = false

    // Highlights (via unified UserDataStore)
    let store: UserDataStoreProtocol
    /// verseId → HighlightColor.rawValue for the current chapter + translation.
    @Published var highlightColors: [String: String] = [:]

    // Reading-position persistence (spec-reader-resume-position.md).
    private let positionStore: ReadingPositionStore
    /// Armed by init() on launch when a saved position / last bookmark should be
    /// restored. ReaderView scrolls the matching verse to the top once verses load,
    /// then clears it. nil → no restore pending (scroll stays at chapter top).
    @Published var pendingRestoreAnchorId: String?
    /// Last verse recorded as the reading anchor; flushed to positionStore (debounced).
    private var lastReadingAnchorId: String?
    /// Reading-mode capture sink: each verse row reports its GLOBAL top (window Y) here as
    /// the user scrolls. Plain (NOT @Published) so continuous scroll never re-evaluates the
    /// heavy reader body. `captureTopVerseUnderToolbar()` reduces this to the single verse
    /// sitting just under the toolbar when scrolling settles.
    private var verseGlobalTops: [String: CGFloat] = [:]
    private var positionSaveTask: Task<Void, Never>?

    // MARK: - Analytics (injected from view layer on appear)
    var sessionTracker: SessionTracker = .noop
    /// Analytics service — injected in ReaderView .task (Slice 3: translationSwitched, highlights).
    var analytics: any AnalyticsService = NoopAnalytics.shared

    // MARK: - Data

    // Computed — DatabaseService.shared is NOT accessed until first method call,
    // so Preview init doesn't trigger sqlite3_open_v2 on launch
    private var db: DatabaseService { DatabaseService.shared }
    @Published var allBooks: [BibleBook] = []
    @Published var availableTranslations: [Translation] = []
    /// Translation-native book names: bookId → (long, short, sortOrder).
    /// Loaded on init and whenever the translation changes.
    @Published var translationBookNames: [String: (long: String, short: String, order: Int)] = [:]

    // MARK: - Init

    init(store: UserDataStoreProtocol,
         positionStore: ReadingPositionStore = UserDefaultsReadingPositionStore()) {
        self.store         = store
        self.positionStore = positionStore
        self.highlightColors = store.highlightColors(translation: Translation.defaultTranslation.id)

        // Previews: use sample data instantly, no DB access
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            allBooks             = BibleBook.sampleBooks
            availableTranslations = [.kjv]
            verses               = BibleVerse.sampleVerses
            isLoading            = false
            return
        }
        #endif

        // Don't block the main thread at launch — schedule DB load after app becomes responsive
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            self.allBooks              = self.db.loadBooks()
            self.availableTranslations = self.db.loadTranslations()
            // Restore persisted default translation (set from Menu settings)
            if let savedId = UserDefaults.standard.string(forKey: AppStorageKeys.defaultTranslationId),
               let match = self.availableTranslations.first(where: { $0.id == savedId }) {
                self.currentTranslation = match
            }
            self.translationBookNames  = self.db.loadBookNames(for: self.currentTranslation.id)
            self.restoreLaunchPosition()
            self.loadChapter()
        }
    }

    // MARK: - Reading position (resume)

    /// Resolves the launch target from the saved behavior and applies it to
    /// currentBook/currentChapter, arming pendingRestoreAnchorId. Falls back to
    /// Genesis 1:1 when there is nothing to restore. Runs inside init on MainActor.
    private func restoreLaunchPosition() {
        func genesis() {
            currentBook = allBooks.first { $0.id == "GEN" } ?? allBooks.first ?? currentBook
            currentChapter = 1
            pendingRestoreAnchorId = nil
        }

        let target: ReadingPosition?
        switch positionStore.launchBehavior {
        case .resume:       target = positionStore.load()
        case .lastBookmark: target = mostRecentBookmarkPosition() ?? positionStore.load()
        }

        guard let t = target,
              let book = allBooks.first(where: { $0.id == t.bookId }) else {
            genesis(); return
        }
        currentBook = book
        currentChapter = max(1, min(t.chapter, book.chapterCount))
        // Restore the anchor only if it belongs to the (possibly clamped) chapter.
        if let anchor = t.verseAnchorId, anchor.hasPrefix("\(book.id)|\(currentChapter)|") {
            // Cover exception: if the target is the very top of a chapter that shows a
            // book cover (chapter 1, covers enabled), resume like a fresh chapter open —
            // leave the scroll at the natural top so the cover is shown, rather than
            // pinning verse 1 under the toolbar. Only verse 1 triggers this; any deeper
            // verse still pins under the toolbar as usual.
            let coverShown = currentChapter == 1
                && !UserDefaults.standard.bool(forKey: AppStorageKeys.hideBookCovers)
            if coverShown && anchor == "\(book.id)|1|1" {
                pendingRestoreAnchorId = nil
            } else {
                pendingRestoreAnchorId = anchor
            }
        } else {
            pendingRestoreAnchorId = nil
        }
    }

    /// Most-recently-created bookmark → its first verse as a ReadingPosition.
    /// `store.bookmarks()` is ordered created_at DESC, so `.first` is the newest.
    private func mostRecentBookmarkPosition() -> ReadingPosition? {
        guard let bm = store.bookmarks().first,
              let vid = bm.verseIds.first,
              let parsed = Self.parseVerseId(vid) else { return nil }
        return ReadingPosition(bookId: parsed.bookId, chapter: parsed.chapter, verseAnchorId: vid)
    }

    /// Parse a compound verse ID "BOOK|chapter|verse" → (bookId, chapter).
    static func parseVerseId(_ id: String) -> (bookId: String, chapter: Int)? {
        let parts = id.split(separator: "|")
        guard parts.count == 3, let ch = Int(parts[1]) else { return nil }
        return (String(parts[0]), ch)
    }

    /// Record the reading anchor (top-visible verse in reading mode, or the focused
    /// verse in Study Mode) and persist it (debounced). No-ops for a verse outside the
    /// current chapter — guards stale scroll callbacks fired during a chapter switch.
    func noteReadingAnchor(_ verseId: String) {
        guard verseId.hasPrefix("\(currentBook.id)|\(currentChapter)|") else { return }
        lastReadingAnchorId = verseId
        let book = currentBook.id, chapter = currentChapter
        positionSaveTask?.cancel()
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.positionStore.save(ReadingPosition(bookId: book, chapter: chapter, verseAnchorId: verseId))
        }
    }

    /// Reading-mode row-top sink. Cheap by design: it only stores the row's global top.
    /// The reduction to a single anchor happens on scroll-idle (or flush), NOT per frame,
    /// so the heavy reader body is never re-evaluated by scrolling.
    func noteVerseTopFrame(_ minY: CGFloat, for verseId: String) {
        verseGlobalTops[verseId] = minY
    }

    /// Record the verse the reader currently sees at the top and persist it.
    /// Winner = the verse CROSSING the toolbar line (top at/above the line, bottom still
    /// below it) — i.e. the verse still visible at the top stays "current" until it has
    /// scrolled off entirely, at which point the next one takes over. Falls back to the
    /// first verse below the line when none crosses it (e.g. at the very top, where the
    /// cover/heading occupies the line). Restore then pins that verse's TOP to the same
    /// line, so a slightly-scrolled verse comes back as itself, not the next one.
    /// No-ops in Study Mode (anchor there is `selectedVerse`) and while a restore is pending.
    func captureTopVerseUnderToolbar() {
        guard activeSheet != .verse,
              pendingRestoreAnchorId == nil,
              toolbarBottomY > 0 else { return }
        let line = toolbarBottomY
        var bestId: String?

        // Preferred: the verse straddling the toolbar line. Among any straddlers pick the
        // lowest one (largest top) — the verse actually at the top of the reading area.
        var straddleTop = -CGFloat.greatestFiniteMagnitude
        for verse in verses {
            guard let minY = verseGlobalTops[verse.id] else { continue }
            let bottom = minY + (verseHeights[verse.id] ?? 0)
            if minY <= line, bottom > line, minY > straddleTop {
                straddleTop = minY
                bestId = verse.id
            }
        }

        // Fallback: nothing crosses the line → first verse below it.
        if bestId == nil {
            var bestMinY = CGFloat.greatestFiniteMagnitude
            for verse in verses {
                guard let minY = verseGlobalTops[verse.id], minY >= line, minY < bestMinY else { continue }
                bestMinY = minY
                bestId = verse.id
            }
        }

        if let id = bestId { noteReadingAnchor(id) }
    }

    /// Immediately persist the last known reading position (e.g. on scenePhase
    /// background), bypassing the debounce so a background kill doesn't lose it.
    func flushReadingPosition() {
        captureTopVerseUnderToolbar()   // fold in the current on-screen top before saving
        positionSaveTask?.cancel()
        positionStore.save(ReadingPosition(bookId: currentBook.id,
                                           chapter: currentChapter,
                                           verseAnchorId: lastReadingAnchorId))
    }

    // MARK: - Computed

    /// Short book abbreviation for the toolbar pill — uses translation-native short name when available.
    var currentBookShortName: String {
        BibleBookNames.spacedShort(
            translationBookNames[currentBook.id]?.short ?? BibleBookNames.short(for: currentBook.id)
        )
    }

    /// Translation-native short name for any book ID, falling back to BibleBookNames.
    func shortBookName(for bookId: String) -> String {
        BibleBookNames.spacedShort(
            translationBookNames[bookId]?.short ?? BibleBookNames.short(for: bookId)
        )
    }

    var chapterTitle: String { "\(currentBookShortName) \(currentChapter)" }

    /// Full chapter heading shown at the top of the reader — "Psalm 23" for Psalms, "Chapter 5" for everything else.
    /// Derives the heading word from the current translation's language so it's always native to the translation.
    var chapterHeading: String { chapterHeading(for: currentChapter) }

    /// Heading for an arbitrary chapter of the current book. Needed by the ADR-026
    /// chapter-paging spikes, where a prefetched adjacent page renders its own heading.
    func chapterHeading(for chapter: Int) -> String {
        let lang = currentTranslation.language
        if currentBook.id == "PSA" {
            switch lang {
            case "ru", "uk": return "Псалом \(chapter)"
            default:         return "Psalm \(chapter)"
            }
        } else {
            switch lang {
            case "ru": return "Глава \(chapter)"
            case "uk": return "Розділ \(chapter)"
            default:   return "Chapter \(chapter)"
            }
        }
    }

    var oldTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .old } }
    var newTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .new } }

    // MARK: - Canonical word↔segment mapping & clickability (ADR-016 amendment 2026-06-22)

    /// Extracts the numeric part from a Strong's ID: "H835a" → "835", "G2316" → "2316".
    func baseStrongsNumber(_ id: String) -> String {
        let s = id.drop(while: { !$0.isNumber })
        return String(s.prefix(while: { $0.isNumber }))
    }

    /// Resolves a segment Strong's ID to the Macula base number, applying the NASB extended
    /// override map when needed. e.g. "S9238" → "3887" (nasbExtendedOverride["9238"] = "3887").
    /// Falls back to the plain base number when no override exists.
    func resolvedMaculaBase(_ segStrongsId: String) -> String {
        let base = baseStrongsNumber(segStrongsId)
        return Self.nasbExtendedOverride[base] ?? base
    }

    /// True when this Macula word is clickable in the Original pill.
    ///
    /// Per-translation gate (ADR-016 amendment 2026-06-22): a word is clickable iff it
    /// participates in the canonical word↔segment mapping for the DISPLAYED translation,
    /// i.e. the translation tags its Strong's number. Particles/affixes fall out naturally
    /// (their own Strong's is never tagged by a translation). Replaces the NASB-set + morph
    /// fallback gate — measurement showed NASB gives no coverage advantage.
    func isClickable(_ word: BibleWord) -> Bool {
        clickableWordIDs.contains(word.id)
    }

    /// One tagged translation segment matched to its Macula word.
    struct WordSegmentPair {
        let word: BibleWord
        let segment: VerseSegment
    }

    /// Canonical per-verse mapping — single source of truth for clickability, navigation,
    /// highlight and the Word-tab title. Tagged segments of the displayed translation matched
    /// to Macula words, in translation reading order, occurrence-indexed (consume-in-order by
    /// resolvedMaculaBase, which still applies nasbExtendedOverride so NASB H9000+ numbers
    /// resolve). Words whose Strong's the translation never tags (particles/affixes) are absent.
    var verseWordSegmentPairs: [WordSegmentPair] {
        guard let segments = selectedVerse?.parsed?.segments,
              let words = selectedVerse?.words else { return [] }

        // Pool Macula words by base number, preserving original order for consume-in-order.
        var pool: [String: [BibleWord]] = [:]
        for word in words {
            guard let sid = word.strongsId else { continue }
            pool[baseStrongsNumber(sid), default: []].append(word)
        }

        var cursor: [String: Int] = [:]
        var pairs: [WordSegmentPair] = []
        var seen: Set<String> = []
        for seg in segments where !seg.strongs.isEmpty {
            for rawId in seg.strongs {
                let base = resolvedMaculaBase(rawId)
                let idx = cursor[base, default: 0]
                if let bucket = pool[base], idx < bucket.count {
                    let word = bucket[idx]
                    cursor[base] = idx + 1
                    if !seen.contains(word.id) {
                        pairs.append(WordSegmentPair(word: word, segment: seg))
                        seen.insert(word.id)
                    }
                }
            }
        }
        return pairs
    }

    /// Ids of clickable words (those present in the canonical mapping).
    var clickableWordIDs: Set<String> {
        Set(verseWordSegmentPairs.map { $0.word.id })
    }

    /// Clickable words in translation reading order — drives <> word navigation.
    var translationOrderedClickableWords: [BibleWord] {
        verseWordSegmentPairs.map { $0.word }
    }

    /// Kept for backward compatibility — prefer translationOrderedClickableWords for navigation.
    var verseWordsWithStrongs: [BibleWord] {
        selectedVerse?.words.filter { $0.strongsId != nil } ?? []
    }

    /// Translation text for the currently selected word/segment — shown as the Word tab header title.
    /// Priority: (1) selectedSegment.text (already translation text), (2) lookup matching ParsedVerse
    /// segment by base Strong's number (handles H835a ↔ H835 sub-entry mismatch),
    /// (3) fallback to BibleWord.text.
    var selectedWordDisplayText: String? {
        if let seg = selectedSegment {
            let t = seg.text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        if let word = selectedWord,
           let seg = verseWordSegmentPairs.first(where: { $0.word.id == word.id })?.segment {
            let t = seg.text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return selectedWord?.text.trimmingCharacters(in: .whitespaces)
    }

    var isCurrentVerseHighlighted: Bool {
        guard let v = selectedVerse else { return false }
        return highlightColors[v.id] != nil
    }

    // MARK: - Study Mode geometry (spec-study-mode-redesign.md R1/R3)
    //
    // Lives in the VM (not ReaderView @State) because the sheet detent must be
    // applied INSIDE VerseBottomSheetView: presentation-modifier arguments
    // captured in the presenting view's .sheet content closure go stale (the
    // closure is not re-evaluated when the presenter's @State changes), while
    // the sheet's own body re-renders on every vm change.

    /// Desired VISIBLE gap between the bottom of the pinned verse card and the
    /// real (on-screen) top of the sheet. Kept below the next row's top padding
    /// (~12 pt) so the next verse's number/text is hidden behind the sheet — at
    /// 16 a ~4 pt sliver peeked and the ±1 px height wobble made it flicker.
    static let sheetGap: CGFloat = 8
    /// Visible gap between the bottom of the toolbar and the pinned verse top.
    /// Separate from `sheetGap` because the references differ: the sheet's frame
    /// top is exact, but `toolbarBottomY` (NavBarBottomReader) is the nav-bar
    /// FRAME bottom, which sits ~4 pt below the visible floating capsule. So a
    /// 16-below-frame gap reads as ~20 below the visible toolbar. With the
    /// deterministic StudyScrollApplier this knob now maps 1:1 to on-screen pt.
    /// (debug 2026-06-16: [SCROLL] confirmed the card lands exactly at
    /// toolbarBottom+gap; perceived gap was ~4 pt larger → 16−4 = 12.)
    static let toolbarGap: CGFloat = 0
    /// Empirical correction. UIKit lays a custom-detent sheet out ~16 pt HIGHER
    /// than `containerHeight − detentHeight` — i.e. the sheet ends up ~16 pt
    /// taller than the detent value it's given. Measured on device
    /// (debug 2026-06-12, iPhone 17 sim): at detent=628, computedTop=246 but
    /// REAL sheet top=230. Without subtracting this, the sheet's real top lands
    /// flush on the verse card (visible gap = sheetGap − 16 = 0).
    /// NOTE: verify on a non–Dynamic-Island device; if it tracks safe area
    /// rather than being constant, derive it from the bottom inset instead.
    static let detentTopOffset: CGFloat = 16

    /// Global (window) Y of the navigation bar's BOTTOM edge, read from UIKit.
    /// The iOS 26 floating toolbar does NOT reduce the SwiftUI safe area, so a
    /// SwiftUI GeometryReader only ever saw the status bar and the pinned verse
    /// landed UNDER the toolbar. Reading the real `UINavigationBar` frame is the
    /// ground truth (mirrors the web prototype's explicit `headerHeight`).
    @Published var toolbarBottomY: CGFloat = 0

    /// Where the pinned verse's TOP lands: `toolbarGap` below the toolbar bottom.
    var pinnedTopAnchorY: CGFloat { toolbarBottomY + Self.toolbarGap }

    /// Measured intrinsic heights of verse rows, keyed by verse id. Each row writes
    /// its height once (it doesn't change with scroll). Stored PER-ID — not as a
    /// single "selected height" — because `onGeometryChange` does NOT re-fire when a
    /// row becomes selected (its height is unchanged), so a selection-gated single
    /// value never updated on tap and the sheet stayed at the fallback size.
    /// Plain (not @Published) to avoid a re-render storm on long chapters; the read
    /// below is driven by `selectedVerse` (which IS @Published) instead.
    private var verseHeights: [String: CGFloat] = [:]

    /// Record a row's measured height. Cheap, idempotent.
    ///
    /// `verseHeights` is intentionally NOT @Published (avoids a re-render storm on
    /// long chapters). The design relied on `selectedVerse` (which IS @Published)
    /// to drive the `studySheetHeight` recompute — which works only when the row is
    /// already measured BEFORE selection (the in-reader tap and warm cross-ref
    /// paths). When the verse is selected BEFORE its row is laid out — opening a
    /// verse from Search in another chapter/book, where a tab switch + deferred
    /// Task present the sheet before the freshly-loaded rows measure — the late
    /// height write published nothing, so the sheet stayed stuck at the
    /// `screenH * 0.45` pre-measurement fallback (the "~50% snap" bug; worst on
    /// huge chapters like Ps 119 where the layout pass is slow).
    ///
    /// Fix: when the row that just measured IS the selected verse, publish once so
    /// `studySheetHeight` recomputes and the detent applier resizes to the real
    /// height. Gated to the selected id → at most one extra render per selection,
    /// so the no-@Published rationale above still holds.
    func setVerseHeight(_ height: CGFloat, for id: String) {
        guard height > 0, abs((verseHeights[id] ?? 0) - height) > 0.5 else { return }
        verseHeights[id] = height
        if id == selectedVerse?.id {
            objectWillChange.send()
        }
    }

    /// Intrinsic height of the currently selected verse (0 until measured). Combined
    /// with `pinnedTopAnchorY` it yields the verse's pinned bottom with NO feedback
    /// loop, so `studySheetHeight` resolves once to its final value.
    var pinnedVerseHeight: CGFloat {
        guard let id = selectedVerse?.id else { return 0 }
        return verseHeights[id] ?? 0
    }

    /// Full screen height in points.
    private var screenHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds.height ?? 874
    }

    /// Single detent height for the Study Mode sheet, measured from the very
    /// bottom of the screen (matches UIKit custom-detent semantics observed
    /// on device): sheet top lands `sheetGap` below the pinned verse bottom.
    /// Clamped: never below 30% (very long verse) nor above 85% of the screen.
    var studySheetHeight: CGFloat {
        let screenH = screenHeight
        // Intrinsic geometry: pinned verse bottom = fixed top anchor + verse height.
        // Neither input depends on the live scroll offset, so this resolves ONCE to
        // its final value — no feedback loop, no chasing a moving target.
        guard toolbarBottomY > 0, pinnedVerseHeight > 0 else { return screenH * 0.45 }  // pre-measurement
        let verseBottom = pinnedTopAnchorY + pinnedVerseHeight
        let h = screenH - verseBottom - Self.sheetGap - Self.detentTopOffset
        return min(max(h, screenH * 0.30), screenH * 0.85)
    }

    /// Bottom scroll inset for Study Mode — the room reserved BELOW the pin point.
    /// This is NOT the sheet height: it must be large enough that even the chapter's
    /// LAST verse (no content beneath it) can scroll up until its top reaches
    /// `pinnedTopAnchorY`. The whole area below the pin (`screenH − anchor`) is always
    /// enough; the surplus over the sheet is invisible (scroll is locked and it sits
    /// behind the sheet). Using `studySheetHeight` here was the bug — roughly half the
    /// room the last verses need, so they could not reach the top.
    var studyScrollRoom: CGFloat {
        let screenH = screenHeight
        guard toolbarBottomY > 0 else { return screenH }   // generous pre-measurement
        return screenH - pinnedTopAnchorY
    }

    // MARK: - Study Mode navigation state
    //
    // Single source of truth for the toolbar <> chevrons in Study Mode
    // (spec-study-mode-redesign.md R5). Mirrors what used to live in
    // VerseBottomSheetView (isPrevDisabled / isNextDisabled).
    // No cross-chapter traversal: disabled at chapter boundaries (N2).

    /// True when the toolbar "previous" chevron should be disabled in Study Mode.
    var navPrevDisabled: Bool {
        if bottomSheetMode == .verse {
            guard let v = selectedVerse else { return true }
            return verses.first?.id == v.id
        } else {
            guard let w = selectedWord else { return true }
            return translationOrderedClickableWords.first?.id == w.id
        }
    }

    /// True when the toolbar "next" chevron should be disabled in Study Mode.
    var navNextDisabled: Bool {
        if bottomSheetMode == .verse {
            guard let v = selectedVerse else { return true }
            return verses.last?.id == v.id
        } else {
            guard let w = selectedWord else { return true }
            return translationOrderedClickableWords.last?.id == w.id
        }
    }

    var currentVerseHighlightColor: HighlightColor? {
        guard let v = selectedVerse, let raw = highlightColors[v.id] else { return nil }
        return HighlightColor(rawValue: raw)
    }

    // MARK: - Navigation

    func navigateTo(book: BibleBook, chapter: Int) {
        currentBook = book
        currentChapter = chapter
        isBookPickerPresented = false
        loadChapter()
    }

    func selectTranslation(_ translation: Translation) {
        // Capture `from` BEFORE assignment so we can compare (spec §C: fire only if from != to).
        let fromId = currentTranslation.id
        currentTranslation = translation
        translationBookNames = db.loadBookNames(for: translation.id)
        isTranslationPickerPresented = false
        loadChapter()
        // Re-load concordance so the word usage tab reflects the new translation immediately.
        if let word = selectedWord {
            loadStrongs(for: word)
        } else if let seg = selectedSegment, let verse = selectedVerse {
            loadStrongs(for: seg, bookId: verse.bookId)
        }
        // Analytics: discrete translation_switched (low-volume, high-value; via analytics directly).
        if fromId != translation.id {
            analytics.track(.translationSwitched(from: fromId, to: translation.id))
        }
    }

    func prevChapter() {
        guard currentChapter > 1 else { return }
        currentChapter -= 1
        loadChapter()
    }

    func nextChapter() {
        guard currentChapter < currentBook.chapterCount else { return }
        currentChapter += 1
        loadChapter()
    }

    // MARK: - Cross-Reference Back Stack (ADR-024)

    /// Stack of verse IDs representing the cross-ref navigation history.
    /// Top of the stack (last element) is the most recent origin.
    /// Session-scoped: cleared when the sheet is dismissed.
    @Published private(set) var crossRefBackStack: [String] = []

    /// True when the back stack has at least one entry (i.e. user followed at least one cross-ref).
    var canCrossRefBack: Bool { !crossRefBackStack.isEmpty }

    /// Follow a cross-reference link from within the open bottom sheet.
    /// Pushes the current verse onto the back stack before navigating.
    func followCrossReference(to verseId: String) {
        navigateToVerse(id: verseId, source: .crossRef)
    }

    /// Navigate back one step in the cross-ref history.
    /// Pops the previous verse from the stack and navigates to it.
    func crossRefBack() {
        guard let previous = crossRefBackStack.popLast() else { return }
        navigateToVerse(id: previous, source: .back)
    }

    /// Clear the back stack — called from onDismiss so the next sheet entry starts fresh.
    func resetCrossRefStack() {
        crossRefBackStack.removeAll()
    }

    /// Navigate to a specific verse by its compound ID "BOOK|chapter|verse" (e.g. "ROM|5|1").
    /// Switches book/chapter if needed, then scrolls to the verse and opens the bottom sheet.
    func navigateToVerse(id verseId: String) {
        navigateToVerse(id: verseId, source: .fresh)
    }

    /// Navigate to a specific verse by its compound ID "BOOK|chapter|verse" (e.g. "ROM|5|1").
    /// Switches book/chapter if needed, then scrolls to the verse and opens the bottom sheet.
    private func navigateToVerse(id verseId: String, source: VerseNavSource) {
        let parts = verseId.split(separator: "|")
        guard parts.count == 3,
              let chapter = Int(parts[1]) else { return }
        let bookId = String(parts[0])

        var needsLoad = false

        // Switch book if needed
        if bookId != currentBook.id {
            if let book = allBooks.first(where: { $0.id == bookId }) {
                currentBook = book
                needsLoad = true   // book changed → verses belong to different book
            }
        }
        // Switch chapter if needed
        if chapter != currentChapter {
            currentChapter = chapter
            needsLoad = true
        }
        if needsLoad {
            loadChapter()
        }

        // Select the target verse, load Macula words, and open the bottom sheet.
        // loadWordsForSelectedVerse() is required here — navigateToVerse() skips
        // the normal tapVerse() path that loads words for the Original tab.
        if let verse = verses.first(where: { $0.id == verseId }) {
            // ADR-024: manage back stack BEFORE updating selectedVerse, using the
            // success branch only (so a failed lookup doesn't pollute the stack).
            switch source {
            case .fresh:
                // New entry point — reset the back stack for a clean session.
                crossRefBackStack.removeAll()
            case .crossRef:
                // Push the current verse (if the sheet is open and a verse is selected)
                // so the user can navigate back to it.
                if activeSheet == .verse, let current = selectedVerse, current.id != verseId {
                    crossRefBackStack.append(current.id)
                }
            case .back:
                // Stack was already popped by crossRefBack() — nothing to do here.
                break
            }

            selectedVerse = verse
            selectedWord = nil
            selectedSegment = nil
            bottomSheetMode = .verse
            loadWordsForSelectedVerse()
            noteReadingAnchor(verse.id)   // Study Mode anchor = focused verse
            isBottomSheetPresented = true
            // Trigger scroll-above-sheet so the selected verse is visible when
            // navigating from search. When the chapter changed (needsLoad = true)
            // the scroll view was reset via .id(currentChapter) — defer one RunLoop
            // tick so the new layout is committed before scrollTo fires.
            verseScrollTrigger += 1
            // Analytics: record unique verse read.
            // Skip incVersesOpened on .back — the verse was already counted when first opened.
            if source != .back {
                sessionTracker.incVersesOpened(verseId: verseId)
            }
        }
    }

    func previousChapter() {
        guard currentChapter > 1 else { return }
        currentChapter -= 1
        loadChapter()
    }

    // MARK: - Load Data

    /// ADR-026 spike prefetch cache: verses for adjacent pager pages, keyed
    /// "book|chapter|translation". Intentionally NOT @Published — pages read it
    /// during body evaluation; a publish would re-render the heavy reader body.
    /// Cleared by loadChapter() so highlights/translation changes re-derive it.
    private var pageVersesCache: [String: [BibleVerse]] = [:]

    /// Verses for one pager page WITHOUT touching @Published state (ADR-026 hard
    /// rule: no loadChapter()/@Published re-map during the page transition).
    /// The current chapter returns the live `verses` (so highlight changes render);
    /// adjacent pages get a cached direct DB read.
    func versesForPage(_ chapter: Int) -> [BibleVerse] {
        if chapter == currentChapter,
           let first = verses.first, first.bookId == currentBook.id, first.chapter == chapter {
            return verses
        }
        #if DEBUG
        // Previews run on sample data — never touch DatabaseService for adjacent pages.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return chapter == currentChapter ? verses : []
        }
        #endif
        let key = "\(currentBook.id)|\(chapter)|\(currentTranslation.id)"
        if let cached = pageVersesCache[key] { return cached }
        let loaded = db.loadChapter(bookId: currentBook.id,
                                    chapter: chapter,
                                    translation: currentTranslation.id)
            .map { v in
                BibleVerse(id: v.id, bookId: v.bookId, chapter: v.chapter,
                           number: v.number, text: v.text, words: v.words,
                           highlightColor: highlightColors[v.id],
                           parsed: v.parsed)
            }
        pageVersesCache[key] = loaded
        return loaded
    }

    func loadChapter() {
        isLoading = true
        errorMessage = nil
        // ADR-026: chapter/translation/highlight state is changing — drop the pager
        // prefetch cache so adjacent pages re-derive from the fresh state.
        pageVersesCache.removeAll()
        // SQLite reads with in-memory cache take <1ms — no background thread needed.
        // Avoids all Swift 6 actor-isolation issues with Task.detached.
        highlightColors = store.highlightColors(translation: currentTranslation.id)
        verses = db.loadChapter(bookId: currentBook.id,
                                chapter: currentChapter,
                                translation: currentTranslation.id)
            .map { v in
                BibleVerse(id: v.id, bookId: v.bookId, chapter: v.chapter,
                           number: v.number, text: v.text, words: v.words,
                           highlightColor: highlightColors[v.id],
                           parsed: v.parsed)
            }
        isLoading = false
    }

    /// Load words for a verse on demand (called from bottom sheet).
    /// Uses Strong's overlap matching to find the correct Macula verse number,
    /// correcting for MT/translation numbering offsets (common in 62 Psalm chapters
    /// where the Hebrew superscription counts as verse 1 but translations omit it).
    func loadWordsForSelectedVerse() {
        guard let verse = selectedVerse else { return }
        let maculaVerse = findBestMaculaVerse(for: verse)
        let words = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: maculaVerse)
        if let idx = verses.firstIndex(where: { $0.id == verse.id }) {
            let v = verses[idx]
            verses[idx] = BibleVerse(id: v.id, bookId: v.bookId, chapter: v.chapter,
                                     number: v.number, text: v.text, words: words,
                                     highlightColor: v.highlightColor, parsed: v.parsed)
            selectedVerse = verses[idx]
        }
    }

    /// Returns the Macula (MT) verse number for the given translation verse.
    ///
    /// Resolution order:
    ///   1. verse_map table (deterministic, pre-computed at DB build time)
    ///      — covers all 459 chapters across all translations where counts differ.
    ///   2. Identity mapping (translation verse == Macula verse) for all other chapters.
    ///   3. Strong's-overlap heuristic (±2 search) as a safety net for any
    ///      genuinely unmapped edge cases.
    private func findBestMaculaVerse(for verse: BibleVerse) -> Int {
        // 1. DB lookup — O(1) indexed read
        if let mapped = db.findMaculaVerse(bookId: verse.bookId,
                                           chapter: verse.chapter,
                                           translationVerse: verse.number,
                                           translation: currentTranslation.id) {
            return mapped
        }

        // 2. Identity — the vast majority of chapters need no adjustment
        //    Verify with a quick Strong's check before trusting identity.
        let prefix = (allBooks.first { $0.id == verse.bookId }?.testament == .new) ? "G" : "H"
        let parsedStrongs = Set(
            verse.parsed?.segments.flatMap(\.strongs).map { id in
                id.hasPrefix("S") ? prefix + id.dropFirst() : id
            } ?? []
        )
        guard parsedStrongs.count >= 2 else { return verse.number }

        let exactWords   = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: verse.number)
        let exactStrongs = Set(exactWords.compactMap(\.strongsId))
        if parsedStrongs.intersection(exactStrongs).count >= 2 { return verse.number }

        // 3. Heuristic fallback — unmapped edge case
        var bestVerse   = verse.number
        var bestOverlap = parsedStrongs.intersection(exactStrongs).count
        for delta in [-1, 1, -2, 2] {
            let candidate = verse.number + delta
            guard candidate > 0 else { continue }
            let words   = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: candidate)
            let overlap = parsedStrongs.intersection(Set(words.compactMap(\.strongsId))).count
            if overlap > bestOverlap { bestOverlap = overlap; bestVerse = candidate }
        }
        return bestVerse
    }

    /// Returns verse text in all available translations.
    func loadParallelVerses() -> [VerseTranslation] {
        guard let verse = selectedVerse else { return [] }
        return availableTranslations.compactMap { t in
            guard let text = db.loadVerseText(bookId: verse.bookId, chapter: verse.chapter,
                                               verse: verse.number, translation: t.id)
            else { return nil }
            return VerseTranslation(id: t.id, translation: t, text: text)
        }
    }

    /// Load cross-references for the selected verse in the currently selected translation.
    func loadCrossReferences() -> [CrossReference] {
        guard let verse = selectedVerse else { return [] }
        return db.loadCrossReferences(bookId: verse.bookId,
                                       chapter: verse.chapter,
                                       verse: verse.number,
                                       translation: currentTranslation.id,
                                       bookShortNames: translationBookNames.mapValues { $0.short })
    }

    // MARK: - Bottom Sheet

    func tapVerse(_ verse: BibleVerse) {
        selectedVerse = verse
        selectedWord = nil
        selectedSegment = nil
        bottomSheetMode = .verse
        activeSheet = .verse
        verseScrollTrigger += 1
        loadWordsForSelectedVerse()
        noteReadingAnchor(verse.id)   // Study Mode anchor = focused verse
        // Analytics: record unique verse read.
        sessionTracker.incVersesOpened(verseId: verse.id)
    }

    /// Called from VerseTextView long press — receives a VerseSegment with strongs: [String].
    /// Bridges to the matching BibleWord so WordMeaningView shows full morphology/xlit/greek.
    func tapWord(_ segment: VerseSegment, in verse: BibleVerse) {
        selectedVerse = verse
        selectedSegment = segment
        bottomSheetMode = .word
        activeSheet = .verse

        // Ensure Macula words are loaded
        if verse.words.isEmpty { loadWordsForSelectedVerse() }

        // Bridge to the exact Macula word paired with THIS segment instance in the canonical
        // mapping — handles repeated words (e.g. לֹא…לֹא…לֹא) without jumping to a prior instance.
        selectedWord = verseWordSegmentPairs.first { $0.segment.id == segment.id }?.word

        // Prefer the Macula word's strongsId (e.g. H3887a) over the segment ID (e.g. H3887).
        // The strongs table is backfilled from Macula, so bare OpenScriptures IDs like H3887
        // may have no row at all — only the sub-entry H3887a exists. Using the Macula ID
        // ensures loadStrongs finds a row and the sub-entry fallback can kick in.
        if let word = selectedWord {
            loadStrongs(for: word)
        } else {
            loadStrongs(for: segment, bookId: verse.bookId)
        }
    }

    /// Called from OriginalWordsView (bottom sheet) — receives a Macula BibleWord.
    /// syncSegment sets selectedSegment so the verse text highlights the word.
    func tapWord(_ word: BibleWord, in verse: BibleVerse) {
        selectedVerse = verse
        selectedWord = word
        bottomSheetMode = .word
        activeSheet = .verse
        syncSegment(for: word)
        loadStrongs(for: word)
    }

    /// Called when the bottom sheet is dismissed — clears word/segment selection
    /// so the verse text no longer shows a highlight after the sheet closes.
    func clearWordSelection() {
        selectedWord = nil
        selectedSegment = nil
    }

    func navigateToPreviousVerse() {
        guard let current = selectedVerse,
              let idx = verses.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        verseScrollIntent = .chevron
        selectedVerse = verses[idx - 1]
        selectedWord = nil
        selectedSegment = nil
        verseScrollTrigger += 1
        loadWordsForSelectedVerse()
        // Analytics: verse chevron nav + unique verse read.
        sessionTracker.incVerseNav()
        if let newId = selectedVerse?.id { sessionTracker.incVersesOpened(verseId: newId) }
    }

    func navigateToNextVerse() {
        guard let current = selectedVerse,
              let idx = verses.firstIndex(where: { $0.id == current.id }),
              idx < verses.count - 1 else { return }
        verseScrollIntent = .chevron
        selectedVerse = verses[idx + 1]
        selectedWord = nil
        selectedSegment = nil
        verseScrollTrigger += 1
        loadWordsForSelectedVerse()
        // Analytics: verse chevron nav + unique verse read.
        sessionTracker.incVerseNav()
        if let newId = selectedVerse?.id { sessionTracker.incVersesOpened(verseId: newId) }
    }

    /// Navigate to the previous meaningful word in the focused verse (translation order).
    func navigateToPreviousWord() {
        let pairs = verseWordSegmentPairs
        guard let word = selectedWord,
              let idx = pairs.firstIndex(where: { $0.word.id == word.id }),
              idx > 0 else { return }
        let prev = pairs[idx - 1]
        selectedWord = prev.word
        selectedSegment = prev.segment
        loadStrongs(for: prev.word)
        // Analytics: word chevron nav.
        sessionTracker.incWordNav()
    }

    /// Navigate to the next meaningful word in the focused verse (translation order).
    func navigateToNextWord() {
        let pairs = verseWordSegmentPairs
        guard let word = selectedWord,
              let idx = pairs.firstIndex(where: { $0.word.id == word.id }),
              idx < pairs.count - 1 else { return }
        let next = pairs[idx + 1]
        selectedWord = next.word
        selectedSegment = next.segment
        loadStrongs(for: next.word)
        // Analytics: word chevron nav.
        sessionTracker.incWordNav()
    }

    /// Sets selectedSegment to the segment paired with `word` in the canonical mapping, so the
    /// verse-text highlight tracks chevron navigation and Original-pill taps — including repeated
    /// words (each occurrence is a distinct pair, so no jumping to a previous instance).
    private func syncSegment(for word: BibleWord) {
        selectedSegment = verseWordSegmentPairs.first { $0.word.id == word.id }?.segment
    }

    /// Switch to word mode; if no word is selected, auto-select the first word with a Strong's number.
    /// Called from tap handlers (also sets the mode).
    func switchToWordMode() {
        bottomSheetMode = .word
        autoSelectFirstWordIfNeeded()
    }

    /// Auto-select the first word with a Strong's number if nothing is currently selected.
    /// Called from the Picker's onChange so the mode is already set — avoids re-triggering the binding.
    func autoSelectFirstWordIfNeeded() {
        guard selectedWord == nil && selectedSegment == nil else { return }
        if let first = verseWordSegmentPairs.first {
            selectedWord = first.word
            selectedSegment = first.segment
            loadStrongs(for: first.word)
        }
    }

    // MARK: - Strong's

    /// Load Strong's entry for a VerseSegment (from VerseTextView long press).
    /// bookId is used to resolve "S1234" placeholders → "H1234" (OT) or "G1234" (NT).
    func loadStrongs(for segment: VerseSegment, bookId: String = "") {
        guard let raw = segment.strongs.first else { strongsEntry = nil; return }
        let strongsId = resolveStrongsId(raw, bookId: bookId)
        loadStrongs(strongsId: strongsId)
    }

    /// Converts "S1234" placeholder → "H1234" (Old Testament) or "G1234" (New Testament).
    /// Already-prefixed ids ("H…" / "G…") pass through unchanged.
    private func resolveStrongsId(_ raw: String, bookId: String) -> String {
        guard raw.hasPrefix("S") else { return raw }
        let testament = allBooks.first(where: { $0.id == bookId })?.testament ?? .old
        return (testament == .old ? "H" : "G") + raw.dropFirst()
    }

    /// Load Strong's entry for a Macula BibleWord (future — called once word table is populated).
    func loadStrongs(for word: BibleWord) {
        guard let strongsId = word.strongsId else {
            strongsEntry = nil
            return
        }
        loadStrongs(strongsId: strongsId)
    }

    private func loadStrongs(strongsId: String) {
        isLoadingStrongs = true
        // Strong's lookups are fast indexed reads — stay on MainActor.
        // Usage (concordance) data is NOT loaded here anymore: loadBookUsageGroups
        // (Queries A+B+C, incl. N per-book verse fetches) was the heavy part of the
        // Word-tab switch lag, and it feeds only the Usage sub-tab while the default
        // sub-tab is Meaning. It loads lazily via loadUsageIfNeeded().
        strongsEntry = db.loadStrongs(id: strongsId)
        isLoadingStrongs = false
    }

    /// Lazily loads Usage (concordance) data into the current Strong's entry.
    /// Called from ConcordanceView on appear and on entry change — the first open
    /// of the Usage sub-tab per word pays the cost (Queries A+B+C: total count,
    /// per-book group-by, N per-book verse fetches; < 50ms even for יהוה with
    /// 6 512 occurrences). Repeat visits are free (usageLoaded guard).
    func loadUsageIfNeeded() {
        guard var entry = strongsEntry, !entry.usageLoaded else { return }
        let result = db.loadBookUsageGroups(strongsId: entry.id,
                                            translation: currentTranslation.id,
                                            bookShortNames: translationBookNames.mapValues { $0.short },
                                            bookLongNames:  translationBookNames.mapValues { $0.long })
        entry.totalCount  = result.total
        entry.bookGroups  = result.groups
        entry.usageLoaded = true
        strongsEntry = entry
    }

    // MARK: - Highlights

    /// Apply or change a highlight color. Always results in an active highlight of the given color.
    func setHighlightColor(_ color: HighlightColor, for verse: BibleVerse) {
        if let existing = highlightColors[verse.id] {
            if existing != color.rawValue {
                // Change color in-place — avoids fragile double-toggle sequencing
                store.updateHighlightColor(verseId: verse.id,
                                           translation: currentTranslation.id,
                                           color: color.rawValue)
            }
            // Same color → already applied, no-op
        } else {
            // no-highlight → highlighted: this is a new annotation (Slice 3 §C).
            store.toggleHighlight(verseId: verse.id,
                                  translation: currentTranslation.id,
                                  color: color.rawValue)
            analytics.track(.highlightCreated(color: color.rawValue))
            sessionTracker.incAnnotation()
        }
        refreshHighlightInList(verseId: verse.id)
    }

    /// Remove any active highlight from the verse. No-op if not highlighted.
    func removeHighlight(for verse: BibleVerse) {
        guard let existing = highlightColors[verse.id] else { return }
        store.toggleHighlight(verseId: verse.id, translation: currentTranslation.id, color: existing)
        refreshHighlightInList(verseId: verse.id)
    }

    /// Legacy convenience — toggles using default yellow color (used by action bar for quick toggle).
    func toggleHighlight(for verse: BibleVerse, color: HighlightColor = .yellow) {
        if highlightColors[verse.id] != nil {
            removeHighlight(for: verse)
        } else {
            setHighlightColor(color, for: verse)
        }
    }

    private func refreshHighlightInList(verseId: String) {
        highlightColors = store.highlightColors(translation: currentTranslation.id)
        if let idx = verses.firstIndex(where: { $0.id == verseId }) {
            let v = verses[idx]
            verses[idx] = BibleVerse(
                id: v.id, bookId: v.bookId, chapter: v.chapter, number: v.number,
                text: v.text, words: v.words,
                highlightColor: highlightColors[v.id],
                parsed: v.parsed
            )
            if selectedVerse?.id == v.id {
                selectedVerse = verses[idx]
            }
        }
    }
}

// MARK: - Verse Navigation Source (ADR-024)

/// Describes what triggered a `navigateToVerse(id:source:)` call.
/// Controls how the cross-ref back stack is updated.
enum VerseNavSource: Equatable {
    /// Fresh tap (verse row, search, bookmarks, notes, pendingVerseId).
    /// Clears the back stack — this is a new entry point.
    case fresh
    /// Cross-reference tap from within an open bottom sheet.
    /// Pushes the current verse onto the back stack before navigating.
    case crossRef
    /// «‹ Назад» button — back stack was already popped by the caller.
    /// No push/clear needed.
    case back
}

// MARK: - Bottom Sheet Mode

enum BottomSheetMode: Hashable {
    case verse, word
}

enum VerseScrollIntent {
    case tap     // direct tap → spring (.snappy)
    case chevron // chevron navigation → easeInOut (calm, sequential)
}

// MARK: - Active Sheet (single slot to avoid multi-sheet conflicts)

enum ActiveSheet: Identifiable {
    case bookPicker
    case translationPicker
    case verse

    var id: Self { self }
}
