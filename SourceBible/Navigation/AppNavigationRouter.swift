// AppNavigationRouter.swift
// SourceBible
//
// Cross-tab navigation coordinator. Owned by ContentView, passed to all tabs
// via .environmentObject(router). Any view sets pendingVerseId to trigger navigation;
// ContentView.onChange switches the tab and calls readerVM.navigateToVerse(id:).
//
// Usage:
//   router.pendingVerseId = "ROM|5|1"   // triggers Reader navigation from any tab

import SwiftUI
import Combine

@MainActor
final class AppNavigationRouter: ObservableObject {

    /// Set to a verseId ("ROM|5|1") to navigate the Reader to that verse.
    /// ContentView resets this to nil after handling.
    @Published var pendingVerseId: String? = nil

    func requestNavigation(to verseId: String) {
        pendingVerseId = verseId
    }
}
