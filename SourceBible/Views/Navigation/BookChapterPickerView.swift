// BookChapterPickerView.swift
// SourceBible

import SwiftUI

struct BookChapterPickerView: View {

    @EnvironmentObject var vm: ReaderViewModel
    @Environment(\.dismiss) var dismiss

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
                    Button(step == .chapter ? "Назад" : "Закрити") {
                        if step == .chapter { step = .book } else { dismiss() }
                    }
                }
            }
        }
    }

    private var bookList: some View {
        List {
            Section(Testament.old.rawValue) {
                ForEach(filtered(.old)) { book in bookRow(book) }
            }
            Section(Testament.new.rawValue) {
                ForEach(filtered(.new)) { book in bookRow(book) }
            }
        }
        .searchable(text: $searchText, prompt: "Пошук книги")
        .navigationTitle("Книга")
    }

    private func bookRow(_ book: BibleBook) -> some View {
        HStack {
            Text(book.name)
            Spacer()
            Text("\(book.chapterCount) гл.").font(.caption).foregroundStyle(.secondary)
            if vm.currentBook.id == book.id {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedBook = book; step = .chapter }
    }

    private func filtered(_ testament: Testament) -> [BibleBook] {
        let books = vm.allBooks.filter { $0.testament == testament }
        return searchText.isEmpty ? books : books.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
        .navigationTitle(book.name)
    }
}

#Preview {
    BookChapterPickerView().environmentObject(ReaderViewModel())
}
