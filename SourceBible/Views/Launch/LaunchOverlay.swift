// LaunchOverlay.swift
// SourceBible
//
// Продовження системного launch screen у SwiftUI: те саме лого (`LaunchLogo`,
// 120 pt) по центру всього екрана, доки не завантажиться перший розділ
// (але не менше `minimumVisibleDuration` від старту процесу), — потім
// одним кадром читанка, без анімації. Коли ховати — вирішує LaunchGate
// (ViewModels/LaunchGate.swift).
//
// Фон — `appBackground` АКТИВНОЇ теми й режиму (Paper + система за
// замовчуванням, тобто той самий колір, що й на launch screen). Якщо
// користувач обрав Incunable або примусовий Light/Dark, оверлей уже в його
// кольорах: launch screen статичний і цього не знає, тож для таких
// користувачів колір змінюється на межі launch screen → оверлей.
//
// ⛔ Центрування — від УСЬОГО екрана (`ignoresSafeArea` на контейнері), бо
// launch screen має `UIImageRespectsSafeAreaInsets = false`. Інакше лого
// зсунеться на пів висоти статус-бару в момент передачі.

import SwiftUI

struct LaunchOverlay: View {
    @Environment(\.colorTheme) private var colorTheme

    /// Має збігатися з розміром LaunchLogo-*.svg (width/height/viewBox = 120).
    static let logoSize: CGFloat = 120

    var body: some View {
        ZStack {
            colorTheme.appBackground
            // Явні 120×120 pt, незалежно від intrinsic-розміру ассета: launch
            // screen бере розмір із SVG (120×120, viewBox теж 120), тут — фіксуємо
            // той самий, щоб при передачі лого не змінювало розмір.
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: Self.logoSize, height: Self.logoSize)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
