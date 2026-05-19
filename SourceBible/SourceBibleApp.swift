// SourceBibleApp.swift
// SourceBible

import SwiftUI

@main
struct SourceBibleApp: App {

    // MARK: - Services (singletons, swappable in v1.5 / v2)

    let authService: AuthServiceProtocol  = LocalAuthService.shared
    let syncEngine:  SyncEngineProtocol   = NoOpSyncEngine.shared
    let store:       UserDataStoreProtocol

    // MARK: - Language

    /// Persisted language code ("en" | "uk"). Drives locale environment on change.
    @AppStorage("appLanguage") private var appLanguage: String = Self.defaultLanguage

    /// On first launch: follow system locale if supported, else "en".
    private static var defaultLanguage: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return AppLanguage.supported.contains(code) ? code : "en"
    }

    // MARK: - Init

    init() {
        // Install LocalizedBundle swizzle BEFORE any view renders.
        // After this, Text("key") and String(localized: "key") both
        // resolve through the active language automatically.
        // See ADR-006: docs/architecture/ADR-006-localization-translation-provider.md
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? Self.defaultLanguage
        LocalizedBundle.install(language: lang)

        // Build the GRDB store — crashes on failure are intentional at init time
        // (a corrupted DB is unrecoverable; better to surface it immediately).
        let grdbStore: GRDBUserDataStore
        do {
            grdbStore = try GRDBUserDataStore(authService: authService)
        } catch {
            fatalError("GRDBUserDataStore init failed: \(error)")
        }
        store = grdbStore

        // One-time migration: UserDefaults highlights → GRDB
        MigrationService(store: store)
            .migrateHighlightsIfNeeded(defaultTranslationId: Translation.defaultTranslation.id)

        // SyncEngine starts in background (NoOp in v1 — no-op call)
        syncEngine.start()
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // Injects the selected locale into the SwiftUI environment.
                // Text("key") — LocalizedStringKey — re-evaluates automatically.
                // String(localized: "key") calls in view bodies also return the
                // correct language because LocalizedBundle is pre-activated in
                // LanguageSettingsView before appLanguage is written.
                // No .id() here — avoids resetting navigation state on language change.
                // See ADR-006: docs/architecture/ADR-006-localization-translation-provider.md
                .environment(\.locale, Locale(identifier: appLanguage))
                .onChange(of: appLanguage) { _, lang in
                    // Keep bundle swizzle in sync for String(localized:) in model code
                    // and UIKit views (e.g. NoteEditorView placeholder).
                    LocalizedBundle.activate(language: lang)
                }
        }
    }
}

// MARK: - Supported languages

enum AppLanguage {
    static let supported: Set<String> = ["en", "uk"]
}
