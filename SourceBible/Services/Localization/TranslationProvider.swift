// TranslationProvider.swift
// SourceBible
//
// Protocol that decouples MorphologyDecoder from its translation storage.
// MVP implementation reads from .xcstrings via LocalizedBundle (Bundle.main swizzled).
// Future: DBTranslationProvider, RemoteTranslationProvider.
//
// ADR-006: docs/architecture/ADR-006-localization-translation-provider.md

import Foundation

// MARK: - Protocol

protocol TranslationProvider {
    /// Return the localized string for a semantic key.
    /// Falls back to the key itself if no translation exists —
    /// visible as a raw key in the UI during development, never a crash.
    func string(for key: String) -> String
}

extension TranslationProvider {
    /// Convenience: resolve key and interpolate format arguments.
    /// Example: provider.string(for: MorphKey.sectionFormInContext, ref) → "Form in Gen 1:1"
    func string(for key: String, _ args: CVarArg...) -> String {
        String(format: string(for: key), arguments: args)
    }
}

// MARK: - BundleTranslationProvider (MVP)

/// Reads translations from Localizable.xcstrings via Bundle.main.
/// Because Bundle.main is swizzled to LocalizedBundle at app launch,
/// this automatically resolves to the user-selected language.
struct BundleTranslationProvider: TranslationProvider {
    func string(for key: String) -> String {
        // value: key — so missing translations show the key, not empty string
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - MockTranslationProvider (tests only)

#if DEBUG
/// Returns the key as-is. Unit tests assert on semantic keys, not translated text,
/// making tests language-independent.
struct MockTranslationProvider: TranslationProvider {
    func string(for key: String) -> String { key }
}
#endif
