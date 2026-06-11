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
        id: "PSA",
        name:      BibleBookNames.full(for: "PSA"),
        nameShort: BibleBookNames.short(for: "PSA"),
        testament: .old,
        chapterCount: 150
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

    /// NASB Strong's base numbers for the currently focused verse.
    /// Loaded once per verse regardless of selected translation, used to gate
    /// clickability in the Original pill (Option A: NASB-gated).
    @Published var nasbVerseStrongs: Set<String> = []

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

    init(store: UserDataStoreProtocol) {
        self.store   = store
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
            if let savedId = UserDefaults.standard.string(forKey: "defaultTranslationId"),
               let match = self.availableTranslations.first(where: { $0.id == savedId }) {
                self.currentTranslation = match
            }
            self.translationBookNames  = self.db.loadBookNames(for: self.currentTranslation.id)
            self.currentBook = self.allBooks.first(where: { $0.id == "PSA" })
                            ?? self.allBooks.first
                            ?? self.currentBook
            self.loadChapter()
        }
    }

    // MARK: - Computed

    /// Short book abbreviation for the toolbar pill — uses translation-native short name when available.
    var currentBookShortName: String {
        translationBookNames[currentBook.id]?.short ?? BibleBookNames.short(for: currentBook.id)
    }

    var chapterTitle: String { "\(currentBookShortName) \(currentChapter)" }

    /// Full chapter heading shown at the top of the reader — "Psalm 23" for Psalms, "Chapter 5" for everything else.
    /// Derives the heading word from the current translation's language so it's always native to the translation.
    var chapterHeading: String {
        let lang = currentTranslation.language
        if currentBook.id == "PSA" {
            switch lang {
            case "ru", "uk": return "Псалом \(currentChapter)"
            default:         return "Psalm \(currentChapter)"
            }
        } else {
            switch lang {
            case "ru": return "Глава \(currentChapter)"
            case "uk": return "Розділ \(currentChapter)"
            default:   return "Chapter \(currentChapter)"
            }
        }
    }

    var oldTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .old } }
    var newTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .new } }

    // MARK: - NASB-gated clickability (Option A)

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

    /// True when this Macula word should be clickable in the Original pill.
    ///
    /// Primary check: the word's Strong's base number appears in NASB tagging for this verse.
    /// Extended override: NASB proprietary numbers (H9000+) are resolved via nasbExtendedOverride.
    /// Fallback (unresolved extended / NASB has no text): allow if word is not a definite article
    /// or pronominal suffix — the only two categories NASB never tags as standalone lexemes.
    func isClickable(_ word: BibleWord) -> Bool {
        guard let sid = word.strongsId else { return false }
        let base = baseStrongsNumber(sid)

        // Direct match against NASB numbers for this verse
        if nasbVerseStrongs.contains(base) { return true }

        // nasbVerseStrongs is empty when NASB has no verse text (very rare / NT Aramaic)
        // or when the verse hasn't loaded yet — fall through to morph fallback below.

        // If NASB is loaded and base not found, check morph fallback:
        // Definite articles (Td, Greek ART-) and pronominal suffixes (Sp*, Sd)
        // are the only morphological categories NASB never tags as standalone words.
        guard let morph = word.morphology else { return nasbVerseStrongs.isEmpty }
        if morph.hasPrefix("Td") || morph.hasPrefix("Sp") || morph.hasPrefix("Sd") { return false }
        if morph.hasPrefix("ART-") { return false }   // Greek definite article

        // If NASB is loaded and this word isn't tagged, it's genuinely untagged (e.g. prefix
        // prepositions H871a, prefix conjunctions H2050b). The old fallback `return true` was
        // intended for unresolved extended NASB numbers, but those are now fully covered by
        // nasbExtendedOverride in loadNASBStrongs — so we no longer need the open fallback.
        return nasbVerseStrongs.isEmpty
    }

    /// Non-particle Macula words for the focused verse — in original Hebrew/Greek order.
    var nasbClickableWords: [BibleWord] {
        selectedVerse?.words.filter { isClickable($0) } ?? []
    }

    /// Clickable words ordered by their position in the translation text (segment order).
    /// Used for <> navigation so stepping through words follows reading order, not original order.
    ///
    /// Algorithm: walk translation segments in order; for each segment with a Strong's match,
    /// find the Nth occurrence of that Strong's in the Macula word list (consume-in-order).
    /// Words with no matching segment are skipped (they have no translation highlight anyway).
    var translationOrderedClickableWords: [BibleWord] {
        guard let segments = selectedVerse?.parsed?.segments else { return nasbClickableWords }
        let clickable = nasbClickableWords

        // Build a base-number → [BibleWord] map preserving Hebrew order for consume-in-order matching
        var pool: [String: [BibleWord]] = [:]
        for word in clickable {
            guard let sid = word.strongsId else { continue }
            let base = baseStrongsNumber(sid)
            pool[base, default: []].append(word)
        }

        // Consumption cursors — how many times we've already consumed each base number
        var cursor: [String: Int] = [:]
        var ordered: [BibleWord] = []
        var seen: Set<String> = []  // avoid duplicates if one segment maps to multiple strongs

        for seg in segments where !seg.strongs.isEmpty {
            for rawId in seg.strongs {
                let base = resolvedMaculaBase(rawId)
                let idx = cursor[base, default: 0]
                if let words = pool[base], idx < words.count {
                    let word = words[idx]
                    if !seen.contains(word.id) {
                        ordered.append(word)
                        seen.insert(word.id)
                    }
                    cursor[base] = idx + 1
                }
            }
        }
        return ordered
    }

    /// Kept for backward compatibility — prefer nasbClickableWords for navigation.
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
           let strongsId = word.strongsId,
           let parsed = selectedVerse?.parsed {
            let base = baseStrongsNumber(strongsId)
            let sameBase = nasbClickableWords.filter {
                guard let sid = $0.strongsId else { return false }
                return baseStrongsNumber(sid) == base
            }
            let occurrenceIdx = sameBase.firstIndex(where: { $0.id == word.id }) ?? 0
            var count = 0
            for seg in parsed.segments {
                if seg.strongs.contains(where: { resolvedMaculaBase($0) == base }) {
                    if count == occurrenceIdx {
                        let t = seg.text.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { return t }
                        break
                    }
                    count += 1
                }
            }
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

    /// Top inset for the pinned verse. The verse TEXT sits 16 pt below the
    /// toolbar: 6 pt inset + 10 pt internal row padding.
    static let pinnedTopInset: CGFloat = 6
    /// Visual gap between the bottom of the pinned verse row and the sheet top.
    static let sheetGap: CGFloat = 8

    /// Measured heights of ALL verse rows (verse.id → height), written by
    /// ReaderView from an unconditional onGeometryChange on every row.
    /// Measuring every row (instead of only the selected one) makes the value
    /// deterministic: selection changes are a dictionary lookup, with no
    /// dependence on a conditional measuring view firing its initial callback.
    /// Rows are re-measured automatically on translation switch / Dynamic Type.
    @Published var verseRowHeights: [String: CGFloat] = [:]

    /// Height of the pinned (selected) verse row.
    var pinnedVerseHeight: CGFloat {
        guard let id = selectedVerse?.id else { return 0 }
        return verseRowHeights[id] ?? 0
    }

    /// Height of the reader content area (below nav bar, above bottom safe
    /// area). Written by ReaderView via onGeometryChange.
    @Published var readerContainerHeight: CGFloat = 0

    /// Global (screen-coordinate) bottom edge of the pinned verse row,
    /// written by ReaderView while Study Mode is active. Direct geometry:
    /// no assumptions about nav-bar or container heights — those produced a
    /// systematic ~50 pt gap (debug session 2026-06-12: ZStack-measured
    /// container disagreed with the scroll viewport's real top inset).
    @Published var pinnedVerseGlobalBottom: CGFloat = 0

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
        guard pinnedVerseGlobalBottom > 0 else { return screenH * 0.45 }  // pre-measurement
        let h = screenH - pinnedVerseGlobalBottom - Self.sheetGap
        return min(max(h, screenH * 0.30), screenH * 0.85)
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

    /// Navigate to a specific verse by its compound ID "BOOK|chapter|verse" (e.g. "ROM|5|1").
    /// Switches book/chapter if needed, then scrolls to the verse and opens the bottom sheet.
    func navigateToVerse(id verseId: String) {
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
            selectedVerse = verse
            selectedWord = nil
            selectedSegment = nil
            bottomSheetMode = .verse
            loadWordsForSelectedVerse()
            isBottomSheetPresented = true
            // Trigger scroll-above-sheet so the selected verse is visible when
            // navigating from search. When the chapter changed (needsLoad = true)
            // the scroll view was reset via .id(currentChapter) — defer one RunLoop
            // tick so the new layout is committed before scrollTo fires.
            verseScrollTrigger += 1
        }
    }

    func previousChapter() {
        guard currentChapter > 1 else { return }
        currentChapter -= 1
        loadChapter()
    }

    // MARK: - Load Data

    func loadChapter() {
        isLoading = true
        errorMessage = nil
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
        // Load NASB Strong's for clickability gating (Option A).
        // Runs regardless of the currently selected translation.
        loadNASBStrongs(for: verse)
    }

    /// Load NASB Strong's base numbers for the given verse into nasbVerseStrongs.
    /// Applies the extended-number override map so H9238 resolves to "3887" etc.
    private func loadNASBStrongs(for verse: BibleVerse) {
        let raw = db.loadNASBStrongs(bookId: verse.bookId,
                                     chapter: verse.chapter,
                                     verse: verse.number)
        var bases = Set<String>()
        for num in raw {
            bases.insert(num)
            // Extended NASB number → add the Macula equivalent base as well
            if let maculaBase = Self.nasbExtendedOverride[num] {
                bases.insert(maculaBase)
            }
        }
        nasbVerseStrongs = bases
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
                                       translation: currentTranslation.id)
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

        // Bridge: find BibleWord by base Strong's number so WordMeaningView gets full data
        if let raw = segment.strongs.first {
            let resolved = resolveStrongsId(raw, bookId: verse.bookId)
            let base = baseStrongsNumber(resolved)
            selectedWord = selectedVerse?.words.first {
                guard let sid = $0.strongsId else { return false }
                return baseStrongsNumber(sid) == base
            }
        } else {
            selectedWord = nil
        }

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
    }

    /// Navigate to the previous meaningful word in the focused verse (translation order).
    func navigateToPreviousWord() {
        let words = translationOrderedClickableWords
        guard let word = selectedWord,
              let idx = words.firstIndex(where: { $0.id == word.id }),
              idx > 0 else { return }
        let newWord = words[idx - 1]
        selectedWord = newWord
        syncSegment(for: newWord)
        loadStrongs(for: newWord)
    }

    /// Navigate to the next meaningful word in the focused verse (translation order).
    func navigateToNextWord() {
        let words = translationOrderedClickableWords
        guard let word = selectedWord,
              let idx = words.firstIndex(where: { $0.id == word.id }),
              idx < words.count - 1 else { return }
        let newWord = words[idx + 1]
        selectedWord = newWord
        syncSegment(for: newWord)
        loadStrongs(for: newWord)
    }

    /// Finds the VerseSegment whose strongs array contains the word's Strong's base number
    /// and sets it as selectedSegment so VerseTextView highlight tracks both chevron navigation
    /// and Original pill taps.
    ///
    /// Handles duplicates (e.g. three H3808 לֹא in Ps 1:1) by finding which occurrence this
    /// word is among clickable words with the same base (Hebrew order), then picking the Nth
    /// matching segment — keeping verse highlight in sync with the correct translation word.
    private func syncSegment(for word: BibleWord) {
        guard let strongsId = word.strongsId,
              let segments = selectedVerse?.parsed?.segments else {
            selectedSegment = nil
            return
        }
        let base = baseStrongsNumber(strongsId)

        // Which occurrence (0-indexed) is this word among same-base clickable words?
        let sameBase = nasbClickableWords.filter {
            guard let sid = $0.strongsId else { return false }
            return baseStrongsNumber(sid) == base
        }
        let occurrenceIdx = sameBase.firstIndex(where: { $0.id == word.id }) ?? 0

        // Pick the Nth segment that matches this base
        var count = 0
        for seg in segments {
            if seg.strongs.contains(where: { resolvedMaculaBase($0) == base }) {
                if count == occurrenceIdx {
                    selectedSegment = seg
                    return
                }
                count += 1
            }
        }
        selectedSegment = nil
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
        if let firstWord = nasbClickableWords.first {
            selectedWord = firstWord
            syncSegment(for: firstWord)
            loadStrongs(for: firstWord)
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
        // loadBookUsageGroups runs Queries A+B+C (total count, per-book group-by,
        // N per-book verse fetches). Total < 50ms even for יהוה (6 512 occurrences).
        var entry = db.loadStrongs(id: strongsId)
        if var e = entry {
            let result = db.loadBookUsageGroups(strongsId: strongsId,
                                                translation: currentTranslation.id)
            e.totalCount = result.total
            e.bookGroups = result.groups
            entry = e
        }
        strongsEntry = entry
        isLoadingStrongs = false
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
            store.toggleHighlight(verseId: verse.id,
                                  translation: currentTranslation.id,
                                  color: color.rawValue)
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
