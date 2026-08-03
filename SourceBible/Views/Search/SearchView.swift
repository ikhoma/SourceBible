// SearchView.swift
// SourceBible

import SwiftUI
import UIKit

struct SearchView: View {

    @Environment(\.analytics)      private var analytics
    @Environment(\.sessionTracker) private var sessionTracker
    @Environment(\.colorTheme)     private var colorTheme

    @StateObject private var vm = SearchViewModel()

    @EnvironmentObject private var router:   AppNavigationRouter
    @EnvironmentObject private var readerVM: ReaderViewModel

    /// True while the search tab is the selected tab (passed by ContentView). Drives a
    /// deterministic restore of the search-bar presentation on tab re-selection
    /// (bug-011) instead of relying on `.onAppear` for a `role: .search` tab.
    var isSelectedTab: Bool = true

    @State private var searchText:       String = ""
    @State private var isSearchActive:   Bool   = false

    /// The query whose results are currently on screen. Empty until the user *commits*
    /// (taps a predictive row or presses the Search key). The typing phase shows only
    /// predictions; results load on commit. When `trimmedQuery != committedQuery` the
    /// user is editing again → back to predictions.
    @State private var committedQuery:   String = ""

    /// Trimmed query — single source of truth for "is the user typing something".
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// True while the user is editing a query that hasn't been committed yet.
    private var isTypingUncommitted: Bool { trimmedQuery != committedQuery }

    /// True when the committed results page is on screen (drives hiding the nav title there).
    private var isShowingResults: Bool { !committedQuery.isEmpty && !isTypingUncommitted }

    // MARK: - Filter state (YouVersion-style: Translation / Testament / Book chips)

    enum TestamentFilter { case all, old, new }
    @State private var testamentFilter: TestamentFilter = .all

    /// Search-only translation override; nil → follow the reader's translation.
    /// Picking a translation here never changes the reader (filter-local by design).
    @State private var selectedTranslationId: String? = nil

    /// Book restriction (OSIS id); nil → all books (within the testament filter).
    @State private var selectedBookId: String? = nil

    private enum FilterSheet: String, Identifiable {
        case translation, testament, book
        var id: String { rawValue }
    }
    @State private var activeFilterSheet: FilterSheet? = nil

    /// Translation the search actually runs against.
    private var effectiveTranslationId: String {
        selectedTranslationId ?? readerVM.currentTranslation.id
    }

