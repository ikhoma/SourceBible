// EntriesView.swift
// SourceBible

import SwiftUI

struct EntriesView: View {
    @State private var tab: EntriesTab = .notes

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Нотатки").tag(EntriesTab.notes)
                    Text("Закладки").tag(EntriesTab.bookmarks)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                if tab == .notes { NotesEmptyView() } else { BookmarksEmptyView() }
            }
            .navigationTitle("Ваші записи")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Створити нотатку", systemImage: "note.text.badge.plus") {}
                        Button("Створити папку",   systemImage: "folder.badge.plus")    {}
                        Button("Створити закладку", systemImage: "bookmark.fill")        {}
                        Button("Створити категорію", systemImage: "tag")                 {}
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}

enum EntriesTab { case notes, bookmarks }

struct NotesEmptyView: View {
    var body: some View { emptyState(icon: "note.text", title: "Немає нотаток", subtitle: "Натисніть на вірш у Читачі\nщоб додати нотатку") }
}

struct BookmarksEmptyView: View {
    var body: some View { emptyState(icon: "bookmark", title: "Немає закладок", subtitle: "Додайте вірші до закладок\nдля швидкого доступу") }
}

private func emptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 16) {
        Spacer()
        Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.quaternary)
        Text(title).font(.headline).foregroundStyle(.secondary)
        Text(subtitle).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        Spacer()
    }
}


#Preview { EntriesView() }
