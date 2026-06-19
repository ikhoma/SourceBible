// SourceBibleApp.swift
// SourceBible

import SwiftUI
import Mixpanel

@main
struct SourceBibleApp: App {

    // MARK: - Services (singletons, swappable in v1.5 / v2)

    let authService: AuthServiceProtocol  = LocalAuthService.shared
    let syncEngine:  SyncEngineProtocol   = NoOpSyncEngine.shared
    let store:       UserDataStoreProtocol

    // MARK: - Analytics
    //
    // analyticsEnabled is the live source of truth (AppStorage → UserDefaults).
    // Read once at init; runtime changes handled via .onChange in body.
    // Consent ON (any build) → MixpanelAnalytics; OFF → NoopAnalytics (zero network).
    // No #if BETA gating — Mixpanel runs in beta AND prod (PDR-Analytics-Mixpanel D3).
    @AppStorage("analyticsEnabled") private var analyticsEnabled: Bool = true
    let analytics: any AnalyticsService

    // MARK: - Session Tracker
    let sessionTracker: SessionTracker

    // MARK: - Language

    /// Persisted language code ("en" | "uk"). Drives locale environment on change.
    @AppStorage("appLanguage") private var appLanguage: String = Self.defaultLanguage
    @AppStorage("isDarkMode") private var isDarkMode: Bool = false

    /// On first launch: follow system locale if supported, else "en".
    private static var defaultLanguage: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return AppLanguage.supported.contains(code) ? code : "en"
    }

    // MARK: - Scene phase (for app_opened + session lifecycle)
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        // ── Analytics init ────────────────────────────────────────────────────
        // Read the persisted toggle value directly from UserDefaults at init
        // time (AppStorage isn't readable before the body runs).
        let enabled = UserDefaults.standard.object(forKey: "analyticsEnabled") as? Bool ?? true

        // Consent ON → MixpanelAnalytics (beta and prod); OFF → NoopAnalytics (zero network).
        if enabled {
            analytics = MixpanelAnalytics.shared
            // Identify with stable anonymous ID (ADR-012 PreAuthIdentity).
            MixpanelAnalytics.shared.identify(distinctId: PreAuthIdentity.stableId)
        } else {
            analytics = NoopAnalytics.shared
        }

        // ── Session tracker init ──────────────────────────────────────────────
        // Inject the same analytics instance so the tracker uses the correct
        // service (Mixpanel or Noop) at the time of creation.
        sessionTracker = SessionTracker(analytics: analytics)

        // ── Localization init ─────────────────────────────────────────────────
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
                // Analytics: inject service + show one-time consent card.
                // onChange handles runtime toggle (no restart needed).
                .environment(\.analytics, analytics)
                .environment(\.sessionTracker, sessionTracker)
                .analyticsConsentIfNeeded()
                // ── Consent runtime toggle ────────────────────────────────────
                .onChange(of: analyticsEnabled) { _, enabled in
                    if enabled {
                        MixpanelAnalytics.shared.identify(distinctId: PreAuthIdentity.stableId)
                    } else {
                        // opt out so SDK stops any in-flight batches
                        Mixpanel.mainInstance().optOutTracking()
                    }
                }
                // ── app_opened + session start on cold launch ─────────────────
                // `.onChange(of: scenePhase)` does NOT fire for the INITIAL `.active`
                // state on a cold launch, so the first foreground must be triggered
                // here. `.task` runs once when the root view first appears.
                .task {
                    analytics.track(.appOpened)
                    sessionTracker.handleForeground()
                }
                // ── Session lifecycle via scenePhase ──────────────────────────
                // Fire `app_opened` only on a REAL return from background
                // (.background → .active). `.inactive → .active` (Control Center,
                // notification shade, permission dialogs, app-switcher peek) must NOT
                // count as an open. Cold launch is handled by `.task` above.
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if oldPhase == .background && newPhase == .active {
                        analytics.track(.appOpened)
                        sessionTracker.handleForeground()
                    } else if newPhase == .background {
                        sessionTracker.handleBackground()
                    }
                }
                // Localization
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .environment(\.locale, Locale(identifier: appLanguage))
                .onChange(of: appLanguage) { _, lang in
                    LocalizedBundle.activate(language: lang)
                }
        }
    }
}

// MARK: - Supported languages

enum AppLanguage {
    static let supported: Set<String> = ["en", "uk"]
}