    /// Book-id restriction pushed into the SQL query (nil = no restriction).
    /// A selected book wins over the testament filter (the book is always
    /// inside the selected testament — enforced in onChange).
    private var effectiveBookIds: [String]? {
        if let bookId = selectedBookId { return [bookId] }
        switch testamentFilter {
        case .all: return nil
        case .old: return readerVM.oldTestamentBooks.map(\.id)
        case .new: return readerVM.newTestamentBooks.map(\.id)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen app background behind everything (incl. safe areas and the
                // floating search field). Matches the ReaderView pattern; a plain
                // `.background(...)` on `content` left the system black showing through
                // the safe areas and the empty space below short List content.
                colorTheme.appBackground.ignoresSafeArea()
                content
                    // Large bold "Search" on the home states (hint / Recent / predictions).
                    // On the results page there's already a "Results for …" header, and the
                    // large title there flickered between states — so hide the nav bar there.
                    .navigationTitle("tab.search")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar(isShowingResults ? .hidden : .automatic, for: .navigationBar)
            }
        }
        // No `.searchSuggestions` overlay (removed the iOS 26 width squeeze). Predictions
        // render inline in `predictiveList`; results load on commit into `resultsList`.
        // `.searchable` + Tab(role: .search) still drive the bottom bar + morph animation. (ADR-008 §5)
        .searchable(
            text: $searchText,
            isPresented: $isSearchActive,
            placement: .automatic,
            // bug-018: String(localized:) bypasses the LocalizedBundle swizzle and
            // resolves against the system locale (always EN). Text(_:) resolves the
            // key through Bundle.main at render time → follows the in-app language.
            prompt: Text("search.prompt.keyword")
        )
        .onSubmit(of: .search) {
            commit(query: searchText)
        }
        .onChange(of: searchText) { _, newValue in
            // Typing phase only refreshes predictions — it does NOT run the full search.
            // (That avoids dense results painting behind the predictions + translucent bar,
            // and the wasted per-keystroke FTS queries.) Results load on commit.
            vm.updateSuggestions(for: newValue)

            // Clearing the field (cancel ✕ or the in-field clear) drops back out of the
            // committed/results state so we don't flash stale results.
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty { committedQuery = "" }
        }
        // Filter changes re-run the committed query against the DB (filters live in
        // SQL now — the result set is paginated, so client-side filtering can't work).
        .onChange(of: testamentFilter) { _, newValue in
            // Book selection must stay inside the chosen testament.
            if let bookId = selectedBookId {
                let t = BibleBookNames.testament(for: bookId)
                if (newValue == .old && t != .old) || (newValue == .new && t != .new) {
                    selectedBookId = nil
                }
            }
            rerunSearchIfNeeded()
        }
        .onChange(of: selectedBookId)        { _, _ in rerunSearchIfNeeded() }
        .onChange(of: selectedTranslationId) { _, _ in rerunSearchIfNeeded() }
        .sheet(item: $activeFilterSheet) { sheet in
            filterSheet(sheet)
        }
        // Wire the live analytics + tracker into the VM on first appear.
        // Can't be done at @StateObject init time (Environment not available then).
        .task {
            vm.analytics      = analytics
            vm.sessionTracker = sessionTracker
        }
        // bug-011: restore the search-bar presentation (the large clear ✕) when
        // returning to a committed results page — see reassertSearchPresentationIfNeeded().
        // Driven off the tab-selection state (reliable for a role: .search tab), with
        // .onAppear as a backup; both are idempotent via the guard.
        .onChange(of: isSelectedTab) { _, selected in
            if selected { reassertSearchPresentationIfNeeded() }
        }
        .onAppear { reassertSearchPresentationIfNeeded() }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if isShowingResults {
            // Committed: full-screen results page (keyboard dismissed on commit).
            resultsPage
        } else if isSearchActive && !trimmedQuery.isEmpty {
            // Typing an uncommitted query: predictions only.
            predictiveList
        } else if !vm.recentQueries.isEmpty {
            recentQueriesSection
        } else {
            searchHintView
        }
    }

    // MARK: - Results page (after commit)

