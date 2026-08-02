// AppPreferences.swift
// SourceBible
//
// Lightweight typed facade over UserDefaults (ADR-025).
// - AppStorageKeys: single source of truth for every @AppStorage key name.
// - AppPreferences: SCOPED clear operations grouped by lifecycle category.
//
// This does NOT replace @AppStorage (its SwiftUI reactivity is kept) — call sites
// just reference AppStorageKeys.x instead of a raw "x" string, killing typo risk
// and key duplication.
//
// ⛔ Consent + migration keys are defined here but are NEVER wiped by any clear
// operation, by design: wiping consent re-prompts the user (legal risk) and wiping
// a migration flag re-runs a one-time migration (data risk). Blanket resets
// (removePersistentDomain) are intentionally not provided.

import Foundation

// MARK: - Key names (single source of truth)

enum AppStorageKeys {

    // ── Appearance / preference (user-set; reset = restore defaults) ──────────
    /// Legacy Bool key — superseded by `appearanceMode`. Kept for one-time
    /// migration (AppearanceMode.migrateFromLegacyDarkMode) and downgrade safety.
    static let isDarkMode           = "isDarkMode"
    /// AppearanceMode rawValue: "light" | "dark" | "matchDevice".
    static let appearanceMode       = "appearanceMode"
    /// ColorTheme rawValue: "paper" | "incunable".
    static let colorTheme           = "colorTheme"
    /// TitleFontStyle rawValue: "modern" | "antique".
    static let titleFontStyle       = "titleFontStyle"
    static let hideBookCovers       = "hideBookCovers"
    static let redLetters           = "redLetters"
    static let defaultTranslationId = "defaultTranslationId"
    static let appLanguage          = "appLanguage"
    /// Book picker books-step layout: "list" (default) or "tiles".
    static let bookPickerBooksViewMode = "bookPickerBooksViewMode"

    // ── Launch preference ─────────────────────────────────────────────────────
    /// Which PASSAGE opens on launch. LaunchBehavior rawValue.
    static let launchBehavior       = "launchBehavior"
    /// Which TRANSLATION opens on launch. TranslationLaunchBehavior rawValue:
    /// "fixed" (use `defaultTranslationId`) | "lastUsed" (use `lastUsedTranslationId`).
    static let translationLaunchBehavior = "translationLaunchBehavior"

    // ── Reading / navigation state (ephemeral; safe to clear) ─────────────────
    static let lastReadBookId        = "lastReadBookId"
    static let lastReadChapter       = "lastReadChapter"
    static let lastReadVerseAnchorId = "lastReadVerseAnchorId"
    /// Last translation the user switched to. Ephemeral state, NOT a preference —
    /// the preference is `defaultTranslationId`. Cleared with reading history:
    /// launch then falls back to the Settings pick, never to a stale translation.
    static let lastUsedTranslationId = "lastUsedTranslationId"

    // ── Device-derived cache (НЕ користувацькі дані) ──────────────────────────
    /// Заміряна поправка лейауту sheet'а (`SheetDetentCalibration`) і версія ОС,
    /// під якою її знято. Це не преференція і не історія — це кеш вимірювання
    /// геометрії пристрою, тому НЕ входить у жоден clear: чистити його означало б
    /// повертати хибний перший кадр після кожного очищення.
    static let sheetDetentTopOffset        = "sheetDetentTopOffset"
    static let sheetDetentTopOffsetOSBuild = "sheetDetentTopOffsetOSBuild"

    // ── Search history (ephemeral; safe to clear) ─────────────────────────────
    static let searchRecentQueries  = "searchRecentQueries"

    // ── Consent (sensitive — NEVER wiped) ─────────────────────────────────────
    static let analyticsEnabled      = "analyticsEnabled"
    static let analyticsConsentShown = "analyticsConsentShown"

    // ── Migration bookkeeping (NEVER wiped) ───────────────────────────────────
    static let migrationHighlightsDone   = "sourcebible.migration.v1.highlights.done"
    static let legacyHighlightedVerseIds = "source_bible.highlighted_verse_ids"
}

// MARK: - Scoped preference operations

enum AppPreferences {

    /// Ephemeral navigation + search history. Safe to clear ("Clear reading history").
    /// Excludes consent & migration flags by design.
    static func clearReadingHistory(_ defaults: UserDefaults = .standard) {
        [AppStorageKeys.lastReadBookId,
         AppStorageKeys.lastReadChapter,
         AppStorageKeys.lastReadVerseAnchorId,
         AppStorageKeys.lastUsedTranslationId,
         AppStorageKeys.searchRecentQueries]
            .forEach { defaults.removeObject(forKey: $0) }
    }

    /// Restore appearance / preference keys to their compiled-in defaults.
    /// Leaves launchBehavior, consent and migration flags untouched.
    static func resetAppearanceToDefaults(_ defaults: UserDefaults = .standard) {
        [AppStorageKeys.isDarkMode,
         AppStorageKeys.appearanceMode,
         AppStorageKeys.colorTheme,
         AppStorageKeys.titleFontStyle,
         AppStorageKeys.hideBookCovers,
         AppStorageKeys.redLetters,
         AppStorageKeys.defaultTranslationId,
         AppStorageKeys.appLanguage,
         AppStorageKeys.bookPickerBooksViewMode]
            .forEach { defaults.removeObject(forKey: $0) }
    }
}
