// SourceBibleApp.swift
// SourceBible

import SwiftUI

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
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true
    let analytics: any AnalyticsService

    // MARK: - Session Tracker
    let sessionTracker: SessionTracker

    // MARK: - Language

    /// Persisted language code ("en" | "uk"). Drives locale environment on change.
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = Self.defaultLanguage

    // MARK: - Appearance
    //
    // appearanceMode replaces the legacy isDarkMode Bool (migrated in init).
    // colorTheme + titleFontStyle are injected into the environment so views
    // re-render immediately when the user switches them in Menu.
    @AppStorage(AppStorageKeys.appearanceMode) private var appearanceModeRaw = AppearanceMode.light.rawValue
    @AppStorage(AppStorageKeys.colorTheme) private var colorThemeRaw = ColorTheme.paper.rawValue
    @AppStorage(AppStorageKeys.titleFontStyle) private var titleFontStyleRaw = TitleFontStyle.modern.rawValue

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .light }

    /// On first launch: follow system locale if supported, else "en".
    private static var defaultLanguage: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return AppLanguage.supported.contains(code) ? code : "en"
    }

    // MARK: - Scene phase (for app_opened + session lifecycle)
    @Environment(\.scenePhase) private var scenePhase

    /// True while the app is in the background. Gates `app_opened` on return so
    /// `.inactive → .active` blips (Control Center, notification shade, permission
    /// dialogs) don't count as an open. See the scenePhase onChange below.
    @State private var wasBackgrounded = false

    // MARK: - Init

    init() {
        // ── Analytics init ────────────────────────────────────────────────────
        // Consent default (PDR D4): TestFlight/dev → ON (opt-out); App Store → OFF (opt-in).
        // Registered as a UserDefaults default so AppStorage + the read below pick it up
        // before the user has touched the toggle.
        let defaultConsent = MixpanelAnalytics.isTestFlight
        UserDefaults.standard.register(defaults: [AppStorageKeys.analyticsEnabled: defaultConsent])
        let enabled = UserDefaults.standard.object(forKey: AppStorageKeys.analyticsEnabled) as? Bool ?? defaultConsent

        // Mixpanel is always the injected service but stays inert until enable() (consent).
        // No SDK is loaded and nothing is sent while consent is OFF (prod opt-in).
        analytics = MixpanelAnalytics.shared
        if enabled {
            MixpanelAnalytics.shared.enable()
            // Identify with stable anonymous ID (ADR-012 PreAuthIdentity).
            MixpanelAnalytics.shared.identify(distinctId: PreAuthIdentity.stableId)
        }

        // ── Session tracker init ──────────────────────────────────────────────
        sessionTracker = SessionTracker(analytics: analytics)

        // ── Localization init ─────────────────────────────────────────────────
        // Install LocalizedBundle swizzle BEFORE any view renders.
        // After this, Text("key") and String(localized: "key") both
        // resolve through the active language automatically.
        // See ADR-006: docs/architecture/ADR-006-localization-translation-provider.md
        let lang = UserDefaults.standard.string(forKey: AppStorageKeys.appLanguage) ?? Self.defaultLanguage
        LocalizedBundle.install(language: lang)

        // ── Appearance init ───────────────────────────────────────────────────
        // Register the bundled Cormorant face (Antique title style) with Core
        // Text — process scope, no Info.plist UIAppFonts entry required.
        TitleFontStyle.registerBundledFonts()
        // One-time migration: legacy isDarkMode Bool → appearanceMode enum.
        AppearanceMode.migrateFromLegacyDarkMode()

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
                        MixpanelAnalytics.shared.enable()
                        MixpanelAnalytics.shared.identify(distinctId: PreAuthIdentity.stableId)
                    } else {
                        MixpanelAnalytics.shared.disable()
                    }
                }
                // ── app_opened + session start on cold launch ─────────────────
                // `.onChange(of: scenePhase)` does NOT fire for the INITIAL `.active`
                // state on a cold launch, so the first foreground must be triggered
                // here. `.task` runs once when the root view first appears.
                .task {
                    analytics.track(.appOpened)
                    sessionTracker.handleForeground()
                    // Start the StoreKit Transaction.updates listener at launch —
                    // StoreKit re-delivers unfinished donation transactions from
                    // the moment the listener starts (DonationService.init).
                    _ = DonationService.shared
                    // Keyboard pre-warm: boots the system keyboard process so the
                    // first Note editor open doesn't pay the spin-up lag. Delayed
                    // off the first-frame render path; runs once per process.
                    try? await Task.sleep(for: .milliseconds(500))
                    KeyboardPrewarm.run()
                }
                // ── Session lifecycle via scenePhase ──────────────────────────
                // iOS NEVER transitions .background → .active directly — resume always
                // passes through .inactive (.background → .inactive → .active), so
                // matching on `oldPhase == .background` never fires. That bug meant
                // handleForeground() only ever ran at cold launch: the pending session
                // flush was never cancelled, the session died 30s after the first
                // backgrounding, and every counter afterwards was silently dropped
                // (study_session_summary undercount found in beta Mixpanel data).
                //
                // Fix: react to every `.active`, gate `app_opened` on wasBackgrounded
                // so `.inactive → .active` blips (Control Center, notification shade,
                // permission dialogs, app-switcher peek) do NOT count as an open.
                // handleForeground() is idempotent: it cancels the pending flush, and
                // begin() no-ops while a session is active (grace logic lives inside
                // SessionTracker). Cold launch is handled by `.task` above.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        if wasBackgrounded {
                            analytics.track(.appOpened)
                            wasBackgrounded = false
                        }
                        sessionTracker.handleForeground()
                    } else if newPhase == .background {
                        wasBackgrounded = true
                        sessionTracker.handleBackground()
                    }
                }
                // Appearance: nil = Match Device (follow system)
                .preferredColorScheme(appearanceMode.colorScheme)
                .environment(\.colorTheme, ColorTheme(rawValue: colorThemeRaw) ?? .paper)
                .environment(\.titleFontStyle, TitleFontStyle(rawValue: titleFontStyleRaw) ?? .modern)
                // Localization
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
