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
        VStack(alignment: .leading, spacing: 16) {
            Text("analytics.consent.title")
                .font(.title2)
                .fontWeight(.bold)

            Text("analytics.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Privacy link — same size as body text
            if let url = URL(string: "https://sourcebible.app/privacy") {
                Link("analytics.consent.privacy_link", destination: url)
                    .font(.subheadline)
                    .foregroundStyle(.appBlue)
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    analyticsEnabled = false
                    isPresented = false
                } label: {
                    Text("analytics.consent.decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.large)

                Button {
                    analyticsEnabled = true
                    isPresented = false
                } label: {
                    Text("analytics.consent.accept")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appBlue)
                .controlSize(.large)
            }
        }
        .padding(24)
        .padding(.bottom, 8)
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
            }
    }
}

extension View {
    func analyticsConsentIfNeeded() -> some View {
        modifier(AnalyticsConsentModifier())
    }
}
