// SearchView.swift
// SourceBible

import SwiftUI
import UIKit

struct SearchView: View {

    @Environment(\.analytics)      private var analytics
    @Environment(\.sessionTracker) private var sessionTracker

    @StateObject private var vm = SearchViewModel()

    @EnvironmentObject private var router:   AppNavigationRouter
    @EnvironmentObject private var readerVM: ReaderViewModel

    @State private var searchText:       String = ""
    @State private var isSearchActive:   Bool   = false

    /// The query whose results are currently on screen. Empty until the user *commits*
    /// (taps a predictive row or presses the Search key). The typing phase shows only
    /// predictions; results load on commit. When `trimmedQuery != committedQuery` the
    /// user is editing again → back to predictions.
    @State private var committedQuery:   String = ""

    /// Trimmed query — single source of truth for "is the user typing something".
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// True while the user is editing a query that hasn't been committed yet.
    private var isTypingUncommitted: Bool { trimmedQuery != committedQuery }

    /// True when the committed results page is on screen (drives hiding the nav title there).
    private var isShowingResults: Bool { !committedQuery.isEmpty && !isTypingUncommitted }

    // MARK: - Filter state
    enum TestamentFilter { case all, old, new }
    @State private var testamentFilter: TestamentFilter = .all

    /// Results after applying the active testament filter.
    private var filteredResults: [SearchResult] {
        vm.results.filter { result in
            let parts  = result.id.split(separator: "|")
            let bookId = parts.isEmpty ? "" : String(parts[0])
            switch testamentFilter {
            case .old where BibleBookNames.testament(for: bookId) != .old: return false
            case .new where BibleBookNames.testament(for: bookId) != .new: return false
            default: return true
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen app background behind everything (incl. safe areas and the
                // floating search field). Matches the ReaderView pattern; a plain
                // `.background(...)` on `content` left the system black showing through
                // the safe areas and the empty space below short List content.
                Color("appBackground").ignoresSafeArea()
                content
                    // Large bold "Search" on the home states (hint / Recent / predictions).
                    // On the results page there's already a "Results for …" header, and the
                    // large title there flickered between states — so hide the nav bar there.
                    .navigationTitle("tab.search")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar(isShowingResults ? .hidden : .automatic, for: .navigationBar)
            }
        }
        // No `.searchSuggestions` overlay (removed the iOS 26 width squeeze). Predictions
        // render inline in `predictiveList`; results load on commit into `resultsList`.
        // `.searchable` + Tab(role: .search) still drive the bottom bar + morph animation. (ADR-008 §5)
        .searchable(
            text: $searchText,
            isPresented: $isSearchActive,
            placement: .automatic,
            prompt: String(localized: "search.prompt.keyword")
        )
        .onSubmit(of: .search) {
            commit(query: searchText)
        }
        .onChange(of: searchText) { _, newValue in
            // Typing phase only refreshes predictions — it does NOT run the full search.
            // (That avoids dense results painting behind the predictions + translucent bar,
            // and the wasted per-keystroke FTS queries.) Results load on commit.
            vm.updateSuggestions(for: newValue)

            // Clearing the field (cancel ✕ or the in-field clear) drops back out of the
            // committed/results state so we don't flash stale results.
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty { committedQuery = "" }
        }
        // Wire the live analytics + tracker into the VM on first appear.
        // Can't be done at @StateObject init time (Environment not available then).
        .task {
            vm.analytics      = analytics
            vm.sessionTracker = sessionTracker
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if isShowingResults {
            // Committed: full-screen results page (keyboard dismissed on commit).
            resultsPage
        } else if isSearchActive && !trimmedQuery.isEmpty {
            // Typing an uncommitted query: predictions only.
            predictiveList
        } else if !vm.recentQueries.isEmpty {
            recentQueriesSection
        } else {
            searchHintView
        }
    }

    // MARK: - Results page (after commit)

    @ViewBuilder
    private var resultsPage: some View {
        if !filteredResults.isEmpty {
            resultsList
        } else if vm.isLoading {
            loadingView
        } else {
            emptyResultsView
        }
    }

    // MARK: - Predictive list (typing phase)

    /// Suggestions minus the term the user has already fully typed, so a completed
    /// query doesn't echo itself back as a one-row suggestion.
    private var visibleSuggestions: [String] {
        let q = trimmedQuery.lowercased()
        return vm.suggestions.filter { $0 != q }
    }

    private var predictiveList: some View {
        // NOTE: a `List` here renders inside the `.searchable` results host, whose
        // own `.systemBackground` (black in dark mode) shows through the transparent
        // list — `scrollContentBackground(.hidden)` and `.background()` can't reach it.
        // A `ScrollView` has a clear background, so the ZStack appBackground shows.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !visibleSuggestions.isEmpty {
                    ForEach(visibleSuggestions, id: \.self) { term in
                        completionRow(term)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                } else {
                    // No predictions yet (or "nonsense"): offer a row to search the literal text.
                    literalQueryRow
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.2)
            Text("search.loading").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A predictive-completion row: the matched prefix is rendered in the primary
    /// colour, the predicted remainder in secondary — matching Apple Music's
    /// "**dak**ooka" treatment. Tapping fills the field and runs the search.
    /// (`search_terms` are stored lowercase, so the row reflects that casing.)
    private func completionRow(_ term: String) -> some View {
        let matchLen = min(trimmedQuery.count, term.count)

        var head = AttributedString(String(term.prefix(matchLen)))
        var headAttrs = AttributeContainer(); headAttrs.swiftUI.foregroundColor = Color.primary
        head.mergeAttributes(headAttrs)

        var tail = AttributedString(String(term.dropFirst(matchLen)))
        var tailAttrs = AttributeContainer(); tailAttrs.swiftUI.foregroundColor = Color.secondary
        tail.mergeAttributes(tailAttrs)

        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(head + tail).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { complete(with: term) }
    }

    /// Echoes the raw query (Apple Music shows this when nothing matches). Tapping commits.
    private var literalQueryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(verbatim: searchText)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { commit(query: searchText) }
    }

    private var testamentPicker: some View {
        Picker("", selection: $testamentFilter) {
            Text("search.filter.all").tag(TestamentFilter.all)
            Text("search.filter.old").tag(TestamentFilter.old)
            Text("search.filter.new").tag(TestamentFilter.new)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 10)
        .padding(.top, -8)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
        // The testament picker uses the NATIVE bar treatment — same as the status/tool
        // bars on the Reader. On iOS 26 it lives in a `.safeAreaBar(edge: .top)`, so the
        // system renders the Liquid Glass scroll-edge blur behind it automatically as the
        // results scroll underneath (no manual material). iOS 18 fallback keeps it pinned
        // as a section header. (iOS 26 rule: #available guard + iOS 18 fallback.)
        if #available(iOS 26.0, *) {
            resultsScroll(pinnedPicker: false)
                .safeAreaBar(edge: .top) {
                    testamentPicker
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
        } else {
            resultsScroll(pinnedPicker: true)
        }
    }

    /// Scrollable results. When `pinnedPicker` is true (iOS 18 fallback) the testament
    /// picker is rendered as a pinned section header; on iOS 26 it's hosted by the
    /// `.safeAreaBar` above instead, so the header is omitted here.
    @ViewBuilder
    private func resultsScroll(pinnedPicker: Bool) -> some View {
        // ScrollView (not List) so the ZStack appBackground shows through — see note
        // on `predictiveList`.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0,
                       pinnedViews: pinnedPicker ? [.sectionHeaders] : []) {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("search.results_header \(searchText.trimmingCharacters(in: .whitespaces))")
                            .font(.title2).bold()
                            .foregroundStyle(.primary)
                        Group {
                            if vm.resultsCapped {
                                Text("search.results_count_max \(filteredResults.count)")
                            } else {
                                Text("search.results_count \(filteredResults.count)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)

                    ForEach(filteredResults) { result in
                        SearchResultRow(result: result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { navigate(to: result) }
                        Divider()
                    }
                } header: {
                    if pinnedPicker {
                        testamentPicker
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Empty states

    private var emptyResultsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("search.no_results.title").font(.headline).foregroundStyle(.primary)
                Text("search.no_results.body")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var recentQueriesSection: some View {
        // ScrollView (not List) so the ZStack appBackground shows through — see note
        // on `predictiveList` re: the `.searchable` results host background.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("search.recent")
                        .font(.title3).bold()
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("search.clear") { vm.clearRecent() }
                        .font(.callout)
                        .foregroundStyle(.appBlue)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                Divider()

                ForEach(vm.recentQueries.prefix(8), id: \.self) { recent in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.tertiary).frame(width: 20)
                        Text(recent)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = recent
                        commit(query: recent)
                    }
                    Divider()
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchHintView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("search.hint.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("search.hint.body \(readerVM.currentTranslation.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Actions

    /// Tapping a predictive completion fills the field with the term and commits.
    private func complete(with term: String) {
        searchText = term
        commit(query: term)
    }

    /// Commit a query → load its results page and dismiss the keyboard.
    /// Setting `committedQuery == trimmedQuery` flips `content` from predictions to results.
    /// Recent is saved by the ViewModel only if the query actually returns results,
    /// so dead queries ("Dhhdhhdh", words absent from this translation) aren't recorded.
    private func commit(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        committedQuery = q
        // Pass the active testament filter so search_committed includes it.
        let filterStr: String?
        switch testamentFilter {
        case .old:  filterStr = "OT"
        case .new:  filterStr = "NT"
        case .all:  filterStr = nil
        }
        vm.search(query: q, translation: readerVM.currentTranslation.id,
                  testamentFilter: filterStr)
        dismissKeyboard()
    }

    private func navigate(to result: SearchResult) {
        // Fire search_result_opened. resultsCount + position are within the FILTERED
        // list the user actually sees and taps (post testament-filter) — intentionally
        // different from search_committed.resultsCount, which is the raw search count.
        let position = filteredResults.firstIndex(where: { $0.id == result.id }) ?? 0
        analytics.track(.searchResultOpened(
            resultsCount: filteredResults.count,
            position:     position
        ))
        router.requestNavigation(to: result.id)
    }

    /// Resign first responder without dismissing the whole search presentation,
    /// so the field keeps showing the query while the keyboard hides (Apple Music behaviour).
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

// MARK: - Result row

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ReferenceLabel(result.reference)

                Text(parseSnippet(result.snippet))
                    .font(.callout)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }

    /// Parses ❮highlighted❯ markers into an AttributedString.
    /// Uses the shared `Color.wordHighlight` background, matching the verse-reader
    /// word selection and the Usage-tab concordance highlight style.
    private func parseSnippet(_ raw: String) -> AttributedString {
        var output    = AttributedString()
        var remaining = raw[raw.startIndex...]

        while let open = remaining.range(of: "❮") {
            let plain = String(remaining[remaining.startIndex ..< open.lowerBound])
            if !plain.isEmpty { output += AttributedString(plain) }
            remaining = remaining[open.upperBound...]

            if let close = remaining.range(of: "❯") {
                let hit = String(remaining[remaining.startIndex ..< close.lowerBound])
                var highlighted = AttributedString(hit)
                var container = AttributeContainer()
                container.swiftUI.foregroundColor = Color.appBlue
                highlighted.mergeAttributes(container)
                output   += highlighted
                remaining = remaining[close.upperBound...]
            }
        }

        if !remaining.isEmpty { output += AttributedString(String(remaining)) }
        return output
    }
}

// MARK: - Preview

#Preview {
    SearchView()
        .environmentObject(AppNavigationRouter())
        .environmentObject(ReaderViewModel(store: InMemoryUserDataStore()))
}
