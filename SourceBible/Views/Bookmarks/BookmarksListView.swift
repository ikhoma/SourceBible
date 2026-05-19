// BookmarksListView.swift
// SourceBible
//
// Bookmarks are pure navigation — tapping a card switches to the Bible tab at that verse.
// No editor sheet, no categories.

import SwiftUI

struct BookmarksListView: View {

    @EnvironmentObject private var bookmarksVM: BookmarksViewModel
    @EnvironmentObject private var router:      AppNavigationRouter

    var body: some View {
        Group {
            if bookmarksVM.bookmarks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(bookmarksVM.bookmarks, id: \.bookmark.id) { item in
                        BookmarkCardView(item: item)
                            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .onTapGesture {
                                if let verseId = item.verseIds.first {
                                    router.requestNavigation(to: verseId)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    bookmarksVM.deleteBookmark(id: item.bookmark.id)
                                } label: {
                                    Label("action.delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 48)).foregroundStyle(.quaternary)
            Text("bookmarks.empty.title").font(.headline).foregroundStyle(.secondary)
            Text("bookmarks.empty.body")
                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
    }
}

#Preview {
    BookmarksListView()
        .environmentObject(BookmarksViewModel(store: InMemoryUserDataStore(), authService: LocalAuthService.shared))
        .environmentObject(AppNavigationRouter())
        .background(Color(.systemGroupedBackground))
}
