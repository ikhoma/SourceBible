// EntriesView.swift
// SourceBible

import SwiftUI

struct EntriesView: View {

    @EnvironmentObject private var notesVM:     NotesViewModel
    @EnvironmentObject private var bookmarksVM: BookmarksViewModel
    @EnvironmentObject private var readerVM:    ReaderViewModel

    @State private var tab: EntriesTab = .notes
    @State private var filter = EntriesFilter()
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
                    .legacySegmentedCapsule()
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    if tab == .notes {
                        NotesListView(filter: filter)
                            .environmentObject(notesVM)
                    } else {
                        BookmarksListView(filter: filter)
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
                // 2026-07: кнопку «+» (нова нотатка без вірша) прибрано з v1 —
                // нотатки створюються тільки з вірша (Study Mode → Нотатка).
                // Замість неї — фільтри списку.
                ToolbarItem(placement: .primaryAction) {
                    filterMenu
                }
            }
        }
    }

    // MARK: - Filter menu

    private var filterMenu: some View {
        Menu {
            // Період (за датою запису)
            Section("entries.filter.period") {
                Picker("entries.filter.period", selection: $filter.period) {
                    ForEach(EntriesFilter.Period.allCases, id: \.self) { p in
                        Text(p.labelKey).tag(p)
                    }
                }
                .pickerStyle(.inline)
            }

            // Книга Біблії — підменю лише з книг, по яких є записи в активній вкладці
            if !availableBookIds.isEmpty {
                Section {
                    Picker("entries.filter.book", selection: $filter.bookId) {
                        Text("entries.filter.all_books").tag(String?.none)
                        ForEach(availableBookIds, id: \.self) { id in
                            Text(readerVM.shortBookName(for: id)).tag(String?.some(id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // Сортування
            Section("entries.filter.sort") {
                Picker("entries.filter.sort", selection: $filter.order) {
                    ForEach(EntriesFilter.Order.allCases, id: \.self) { o in
                        Text(o.labelKey).tag(o)
                    }
                }
                .pickerStyle(.inline)
            }

            if filter != EntriesFilter() {
                Section {
                    Button("entries.filter.reset") { filter = EntriesFilter() }
                }
            }
        } label: {
            // 2026-08-03: плоский гліф замість `.circle` / `.circle.fill`.
            // ⚠️ У `line.3.horizontal.decrease` НЕМАЄ fill-варіанта, тож старий
            // індикатор «фільтр активний» (контур ↔ заливка) тут не працює.
            // Тимчасово стан позначено вагою — рішення про фінальний індикатор
            // за користувачем.
            Image(systemName: "line.3.horizontal.decrease")
                .fontWeight(filter.isFiltering ? .bold : .regular)
        }
        .accessibilityLabel(Text("entries.filter.a11y"))
    }

    /// Книги, по яких реально є записи в активній вкладці, у канонічному порядку
    /// поточного перекладу.
    private var availableBookIds: [String] {
        let ids: Set<String>
        switch tab {
        case .notes:
            ids = Set(notesVM.notes.flatMap(\.verseIds).compactMap(EntriesFilter.bookId(fromVerseId:)))
        case .bookmarks:
            ids = Set(bookmarksVM.bookmarks.flatMap(\.verseIds).compactMap(EntriesFilter.bookId(fromVerseId:)))
        }
        return ids.sorted {
            let a = readerVM.translationBookNames[$0]?.order ?? Int.max
            let b = readerVM.translationBookNames[$1]?.order ?? Int.max
            return a < b
        }
    }

    // TODO: Re-enable when the folders feature is implemented. Hidden from the
    // toolbar for now (no folder UI shipped yet).
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

// MARK: - Entries filter model
// Спільний для нотаток і закладок. Дата: нотатки — updatedAt, закладки — createdAt.

struct EntriesFilter: Equatable {

    enum Period: CaseIterable {
        case all, today, week, month

        var labelKey: LocalizedStringKey {
            switch self {
            case .all:   return "entries.filter.period.all"
            case .today: return "entries.filter.period.today"
            case .week:  return "entries.filter.period.week"
            case .month: return "entries.filter.period.month"
            }
        }

        /// Нижня межа періоду; nil = без обмеження.
        var cutoff: Date? {
            let cal = Calendar.current
            switch self {
            case .all:   return nil
            case .today: return cal.startOfDay(for: Date())
            case .week:  return cal.date(byAdding: .day, value: -7,  to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

    enum Order: CaseIterable {
        case newest, oldest

        var labelKey: LocalizedStringKey {
            switch self {
            case .newest: return "entries.filter.sort.newest"
            case .oldest: return "entries.filter.sort.oldest"
            }
        }
    }

    var period: Period   = .all
    var order:  Order    = .newest
    var bookId: String?  = nil

    /// true, коли список реально звужено (сортування не рахується) —
    /// живить filled-варіант іконки.
    var isFiltering: Bool { period != .all || bookId != nil }

    // MARK: Apply

    func apply(to notes: [NoteWithBlocks]) -> [NoteWithBlocks] {
        var result = notes
        if let cutoff = period.cutoff {
            result = result.filter { $0.note.updatedAt >= cutoff }
        }
        if let bookId {
            result = result.filter { item in
                item.verseIds.contains { Self.bookId(fromVerseId: $0) == bookId }
            }
        }
        return result.sorted {
            order == .newest ? $0.note.updatedAt > $1.note.updatedAt
                             : $0.note.updatedAt < $1.note.updatedAt
        }
    }

    func apply(to bookmarks: [BookmarkWithVerses]) -> [BookmarkWithVerses] {
        var result = bookmarks
        if let cutoff = period.cutoff {
            result = result.filter { $0.bookmark.createdAt >= cutoff }
        }
        if let bookId {
            result = result.filter { item in
                item.verseIds.contains { Self.bookId(fromVerseId: $0) == bookId }
            }
        }
        return result.sorted {
            order == .newest ? $0.bookmark.createdAt > $1.bookmark.createdAt
                             : $0.bookmark.createdAt < $1.bookmark.createdAt
        }
    }

    /// "PSA|50|3" → "PSA"
    static func bookId(fromVerseId verseId: String) -> String? {
        let parts = verseId.split(separator: "|")
        guard let first = parts.first, !first.isEmpty else { return nil }
        return String(first)
    }
}

#Preview {
    @MainActor in
    let store = InMemoryUserDataStore()
    let auth  = LocalAuthService.shared
    EntriesView()
        .environmentObject(NotesViewModel(store: store, authService: auth))
        .environmentObject(BookmarksViewModel(store: store, authService: auth))
        .environmentObject(ReaderViewModel(store: store))
        .environmentObject(AppNavigationRouter())
}
