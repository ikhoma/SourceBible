// SearchView.swift
// SourceBible

import SwiftUI

struct SearchView: View {

    @StateObject private var vm = SearchViewModel()

    @EnvironmentObject private var router:   AppNavigationRouter
    @EnvironmentObject private var readerVM: ReaderViewModel

    @State private var searchText:     String = ""
    @State private var isSearchActive: Bool   = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("tab.search")
                .navigationBarTitleDisplayMode(.large)
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
            vm.updateSuggestions(for: newValue)
            vm.search(query: newValue, translation: readerVM.currentTranslation.id)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            loadingView
        } else if !vm.results.isEmpty {
            resultsList
        } else if vm.hasSearched {
            emptyResultsView
        } else {
            emptyStateView
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        List(vm.results) { result in
            SearchResultRow(result: result)
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .contentShape(Rectangle())
                .onTapGesture { navigate(to: result) }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            Text("search.results_count \(vm.results.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Autocomplete suggestions

    @ViewBuilder
    private var searchSuggestionsContent: some View {
        ForEach(vm.suggestions, id: \.self) { term in
            // Use Text(verbatim:) + explicit HStack instead of Label(_:systemImage:).
            // In iOS 26's bottom search bar, Label's LocalizedStringKey overload
            // mis-renders String suggestions — each character appears on its own line.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(verbatim: term)
            }
            .searchCompletion(term)
        }

        if !vm.recentQueries.isEmpty && vm.suggestions.count < 4 {
            Section("search.recent") {
                ForEach(vm.recentQueries.prefix(4), id: \.self) { recent in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(verbatim: recent)
                    }
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
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = recent
                        vm.search(query: recent, translation: readerVM.currentTranslation.id)
                    }
                }
            } header: {
                HStack {
                    Text("search.recent")
                    Spacer()
                    Button("search.clear") { vm.clearRecent() }
                        .font(.caption)
                }
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(result.reference)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)

            Text(parseSnippet(result.snippet))
                .font(.callout)
                .lineLimit(3)
        }
    }

    /// Parses ❮highlighted❯ markers into an AttributedString with tint + bold on matches.
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
                container.swiftUI.foregroundColor = Color.accentColor
                container.swiftUI.font            = .callout.bold()
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
