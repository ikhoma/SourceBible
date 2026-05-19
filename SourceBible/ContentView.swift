// ContentView.swift
// SourceBible

import SwiftUI

@MainActor
struct ContentView: View {

    @StateObject private var readerVM:     ReaderViewModel
    @StateObject private var notesVM:      NotesViewModel
    @StateObject private var bookmarksVM:  BookmarksViewModel
    @StateObject private var router:       AppNavigationRouter = AppNavigationRouter()
    @State private var selectedTab: AppTab = .bible

    @MainActor
    init(store: UserDataStoreProtocol) {
        let auth     = LocalAuthService.shared
        _readerVM    = StateObject(wrappedValue: ReaderViewModel(store: store))
        _notesVM     = StateObject(wrappedValue: NotesViewModel(store: store, authService: auth))
        _bookmarksVM = StateObject(wrappedValue: BookmarksViewModel(store: store, authService: auth))
    }

    var body: some View {
        tabView
            // Cross-tab navigation: any view sets router.pendingVerseId to jump to Reader
            .onChange(of: router.pendingVerseId) { _, verseId in
                guard let verseId else { return }
                // Switch to Bible tab first, then navigate on the next runloop tick
                // so the tab's view hierarchy is fully mounted before we scroll.
                selectedTab = .bible
                Task { @MainActor in
                    readerVM.navigateToVerse(id: verseId)
                    router.pendingVerseId = nil
                }
            }
    }

    // MARK: - Tab view (split out to keep body concise)

    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18, *) {
            TabView(selection: $selectedTab) {
                Tab("tab.bible", systemImage: "book.fill", value: AppTab.bible) {
                    ReaderView()
                        .environmentObject(readerVM)
                        .environmentObject(notesVM)
                        .environmentObject(bookmarksVM)
                        .environmentObject(router)
                }
                Tab("tab.entries", systemImage: "bookmark.fill", value: AppTab.entries) {
                    EntriesView()
                        .environmentObject(notesVM)
                        .environmentObject(bookmarksVM)
                        .environmentObject(router)
                }
                Tab("tab.menu", systemImage: "ellipsis.circle.fill", value: AppTab.menu) {
                    MenuView()
                }
                Tab("tab.search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                    SearchView()
                        .environmentObject(readerVM)
                        .environmentObject(router)
                }
            }
            .tint(.primary)
        } else {
            TabView(selection: $selectedTab) {
                ReaderView()
                    .environmentObject(readerVM)
                    .environmentObject(notesVM)
                    .environmentObject(bookmarksVM)
                    .environmentObject(router)
                    .tabItem { Label("tab.bible", systemImage: "book.fill") }
                    .tag(AppTab.bible)

                EntriesView()
                    .environmentObject(notesVM)
                    .environmentObject(bookmarksVM)
                    .environmentObject(router)
                    .tabItem { Label("tab.entries", systemImage: "bookmark.fill") }
                    .tag(AppTab.entries)

                MenuView()
                    .tabItem { Label("tab.menu", systemImage: "ellipsis.circle.fill") }
                    .tag(AppTab.menu)

                SearchView()
                    .environmentObject(readerVM)
                    .environmentObject(router)
                    .tabItem { Label("tab.search", systemImage: "magnifyingglass") }
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
    @MainActor in
    ContentView(store: InMemoryUserDataStore())
}
