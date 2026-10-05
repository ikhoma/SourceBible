// WordRenderingsSheet.swift
// SourceBible
//
// ADR-041 частина 3: stacked sheet «усі входження слова в перекладі».
// Відкривається з рядка «Translated in KJV» (Meaning) з уже вибраною передачею.
// Чипи-передачі переносяться на кілька рядків (без горизонтального скролу — рішення
// Івана на демо v8), пікер книг — у тулбарі, список згрупований за книгами.
// Тап по вірші → читанка; «‹ Назад» відкриває аркуш знову з тим самим фільтром (ч.4).

import SwiftUI

struct WordRenderingsSheet: View {
    let state: RenderingsSheetState

    @EnvironmentObject private var vm: ReaderViewModel
    @Environment(\.colorTheme) private var colorTheme

    /// nil = «Все».
    @State private var renderingFilter: Int?
    /// nil = всі книги.
    @State private var bookFilter: String?
    @State private var summary: RenderingSummary?
    @State private var occurrences: [RenderingOccurrence] = []
    @State private var loaded = false

    init(state: RenderingsSheetState) {
        self.state = state
        _renderingFilter = State(initialValue: state.renderingFilter)
        _bookFilter = State(initialValue: state.bookFilter)
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

    private func close() { vm.renderingsSheet = nil }

    /// Тап по вірші (ч.4): у читанку, а поточний фільтр і вірш-якір — у back-stack,
    /// щоб «‹ Назад» відкрив аркуш таким самим.
    private func open(_ occ: RenderingOccurrence) {
        var back = state
        back.renderingFilter = renderingFilter
        back.bookFilter = bookFilter
        back.anchorOccurrenceId = occ.id
        vm.followRenderingOccurrence(to: "\(occ.bookId)|\(occ.chapter)|\(occ.verse)", returnTo: back)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // ScrollView + LazyVStack, а не List — та сама анатомія, що в
                // результатах Пошуку (resultsScroll): поля 20, рядок ±10, Divider.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        chips
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        if !loaded {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.items) { occ in
                                        OccurrenceRow(occurrence: occ,
                                                      reference: "\(bookName(occ.bookId)) \(occ.chapter):\(occ.verse)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 10)
                                            .contentShape(Rectangle())
                                            .onTapGesture { open(occ) }
                                            .accessibilityAddTraits(.isButton)
                                            .id(occ.id)
                                        Divider()
                                    }
                                } header: {
                                    bookHeader(section)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .pinnedHeaderEdge()
                .navigationTitle(Text(verbatim: state.lemma))
                .transliterationSubtitle(state.transliteration)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCloseButton(action: close)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        bookMenu
                    }
                }
                .task(id: state.id) {
                    summary = vm.renderingSummaryForSheet(strongsId: state.strongsId,
                                                          translation: state.translationId)
                    occurrences = vm.renderingOccurrences(strongsId: state.strongsId,
                                                          translation: state.translationId)
                    loaded = true
                    // Повернення з читанки: до вірша, з якого пішли.
                    if let anchor = state.anchorOccurrenceId {
                        await Task.yield()
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
        }
        .themedSheet(colorTheme)
        .presentationDetents([.large])
        .onChange(of: renderingFilter) { _, _ in
            // Книга могла зникнути з нового фільтра — тоді показуємо всі.
            if let b = bookFilter, !bookCounts.contains(where: { $0.bookId == b }) {
                bookFilter = nil
            }
        }
    }

    /// Липкий заголовок книги: назва + кількість. Непрозорий фон аркуша, щоб
    /// рядки не просвічували під ним під час прокрутки.
    private func bookHeader(_ section: BookSection) -> some View {
        HStack {
            Text(verbatim: bookName(section.id))
            Spacer()
            Text(verbatim: "\(section.items.count)")
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .background(colorTheme.sheetBackground)
    }

    // MARK: Chips

    @ViewBuilder
    private var chips: some View {
        if let summary {
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
            // Шеврон — та сама ознака вибору, що в тулбарі читанки й чипах Пошуку.
            HStack(spacing: 4) {
                if let b = bookFilter {
                    Text(verbatim: vm.translationBookNames[b]?.short ?? BibleBookNames.short(for: b))
                } else {
                    Text("search.filter.all_books")
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

// MARK: - Row

private struct OccurrenceRow: View {
    let occurrence: RenderingOccurrence
    let reference: String

    // Та сама анатомія, що в перехресних посиланнях і результатах Пошуку:
    // шеврон справа = рядок веде на вірш.
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ReferenceLabel(reference)
                Text(VerseHighlight.attributed(raw: occurrence.rawText,
                                               verseId: occurrence.id,
                                               taggedOrdinal: occurrence.segOrd,
                                               spans: occurrence.highlight))
                    .font(.callout)
                }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Highlight by segment ordinal

/// Текст вірша з підсвіченим ОДНИМ словом — сегментом № `taggedOrdinal` серед
/// сегментів з Strong's. Розбір — той самий `VerseParser`, що й у читанці та
/// build-скрипті (`seg_ord`), тож підсвічується саме те слово, яке зіставлено,
/// а не всі збіги номера у вірші (як у старому `highlightedVerseText` для Usage).
enum VerseHighlight {
    /// - Parameter spans: `hl` з бази — «ord:start:len;…»: підсвітити лише передачу
    ///   («for his **mercy**», а не весь сегмент), у т.ч. слово, розбите на кілька
    ///   сегментів («**put** him **to death**»). Зсуви — в Unicode-скалярах тексту
    ///   сегмента, як рахує Python-порт `VerseParser`. `nil` або зсув за межами
    ///   тексту → весь сегмент `taggedOrdinal`, як раніше.
    static func attributed(raw: String, verseId: String, taggedOrdinal: Int,
                           spans: String? = nil) -> AttributedString {
        let parsed = VerseParser.parse(verseId: verseId, rawText: raw)
        let ranges = parseSpans(spans)
        var pieces: [(String, Bool)] = []
        var ord = -1
        for seg in parsed.segments {
            if seg.isParagraphBreak { continue }
            if seg.isLineBreak { pieces.append((" ", false)); continue }
            var hit = false
            if !seg.strongs.isEmpty {
                ord += 1
                if let ranges {
                    if let r = ranges[ord], let split = split(seg.text, r) {
                        pieces.append(contentsOf: split)
                        continue
                    }
                    hit = ranges[ord] != nil      // зсув не ліг — хоч увесь сегмент
                } else {
                    hit = ord == taggedOrdinal
                }
            }
            // Пробіл перед комою прибирає сам VerseParser (bug-056).
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

    /// «3:0:3;5:1:8» → [3: 0..<3, 5: 1..<9]. Будь-що непарсабельне → nil (весь сегмент).
    private static func parseSpans(_ spec: String?) -> [Int: Range<Int>]? {
        guard let spec, !spec.isEmpty else { return nil }
        var out: [Int: Range<Int>] = [:]
        for part in spec.split(separator: ";") {
            let f = part.split(separator: ":").compactMap { Int($0) }
            guard f.count == 3, f[1] >= 0, f[2] > 0 else { return nil }
            out[f[0]] = f[1]..<(f[1] + f[2])
        }
        return out.isEmpty ? nil : out
    }

    /// Текст сегмента → [до, передача, після] за зсувами в Unicode-скалярах.
    private static func split(_ text: String, _ r: Range<Int>) -> [(String, Bool)]? {
        let scalars = Array(text.unicodeScalars)
        guard r.upperBound <= scalars.count else { return nil }
        func str(_ s: ArraySlice<Unicode.Scalar>) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: s)
            return String(v)
        }
        return [(str(scalars[..<r.lowerBound]), false),
                (str(scalars[r]), true),
                (str(scalars[r.upperBound...]), false)].filter { !$0.0.isEmpty }
    }
}

// MARK: - Transliteration subtitle

private extension View {
    /// Транслітерація під лемою — системний підзаголовок навбару (iOS 26: менший
    /// шрифт, secondary-колір — стиль дає система, своїх не заводимо). iOS 18 цього
    /// API не має — там лишається тільки лема, як було.
    @ViewBuilder
    func transliterationSubtitle(_ xlit: String) -> some View {
        if #available(iOS 26.0, *), !xlit.isEmpty {
            navigationSubtitle(Text(verbatim: xlit))
        } else {
            self
        }
    }
}

// MARK: - Pinned header edge

private extension View {
    /// iOS 26: тулбар аркуша прозорий, і рядки видно в смузі між ним та липким
    /// заголовком книги. Apple радить `.hard` для прокрутки з закріпленими
    /// заголовками — край під тулбаром стає суцільним. iOS 18: бар і так непрозорий.
    @ViewBuilder
    func pinnedHeaderEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
