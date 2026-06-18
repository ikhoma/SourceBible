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

    enum Step { case book, chapter }

    var body: some View {
        NavigationStack {
            Group {
                if step == .book {
                    bookList
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

    private func filtered(_ testament: Testament) -> [BibleBook] {
        let books = vm.allBooks
            .filter { $0.testament == testament }
            .sorted {
                let a = vm.translationBookNames[$0.id]?.order ?? Int.max
                let b = vm.translationBookNames[$1.id]?.order ?? Int.max
                return a < b
            }
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
