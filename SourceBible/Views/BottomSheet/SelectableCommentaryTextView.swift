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
// жорсткий контракт — QA Action Item 9 в ADR-037).

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

            // Прибираємо ГОЛИЙ системний Share (без атрибуції) — заміняємо його
            // своїм нижче. Дефензивна подвійна перевірка: системний Share у
            // suggestedActions може прийти або як UIMenu(.share), або як
            // UIAction з ідентифікатором "share" — жоден варіант не
            // задокументований як гарантований контракт (ADR-037 §2 QA note).
            let filtered = suggestedActions.filter { element in
                if let menu = element as? UIMenu, menu.identifier == .share { return false }
                if let action = element as? UIAction, action.identifier.rawValue == "share" { return false }
                return true
            }

            let share = UIAction(title: NSLocalizedString("action.share", comment: "")) { [weak self] _ in
                self?.onShareRequested(selected)
            }
            let addToNote = UIAction(title: NSLocalizedString("commentary.menu.addToNote", comment: "")) { [weak self] _ in
                self?.onAddToNoteRequested(selected)
            }
            let ourActions = UIMenu(options: .displayInline, children: [share, addToNote])

            // Copy/Look Up/Translate/Search Web лишаються як є, у своєму
            // порядку; наша група стає туди, де раніше був системний Share.
            return UIMenu(children: filtered + [ourActions])
        }

        // UITextViewDelegate успадковує UIScrollViewDelegate — призначення
        // цього ж coordinator у tv.delegate вже дає виклики scrollViewDidScroll,
        // окремого delegate-слота не потрібно.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onScroll(scrollView.contentOffset.y)
        }
    }
}
