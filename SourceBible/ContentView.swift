// ContentView.swift
// SourceBible

import SwiftUI

@MainActor
struct ContentView: View {

    @StateObject private var readerVM = ReaderViewModel()
    @State private var selectedTab: AppTab = .bible

    var body: some View {
        if #available(iOS 18, *) {
            TabView(selection: $selectedTab) {
                Tab("Біблія", systemImage: "book.fill", value: AppTab.bible) {
                    ReaderView()
                        .environmentObject(readerVM)
                }
                Tab("Записи", systemImage: "bookmark.fill", value: AppTab.entries) {
                    EntriesView()
                }
                Tab("Меню", systemImage: "ellipsis.circle.fill", value: AppTab.menu) {
                    MenuView()
                }
                Tab("Пошук", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                    SearchView()
                }
            }
            .tint(.primary)
        } else {
            TabView(selection: $selectedTab) {
                ReaderView()
                    .environmentObject(readerVM)
                    .tabItem { Label("Біблія", systemImage: "book.fill") }
                    .tag(AppTab.bible)

                EntriesView()
                    .tabItem { Label("Записи", systemImage: "bookmark.fill") }
                    .tag(AppTab.entries)

                MenuView()
                    .tabItem { Label("Меню", systemImage: "ellipsis.circle.fill") }
                    .tag(AppTab.menu)

                SearchView()
                    .tabItem { Label("Пошук", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
            }
            .tint(.primary)
        }
    }
}

enum AppTab {
    case bible, entries, menu, search
}

#Preview {
    ContentView()
}
