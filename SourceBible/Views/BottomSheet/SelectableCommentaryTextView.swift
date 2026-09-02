// SelectableCommentaryTextView.swift
// SourceBible
//
// Тіло коментаря — SwiftUI ScrollView + LazyVStack з групою НЕ-скролячих
// UITextView-чанків (замість одного великого скролячого UITextView, як було
// до 2026-09-02 — див. ADR-037 §1). Причина заміни: один UITextView з усім
// текстом секції одразу ламався на справді величезних секціях (Оуен, Євр
// 1:1-2 ≈ 231 000 символів — біла сторінка; Генрі Євр 11:4-31 ≈ 62 000 —
// гальмує скрол). Це РЕГРЕС відносно оригінального фіксу з коміту 9ef6ec1
// (4 червня) — тодішній per-paragraph LazyVStack+Text — який ADR-037 замінив
// заради нативного виділення тексту через межу абзаців, не переперевіривши
// на цьому ж великому кейсі (баг знайдено повторно Іваном, manual test,
// 2026-09-02, /engineering:debug).
//
// Компроміс цього фіксу: абзаци групуються у чанки по ~12 000 символів
// (buildChunks) — 94.5% реальних секцій (виміряно на commentaries-en.db,
// 23 275 секцій) вкладаються в ОДИН чанк, тобто нуль візуальних змін проти
// попередньої поведінки. Лише вироджені секції (Оуен, Генрі) розбиваються
// на кілька чанків; найгірший випадок (Оуен, Євр 3:7-11, 282 543 символи) —
// 25 чанків замість одного нерендерабельного блоку. Ціна: виділення тексту
// НЕ тягнеться через межу чанка (та сама ціна, що мав оригінальний
// per-paragraph фікс 9ef6ec1 — компроміс узгоджено з Іваном, 2026-09-02).
//
// Кожен чанк — свій маленький isScrollEnabled=false UITextView (сам не
// скролиться, розмір визначається sizeThatFits — стандартний спосіб
// авто-висоти UITextView у SwiftUI); скролить зовнішній ScrollView. Прогрес
// колапсу шапки (onScroll) тепер рахується з offset-у ЦЬОГО зовнішнього
// ScrollView через iOS 18 onScrollGeometryChange, а не з внутрішнього
// scrollViewDidScroll одного UITextView, як було раніше.
//
// Меню виділення на кожному чанку: власні пункти «Поділитися» / «Додати в
// нотатку» через UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)
// (iOS 16+) — НЕ buildMenu(with:)/UIMenuBuilder, той API не застосовується до
// меню виділення тексту (лише до UIMenuSystem.main/.context). Системний Share
// прибирається дефензивним фільтром suggestedActions (недокументований як
// жорсткий контракт — QA Action Item 9 в ADR-037). Writing Tools приховано
// офіційним UITextView.writingToolsBehavior = .none (плюс дефензивний
// фільтр про всяк випадок); Translate перегруповано в один ряд з Copy
// (Ivan, 2026-09-01).

import SwiftUI
import UIKit

struct SelectableCommentaryTextView: View {

    let text: String
    /// Викликається з обраним рядком, коли натиснуто «Поділитися».
    var onShareRequested: (String) -> Void
    /// Викликається з обраним рядком, коли натиснуто «Додати в нотатку».
    var onAddToNoteRequested: (String) -> Void
    /// Вертикальний scroll-offset ЗОВНІШНЬОГО ScrollView — джерело для
    /// анімованого колапсу шапки теолога у CommentaryDetailView (двостейтова
    /// шапка, рішення Івана).
    var onScroll: (CGFloat) -> Void = { _ in }

    /// Максимум символів на чанк — 12 000, узгоджено з Іваном 2026-09-02
    /// (94.5% секцій = 1 чанк; найгірший реальний кейс, Оуен Євр 3:7-11,
    /// 282 543 символи → 25 чанків по ~11 тис.).
    private static let chunkBudget = 12_000

