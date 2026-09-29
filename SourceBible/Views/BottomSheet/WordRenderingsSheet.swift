// WordRenderingsSheet.swift
// SourceBible
//
// ADR-041 частина 3: stacked sheet «усі входження слова в перекладі».
// Відкривається з рядка «Translated in KJV» (Meaning) з уже вибраною передачею.
// Чипи-передачі переносяться на кілька рядків (без горизонтального скролу — рішення
// Івана на демо v8), пікер книг — у тулбарі, список згрупований за книгами.
// Тап по вірші (перехід у читанку з back-stack) — частина 4, тут ще не підключено.

import SwiftUI

struct WordRenderingsSheet: View {
    let entry: StrongsEntry
    let summary: RenderingSummary
    let onClose: () -> Void

    @EnvironmentObject private var vm: ReaderViewModel
    @Environment(\.colorTheme) private var colorTheme

    /// nil = «Все». Початкове значення — передача, з рядка якої відкрили аркуш.
    @State private var renderingFilter: Int?
    /// nil = всі книги.
    @State private var bookFilter: String?
    @State private var occurrences: [RenderingOccurrence] = []
    @State private var loaded = false

    init(entry: StrongsEntry, summary: RenderingSummary, initialRendering: Int?,
         onClose: @escaping () -> Void) {
        self.entry = entry
        self.summary = summary
        self.onClose = onClose
        _renderingFilter = State(initialValue: initialRendering)
    }

    // MARK: Derived

    private var byRendering: [RenderingOccurrence] {
        guard let r = renderingFilter else { return occurrences }
        return occurrences.filter { $0.renderingId == r }
    }

    private var visible: [RenderingOccurrence] {
        guard let b = bookFilter else { return byRendering }
        return byRendering.filter { $0.bookId == b }
    }

    /// Книги для пікера — лише ті, де є входження ПОТОЧНОЇ передачі, у канонічному порядку.
    private var bookCounts: [(bookId: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for o in byRendering {
            if counts[o.bookId] == nil { order.append(o.bookId) }
            counts[o.bookId, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private struct BookSection: Identifiable {
        let id: String
        let items: [RenderingOccurrence]
    }

    private var sections: [BookSection] {
        var out: [BookSection] = []
        for o in visible {
            if out.last?.id == o.bookId {
                out[out.count - 1] = BookSection(id: o.bookId, items: out[out.count - 1].items + [o])
            } else {
                out.append(BookSection(id: o.bookId, items: [o]))
            }
        }
        return out
    }

    private func bookName(_ id: String) -> String {
        vm.translationBookNames[id]?.long ?? BibleBookNames.full(for: id)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                Section {
                    chips
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { occ in
                                OccurrenceRow(occurrence: occ,
                                              reference: "\(bookName(occ.bookId)) \(occ.chapter):\(occ.verse)")
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            HStack {
                                Text(verbatim: bookName(section.id))
                                Spacer()
                                Text(verbatim: "\(section.items.count)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .themedList(colorTheme)
            .navigationTitle(Text(verbatim: entry.originalWord))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    bookMenu
                }
            }
        }
        .themedSheet(colorTheme)
        .presentationDetents([.large])
        .task(id: "\(entry.id)|\(summary.translationId)") {
            occurrences = vm.renderingOccurrences(for: entry, translation: summary.translationId)
            loaded = true
        }
        .onChange(of: renderingFilter) { _, _ in
            // Книга могла зникнути з нового фільтра — тоді показуємо всі.
            if let b = bookFilter, !bookCounts.contains(where: { $0.bookId == b }) {
                bookFilter = nil
            }
        }
    }

    // MARK: Chips

    private var chips: some View {
        FlowLayout(spacing: 8) {
            chip(label: Text("search.filter.all"), count: summary.matched,
                 selected: renderingFilter == nil) { renderingFilter = nil }
            ForEach(summary.items) { item in
                chip(label: Text(verbatim: item.text), count: item.count,
                     selected: renderingFilter == item.id) {
                    // Повторний тап по активному чипу знімає фільтр (m5 з review).
                    renderingFilter = (renderingFilter == item.id) ? nil : item.id
                }
            }
        }
    }

    @ViewBuilder
    private func chip(label: Text, count: Int, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        let content = HStack(spacing: 4) {
            label
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .opacity(0.7)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)

        // Системні капсули, як фільтри Пошуку: вибраний — prominent з акцентом.
        if selected {
            Button(action: action) { content }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.appBlue)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.primary)
        }
    }

    // MARK: Book picker

    private var bookMenu: some View {
        Menu {
            Picker(selection: $bookFilter) {
                Text("search.filter.all_books").tag(String?.none)
                ForEach(bookCounts, id: \.bookId) { b in
                    Text(verbatim: "\(bookName(b.bookId))  \(b.count)").tag(Optional(b.bookId))
                }
            } label: {
                Text("search.filter.book.title")
            }
            .pickerStyle(.inline)
        } label: {
            if let b = bookFilter {
                Text(verbatim: vm.translationBookNames[b]?.short ?? BibleBookNames.short(for: b))
            } else {
                Text("search.filter.all_books")
            }
        }
    }
}

// MARK: - Row

private struct OccurrenceRow: View {
    let occurrence: RenderingOccurrence
    let reference: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReferenceLabel(reference)
            Text(VerseHighlight.attributed(raw: occurrence.rawText,
                                           verseId: occurrence.id,
                                           taggedOrdinal: occurrence.segOrd))
                .font(.callout)
                .lineSpacing(3)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Highlight by segment ordinal

/// Текст вірша з підсвіченим ОДНИМ словом — сегментом № `taggedOrdinal` серед
/// сегментів з Strong's. Розбір — той самий `VerseParser`, що й у читанці та
/// build-скрипті (`seg_ord`), тож підсвічується саме те слово, яке зіставлено,
/// а не всі збіги номера у вірші (як у старому `highlightedVerseText` для Usage).
enum VerseHighlight {
    static func attributed(raw: String, verseId: String, taggedOrdinal: Int) -> AttributedString {
        let parsed = VerseParser.parse(verseId: verseId, rawText: raw)
        var pieces: [(String, Bool)] = []
        var ord = -1
        for seg in parsed.segments {
            if seg.isParagraphBreak { continue }
            if seg.isLineBreak { pieces.append((" ", false)); continue }
            var hit = false
            if !seg.strongs.isEmpty {
                ord += 1
                hit = ord == taggedOrdinal
            }
            if !seg.text.isEmpty { pieces.append((seg.text, hit)) }
        }
        // Краї вірша: джерело кодує пробіл між словами як ведучий пробіл сегмента
        // (bug-008/009) — усередині це правильно, на краях дає зайвий відступ.
        if !pieces.isEmpty {
            pieces[0].0 = String(pieces[0].0.drop(while: { $0 == " " }))
            let last = pieces.count - 1
            while pieces[last].0.hasSuffix(" ") { pieces[last].0.removeLast() }
        }
        var result = AttributedString()
        for (text, hit) in pieces where !text.isEmpty {
            var a = AttributedString(text)
            if hit { a.foregroundColor = Color.appBlue }
            result += a
        }
        return result
    }
}
