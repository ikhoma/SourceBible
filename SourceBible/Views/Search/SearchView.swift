// SearchView.swift
// SourceBible

import SwiftUI

struct SearchView: View {

    @State private var tab: SearchTab = .keyword
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("За словом").tag(SearchTab.keyword)
                    Text("Розумний пошук").tag(SearchTab.smart)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                SearchEmptyStateView(tab: tab)
            }
            .navigationTitle("Пошук")
            .navigationBarTitleDisplayMode(.large)
        }
        // Цей модифікатор вмикає анімацію Apple Music:
        // bubble → search bar, решта табів collapse в один при тапі на Search
        .searchable(
            text: $searchText,
            placement: .automatic,
            prompt: tab == .keyword ? "Слово або фраза..." : "Питання природною мовою..."
        )
    }
}

// MARK: - Tabs

enum SearchTab {
    case keyword, smart
}

// MARK: - Empty State

struct SearchEmptyStateView: View {
    let tab: SearchTab

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: tab == .keyword ? "magnifyingglass" : "sparkle.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            Text(tab == .keyword ? "Пошук за словом" : "Розумний пошук")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                tab == .keyword
                    ? "Введіть слово або фразу\nщоб знайти вірші"
                    : "Поставте питання природною мовою\nнаприклад «Де говориться про успіх?»"
            )
            .font(.callout)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    SearchView()
}
