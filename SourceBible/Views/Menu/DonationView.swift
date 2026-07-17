// DonationView.swift
// SourceBible
//
// One-time donation screen (Menu → Support). Amount grid → App Store
// payment sheet via SwiftUI PurchaseAction. Products: DonationService.

import SwiftUI
import StoreKit

struct DonationView: View {
    @ObservedObject private var service = DonationService.shared
    @Environment(\.purchase) private var purchase
    @Environment(\.colorTheme) private var colorTheme

    @State private var selectedProductId: String?
    @State private var showThanks = false

    /// Apple's standard EULA covers this free app with optional donations (no custom Terms needed).
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Same policy the analytics consent card links to — keep the two in sync.
    private let privacyURL = URL(string: "https://source-bible.vercel.app/privacy")!

    private var selectedProduct: Product? {
        service.products.first { $0.id == selectedProductId }
    }

    var body: some View {
        ZStack {
            colorTheme.appBackground.ignoresSafeArea()
            switch service.loadState {
            case .loading:
                ProgressView()
            case .failed:
                unavailableView(
                    symbol: "wifi.exclamationmark",
                    message: "donation.error.load",
                    showsRetry: true
                )
            case .unavailable:
                unavailableView(
                    symbol: "heart.slash",
                    message: "donation.error.unavailable",
                    showsRetry: false
                )
            case .loaded:
                content
            }
        }
        .navigationTitle("donation.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.loadProducts()
            // A transaction can land via Transaction.updates while this view
            // isn't on screen (Ask to Buy approval, purchase on another
            // device). In that case purchaseState is ALREADY .thanked on
            // appear and onChange never fires — so check it here too.
            if service.purchaseState == .thanked { showThanks = true }
        }
        .onChange(of: service.purchaseState) { _, state in
            if state == .thanked { showThanks = true }
        }
        .alert("donation.thanks.title", isPresented: $showThanks) {
            Button("donation.thanks.done") { service.purchaseState = .idle }
        } message: {
            Text("donation.thanks.message")
        }
        .alert("donation.restore.done.title", isPresented: $service.restoreCompleted) {
            Button("donation.thanks.done", role: .cancel) { }
        } message: {
            Text("donation.restore.done.message")
        }
        .alert(
            "donation.error.title",
            isPresented: Binding(
                get: { if case .failed = service.purchaseState { return true } else { return false } },
                set: { if !$0 { service.purchaseState = .idle } }
            )
        ) {
            Button("donation.thanks.done", role: .cancel) { service.purchaseState = .idle }
        } message: {
            if case .failed(let message) = service.purchaseState {
                Text(message)
            }
        }
    }

    // MARK: - Loaded content

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("donation.choose_amount")
                        .font(.footnote)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(service.products, id: \.id) { product in
                            AmountButton(
                                product: product,
                                isSelected: product.id == selectedProductId
                            ) {
                                selectedProductId = product.id
                            }
                        }
                    }

                    Text("donation.description")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button {
                guard let product = selectedProduct else { return }
                service.purchaseState = .purchasing
                Task {
                    // This closure is already @MainActor-isolated, so the Task
                    // inherits MainActor — no MainActor.run hop needed.
                    do {
                        let result = try await purchase(product)
                        await service.handle(result)
                    } catch {
                        service.purchaseState = .failed(error.localizedDescription)
                    }
                }
            } label: {
                if service.purchaseState == .purchasing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("donation.cta").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.appBlue)
            .disabled(selectedProduct == nil || service.purchaseState == .purchasing)

            HStack(spacing: 6) {
                Button {
                    Task { await service.restorePurchases() }
                } label: {
                    if service.isRestoring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("donation.restore")
                    }
                }
                .disabled(service.isRestoring)
                dot
                Link("donation.terms", destination: termsURL)
                dot
                Link("donation.privacy", destination: privacyURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var dot: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 3, height: 3)
            .accessibilityHidden(true)
    }

    // MARK: - Failure states

    private func unavailableView(
        symbol: String,
        message: LocalizedStringKey,
        showsRetry: Bool
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsRetry {
                Button("donation.retry") {
                    Task { await service.loadProducts() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - AmountButton

/// Selectable donation amount. Uses the system button styles rather than a
/// hand-rolled card so it picks up Liquid Glass, Dynamic Type, the correct
/// corner radius and the platform's selected/pressed treatment for free.
private struct AmountButton: View {
    let product: Product
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.large)
        .tint(.appBlue)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(Text(product.displayName))
        .accessibilityValue(Text(product.displayPrice))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var button: some View {
        Button(action: action) {
            Text(product.displayPrice)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { DonationView() }
}
#endif
