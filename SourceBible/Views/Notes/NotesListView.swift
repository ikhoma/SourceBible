// NotesListView.swift
// SourceBible

import SwiftUI

struct NotesListView: View {

    @EnvironmentObject private var notesVM: NotesViewModel
    @EnvironmentObject private var router:  AppNavigationRouter

    /// Фільтри вкладки Entries (період / книга / сортування).
    var filter = EntriesFilter()

    private var filteredNotes: [NoteWithBlocks] {
        filter.apply(to: notesVM.notes)
    }

    var body: some View {
        Group {
            if notesVM.notes.isEmpty {
                emptyState
            } else if filteredNotes.isEmpty {
                filteredEmptyState
            } else {
                List {
                    ForEach(filteredNotes, id: \.note.id) { item in
                        Button {
                            notesVM.openEdit(note: item)
                        } label: {
                            NoteCardView(item: item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                notesVM.deleteNote(id: item.note.id)
                            } label: {
                                Label("action.delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $notesVM.isEditorPresented,
               onDismiss: { notesVM.refresh() }) {
            if let note = notesVM.editingNote {
                NoteEditorView(noteWithBlocks: note)
                    .environmentObject(notesVM)
                    .environmentObject(router)
                    .presentationDetents([.large])
            }
        }
    }

    /// Записи є, але фільтри сховали всі — окремий стан, щоб не плутати з
    /// «нотаток ще немає».
    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 48)).foregroundStyle(.quaternary)
            Text("entries.filter.empty")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 48)).foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("notes.empty.title").font(.headline).foregroundStyle(.primary)
                Text("notes.empty.body")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
    }
}

#Preview {
    NotesListView()
        .environmentObject(NotesViewModel(store: InMemoryUserDataStore(),
                                          authService: LocalAuthService.shared))
        .environmentObject(AppNavigationRouter())
        .background(Color(.systemGroupedBackground))
}
