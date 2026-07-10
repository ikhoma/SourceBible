// BookChapterPickerView.swift
// SourceBible

import SwiftUI

struct BookChapterPickerView: View {

    @EnvironmentObject var vm: ReaderViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.locale) private var locale

    @State private var step: Step = .book
    @State private var selectedBook: BibleBook? = nil
    @State private var searchText = ""

    /// Books-step layout, persisted (ADR-025 key).
    @AppStorage(AppStorageKeys.bookPickerBooksViewMode)
    private var booksViewMode: BooksViewMode = .list

    enum Step { case book, chapter }

    enum BooksViewMode: String { case list, tiles }

    var body: some View {
        NavigationStack {
            Group {
                if step == .book {
                    if booksViewMode == .tiles {
                        bookTiles
                    } else {
                        bookList
                    }
                } else if let book = selectedBook {
                    chapterGrid(for: book)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .chapter ? "action.back" : "action.close") {
                        if step == .chapter { step = .book } else { dismiss() }
                    }
                }
                if step == .book {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            booksViewMode = (booksViewMode == .list) ? .tiles : .list
                        } label: {
                            Label(booksViewMode == .list ? "picker.view_tiles" : "picker.view_list",
                                  systemImage: booksViewMode == .list ? "square.grid.2x2" : "list.bullet")
                        }
                    }
                }
            }
        }
    }

    private var bookList: some View {
        List {
            Section(header: Text("testament.old")) {
                ForEach(filtered(.old)) { book in bookRow(book) }
            }
            Section(header: Text("testament.new")) {
                ForEach(filtered(.new)) { book in bookRow(book) }
            }
        }
        .searchable(text: $searchText, prompt: Text("picker.search_book"))
        .navigationTitle("picker.title_book")
    }

    private func bookRow(_ book: BibleBook) -> some View {
        let displayName = translationName(for: book.id)
        return HStack {
            Text(displayName)
            Spacer()
            Text(String(format: String(localized: "picker.chapters_count"), book.chapterCount))
                .font(.caption).foregroundStyle(.secondary)
            if vm.currentBook.id == book.id {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.appBlue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedBook = book; step = .chapter }
    }

    // MARK: - Tile mode

    /// Flat grid of all 66 books — short names, OT/NT color coded.
    /// OT = secondarySystemFill, NT = appBlue (existing brand accent).
    private var bookTiles: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(sortedBooks(.old) + sortedBooks(.new)) { book in
                    bookTile(book)
                }
            }
            .padding(16)
        }
        .navigationTitle("picker.title_book")
    }

    private func bookTile(_ book: BibleBook) -> some View {
        let isNT = book.testament == .new
        let isCurrent = vm.currentBook.id == book.id
        return Button {
            selectedBook = book
            step = .chapter
        } label: {
            Text(vm.shortBookName(for: book.id))
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 44).frame(maxWidth: .infinity)
                .background(isCurrent ? Color.primary : (isNT ? Color.appBlue : Color(UIColor.secondarySystemFill)))
                .foregroundStyle(isCurrent ? Color(UIColor.systemBackground) : (isNT ? .white : .primary))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(translationName(for: book.id))
    }

    /// Testament's books in translation order, unfiltered (tile mode has no search).
    private func sortedBooks(_ testament: Testament) -> [BibleBook] {
        vm.allBooks
            .filter { $0.testament == testament }
            .sorted {
                let a = vm.translationBookNames[$0.id]?.order ?? Int.max
                let b = vm.translationBookNames[$1.id]?.order ?? Int.max
                return a < b
            }
    }

    private func filtered(_ testament: Testament) -> [BibleBook] {
        let books = sortedBooks(testament)
        guard !searchText.isEmpty else { return books }
        return books.filter {
            translationName(for: $0.id).localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Returns the translation-native book name, falling back to the UI locale name.
    private func translationName(for bookId: String) -> String {
        vm.translationBookNames[bookId]?.long ?? BibleBookNames.full(for: bookId)
    }

    private func chapterGrid(for book: BibleBook) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(1...book.chapterCount, id: \.self) { ch in
                    let isActive = vm.currentBook.id == book.id && vm.currentChapter == ch
                    Button {
                        vm.navigateTo(book: book, chapter: ch)
                        dismiss()
                    } label: {
                        Text("\(ch)")
                            .font(.callout).fontWeight(.medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: 44).frame(maxWidth: .infinity)
                            .background(isActive ? Color.primary : Color(UIColor.secondarySystemFill))
                            .foregroundStyle(isActive ? Color(UIColor.systemBackground) : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(translationName(for: book.id))
    }
}

#Preview {
    BookChapterPickerView().environmentObject(ReaderViewModel(store: InMemoryUserDataStore()))
}
