// FootnoteTooltip.swift
// SourceBible
//
// Примітка перекладача, показана як тултіп біля знака виноски (літера a, b…) у тексті вірша.
//
// Чому тултіп, а не sheet чи секція в bottom sheet — за виміром вмісту (2026-08-07):
// у перекладі Огієнка 1 203 примітки, медіана 42 символи, максимум 298, жодної довшої
// за 400. Це глоса в один рядок («Бошет — Ваал, сором», «Grecьке ώραίαν — цвітучі,
// хороші»), а не коментар. Sheet під два рядки тексту забирає екран і рве читання;
// поповер лишає вірш на місці, тобто примітка читається В контексті, для чого її й писали.
//
// ⛔ Не додавати сюди заголовок, кнопку закриття чи роздільники. Поповер закривається
// тапом поза ним (системна поведінка), а шапка над 42 символами тексту важила б більше
// за сам текст.

import SwiftUI
import UIKit

struct FootnoteTooltip: View {

    let text: String

    /// Стеля ширини. 280 pt лишає поповеру місце на дзьобик і поля навіть на SE.
    private let maxWidth: CGFloat = 280
    private let hPad: CGFloat = 16
    private let vPad: CGFloat = 14

    /// Ширина тексту: власна ширина в один рядок, але не ширша за стелю.
    ///
    /// Поповер, як і в системі (Apple Books), має ОБГОРТАТИ вміст: «Or, deep darkness» —
    /// вузький пузир, а не 280 pt порожнечі. SwiftUI-поповер бере розмір із ideal size
    /// вмісту, а в `Text` без запропонованої ширини ideal — це один нескінченний рядок, тож
    /// ширину рахуємо явно тим самим шрифтом (`.callout` з поточним Dynamic Type).
    private var textWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .callout)
        let oneLine = (text as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(oneLine), maxWidth - 2 * hPad)
    }

    var body: some View {
        // ⛔ НЕ загортати текст у ScrollView безумовно (так було до 2026-10-07): ScrollView не
        // має власної висоти, тож поповер брав типову й однорядкова примітка сиділа в пузирі
        // на три рядки з порожнечею знизу. ViewThatFits спершу пробує голий текст (поповер
        // обгортає його точно), а ScrollView — лише запасний варіант, коли текст не влазить
        // (найдовша виноска ASV — 302 символи; реально лише при великому Dynamic Type).
        ViewThatFits(in: .vertical) {
            noteText
            ScrollView { noteText }
                // Без «гумки», коли прокручувати нічого.
                .scrollBounceBehavior(.basedOnSize)
        }
        // ⛔ `.presentationCompactAdaptation(.popover)` — БЕЗ нього на iPhone (compact size
        // class) SwiftUI перетворює поповер на модальний sheet, тобто рівно на те, чого ця
        // фіча уникає. Доступний з iOS 16.4 — нижче за наш мінімум iOS 18, тож без гейта.
        .presentationCompactAdaptation(.popover)
        // ⛔ Не задавати presentationCornerRadius і власний фон: система малює матеріал
        // поповера й радіус сама (правило про corner radius у CLAUDE.md).
    }

    private var noteText: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            // Примітки Огієнка містять і латинську транслітерацію, і грецькі слова —
            // розрив рядка має йти по словах.
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
    }
}

#if DEBUG
#Preview("Однорядкова — ASV") {
    FootnoteTooltip(text: "Hebrew see for himself.")
}

#Preview("Коротка — значення імені") {
    FootnoteTooltip(text: "Бошет — Ваал, сором.")
}

#Preview("Довга — з посиланням у тексті") {
    FootnoteTooltip(text: "Число Псалма подається за порядком грецьким, а в дужках біля "
                        + "нього — порядок гебрейський. При цитаціях (відсилачах) — "
                        + "порядок єврейський.")
}
#endif
