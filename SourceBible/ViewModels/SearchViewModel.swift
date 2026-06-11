// SearchViewModel.swift
// SourceBible

import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Published state

    @Published var results:      [SearchResult] = []
    @Published var suggestions:  [String]       = []
    @Published var isLoading:    Bool           = false
    @Published var hasSearched:  Bool           = false
    /// True when results hit the 150-result query cap (real count may be higher).
    @Published var resultsCapped: Bool          = false

    // MARK: - Recent queries (persisted)

    @AppStorage("searchRecentQueries") private var recentRaw: String = ""

    var recentQueries: [String] {
        recentRaw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Private

    private let db = DatabaseService.shared
    private var searchTask:  Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    // MARK: - Search

    /// Debounced full-text search (280ms). FTS5 queries run on @MainActor —
    /// same as all other DatabaseService calls; fast enough (~10–30ms) after debounce.
    func search(query: String, translation: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results     = []
            isLoading   = false
            hasSearched = false
            return
        }

        searchTask = Task {
            isLoading = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            let found = db.searchByText(query: trimmed, translation: translation)

            guard !Task.isCancelled else { return }
            results       = found
            resultsCapped = found.count >= 150
            isLoading     = false
            hasSearched   = true

            // Record to Recent only when the query actually matched something —
            // dead queries (nonsense, or words absent from this translation) are noise.
            if !found.isEmpty { self.saveRecent(trimmed) }
        }
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
