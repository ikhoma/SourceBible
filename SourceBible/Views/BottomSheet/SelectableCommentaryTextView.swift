// SelectableCommentaryTextView.swift
// SourceBible
//
// UIViewRepresentable, що рендерить тіло коментаря як ОДИН скролячий UITextView
// (не пораграфний LazyVStack — див. ADR-037). isScrollEnabled = true: сам
// UITextView є скрол-контейнером, батьківський SwiftUI не додає ще один
// ScrollView навколо. Це і знімає обмеження SwiftUI Text на дуже довгих рядках
// (Calvin PSA 150:6 ≈ 329k символів — найбільша відома секція, ADR-037 §1),
// і дозволяє тягнути виділення через межу абзаців, як в Apple Books.
//
// Меню виділення: власні пункти «Поділитися» / «Додати в нотатку» додаються
// через UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)
// (iOS 16+) — НЕ buildMenu(with:)/UIMenuBuilder, той API не застосовується до
// меню виділення тексту (лише до UIMenuSystem.main/.context). Системний Share
// прибирається дефензивним фільтром suggestedActions (недокументований як
// жорсткий контракт — QA Action Item 9 в ADR-037). Writing Tools приховано
// офіційним UITextView.writingToolsBehavior = .none (плюс дефензивний
// фільтр про всяк випадок); Translate перегруповано в один ряд з Copy
// (Ivan, 2026-09-01).

import SwiftUI
import UIKit

struct SelectableCommentaryTextView: UIViewRepresentable {

    let text: String
    /// Викликається з обраним рядком, коли натиснуто «Поділитися».
    var onShareRequested: (String) -> Void
    /// Викликається з обраним рядком, коли натиснуто «Додати в нотатку».
    var onAddToNoteRequested: (String) -> Void
    /// Вертикальний contentOffset — джерело для анімованого колапсу шапки теолога
    /// у CommentaryDetailView (двостейтова шапка, рішення Івана).
    var onScroll: (CGFloat) -> Void = { _ in }

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable         = false
        tv.isSelectable       = true
        tv.isScrollEnabled    = true
        tv.backgroundColor    = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        tv.delegate           = context.coordinator
        tv.attributedText     = context.coordinator.attributedString
        // tintColor drives BOTH the selection handles/caret AND the selected-
        // range highlight in UITextView — one property, both asks (Ivan,
        // 2026-09-01). System default (label/system blue) → app's own brand
        // blue (HighlightColor.swift, single source of truth, same color used
        // for word-tap tint elsewhere in the reader). Not touching alpha: UIKit
        // applies its own translucency to the highlight from tintColor already,
        // so opacity stays exactly what it was — only the hue changes.
        tv.tintColor           = .appBlue
        // Приховуємо Writing Tools повністю (Ivan, 2026-09-01) — офіційний,
        // задокументований спосіб: UITextView.writingToolsBehavior, iOS 18+.
        // Мінімальний deployment target проєкту й так iOS 18, тому без
        // #available. Пункт «Writing Tools» у suggestedActions теж
        // фільтруємо нижче в Coordinator про всяк випадок, тим самим
        // дефензивним стилем, що і Share (жоден системний ідентифікатор тут
        // не задокументований як гарантований контракт).
        tv.writingToolsBehavior = .none
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        // Перебудовуємо NSAttributedString лише коли текст справді змінився
        // (нова секція/теолог), а не на кожен виклик updateUIView.
        if coord.text != text {
            coord.text             = text
            coord.attributedString = Self.buildAttributedString(from: text)
            tv.attributedText      = coord.attributedString
        }
        coord.onShareRequested    = onShareRequested
        coord.onAddToNoteRequested = onAddToNoteRequested
        coord.onScroll            = onScroll
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator()
        coord.text                 = text
        coord.attributedString     = Self.buildAttributedString(from: text)
        coord.onShareRequested     = onShareRequested
        coord.onAddToNoteRequested = onAddToNoteRequested
        coord.onScroll             = onScroll
        return coord
    }

    /// Зберігає той самий візуальний ритм між абзацами, що раніше давав
    /// LazyVStack(spacing: 12), через paragraphSpacingBefore на кожному абзаці
    /// крім першого.
    static func buildAttributedString(from text: String) -> NSAttributedString {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let font = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()

        for (index, para) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            if index > 0 { style.paragraphSpacingBefore = 12 }

            result.append(NSAttributedString(string: para, attributes: [
                .font:            font,
                .foregroundColor: UIColor.label,
                .paragraphStyle:  style
            ]))
        }
        return result
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIScrollViewDelegate {
        var text: String = ""
        var attributedString = NSAttributedString()
        var onShareRequested:     (String) -> Void = { _ in }
        var onAddToNoteRequested: (String) -> Void = { _ in }
        var onScroll:             (CGFloat) -> Void = { _ in }

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

        // UITextViewDelegate успадковує UIScrollViewDelegate — призначення
        // цього ж coordinator у tv.delegate вже дає виклики scrollViewDidScroll,
        // окремого delegate-слота не потрібно.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onScroll(scrollView.contentOffset.y)
        }
    }
}
