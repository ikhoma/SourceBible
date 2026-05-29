// ReaderViewModel.swift
// SourceBible

import Foundation
import Combine

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
    @Published var selectedWord: BibleWord? = nil       // Macula word (future — nil until OT/NT word tables populated)
    @Published var selectedSegment: VerseSegment? = nil // segment from VerseTextView long press
    @Published var bottomSheetMode: BottomSheetMode = .verse

    /// Actual height of the verse sheet at its current detent, measured from inside the sheet.
    /// Used by ReaderView to calculate how much bottom inset to reserve so the selected verse
    /// scrolls to sit exactly 6 pt above the sheet top.
    /// Starts at 0; ReaderView supplies a UIWindowScene-based fallback until the first measurement.
    @Published var verseSheetHeight: CGFloat = 0

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
            self.allBooks             = self.db.loadBooks()
            self.availableTranslations = self.db.loadTranslations()
            self.currentBook = self.allBooks.first(where: { $0.id == "PSA" })
                            ?? self.allBooks.first
                            ?? self.currentBook
            self.loadChapter()
        }
    }

    // MARK: - Computed

    // Always resolved via BibleBookNames so language switches take effect immediately
    // without needing to reload allBooks from the DB.
    var chapterTitle: String { "\(BibleBookNames.short(for: currentBook.id)) \(currentChapter)" }

    /// Full chapter heading shown at the top of the reader — "Psalm 23" for Psalms, "Chapter 5" for everything else.
    /// Reads appLanguage from UserDefaults so language switches take effect immediately.
    var chapterHeading: String {
        let isUkrainian = UserDefaults.standard.string(forKey: "appLanguage") == "uk"
        if currentBook.id == "PSA" {
            return isUkrainian ? "Псалом \(currentChapter)" : "Psalm \(currentChapter)"
        } else {
            return isUkrainian ? "Розділ \(currentChapter)" : "Chapter \(currentChapter)"
        }
    }

    var oldTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .old } }
    var newTestamentBooks: [BibleBook] { allBooks.filter { $0.testament == .new } }

    /// Words in the focused verse that have a Strong's number — used for word navigation in the bottom sheet.
    var verseWordsWithStrongs: [BibleWord] {
        selectedVerse?.words.filter { $0.strongsId != nil } ?? []
    }

    /// Translation text for the currently selected word/segment — shown as the Word tab header title.
    /// Priority: (1) selectedSegment.text (already translation), (2) lookup matching ParsedVerse segment
    /// by strongsId, (3) fallback to BibleWord.text (may be original language in Macula data).
    var selectedWordDisplayText: String? {
        if let seg = selectedSegment {
            let t = seg.text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        if let word = selectedWord,
           let strongsId = word.strongsId,
           let parsed = selectedVerse?.parsed {
            if let segText = parsed.segments
                .first(where: { $0.strongs.contains(strongsId) })?
                .text.trimmingCharacters(in: .whitespaces),
               !segText.isEmpty {
                return segText
            }
        }
        return selectedWord?.text.trimmingCharacters(in: .whitespaces)
    }

    var isCurrentVerseHighlighted: Bool {
        guard let v = selectedVerse else { return false }
        return highlightColors[v.id] != nil
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
        isTranslationPickerPresented = false
        loadChapter()
        // Re-load concordance so the word usage tab reflects the new translation immediately.
        if let word = selectedWord {
            loadStrongs(for: word)
        } else if let seg = selectedSegment, let verse = selectedVerse {
            loadStrongs(for: seg, bookId: verse.bookId)
        }
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
            loadWordsForSelectedVerse()
            isBottomSheetPresented = true
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
        loadWordsForSelectedVerse()
    }

    /// Called from VerseTextView long press — receives a VerseSegment with strongs: [String].
    func tapWord(_ segment: VerseSegment, in verse: BibleVerse) {
        selectedVerse = verse
        selectedSegment = segment
        selectedWord = nil   // Macula BibleWord lookup is future work (Task #1)
        bottomSheetMode = .word
        activeSheet = .verse
        loadStrongs(for: segment, bookId: verse.bookId)
    }

    /// Called from OriginalWordsView (bottom sheet) — receives a Macula BibleWord.
    func tapWord(_ word: BibleWord, in verse: BibleVerse) {
        selectedVerse = verse
        selectedWord = word
        selectedSegment = nil
        bottomSheetMode = .word
        activeSheet = .verse
        loadStrongs(for: word)
    }

    func navigateToPreviousVerse() {
        guard let current = selectedVerse,
              let idx = verses.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        selectedVerse = verses[idx - 1]
        selectedWord = nil
        selectedSegment = nil
        loadWordsForSelectedVerse()
    }

    func navigateToNextVerse() {
        guard let current = selectedVerse,
              let idx = verses.firstIndex(where: { $0.id == current.id }),
              idx < verses.count - 1 else { return }
        selectedVerse = verses[idx + 1]
        selectedWord = nil
        selectedSegment = nil
        loadWordsForSelectedVerse()
    }

    /// Navigate to the previous word with a Strong's number in the focused verse.
    func navigateToPreviousWord() {
        let words = verseWordsWithStrongs
        guard let word = selectedWord,
              let idx = words.firstIndex(where: { $0.id == word.id }),
              idx > 0 else { return }
        let newWord = words[idx - 1]
        selectedWord = newWord
        syncSegment(for: newWord)
        loadStrongs(for: newWord)
    }

    /// Navigate to the next word with a Strong's number in the focused verse.
    func navigateToNextWord() {
        let words = verseWordsWithStrongs
        guard let word = selectedWord,
              let idx = words.firstIndex(where: { $0.id == word.id }),
              idx < words.count - 1 else { return }
        let newWord = words[idx + 1]
        selectedWord = newWord
        syncSegment(for: newWord)
        loadStrongs(for: newWord)
    }

    /// Finds the VerseSegment whose `strongs` array contains the word's strongsId
    /// and sets it as `selectedSegment` so VerseTextView highlight tracks arrow navigation.
    /// Falls back to clearing selectedSegment when no matching segment exists.
    private func syncSegment(for word: BibleWord) {
        guard let strongsId = word.strongsId,
              let segments = selectedVerse?.parsed?.segments else {
            selectedSegment = nil
            return
        }
        selectedSegment = segments.first { $0.strongs.contains(strongsId) }
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
        if let firstWord = verseWordsWithStrongs.first {
            selectedWord = firstWord
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

// MARK: - Active Sheet (single slot to avoid multi-sheet conflicts)

enum ActiveSheet: Identifiable {
    case bookPicker
    case translationPicker
    case verse

    var id: Self { self }
}
