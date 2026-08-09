// FootnoteTooltip.swift
// SourceBible
//
// Примітка перекладача, показана як тултіп біля хрестика † у тексті вірша.
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

struct FootnoteTooltip: View {

    let text: String

    /// Стеля ширини. 280 pt лишає поповеру місце на дзьобик і поля навіть на SE, і при
    /// медіані 42 символи більшість приміток вкладається у два рядки.
    private let maxWidth: CGFloat = 280

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                // Примітки Огієнка містять і латинську транслітерацію (`Lechem
                // hammaarachet`), і грецькі слова — розрив рядка має йти по словах.
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        // ScrollView лише для тих кількох приміток, що не вміщаються (max 298 символів +
        // великий Dynamic Type). `scrollBounceBehavior(.basedOnSize)` прибирає «гумку» на
        // коротких — інакше дворядковий тултіп пружинив би, ніби там ще щось є.
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: maxWidth)
        // ⛔ `.presentationCompactAdaptation(.popover)` — БЕЗ нього на iPhone (compact size
        // class) SwiftUI перетворює поповер на модальний sheet, тобто рівно на те, чого ця
        // фіча уникає. Доступний з iOS 16.4 — нижче за наш мінімум iOS 18, тож без гейта.
        .presentationCompactAdaptation(.popover)
        // ⛔ Не задавати presentationCornerRadius і власний фон: система малює матеріал
        // поповера й радіус сама (правило про corner radius у CLAUDE.md).
    }
}

#if DEBUG
#Preview("Коротка — значення імені") {
    FootnoteTooltip(text: "Бошет — Ваал, сором.")
}

#Preview("Довга — з посиланням у тексті") {
    FootnoteTooltip(text: "Число Псалма подається за порядком грецьким, а в дужках біля "
                        + "нього — порядок гебрейський. При цитаціях (відсилачах) — "
                        + "порядок єврейський.")
}
#endif
