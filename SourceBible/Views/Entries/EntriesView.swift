// EntriesView.swift
// SourceBible

import SwiftUI

struct EntriesView: View {

    @EnvironmentObject private var notesVM:     NotesViewModel
    @EnvironmentObject private var bookmarksVM: BookmarksViewModel

    @State private var tab: EntriesTab = .notes
    @Environment(\.locale) private var locale
    @Environment(\.colorTheme) private var colorTheme

    var body: some View {
        NavigationStack {
            ZStack {
                colorTheme.appBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("entries.tab.notes").tag(EntriesTab.notes)
                        Text("entries.tab.bookmarks").tag(EntriesTab.bookmarks)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    if tab == .notes {
                        NotesListView()
                            .environmentObject(notesVM)
                    } else {
                        BookmarksListView()
                            .environmentObject(bookmarksVM)
                    }
                }
                .animation(nil, value: tab)
            }
            // .id forces the Picker and list content to reconstruct on locale change.
            // Picker segment labels (LocalizedStringKey) are cached by UISegmentedControl
            // and do not re-evaluate automatically when the SwiftUI locale environment changes.
            .id(locale.identifier)
            .navigationTitle("entries.title")
            .toolbar {
                // "+" directly creates a new note. The folder option is hidden until
                // the folders feature is implemented (analytics slice 4). When folders
                // ship, restore the Menu with both "new note" and "new folder" actions
                // (see createFolder() below).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        notesVM.openNewNote()
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("entries.new_note"))
                }
            }
        }
    }

    // TODO: Re-enable when the folders feature is implemented. Hidden from the
    // "+" menu for now (no folder UI shipped yet).
//    private func createFolder() {
//        let now    = Date()
//        let folder = NoteFolder(
//            id: UUID().uuidString,
//            userId: notesVM.authUserId,
//            name: String(localized: "entries.new_folder"),
//            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
//        notesVM.saveFolder(folder)
//    }

}

enum EntriesTab { case notes, bookmarks }

#Preview {
    @MainActor in
    let store = InMemoryUserDataStore()
    let auth  = LocalAuthService.shared
    EntriesView()
        .environmentObject(NotesViewModel(store: store, authService: auth))
        .environmentObject(BookmarksViewModel(store: store, authService: auth))
        .environmentObject(AppNavigationRouter())
}
