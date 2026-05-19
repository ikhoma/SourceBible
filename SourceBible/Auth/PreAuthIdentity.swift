// PreAuthIdentity.swift
// SourceBible
//
// Stable Keychain UUID used as owner identifier before real auth exists.
// ⛔ Do NOT use this outside of LocalAuthService. All other code calls authService.userId.

import Foundation
import Security

enum PreAuthIdentity {

    private static let keychainKey = "com.sourcebible.preauth.stableId"

    /// Stable identifier for the current device/install.
    /// Generated once, persisted in Keychain, survives app updates.
    /// Replaced by Supabase auth.uid() in the v1.5 GRDB migration.
    static var stableId: String {
        if let stored = readFromKeychain() { return stored }
        let id = UUID().uuidString
        writeToKeychain(id)
        return id
    }

    /// Called after v1.5 migration completes — removes the pre-auth entry
    /// so the Keychain doesn't permanently hold a now-irrelevant UUID.
    static func markMigrated() {
        deleteFromKeychain()
    }

    // MARK: - Keychain helpers

    private static func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainKey,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func writeToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete any stale entry first, then add fresh
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrAccount:        keychainKey,
            kSecValueData:          data,
            kSecAttrAccessible:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
