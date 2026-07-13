// DonationService.swift
// SourceBible
//
// StoreKit 2 donation support — one-time consumable "tips".
// Donations grant no entitlement: on any verified transaction the only
// required action is `finish()`. Products must exist in App Store Connect
// (and in SourceBible.storekit for local/simulator testing) with the IDs
// listed in `productIds`.

import Combine
import Foundation
import StoreKit

@MainActor
final class DonationService: ObservableObject {

    /// Shared instance. Referenced once at app launch (SourceBibleApp `.task`)
    /// so the Transaction.updates listener starts before any purchase UI —
    /// StoreKit re-delivers unfinished transactions from that moment.
    /// Lives for the process lifetime; never deallocated, hence no `deinit`.
    static let shared = DonationService()

    /// Donation product IDs, ascending by amount ($1/5/10/25/50/100).
    /// Single source of truth — App Store Connect and SourceBible.storekit
    /// must match exactly.
    static let productIds: [String] = [
        "com.ivankhoma.SourceBible.donation.1",
        "com.ivankhoma.SourceBible.donation.5",
        "com.ivankhoma.SourceBible.donation.10",
        "com.ivankhoma.SourceBible.donation.25",
        "com.ivankhoma.SourceBible.donation.50",
        "com.ivankhoma.SourceBible.donation.100",
    ]

    enum LoadState: Equatable {
        case loading
        /// The request succeeded but returned no products — the IDs aren't
        /// live in App Store Connect yet. Distinct from `.failed`, which is a
        /// network/StoreKit error and is the only case worth offering a retry.
        case unavailable
        case loaded
        case failed
    }

    enum PurchaseState: Equatable { case idle, purchasing, thanked, failed(String) }

    /// Sorted by price ascending.
    @Published private(set) var products: [Product] = []
    @Published private(set) var loadState: LoadState = .loading
    @Published var purchaseState: PurchaseState = .idle

    @Published private(set) var isRestoring = false
    @Published var restoreCompleted = false

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Finish transactions delivered OUTSIDE the direct purchase flow:
        // interrupted purchases, Ask to Buy approvals, purchases completed
        // on another device. Without finish() StoreKit re-delivers forever —
        // which is why the .unverified branch must finish too. Donations grant
        // no entitlement, so an unverified transaction costs us nothing to
        // finish; we simply don't thank the user for it.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                switch update {
                case .verified(let transaction):
                    await transaction.finish()
                    if transaction.productType == .consumable {
                        self.purchaseState = .thanked
                    }
                case .unverified(let transaction, _):
                    await transaction.finish()
                }
            }
        }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        loadState = .loading
        do {
            let fetched = try await Product.products(for: Self.productIds)
            products = fetched.sorted { $0.price < $1.price }
            loadState = fetched.isEmpty ? .unavailable : .loaded
        } catch {
            loadState = .failed
        }
    }

    /// Processes the result of a SwiftUI `PurchaseAction` call
    /// (`@Environment(\.purchase)` — scene-safe on iOS 18.2+, unlike bare
    /// `Product.purchase()` which can fail to resolve a confirmation scene).
    func handle(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                purchaseState = .thanked
            case .unverified(let transaction, _):
                // Finish it anyway so StoreKit stops re-delivering, but don't
                // present it as a completed donation.
                await transaction.finish()
                purchaseState = .failed(String(localized: "donation.error.unverified"))
            }
        case .pending:
            // Ask to Buy / SCA — the transaction arrives later via
            // Transaction.updates; nothing to do now.
            purchaseState = .idle
        case .userCancelled:
            purchaseState = .idle
        @unknown default:
            purchaseState = .idle
        }
    }

    /// Consumables aren't restorable, but Apple expects a Restore entry
    /// wherever IAP is offered; sync() also unsticks pending transactions.
    func restorePurchases() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            restoreCompleted = true
        } catch {
            // AppStore.sync() throws on user cancellation of the sign-in
            // prompt too — that isn't an error worth alerting about.
            if let skError = error as? StoreKitError, case .userCancelled = skError { return }
            purchaseState = .failed(error.localizedDescription)
        }
    }
}
