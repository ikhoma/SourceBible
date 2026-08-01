// BookmarksListView.swift
// SourceBible
//
// Bookmarks are pure navigation — tapping a card switches to the Bible tab at that verse.
// No editor sheet, no categories.

import SwiftUI

struct BookmarksListView: View {

    @EnvironmentObject private var bookmarksVM: BookmarksViewModel
    @EnvironmentObject private var router:      AppNavigationRouter

    /// Фільтри вкладки Entries (період / книга / сортування).
    var filter = EntriesFilter()

    private var filteredBookmarks: [BookmarkWithVerses] {
        filter.apply(to: bookmarksVM.bookmarks)
    }

    var body: some View {
        Group {
            if bookmarksVM.bookmarks.isEmpty {
                emptyState
            } else if filteredBookmarks.isEmpty {
                filteredEmptyState
            } else {
                List {
                    ForEach(filteredBookmarks, id: \.bookmark.id) { item in
                        BookmarkCardView(item: item)
                            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
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
                                .tint(.red)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Записи є, але фільтри сховали всі — окремий стан, щоб не плутати з
    /// «закладок ще немає».
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
            Image(systemName: "bookmark")
                .font(.system(size: 48)).foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("bookmarks.empty.title").font(.headline).foregroundStyle(.primary)
                Text("bookmarks.empty.body")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
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
