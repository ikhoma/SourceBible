// LocalizedBundle.swift
// SourceBible
//
// Enables instant in-app language switching without an app restart.
//
// Strategy: swizzle Bundle.main's runtime class to LocalizedBundle via
// object_setClass(). After this, Text("key"), String(localized: "key"),
// and NSLocalizedString all automatically resolve through the active language
// without any explicit `bundle:` parameter at call sites.
//
// ADR-006: docs/architecture/ADR-006-localization-translation-provider.md
//
// iOS 26 / Swift 6 note:
// Bundle gained @MainActor annotation in the iOS 26 SDK, so LocalizedBundle
// inherits @MainActor isolation.  Every method that must remain callable from
// any thread (init, localizedString, activate, warmCache) is explicitly marked
// nonisolated.  Module-level state uses nonisolated(unsafe) to prevent the
// compiler from inferring @MainActor on the globals through the static methods.

import Foundation

// MARK: - Module-level state
//
// Lives outside the class so actor-isolation inference from LocalizedBundle's
// @MainActor-inherited class body does not reach these globals.
//
// iOS 26 / Swift 6: Bundle is @MainActor, so LocalizedBundle inherits @MainActor,
// and that isolation propagates to ALL file-scope globals in this file — including
// `let` constants of `Sendable` types like NSLock.
//
// The annotation severs that @MainActor inference chain so the nonisolated overrides
// (localizedString, activate, warmCache, install) can reach these globals. Thread
// safety is provided by _lbLock itself; @unchecked Sendable on the class documents
// this intentional trade-off.
//
// The lock is `nonisolated`, the two vars are `nonisolated(unsafe)` — the asymmetry
// is deliberate, not an oversight. On the lock the compiler emits "'nonisolated(unsafe)'
// is unnecessary for a constant with 'Sendable' type 'NSLock', consider removing it".
// That warning is HALF right, and an earlier revision of this comment got it wrong in
// the other direction by calling it simply incorrect:
//   • `(unsafe)` really is needless here — NSLock is Sendable and this is a `let`,
//     so the unchecked variant buys nothing.
//   • but taking the fix-it literally and deleting the whole annotation re-isolates
//     the global to @MainActor and breaks the four `_lbLock.withLock` call sites.
// Correct resolution: keep `nonisolated`, drop `(unsafe)`. Measured 2026-08-26 on the
// twin case in SessionTracker.noop — bare = build error, `nonisolated` = clean build.
// The two vars keep `(unsafe)`: they are mutable, so the warning does not apply to them
// and the unchecked opt-out is what actually carries them.
private nonisolated let _lbLock = NSLock()
// swiftlint:disable:next nonisolated_unsafe
private nonisolated(unsafe) var _lbLanguage: String          = "en"
// swiftlint:disable:next nonisolated_unsafe
private nonisolated(unsafe) var _lbCache:   [String: Bundle] = [:]

// MARK: - LocalizedBundle

/// Bundle subclass that overrides localizedString(forKey:value:table:) to load
/// strings from the user-selected language's .lproj at runtime.
///
/// Activated by calling `LocalizedBundle.activate(language:)` once in
/// SourceBibleApp.init(), and again whenever the user changes language in Settings.
final class LocalizedBundle: Bundle, @unchecked Sendable {

    // MARK: Init

    // Bundle.init(path:) is nonisolated in Bundle's declaration, but
    // LocalizedBundle inherits @MainActor from Bundle (iOS 26 SDK).
    // Explicit nonisolated override restores the correct isolation.
    nonisolated override init?(path: String) {
        super.init(path: path)
    }

    // MARK: Override

    // Matches Bundle's nonisolated declaration and allows the system to call
    // this from any thread during string resolution.
    nonisolated override func localizedString(forKey key: String,
                                              value: String?,
                                              table tableName: String?) -> String {
        let bundle = _lbLock.withLock { _lbCache[_lbLanguage] }
        return bundle?.localizedString(forKey: key, value: value, table: tableName)
            ?? super.localizedString(forKey: key, value: value, table: tableName)
    }

    // MARK: Language control

    /// Switch the active language. nonisolated so it can be called from the
    /// main actor without making the module-level globals @MainActor.
    nonisolated static func activate(language: String) {
        _lbLock.withLock { _lbLanguage = language }
        warmCache(for: language)
    }

    nonisolated private static func warmCache(for language: String) {
        // Check existence under lock first (fast path avoids unnecessary I/O).
        let exists = _lbLock.withLock { _lbCache[language] != nil }
        guard !exists else { return }
        // Bundle(path:) does file I/O — perform outside the lock.
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            _lbLock.withLock { _lbCache[language] = bundle }
        }
    }
}

// MARK: - Activation helper

extension LocalizedBundle {
    /// Call once in SourceBibleApp.init() before any view renders.
    /// Swizzles Bundle.main so all standard localization APIs use this subclass.
    nonisolated static func install(language: String) {
        object_setClass(Bundle.main, LocalizedBundle.self)
        activate(language: language)
    }
}
