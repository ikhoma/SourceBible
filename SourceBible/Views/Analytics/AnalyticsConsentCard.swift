// AnalyticsConsentCard.swift
// SourceBible
//
// One-time bottom sheet shown on first launch asking the user to share
// anonymous usage data.
//
// Persistence:
//   - "analyticsConsentShown"  (Bool) — true after shown once, never show again
//   - "analyticsEnabled"       (Bool) — user's live choice; default ON
//
// ⚠️ ЗГОДА МУСИТЬ БУТИ ЯВНОЮ (перероблено 2026-08-03).
//
// Було дві нечесності, обидві виправлені тут:
//
// 1. Кнопка казала «Не зараз», але `analyticsConsentShown` виставляється в
//    момент ПОКАЗУ, тож екран більше ніколи не зʼявлявся. «Не зараз» де-факто
//    означало «ніколи». Тепер текст = поведінці: «Не ділитися», питаємо один
//    раз, шлях назад — перемикач у Меню.
//
// 2. Свайп вниз не чіпав `analyticsEnabled`, тобто закрити не читаючи
//    означало лишити дефолт. Дефолт реєструється в `SourceBibleApp.init` як
//    `MixpanelAnalytics.isTestFlight` (PDR D4: TestFlight/dev → ON, App Store
//    → OFF), тож у релізі мовчазної згоди НЕ було — але в TestFlight була.
//    Тепер будь-яке закриття без явного вибору = відмова, однаково в усіх
//    збірках: згода існує тільки як affirmative action.
//
//    ⚠️ Побічний ефект для TestFlight: тестер, який змахнув шіт, вимикає собі
//    аналітику, хоча PDR D4 робив її для тестерів opt-out. Свідомий розмін —
//    однозначність семантики проти телеметрії кількох тестерів; шлях назад є
//    в Меню.
//
// ⛔ Не прибирати `onDismiss` і не покладатись на дефолт у цьому шляху —
// це поверне пункт 2.

import SwiftUI

// MARK: - Height measurement

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Consent Card

struct AnalyticsConsentCard: View {
    @Binding var isPresented: Bool
    /// Ставиться лише явним тапом. Усе решта (свайп, тап поза шітом) — відмова.
    @Binding var decisionMade: Bool
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            // Образ замість стіни тексту: за пів секунди видно, про що мова,
            // ще до читання. Тонований круг, а не ілюстрація — той самий ефект
            // ціною одного символа.
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.appBlue)
                .frame(width: 56, height: 56)
                .background(Color.appBlue.opacity(0.12), in: Circle())
                .padding(.bottom, 4)
                .accessibilityHidden(true)   // суто декоративний

            Text("analytics.consent.title")
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Лінк на політику вшитий у речення (markdown у LocalizedStringKey),
            // а не окремим рядком: окремо він читався як третя кнопка й тягнув
            // увагу на себе. `.tint` задає колір лінка — `.foregroundStyle`
            // фарбує лише звичайний текст.
            Text("analytics.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .tint(.appBlue)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Ієрархія дій: залита кнопка + текстова, а не дві однакові.
            // Раніше обидві мали підкладку, і з першого погляду не читалось,
            // яка з них основна.
            VStack(spacing: 4) {
                if #available(iOS 26, *) {
                    acceptButton.buttonStyle(.glassProminent)
                } else {
                    acceptButton.buttonStyle(.borderedProminent)
                }
                declineButton
            }
            .padding(.top, 4)
        }
        .padding(24)
        .padding(.bottom, 8)
    }

    // Accept action WITHOUT its buttonStyle, so the surface can branch by OS.
    // .foregroundStyle(.white): the system auto-contrast on .appBlue (#3085CF)
    // picks a black label in dark mode; the correct color on an accent capsule
    // is white, matching the system's own prominent buttons.
    private var acceptButton: some View {
        Button {
            analyticsEnabled = true
            decisionMade = true
            isPresented = false
        } label: {
            Text("analytics.consent.accept")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.appBlue)
    }

    // Тиха текстова дія без підкладки — щоб основна кнопка читалась основною.
    // Повна ширина збережена заради зони дотику, не заради ваги.
    private var declineButton: some View {
        Button {
            analyticsEnabled = false
            decisionMade = true
            isPresented = false
        } label: {
            Text("analytics.consent.decline")
                .font(.body)
                .foregroundStyle(.appBlue)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Consent Modifier
//
// Usage: attach .analyticsConsentIfNeeded() to the root ContentView.
// Shows the sheet once; never again after that.
//
// Sheet sizing: measured dynamically via GeometryReader so the sheet
// hugs its content. Initial value of 300 avoids a visible jump on first
// appearance (actual measured height is typically ~260–280 pt).
//
// Corner radius: not set — iOS 26 floating partial sheets automatically
// use the device's rounded-corner radius. Explicit values looked "off".

struct AnalyticsConsentModifier: ViewModifier {
    @AppStorage(AppStorageKeys.analyticsConsentShown) private var consentShown: Bool = false
    // Reaches this modifier even though .analyticsConsentIfNeeded() is applied before
    // .environment(\.colorTheme) in SourceBibleApp: the later modifier wraps the chain,
    // so it is an ancestor and the value flows down.
    @Environment(\.colorTheme) private var colorTheme
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true
    @State private var showSheet = false
    @State private var sheetHeight: CGFloat = 300
    @State private var decisionMade = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !consentShown {
                    showSheet = true
                    consentShown = true
                }
            }
            // onDismiss ловить свайп вниз і тап поза шітом. Без явного вибору
            // згоди немає — гасимо аналітику. Див. пункт 2 у шапці файлу.
            .sheet(isPresented: $showSheet, onDismiss: {
                if !decisionMade { analyticsEnabled = false }
            }) {
                AnalyticsConsentCard(isPresented: $showSheet, decisionMade: $decisionMade)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: SheetHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(SheetHeightKey.self) { height in
                        if height > 0 { sheetHeight = height }
                    }
                    .presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
                    .themedSheet(colorTheme)
            }
    }
}

extension View {
    func analyticsConsentIfNeeded() -> some View {
        modifier(AnalyticsConsentModifier())
    }
}
