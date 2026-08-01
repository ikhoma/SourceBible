// ReadingPositionStore.swift
// SourceBible
//
// Persists the reader's last position so the app reopens where the user left off
// instead of always Genesis 1:1 (spec-reader-resume-position.md).
//
// Storage: UserDefaults via AppStorageKeys (ADR-025) — NOT GRDB. One small,
// frequently-overwritten record; losing it is non-fatal (falls back to Genesis).
// The protocol isolates this choice so a future cross-device sync can swap the
// implementation to GRDB without touching call sites.

import Foundation

// MARK: - Model

/// What the app opens to on launch.
enum LaunchBehavior: String, CaseIterable {
    case resume        // continue where the user left off
    case lastBookmark  // open the most-recently-created bookmark
}

/// WHICH TRANSLATION the reader opens with on launch — the sibling of
/// `LaunchBehavior`, which answers "which passage".
///
/// `.fixed` is the default because it is the pre-existing behaviour: before this
/// setting existed the reader unconditionally applied `defaultTranslationId`.
/// Defaulting to `.lastUsed` would silently change what upgrading users see.
enum TranslationLaunchBehavior: String, CaseIterable {
    case fixed     // always open the translation picked in Settings
    case lastUsed  // reopen whichever translation was active last
}

/// A persisted reading position. `verseAnchorId` is the top-visible verse
/// (reading mode) or the focused verse (Study Mode) — compound ID "BOOK|ch|v".
struct ReadingPosition: Equatable {
    let bookId: String
    let chapter: Int
    let verseAnchorId: String?
}

// MARK: - Store

protocol ReadingPositionStore: AnyObject {
    var launchBehavior: LaunchBehavior { get set }
    var translationLaunchBehavior: TranslationLaunchBehavior { get set }
    /// Returns nil when no position has ever been saved (first launch / clean install).
    func load() -> ReadingPosition?
    func save(_ position: ReadingPosition)
    /// The translation id the reader should open with, resolved from
    /// `translationLaunchBehavior`. nil = nothing to restore (caller keeps
    /// `Translation.defaultTranslation`).
    func launchTranslationId() -> String?
    /// Records the translation the user switched to, for `.lastUsed`.
    func saveLastUsedTranslation(_ id: String)
}

/// UserDefaults-backed implementation. Uses an empty `lastReadBookId` as the
/// "no state yet" sentinel so a fresh install is distinguishable from someone
/// who genuinely read Genesis.
final class UserDefaultsReadingPositionStore: ReadingPositionStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var launchBehavior: LaunchBehavior {
        get {
            LaunchBehavior(rawValue: defaults.string(forKey: AppStorageKeys.launchBehavior) ?? "")
                ?? .resume
        }
        set { defaults.set(newValue.rawValue, forKey: AppStorageKeys.launchBehavior) }
    }

    var translationLaunchBehavior: TranslationLaunchBehavior {
        get {
            TranslationLaunchBehavior(
                rawValue: defaults.string(forKey: AppStorageKeys.translationLaunchBehavior) ?? ""
            ) ?? .fixed
        }
        set { defaults.set(newValue.rawValue, forKey: AppStorageKeys.translationLaunchBehavior) }
    }

    func launchTranslationId() -> String? {
        switch translationLaunchBehavior {
        case .fixed:
            return fixedTranslationId()
        case .lastUsed:
            let id = defaults.string(forKey: AppStorageKeys.lastUsedTranslationId) ?? ""
            // Nothing used yet (mode flipped before the first switch, or history
            // cleared): fall back to the Settings pick rather than to the
            // compiled-in default, so the user's explicit choice still wins.
            return id.isEmpty ? fixedTranslationId() : id
        }
    }

    func saveLastUsedTranslation(_ id: String) {
        defaults.set(id, forKey: AppStorageKeys.lastUsedTranslationId)
    }

    /// The translation explicitly picked in Settings. Empty = never set.
    private func fixedTranslationId() -> String? {
        let id = defaults.string(forKey: AppStorageKeys.defaultTranslationId) ?? ""
        return id.isEmpty ? nil : id
    }

    func load() -> ReadingPosition? {
        let bookId = defaults.string(forKey: AppStorageKeys.lastReadBookId) ?? ""
        guard !bookId.isEmpty else { return nil }   // sentinel: nothing saved yet

        let chapter = max(1, defaults.integer(forKey: AppStorageKeys.lastReadChapter))
        let anchor  = defaults.string(forKey: AppStorageKeys.lastReadVerseAnchorId) ?? ""
        return ReadingPosition(bookId: bookId,
                               chapter: chapter,
                               verseAnchorId: anchor.isEmpty ? nil : anchor)
    }

    func save(_ position: ReadingPosition) {
        defaults.set(position.bookId, forKey: AppStorageKeys.lastReadBookId)
        defaults.set(position.chapter, forKey: AppStorageKeys.lastReadChapter)
        defaults.set(position.verseAnchorId ?? "", forKey: AppStorageKeys.lastReadVerseAnchorId)
    }
}
