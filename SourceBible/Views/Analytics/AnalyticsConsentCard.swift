// AnalyticsConsentCard.swift
// SourceBible
//
// One-time bottom sheet shown on first launch asking the user to share
// anonymous usage data. Pattern: "допоможи покращити" (like Meta AI / Transit).
//
// Persistence:
//   - "analyticsConsentShown"  (Bool) — true after shown once, never show again
//   - "analyticsEnabled"       (Bool) — user's live choice; default ON
//
// On "Не зараз" → analyticsEnabled = false (SDK stays silent).
// On "Добре"    → analyticsEnabled stays true.
// Either way    → analyticsConsentShown = true.

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
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            Text("analytics.consent.title")
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("analytics.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Privacy link — same size as body text
            if let url = URL(string: "https://source-bible.vercel.app/privacy") {
                Link("analytics.consent.privacy_link", destination: url)
                    .font(.subheadline)
                    .foregroundStyle(.appBlue)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            // Actions — full-width, stacked, native Liquid Glass surfaces.
            // Styles branch by OS the same way AboutView does:
            // iOS 26 Liquid Glass (.glassProminent / .glass) with the
            // pre-26 system fallback (.borderedProminent / .bordered).
            VStack(spacing: 12) {
                if #available(iOS 26, *) {
                    acceptButton.buttonStyle(.glassProminent)
                    declineButton.buttonStyle(.glass)
                } else {
                    acceptButton.buttonStyle(.borderedProminent)
                    declineButton.buttonStyle(.bordered)
                }
            }
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
            isPresented = false
        } label: {
            Text("analytics.consent.accept")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.appBlue)
    }

    // Decline action WITHOUT its buttonStyle, so the surface can branch by OS.
    private var declineButton: some View {
        Button {
            analyticsEnabled = false
            isPresented = false
        } label: {
            Text("analytics.consent.decline")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.secondary)
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
    @State private var showSheet = false
    @State private var sheetHeight: CGFloat = 300

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !consentShown {
                    showSheet = true
                    consentShown = true
                }
            }
            .sheet(isPresented: $showSheet) {
                AnalyticsConsentCard(isPresented: $showSheet)
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
