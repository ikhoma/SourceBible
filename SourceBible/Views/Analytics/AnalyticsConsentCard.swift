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

// MARK: - Consent Card

struct AnalyticsConsentCard: View {
    @Binding var isPresented: Bool
    @AppStorage("analyticsEnabled") private var analyticsEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .foregroundStyle(.appBlue)
                Text("analytics.consent.title")
                    .font(.headline)
            }

            Text("analytics.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Privacy link
            if let url = URL(string: "https://sourcebible.app/privacy") {
                Link("analytics.consent.privacy_link", destination: url)
                    .font(.caption)
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

                Button {
                    analyticsEnabled = true
                    isPresented = false
                } label: {
                    Text("analytics.consent.accept")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appBlue)
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

struct AnalyticsConsentModifier: ViewModifier {
    @AppStorage("analyticsConsentShown") private var consentShown: Bool = false
    @State private var showSheet = false

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
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
    }
}

extension View {
    func analyticsConsentIfNeeded() -> some View {
        modifier(AnalyticsConsentModifier())
    }
}
