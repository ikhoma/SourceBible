// LegacyTabBarAppearance.swift
// SourceBible
//
// Явна конфігурація UITabBar — ТІЛЬКИ для iOS 18 (bug-032).
//
// ⛔ На iOS 26 не робить нічого і не має починати. Там таббар — плаваючий
// Liquid Glass зі своєю логікою фону; підсовувати йому UITabBarAppearance
// означає воювати з системою (той самий принцип, що й заборона домальовувати
// .glassEffect до тулбарних кнопок у CLAUDE.md).
//
// ЧОМУ ЦЕ ВЗАГАЛІ ПОТРІБНО. До 2026-08-01 у проєкті не було ЖОДНОГО налаштування
// таббара — він лишався повністю стоковим. На iOS 26 це не мало наслідків. На 18
// класичний бар лишився зі своїми дефолтами, і це дало два симптоми з одного кореня:
//
//   1. Зникав підклад на коротких екранах. `scrollEdgeAppearance` (механіка з iOS 15)
//      застосовується, коли сусідній скрол стоїть біля свого краю або не скролиться
//      взагалі — а він за замовчуванням ПРОЗОРИЙ. На Entries з однією карткою скролу
//      немає, тож бар був прозорим завжди; у рідері глава довга — і бар брав звичайний
//      вигляд із матеріалом. Два екрани стабільно падали в дві різні гілки.
//
//   2. Бар лишався темним після перемикання теми. Без власного appearance UIKit
//      виводить вигляд із trait collection і кешує його; зміна `preferredColorScheme`
//      у рантаймі до вже змонтованого бара не доїжджала. Решта контенту перемикалась
//      правильно — відставав лише UIKit-бар.

import SwiftUI
import UIKit

@MainActor
enum LegacyTabBarAppearance {

    /// Проксі `UITabBar.appearance()` впливає лише на бари, СТВОРЕНІ після зміни,
    /// тому цей виклик має відбутись до побудови сцени (init застосунку).
    static func install() {
        guard #unavailable(iOS 26) else { return }
        let bar = UITabBar.appearance()
        bar.standardAppearance = makeAppearance()
        bar.scrollEdgeAppearance = makeAppearance()
    }

    /// Переприкладає вигляд до вже ЖИВИХ барів. Потрібне при зміні теми: проксі
    /// змонтований бар не чіпає, тож без цього перемикання dark→light його омине.
    static func refresh() {
        guard #unavailable(iOS 26) else { return }
        install()
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                applyToTabBars(in: window)
            }
        }
    }

    // MARK: - Private

    /// `configureWithDefaultBackground()` бере системний матеріал, який резолвиться
    /// з поточної trait collection — саме тому переприкладання лікує застряглу тему.
    /// Нових кольорів не вводимо: мета — системний вигляд, а не власний.
    private static func makeAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        return appearance
    }

    private static func applyToTabBars(in view: UIView) {
        if let tabBar = view as? UITabBar {
            tabBar.standardAppearance = makeAppearance()
            tabBar.scrollEdgeAppearance = makeAppearance()
        }
        for subview in view.subviews {
            applyToTabBars(in: subview)
        }
    }
}
