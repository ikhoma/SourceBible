// MigrationService.swift
// SourceBible
//
// One-time data migration: UserDefaults highlights → GRDBUserDataStore.
// Runs on first launch after installing the GRDB update.

import Foundation

final class MigrationService {

    private let store: UserDataStoreProtocol

    init(store: UserDataStoreProtocol) {
        self.store = store
    }

    /// Migrates legacy UserDefaults highlights into GRDB — runs once, idempotent.
    ///
    /// Old model: `Set<String>` of verseIds under key "source_bible.highlighted_verse_ids".
    /// New model: per-translation highlights. Migrated as the user's default translation.
    ///
    /// - Parameter defaultTranslationId: Translation ID to assign migrated highlights (e.g. "KJV").
    func migrateHighlightsIfNeeded(defaultTranslationId: String) {
        let doneKey = AppStorageKeys.migrationHighlightsDone
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let legacyKey = AppStorageKeys.legacyHighlightedVerseIds
        let ids = UserDefaults.standard.stringArray(forKey: legacyKey) ?? []

        for verseId in ids {
            guard !store.isHighlighted(verseId: verseId, translation: defaultTranslationId) else {
                continue
            }
            store.toggleHighlight(verseId: verseId, translation: defaultTranslationId, color: "green")
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