    /// Кешовані чанки — НЕ computed property (code review 2026-09-02, Critical
    /// #1). `chunks` раніше рахувався наживо в `body`: `CommentaryDetailView`
    /// пише `@State headerCollapseProgress` на КОЖЕН тік `onScroll` (навіть
    /// без зміни значення), що перемальовує `CommentaryDetailView.body`, що
    /// перебудовує цей `View` заново, що знову викликає його `body` — тобто
    /// `buildChunks` (спліт+trim+побудова NSAttributedString під сотні
    /// абзаців) ганяв на КОЖЕН кадр скролу. Той самий клас бага, що ADR-037
    /// §1 явно попереджав ще для старої (одно-UITextView) версії: «Будувати
    /// NSAttributedString один раз і кешувати... інакше кожен updateUIView =
    /// повна верстка». Тепер рахуємо лише коли `text` дійсно змінюється.
    @State private var chunks: [NSAttributedString] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chunks.indices, id: \.self) { i in
                    CommentaryChunkTextView(
                        attributedText: chunks[i],
                        onShareRequested: onShareRequested,
                        onAddToNoteRequested: onAddToNoteRequested
                    )
                }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newValue in
            onScroll(newValue)
        }
        .onAppear { rebuildChunksIfNeeded() }
        .onChange(of: text) { _, _ in rebuildChunksIfNeeded() }
    }

    private func rebuildChunksIfNeeded() {
        chunks = Self.buildChunks(from: text, budget: Self.chunkBudget)
    }

    /// Групує абзаци (розділені "\n\n") у чанки, кожен ≤ `budget` символів
    /// (крім одиничного абзацу, що сам по собі перевищує бюджет — тоді він
    /// стає власним чанком, як є). Індекс абзацу рахується ГЛОБАЛЬНО через
    /// усі чанки (не скидається на межі чанка), тому paragraphSpacingBefore
    /// застосовується однаково і всередині чанка, і на межі між чанками —
    /// межа чанка (view boundary) лишається невидимою для читача.
    ///
    /// "\n" МІЖ абзацами — без нього TextKit бачить один суцільний абзац
    /// (append() сам по собі не створює межу абзацу), тому
    /// paragraphSpacingBefore ніколи не спрацьовував і текст виглядав одним
    /// шматком без розбивки (Henry HEB, баг знайдений Іваном, 2026-09-02).
    /// Без "\n" після ОСТАННЬОГО абзацу всього тексту — щоб не повернути
    /// зайвий відступ знизу, щойно прибраний.
    static func buildChunks(from text: String, budget: Int) -> [NSAttributedString] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        let font = UIFont.preferredFont(forTextStyle: .body)
        var chunks: [NSAttributedString] = []
        var current = NSMutableAttributedString()
        var currentLen = 0

        for (index, para) in paragraphs.enumerated() {
            if currentLen > 0 && currentLen + para.count > budget {
                chunks.append(current)
                current = NSMutableAttributedString()
                currentLen = 0
            }

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            if index > 0 { style.paragraphSpacingBefore = 12 }

            let isLastParagraphOverall = index == paragraphs.count - 1
            let piece = isLastParagraphOverall ? para : para + "\n"

            current.append(NSAttributedString(string: piece, attributes: [
                .font:            font,
                .foregroundColor: UIColor.label,
                .paragraphStyle:  style
            ]))
            currentLen += para.count
        }
        if current.length > 0 { chunks.append(current) }
        return chunks
    }
}

// MARK: - CommentaryChunkTextView (один нескролячий UITextView-чанк)

/// Один чанк (група абзаців у межах char-бюджету), що рендериться власним
/// UITextView з isScrollEnabled = false — розмір визначається sizeThatFits,
/// сам чанк не скролиться, скролить батьківський ScrollView
/// (SelectableCommentaryTextView.body). Той самий принцип, який ADR-037 вже
/// підтвердив як безпечний для МАЛОГО вмісту — тут застосований по
/// ~12К-шматках, а не по всьому документу відразу (яке ADR-037 відхилив
/// саме тому, що весь документ одразу — це вже не малий вміст).
private struct CommentaryChunkTextView: UIViewRepresentable {