    /// The filter chip bar uses the NATIVE bar treatment — same as the status/tool
    /// bars on the Reader. On iOS 26 it lives in a `.safeAreaBar(edge: .top)`, so the
    /// system renders the Liquid Glass scroll-edge blur behind it automatically as the
    /// results scroll underneath (no manual material). iOS 18 fallback keeps it pinned
    /// as a section header. (iOS 26 rule: #available guard + iOS 18 fallback.)
    /// The bar stays visible on the empty state too, so over-narrowed filters can be
    /// loosened without retyping the query.
    @ViewBuilder
    private var resultsPage: some View {
        if #available(iOS 26.0, *) {
            resultsBody
                .safeAreaBar(edge: .top) {
                    filterBar   // padding is inside filterBar — see note there
                }
        } else {
            resultsBody
                .safeAreaInset(edge: .top, spacing: 0) { legacyFilterBar }
        }
    }

    /// iOS 18 fallback for `.safeAreaBar` — `safeAreaInset(edge: .top)` is its
    /// direct predecessor (iOS 15+): так само резервує місце зверху, так само не
    /// скролиться разом із вмістом.
    ///
    /// ⛔ `ignoresSafeArea` — ТІЛЬКИ на фоні, не на всій смузі. У цьому вся правка:
    /// чипи мусять лишитись під статус-баром, а матеріал — дотягнутись до краю
    /// екрана. Раніше смуга була закріпленою секційною шапкою ВСЕРЕДИНІ скролу,
    /// тож її фон обмежувався висотою чипів — над ним лишалась смуга, крізь яку
    /// проїжджав текст результатів («дірка»), а сам фон читався як окрема плашка.
    ///
    /// Нав-бар на сторінці результатів схований (`toolbar(.hidden)` вище), тому
    /// матеріал тут — єдине, що прикриває цю зону.
    private var legacyFilterBar: some View {
        filterBar
            .background {
                Rectangle()
                    // `.bar` — матеріал, яким система малює саме нав-бари й таббари.
                    // `.ultraThinMaterial` тонший і прозоріший, тож смуга помітно
                    // відрізнялась від тулбара за кольором (зауваження 2026-08-02).
                    .fill(.bar)
                    .ignoresSafeArea(edges: .top)
            }
            // Волосяна лінія на нижній межі — те, що системні нав-бар і таббар
            // малюють як shadow своєї appearance. Без неї смуга обривалась у порожнечу
            // й не читалась як бар (зауваження 2026-08-02).
            //
            // NB: система ховає цю лінію, коли скрол стоїть на самому верху
            // (scrollEdgeAppearance без shadow), і показує, коли вміст заїхав під бар.
            // Тут вона стала: на сторінці результатів під смугою ЗАВЖДИ є список,
            // тож стан «нема під що підкладати лінію» недосяжний.
            .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var resultsBody: some View {
        if !vm.results.isEmpty {
            resultsScroll
        } else if vm.isLoading {
            loadingView
        } else {
            // Смуга приходить із safeAreaBar / safeAreaInset вище — на порожньому
            // стані теж, тож окремий VStack для iOS 18 більше не потрібен.
            emptyResultsView
        }
    }

    // MARK: - Predictive list (typing phase)

    /// Suggestions minus the term the user has already fully typed, so a completed
    /// query doesn't echo itself back as a one-row suggestion.
    private var visibleSuggestions: [String] {
        let q = trimmedQuery.lowercased()
        return vm.suggestions.filter { $0 != q }
    }

    private var predictiveList: some View {
        // NOTE: a `List` here renders inside the `.searchable` results host, whose
        // own `.systemBackground` (black in dark mode) shows through the transparent
        // list — `scrollContentBackground(.hidden)` and `.background()` can't reach it.
        // A `ScrollView` has a clear background, so the ZStack appBackground shows.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !visibleSuggestions.isEmpty {
                    ForEach(visibleSuggestions, id: \.self) { term in
                        completionRow(term)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                } else {
                    // No predictions yet (or "nonsense"): offer a row to search the literal text.
                    literalQueryRow
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.2)
            Text("search.loading").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A predictive-completion row: the matched prefix is rendered in the primary
    /// colour, the predicted remainder in secondary — matching Apple Music's
    /// "**dak**ooka" treatment. Tapping fills the field and runs the search.
    /// (`search_terms` are stored lowercase, so the row reflects that casing.)
    private func completionRow(_ term: String) -> some View {
        let matchLen = min(trimmedQuery.count, term.count)

        var head = AttributedString(String(term.prefix(matchLen)))
        var headAttrs = AttributeContainer(); headAttrs.swiftUI.foregroundColor = Color.primary
        head.mergeAttributes(headAttrs)

        var tail = AttributedString(String(term.dropFirst(matchLen)))
        var tailAttrs = AttributeContainer(); tailAttrs.swiftUI.foregroundColor = Color.secondary
        tail.mergeAttributes(tailAttrs)

        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(head + tail).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { complete(with: term) }
    }

    /// Echoes the raw query (Apple Music shows this when nothing matches). Tapping commits.
    private var literalQueryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(verbatim: searchText)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { commit(query: searchText) }
    }

    // MARK: - Filter bar (Translation / Testament / Book chips)

    private var testamentChipKey: LocalizedStringKey {
        switch testamentFilter {
        case .all: return "search.filter.testament_all"
        case .old: return "search.filter.ot"
        case .new: return "search.filter.nt"
        }
    }

    /// ⚠️ The padding lives INSIDE the ScrollView, on the HStack — do not move it back
    /// out to the call sites. A horizontal ScrollView clips to its bounds, and the
    /// `.glass` chips draw their Liquid Glass shadow OUTSIDE the capsule: with the
    /// padding outside the scroll view there was no room inside the clip rect and the
    /// shadow was sliced off flat on all four sides (bug: "shadow behind filters looks
    /// cut off", 2026-07-14). Padding the content gives the shadow room within the clip
    /// AND lets the bar span the full width, so the scroll-edge blur reaches the screen
    /// edges instead of stopping at a 20pt inset.
    /// Поля смуги фільтрів.
    ///
    /// iOS 26: як було — чипи `.buttonStyle(.glass)` мають власну геометрію,
    /// і 20/8 підібрані під неї. ⛔ Не чіпати.
    ///
    /// iOS 18: чипи голі, тож розміри смуги задають вигляд повністю.
    /// - 16 по горизонталі = стандартний leading-інсет нав-бара, тож перший чип
    ///   стоїть рівно там, де «Hos 4 ⌄» у рідері;
    /// - 11 по вертикалі: `.headline` дає ~22 pt, 22 + 11·2 = 44 — висота
    ///   дефолтного тулбара. До цього було 8 + власні 6 чипа з кожного боку,
    ///   тобто ~50, і смуга помітно переростала тулбар.
    private static var filterBarHorizontalPadding: CGFloat {
        if #available(iOS 26, *) { return 20 } else { return 16 }
    }

    private static var filterBarVerticalPadding: CGFloat {
        if #available(iOS 26, *) { return 8 } else { return 11 }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(action: { activeFilterSheet = .translation }) {
                    Text(effectiveTranslationId)
                }
                filterChip(action: { activeFilterSheet = .testament }) {
                    Text(testamentChipKey)
                }
                filterChip(action: { activeFilterSheet = .book }) {
                    if let bookId = selectedBookId {
                        Text(bookDisplayName(bookId))
                    } else {
                        Text("search.filter.all_books")
                    }
                }
            }
            .padding(.horizontal, Self.filterBarHorizontalPadding)
            .padding(.vertical, Self.filterBarVerticalPadding)
        }
        // The .glass chips' shadow blur is wider than any padding we'd want to add
        // (padding alone just pushes the pills around and still clips at the bottom).
        // scrollClipDisabled lets the shadow render outside the scroll view's bounds.
        // Safe here: the content only overflows HORIZONTALLY when the chips are wider
        // than the screen, and that overflow lands in the 20pt side margins — there is
        // no vertical overflow to leak over the results list.
        .scrollClipDisabled()
    }

    /// Filter chip styled like the Reader's toolbar pickers (`pickerGroup`):
    /// headline text + caption chevron.down in `.primary`, glass capsule around it.
    /// The Reader gets the capsule for free from the iOS 26 toolbar; outside a
    /// toolbar the equivalent is `.buttonStyle(.glass)`. На iOS 18 — без заливки,
    /// як тулбар рідера (див. коментар у гілці нижче).
    @ViewBuilder
    private func filterChip(action: @escaping () -> Void,
                            @ViewBuilder label: () -> some View) -> some View {
        let content = HStack(spacing: 4) {
            label()
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                // NOTE: the Reader's toolbar renders this same .caption chevron at
                // .large image scale (iOS 26 toolbar default — don't override there).
                // Here, outside a toolbar, the .medium default looks better and is
                // kept deliberately (sign-off 2026-07-08).
                .foregroundStyle(.primary)
        }
        if #available(iOS 26.0, *) {
            Button(action: action) { content }
                .buttonStyle(.glass)
        } else {
            // 1:1 з `pickerGroup` рідера: той самий вміст, і ЖОДНИХ власних
            // падінгів. Спершу (2026-08-03) прибрали лише заливку, а падінги
            // 12/6 лишили «щоб тримати зону дотику» — і чипи, втративши фон,
            // почали читатись як текст із випадковими великими проміжками.
            // Розміри тепер задає сама смуга (`filterBar`), як тулбар задає
            // розміри своїх пікерів.
            Button(action: action) { content }
                .buttonStyle(.plain)
        }
    }

    // MARK: - Filter sheets

    @ViewBuilder
    private func filterSheet(_ sheet: FilterSheet) -> some View {
        switch sheet {
        case .translation:
            // Reuses the settings translation picker (Binding-based — selection is
            // local to search and does NOT touch the reader's translation).
            NavigationStack {
                DefaultTranslationPickerView(
                    translations: readerVM.availableTranslations,
                    selectedId: Binding(
                        get: { effectiveTranslationId },
                        set: { selectedTranslationId = $0 }
                    ),
                    titleKey: "search.filter.translation.title"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Консистентний X-close для всіх sheet-ів (SheetCloseButton)
                        SheetCloseButton { activeFilterSheet = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        case .testament:
            testamentSheet
        case .book:
            bookSheet
        }
    }

    private var testamentSheet: some View {
        NavigationStack {
            List {
                testamentRow("search.filter.all", .all).themedRow(colorTheme)
                testamentRow("search.filter.old", .old).themedRow(colorTheme)
                testamentRow("search.filter.new", .new).themedRow(colorTheme)
            }
            .themedList(colorTheme)
            .navigationTitle("search.filter.testament.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Консистентний X-close для всіх sheet-ів (SheetCloseButton)
                    SheetCloseButton { activeFilterSheet = nil }
                }
            }
        }
        .themedSheet(colorTheme)
        .presentationDetents([.medium])
    }

    private func testamentRow(_ key: LocalizedStringKey,
                              _ value: TestamentFilter) -> some View {
        HStack {
            Text(key)
            Spacer()
            if testamentFilter == value {
                Image(systemName: "checkmark").foregroundStyle(.appBlue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            testamentFilter   = value
            activeFilterSheet = nil
        }
    }

    /// Books shown in the Book sheet: per-book result counts for the current query,
    /// ordered by count desc (YouVersion style), restricted to the testament filter.
    private var bookSheetCounts: [SearchBookCount] {
        vm.bookCounts.filter { entry in
            switch testamentFilter {
            case .all: return true
            case .old: return BibleBookNames.testament(for: entry.bookId) == .old
            case .new: return BibleBookNames.testament(for: entry.bookId) == .new
            }
        }
    }

    private var bookSheet: some View {
        NavigationStack {
            List {
                HStack {
                    Text("search.filter.all")
                    Spacer()
                    if selectedBookId == nil {
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedBookId    = nil
                    activeFilterSheet = nil
                }
                .themedRow(colorTheme)

                ForEach(bookSheetCounts) { entry in
                    HStack {
                        Text(bookDisplayName(entry.bookId))
                        Spacer()
                        Text("\(entry.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if selectedBookId == entry.bookId {
                            Image(systemName: "checkmark").foregroundStyle(.appBlue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedBookId    = entry.bookId
                        activeFilterSheet = nil
                    }
                    .themedRow(colorTheme)
                }
            }
            .themedList(colorTheme)
            .navigationTitle("search.filter.book.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Консистентний X-close для всіх sheet-ів (SheetCloseButton)
                    SheetCloseButton { activeFilterSheet = nil }
                }
            }
        }
        .themedSheet(colorTheme)
        .presentationDetents([.medium, .large])
    }

    /// Book display name in the SEARCH translation's native naming, with the
    /// locale-aware static table as fallback.
    private func bookDisplayName(_ bookId: String) -> String {
        vm.bookNames[bookId]?.long ?? BibleBookNames.full(for: bookId)
    }

    // MARK: - Results list

    /// Scrollable results with infinite scroll. Смуга фільтрів сюди БІЛЬШЕ НЕ
    /// входить: на обох платформах вона живе в `resultsPage` як safe-area бар
    /// (`safeAreaBar` на 26, `safeAreaInset` на 18). Раніше на 18 вона була
    /// закріпленою секційною шапкою всередині цього скролу — звідси й «дірка».
    @ViewBuilder
    private var resultsScroll: some View {
        // ScrollView (not List) so the ZStack appBackground shows through — see note
        // on `predictiveList`.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Group {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("search.results_header \(searchText.trimmingCharacters(in: .whitespaces))")
                            .font(.title2).bold()
                            .foregroundStyle(.primary)
                        Text("search.results_count \(vm.totalCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)

                    ForEach(vm.results) { result in
                        SearchResultRow(result: result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { navigate(to: result) }
                            // Infinite scroll: prefetch the next page as the tail
                            // of the loaded window comes into view.
                            .onAppear { prefetchIfNeeded(after: result) }
                        Divider()
                    }

                    if vm.canLoadMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .padding(.horizontal, 20)
            // ux-013: consistent 16pt end-of-content margin (matches reader chapter end).
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// Loads the next page when the appearing row is within the last 10 of the
    /// loaded window (smooth scroll — the page lands before the spinner is reached).
    private func prefetchIfNeeded(after result: SearchResult) {
        guard vm.canLoadMore,
              let idx = vm.results.firstIndex(where: { $0.id == result.id }),
              idx >= vm.results.count - 10 else { return }
        vm.loadMore()
    }

    // MARK: - Empty states

    private var emptyResultsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("search.no_results.title").font(.headline).foregroundStyle(.primary)
                Text("search.no_results.body")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var recentQueriesSection: some View {
        // ScrollView (not List) so the ZStack appBackground shows through — see note
        // on `predictiveList` re: the `.searchable` results host background.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("search.recent")
                        .font(.title3).bold()
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("search.clear") { vm.clearRecent() }
                        .font(.callout)
                        .foregroundStyle(.appBlue)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                Divider()

                ForEach(vm.recentQueries.prefix(8), id: \.self) { recent in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.tertiary).frame(width: 20)
                        Text(recent)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = recent
                        commit(query: recent)
                    }
                    Divider()
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchHintView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("search.hint.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("search.hint.body \(readerVM.currentTranslation.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Actions

    /// Tapping a predictive completion fills the field with the term and commits.
    private func complete(with term: String) {
        searchText = term
        commit(query: term)
    }

    /// Commit a query → load its results page and dismiss the keyboard.
    /// Setting `committedQuery == trimmedQuery` flips `content` from predictions to results.
    /// Recent is saved by the ViewModel only if the query actually returns results,
    /// so dead queries ("Dhhdhhdh", words absent from this translation) aren't recorded.
    private func commit(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        committedQuery = q
        runSearch(q)
        dismissKeyboard()
    }

    /// (Re)runs a query with the current filter set. Filters live in SQL — the
    /// ViewModel loads page 0 + total count; further pages via infinite scroll.
    private func runSearch(_ q: String) {
        // Pass the active testament filter so search_committed includes it.
        let filterStr: String?
        switch testamentFilter {
        case .old:  filterStr = "OT"
        case .new:  filterStr = "NT"
        case .all:  filterStr = nil
        }
        vm.search(query: q, translation: effectiveTranslationId,
                  bookIds: effectiveBookIds,
                  testamentFilter: filterStr)
    }

    /// Filter changed while results are on screen → re-query with the same text.
    private func rerunSearchIfNeeded() {
        guard isShowingResults else { return }
        runSearch(committedQuery)
    }

    private func navigate(to result: SearchResult) {
        // Fire search_result_opened. Filters are applied in SQL now, so resultsCount
        // is the TOTAL filtered match count the header shows; position is the index
        // within the loaded (paginated) list the user actually tapped.
        let position = vm.results.firstIndex(where: { $0.id == result.id }) ?? 0
        analytics.track(.searchResultOpened(
            resultsCount: vm.totalCount,
            position:     position
        ))
        router.requestNavigation(to: result.id)
    }

    /// Resign first responder without dismissing the whole search presentation,
    /// so the field keeps showing the query while the keyboard hides (Apple Music behaviour).
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// bug-011: Opening a result switches to the Bible tab, which deselects this
    /// search-role tab and collapses its `.searchable` presentation
    /// (`isSearchActive` -> false). On return, `committedQuery` still drives the
    /// results page, but the system search bar that draws the large clear (✕) button
    /// is inactive, so the ✕ is missing on the 2nd+ open. Re-assert the presented
    /// state whenever a committed results page is on screen so every return matches
    /// the first-open chrome.
    private func reassertSearchPresentationIfNeeded() {
        guard isShowingResults, !isSearchActive else { return }
        isSearchActive = true
        // The committed results state is keyboard-free (see `commit`). Re-presenting
        // the field can make it first responder, so drop the keyboard on the next tick
        // once the presentation has mounted (mirrors ContentView's deferred cross-tab
        // navigation hop).
        Task { @MainActor in dismissKeyboard() }
    }
}

// MARK: - Result row

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ReferenceLabel(result.reference)

                Text(parseSnippet(result.snippet))
                    .font(.callout)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }

    /// Parses ❮highlighted❯ markers into an AttributedString.
    /// Uses the shared `Color.wordHighlight` background, matching the verse-reader
    /// word selection and the Usage-tab concordance highlight style.
    private func parseSnippet(_ raw: String) -> AttributedString {
        var output    = AttributedString()
        var remaining = raw[raw.startIndex...]

        while let open = remaining.range(of: "❮") {
            let plain = String(remaining[remaining.startIndex ..< open.lowerBound])
            if !plain.isEmpty { output += AttributedString(plain) }
            remaining = remaining[open.upperBound...]

            if let close = remaining.range(of: "❯") {
                let hit = String(remaining[remaining.startIndex ..< close.lowerBound])
                var highlighted = AttributedString(hit)
                var container = AttributeContainer()
                container.swiftUI.foregroundColor = Color.appBlue
                highlighted.mergeAttributes(container)
                output   += highlighted
                remaining = remaining[close.upperBound...]
            }
        }

        if !remaining.isEmpty { output += AttributedString(String(remaining)) }
        return output
    }
}

// MARK: - Preview

#Preview {
    SearchView()
        .environmentObject(AppNavigationRouter())
        .environmentObject(ReaderViewModel(store: InMemoryUserDataStore()))
}
