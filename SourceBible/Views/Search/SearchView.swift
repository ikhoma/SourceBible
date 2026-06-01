// SearchView.swift
// SourceBible

import SwiftUI

struct SearchView: View {

    @StateObject private var vm = SearchViewModel()

    @EnvironmentObject private var router:   AppNavigationRouter
    @EnvironmentObject private var readerVM: ReaderViewModel

    @State private var searchText:       String = ""
    @State private var isSearchActive:   Bool   = false
    /// Tracks whether the user pressed the Search key (vs. still typing).
    /// Used to decide whether to show the loading spinner or blank content
    /// while waiting for results, since the two phases need different layouts.
    @State private var didCommitSearch:  Bool   = false

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
            content
                .navigationTitle("tab.search")
                .navigationBarTitleDisplayMode(.large)
                .toolbar(!vm.results.isEmpty && !isSearchActive ? .hidden : .automatic, for: .navigationBar)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(
            text: $searchText,
            isPresented: $isSearchActive,
            placement: .automatic,
            prompt: String(localized: "search.prompt.keyword")
        )
        .searchSuggestions {
            searchSuggestionsContent
        }
        .onSubmit(of: .search) {
            commitSearch()
        }
        .onChange(of: searchText) { _, newValue in
            didCommitSearch = false          // typing reset — suppress spinner, show blank
            vm.updateSuggestions(for: newValue)
            vm.search(query: newValue, translation: readerVM.currentTranslation.id)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if !vm.results.isEmpty {
            resultsList
        } else if vm.hasSearched && !vm.isLoading {
            emptyResultsView
        } else if vm.isLoading && didCommitSearch {
            // User pressed the Search key — show spinner while the query runs.
            loadingView
        } else if isSearchActive && !searchText.isEmpty {
            // iOS 26 bottom search bar: the suggestion overlay shares the same
            // vertical layout space as this content. While typing (pre-results),
            // render blank so the overlay doesn't squish a Spacer-based view
            // into a narrow strip. The suggestions are the UX for this phase.
            Color.clear
        } else if vm.isLoading {
            loadingView
        } else {
            emptyStateView
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        List {
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
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)

                ForEach(filteredResults) { result in
                    SearchResultRow(result: result)
                        .contentShape(Rectangle())
                        .onTapGesture { navigate(to: result) }
                }
            } header: {
                Picker("", selection: $testamentFilter) {
                    Text("search.filter.all").tag(TestamentFilter.all)
                    Text("search.filter.old").tag(TestamentFilter.old)
                    Text("search.filter.new").tag(TestamentFilter.new)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 10)
                .padding(.top, -8)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Autocomplete suggestions

    @ViewBuilder
    private var searchSuggestionsContent: some View {
        ForEach(vm.suggestions, id: \.self) { term in
            // iOS 26 bottom search bar gives suggestion rows a near-zero proposed width,
            // causing text to wrap character-by-character. Fix: claim full row width and
            // clamp to a single line. Text(verbatim:) avoids the LocalizedStringKey
            // overload that triggers a separate mis-render on the same OS version.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(verbatim: term)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .searchCompletion(term)
        }

        if !vm.recentQueries.isEmpty && vm.suggestions.count < 4 {
            Section("search.recent") {
                ForEach(vm.recentQueries.prefix(4), id: \.self) { recent in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(verbatim: recent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .searchCompletion(recent)
                }
            }
        }
    }

    // MARK: - Empty / loading states

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.2)
            Text("search.loading").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("search.no_results.title").font(.headline)
            Text("search.no_results.body")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var emptyStateView: some View {
        Group {
            if !vm.recentQueries.isEmpty && searchText.isEmpty {
                recentQueriesSection
            } else {
                searchHintView
            }
        }
    }

    private var recentQueriesSection: some View {
        List {
            Section {
                ForEach(vm.recentQueries.prefix(8), id: \.self) { recent in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.tertiary).frame(width: 20)
                        Text(recent)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = recent
                        vm.search(query: recent, translation: readerVM.currentTranslation.id)
                    }
                }
            } header: {
                VStack(spacing: 0) {
                    HStack {
                        Text("search.recent")
                            .font(.title3).bold()
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        Spacer()
                        Button("search.clear") { vm.clearRecent() }
                            .font(.callout)
                            .foregroundStyle(.tint)
                            .textCase(nil)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    Divider()
                }
            }
        }
        .listStyle(.plain)
    }

    private var searchHintView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            Text("search.hint.title")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("search.hint.body \(readerVM.currentTranslation.id)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Actions

    private func commitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        didCommitSearch = true               // explicit submit — show spinner
        vm.saveRecent(q)
        vm.search(query: q, translation: readerVM.currentTranslation.id)
    }

    private func navigate(to result: SearchResult) {
        vm.saveRecent(searchText.trimmingCharacters(in: .whitespaces))
        router.requestNavigation(to: result.id)
    }
}

// MARK: - Result row

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.reference)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)

                Text(parseSnippet(result.snippet))
                    .font(.callout)
                    .lineLimit(3)
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
                container.swiftUI.backgroundColor = Color.wordHighlight
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
