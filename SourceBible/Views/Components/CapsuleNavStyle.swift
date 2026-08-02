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

/// Капсула для контролів, які на iOS 26 система стилізує САМА:
/// `ToolbarItemGroup` дає скляну капсулу автоматично, `.buttonStyle(.glass)` — теж.
///
/// ⛔ На iOS 26 це НАВМИСНО no-op. `CLAUDE.md` прямо забороняє домальовувати
/// `.glassEffect` до тулбарних кнопок — система вже все зробила, ручний шар лише
/// ламає системну консистентність.
///
/// Застосовується ТІЛЬКИ до чипів у контенті (фільтри пошуку). Тулбар рідера
/// свідомо лишається без капсул на iOS 18 — рішення 2026-08-01: у нав-барі 18
/// нативні саме голі контроли, а капсула там читається як чужа мова iOS 26.
/// Матеріал — системний `secondarySystemFill`, легший за `.bordered`, який давав
/// важку «кнопкову» заливку.
struct LegacyControlCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemFill), in: Capsule())
        }
    }
}

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
    func legacyControlCapsule() -> some View {
        modifier(LegacyControlCapsule())
    }
}