    let attributedText: NSAttributedString
    var onShareRequested: (String) -> Void
    var onAddToNoteRequested: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable         = false
        tv.isSelectable       = true
        tv.isScrollEnabled    = false
        tv.backgroundColor    = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate           = context.coordinator
        tv.attributedText      = attributedText
        // tintColor драйвить і selection handles/caret, і підсвітку виділеного
        // діапазону в UITextView — одна властивість, обидва запити (Ivan,
        // 2026-09-01). Системний дефолт → фірмовий синій застосунку
        // (HighlightColor.swift, єдине джерело правди, той самий колір, що і
        // для тапу по слову деінде в рідері).
        tv.tintColor           = .appBlue
        // Приховуємо Writing Tools повністю (Ivan, 2026-09-01) — офіційний,
        // задокументований спосіб: UITextView.writingToolsBehavior, iOS 18+.
        // Мінімальний deployment target проєкту й так iOS 18, тому без
        // #available. Пункт «Writing Tools» у suggestedActions теж
        // фільтруємо нижче в Coordinator про всяк випадок, тим самим
        // дефензивним стилем, що і Share (жоден системний ідентифікатор тут
        // не задокументований як гарантований контракт).
        tv.writingToolsBehavior = .none
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.attributedText != attributedText {
            tv.attributedText = attributedText
        }
        context.coordinator.onShareRequested    = onShareRequested
        context.coordinator.onAddToNoteRequested = onAddToNoteRequested
    }

    /// isScrollEnabled = false робить UITextView саморозмірним по контенту —
    /// це стандартний спосіб дати йому реальну (не 0) висоту всередині
    /// SwiftUI-стеку без окремого скролу.
    ///
    /// НЕ через uiView.sizeThatFits(_:) напряму — той може повернути висоту,
    /// заміряну під СТАРУ ширину textContainer з попереднього layout-проходу
    /// (кешовану), а не під ширину, яку щойно запропонував SwiftUI. У списку
    /// чанків (LazyVStack) це проявлялось як обрізаний останній видимий
    /// шматок тексту внизу секції — ScrollView вважав контент коротшим, ніж
    /// він є насправді, і не давав доскролити до кінця (Ivan, manual test,
    /// 2026-09-02, /engineering:debug). Фікс: примусово виставляємо ширину
    /// textContainer і питаємо layoutManager про usedRect — це форсує
    /// реальний перерахунок під ЦЮ конкретну ширину, а не читає кеш.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer)
        return CGSize(width: width, height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator()
        coord.onShareRequested     = onShareRequested
        coord.onAddToNoteRequested = onAddToNoteRequested
        return coord
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var onShareRequested:     (String) -> Void = { _ in }
        var onAddToNoteRequested: (String) -> Void = { _ in }

        // Кастомні пункти меню виділення. `range`/`suggestedActions` приходять
        // від делегата — НЕ читаємо textView.selectedRange (може розійтись у
        // async-контексті виклику меню).
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let plain = textView.text,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= (plain as NSString).length
            else { return nil }

            let selected = (plain as NSString).substring(with: range)

            // Ivan, 2026-09-01: «Копіювання та переклад з системних вистачить»
            // — з усього suggestedActions лишаємо ТІЛЬКИ Copy і Translate,
            // решту (Look Up, Search Web, Share, Writing Tools і будь-що ще
            // системне) свідомо ігноруємо. Це allowlist, а не denylist: явно
            // ВИТЯГУЄМО потрібні два елементи (можливо, вкладені в підменю
            // Look Up — там типово лежать Look Up/Translate/Search Web
            // разом), а не перелічуємо все, що треба прибрати — так нові
            // системні пункти в майбутніх iOS не просочаться самі по собі.
            let (translateAction, afterTranslate) = extractElement(
                from: suggestedActions, identifierContains: "translate", titles: ["Translate"])
            let (copyAction, _) = extractElement(
                from: afterTranslate, identifierContains: "copy", titles: ["Copy"])

            let share = UIAction(title: NSLocalizedString("action.share", comment: "")) { [weak self] _ in
                self?.onShareRequested(selected)
            }
            let addToNote = UIAction(title: NSLocalizedString("commentary.menu.addToNote", comment: "")) { [weak self] _ in
                self?.onAddToNoteRequested(selected)
            }
            let ourActions = UIMenu(options: .displayInline, children: [share, addToNote])

            var copyTranslateChildren: [UIMenuElement] = []
            if let copyAction { copyTranslateChildren.append(copyAction) }
            if let translateAction { copyTranslateChildren.append(translateAction) }
            let copyTranslateGroup: [UIMenuElement] = copyTranslateChildren.isEmpty
                ? []
                : [UIMenu(options: .displayInline, children: copyTranslateChildren)]

            // Порядок: Copy+Translate (якщо знайшлись) → наша група
            // Share/Додати в нотатку. Усе інше системне — не потрапляє.
            return UIMenu(children: copyTranslateGroup + [ourActions])
        }

        /// Системний пункт меню за ідентифікатором АБО заголовком — жоден з
        /// двох не задокументований як гарантований контракт для системних
        /// пунктів меню виділення тексту, тож перевіряємо обидва (той самий
        /// дефензивний стиль, що і фільтр Share вище).
        private func isSystemAction(_ element: UIMenuElement, identifierContains needle: String, titles: [String]) -> Bool {
            let idMatch: Bool
            if let menu = element as? UIMenu {
                idMatch = menu.identifier.rawValue.lowercased().contains(needle)
            } else if let action = element as? UIAction {
                idMatch = action.identifier.rawValue.lowercased().contains(needle)
            } else {
                idMatch = false
            }
            if idMatch { return true }
            return titles.contains { element.title.caseInsensitiveCompare($0) == .orderedSame }
        }

        /// Витягує перший елемент, що відповідає ідентифікатору/заголовку —
        /// або на верхньому рівні, або як дитину одного з вкладених UIMenu
        /// (Translate типово лежить всередині групи Look Up/Search Web).
        /// Повертає знайдений елемент і решту дерева без нього; підменю, з
        /// якого забрали дитину, лишається зі своїми іншими дітьми
        /// (`UIMenu.replacingChildren`), а якщо дітей не лишилось — підменю
        /// прибирається повністю.
        private func extractElement(from elements: [UIMenuElement], identifierContains needle: String, titles: [String]) -> (UIMenuElement?, [UIMenuElement]) {
            var found: UIMenuElement?
            var result: [UIMenuElement] = []

            for element in elements {
                if found == nil, isSystemAction(element, identifierContains: needle, titles: titles) {
                    found = element
                    continue
                }
                if found == nil, let menu = element as? UIMenu,
                   let childMatch = menu.children.first(where: { isSystemAction($0, identifierContains: needle, titles: titles) }) {
                    found = childMatch
                    let remainingChildren = menu.children.filter { $0 !== childMatch }
                    if !remainingChildren.isEmpty {
                        result.append(menu.replacingChildren(remainingChildren))
                    }
                    continue
                }
                result.append(element)
            }
            return (found, result)
        }
    }
}
