// SearchViewModel.swift
// SourceBible

import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Published state

    @Published var results:       [SearchResult]    = []
    /// Total match count for the current query+filters (from COUNT query, not capped).
    @Published var totalCount:    Int               = 0
    /// Per-book match counts for the current query+translation (Book filter sheet,
    /// ordered by count desc). NOT restricted by the active book/testament filter.
    @Published var bookCounts:    [SearchBookCount] = []
    @Published var suggestions:   [String]          = []
    @Published var isLoading:     Bool              = false
    @Published var isLoadingMore: Bool              = false
    @Published var hasSearched:   Bool              = false

    /// Translation-native book names for the SEARCH translation (may differ from the
    /// reader's). Used for result references and the Book filter sheet labels.
    @Published var bookNames: [String: (long: String, short: String, order: Int)] = [:]

    /// True when more pages exist beyond what is already loaded (infinite scroll sentinel).
    var canLoadMore: Bool { results.count < totalCount }

    // MARK: - Recent queries (persisted)

    @AppStorage(AppStorageKeys.searchRecentQueries) private var recentRaw: String = ""

    var recentQueries: [String] {
        recentRaw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Private

    private let db = DatabaseService.shared
    private var searchTask:  Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    /// Page size for infinite scroll. FTS5 page fetch is ~ms; 50 keeps scroll smooth
    /// without flooding the LazyVStack.
    private let pageSize = 50

    // Parameters of the query whose results are on screen — used by loadMore().
    private var currentQuery       = ""
    private var currentTranslation = ""
    private var currentBookIds:    [String]? = nil

    /// Analytics service injected from the view layer (via wireAnalytics on appear).
    var analytics: any AnalyticsService = NoopAnalytics.shared
    /// Session tracker injected from the view layer.
    var sessionTracker: SessionTracker = .noop

    // MARK: - Search

    /// Debounced full-text search (280ms). FTS5 queries run on @MainActor —
    /// same as all other DatabaseService calls; fast enough (~10–30ms) after debounce.
    ///
    /// Loads the FIRST page + total count + per-book counts; further pages arrive
    /// via `loadMore()`. `bookIds` is the effective book restriction from the
    /// Testament/Book filters (nil = no restriction).
    func search(query: String, translation: String,
                bookIds: [String]? = nil,
                testamentFilter: String? = nil) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results     = []
            totalCount  = 0
            bookCounts  = []
            isLoading   = false
            hasSearched = false
            return
        }

        searchTask = Task {
            isLoading = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            // Book names follow the SEARCH translation (references + Book sheet labels).
            if translation != currentTranslation || bookNames.isEmpty {
                bookNames = db.loadBookNames(for: translation)
            }
            let shortNames = bookNames.mapValues { $0.short }

            let total = db.searchResultCount(query: trimmed, translation: translation,
                                             bookIds: bookIds)
            let found = db.searchByText(query: trimmed, translation: translation,
                                        bookIds: bookIds,
                                        limit: pageSize, offset: 0,
                                        bookShortNames: shortNames)
            let counts = db.searchBookCounts(query: trimmed, translation: translation)

            guard !Task.isCancelled else { return }
            currentQuery       = trimmed
            currentTranslation = translation
            currentBookIds     = bookIds

            results       = found
            totalCount    = total
            bookCounts    = counts
            isLoading     = false
            isLoadingMore = false
            hasSearched   = true

            // Record to Recent only when the query actually matched something —
            // dead queries (nonsense, or words absent from this translation) are noise.
            if total > 0 { self.saveRecent(trimmed) }

            // Analytics: fire search_committed AFTER results are populated.
            // Also increment the session search counter.
            //
            // resultsCount = TOTAL match count for the committed query+filters
            // (COUNT query — no longer capped at 150 since infinite scroll).
            self.analytics.track(.searchCommitted(
                resultsCount:    total,
                hadZeroResults:  total == 0,
                translation:     translation,
                testamentFilter: testamentFilter
            ))
            self.sessionTracker.incSearch()
        }
    }

    /// Loads the next page and appends it (infinite scroll). Synchronous DB call on
    /// @MainActor — a 50-row FTS5 page is ~ms, same budget as the initial search.
    func loadMore() {
        guard !isLoading, !isLoadingMore, canLoadMore, !currentQuery.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let more = db.searchByText(query: currentQuery, translation: currentTranslation,
                                   bookIds: currentBookIds,
                                   limit: pageSize, offset: results.count,
                                   bookShortNames: bookNames.mapValues { $0.short })
        guard !more.isEmpty else {
            // DB disagreed with totalCount (shouldn't happen) — stop the sentinel loop.
            totalCount = results.count
            return
        }
        results.append(contentsOf: more)
    }

    // MARK: - Suggestions

    /// Debounced autocomplete from `search_terms` table (120ms).
    func updateSuggestions(for prefix: String) {
        suggestTask?.cancel()

        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else {
            suggestions = []
            return
        }

        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            suggestions = db.suggestTerms(prefix: trimmed)
        }
    }

    // MARK: - Recent queries

    func saveRecent(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var recents = recentQueries.filter { $0 != trimmed }
        recents.insert(trimmed, at: 0)
        recentRaw = recents.prefix(12).joined(separator: "\n")
    }

    func clearRecent() {
        recentRaw   = ""
        suggestions = []
    }
}
