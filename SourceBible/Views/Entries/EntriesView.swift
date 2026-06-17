// EntriesView.swift
// SourceBible

import SwiftUI

struct EntriesView: View {

    @EnvironmentObject private var notesVM:     NotesViewModel
    @EnvironmentObject private var bookmarksVM: BookmarksViewModel

    @State private var tab: EntriesTab = .notes
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ZStack {
                Color("appBackground").ignoresSafeArea()
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("entries.new_note", systemImage: "note.text.badge.plus") {
                            notesVM.openNewNote()
                        }
                        Button("entries.new_folder", systemImage: "folder.badge.plus") {
                            createFolder()
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func createFolder() {
        let now    = Date()
        let folder = NoteFolder(
            id: UUID().uuidString,
            userId: notesVM.authUserId,
            name: String(localized: "entries.new_folder"),
            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
        notesVM.saveFolder(folder)
    }

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
