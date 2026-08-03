// CapsuleNavStyle.swift
// SourceBible
//
// ViewModifier that applies a capsule background to navigation button groups.
// iOS 26+: native Liquid Glass via .glassEffect.
// iOS 16–25: filled capsule with secondarySystemFill.

import SwiftUI

struct CapsuleNavGroupStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(in: Capsule())
        } else {
            content
                .background(Color(UIColor.secondarySystemFill))
                .clipShape(Capsule())
        }
    }
}

/// Liquid Glass capsule pill for the action bar.
/// iOS 26+: native glassEffect. iOS 18–25: ultraThinMaterial fallback.
struct GlassActionPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    func capsuleNavGroupStyle() -> some View {
        modifier(CapsuleNavGroupStyle())
    }

    func glassActionPill() -> some View {
        modifier(GlassActionPillModifier())
    }
}

// MARK: - Legacy (iOS 18) parity helpers

/// Капсульна форма для системних кнопок (`.bordered` / `.borderedProminent`).
///
/// На iOS 26 кнопки капсульні за замовчуванням — там це НАВМИСНО no-op, щоб
/// не чіпати системний вигляд. На iOS 18 `.bordered*` дає прямокутник із малим
/// радіусом, і поруч із рештою застосунку він читається як з іншої епохи.
///
/// `.buttonBorderShape(.capsule)` — системний API, а не ручний `cornerRadius`:
/// форма лишається на совісті стилю кнопки, ми лише просимо іншу.
struct LegacyCapsuleButtonShape: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.buttonBorderShape(.capsule)
        }
    }
}

// ⛔ Сегментований контрол на iOS 18 лишається СИСТЕМНИМ. Не заокруглювати.
//
// Пробували 2026-08-03: `clipShape(Capsule())` на `.pickerStyle(.segmented)`.
// Трек став капсулою, а «пігулка» виділення всередині лишилась зі своїм
// радіусом ~9 — вийшов прямокутник у капсулі, гірше за вихідний вигляд.
//
// Форму індикатора SwiftUI не віддає, а `UISegmentedControl` не має для неї
// публічного API. Єдиний спосіб — лізти в його `subviews` і правити
// `layer.cornerRadius` вручну: недокументована ієрархія, що ламається між
// версіями iOS. Не варте того заради кількох пунктів радіуса.
//
// Якщо колись справді знадобиться капсульний сегментований — це власний
// контрол, а не патч системного.

/// Радіус карток у Entries (нотатки, закладки).
///
/// iOS 26 малює 32 — squircle в дусі згрупованих меню цієї версії. На iOS 18 такої
/// мови немає, і 32 читається як завеликий міхур. Нативний орієнтир на 18 — радіус
/// секції згрупованого списку (`insetGrouped`), тобто 10: рівно те, що дають секції
/// у нашому ж Меню, бо вони системний `List`.
///
/// ⛔ Один токен на всі картки. Розсипати числа по файлах — рівно те, через що
/// пікери рідера й чипи пошуку розʼїхались.
enum AppCornerRadius {
    static var card: CGFloat {
        if #available(iOS 26, *) { return 32 } else { return 10 }
    }

    /// Радіус превʼю-плиток теми в Меню (Paper / Incunable).
    /// Це не системний компонент, тож автоматики немає ні там, ні там — але 14 з
    /// мови iOS 26 на 18 виглядає завеликим поруч із плоскішими секціями списку.
    /// На 18 беремо ту саму 10, що й `card`: у Меню плитки стоять усередині секції
    /// згрупованого списку, тож збігатися їм логічно саме з нею.
    static var tile: CGFloat {
        if #available(iOS 26, *) { return 14 } else { return 10 }
    }

    /// Радіус вкладених елементів усередині картки (бабл нотатки).
    /// Мусить лишатись помітно МЕНШИМ за `card`: при картці 10 і баблі 16
    /// вкладене ставало круглішим за контейнер і ієрархія читалась навиворіт.
    static var cardInner: CGFloat {
        if #available(iOS 26, *) { return 16 } else { return 8 }
    }
}

extension View {
    func legacyCapsuleButton() -> some View {
        modifier(LegacyCapsuleButtonShape())
    }

}
