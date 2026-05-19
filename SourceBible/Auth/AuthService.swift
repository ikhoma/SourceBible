// AuthService.swift
// SourceBible
//
// v1:   LocalAuthService — NoOp, returns PreAuthIdentity.stableId
// v1.5: Swap in SupabaseAuthService (Apple / Google / Email)

import Foundation

// MARK: - Protocol

protocol AuthServiceProtocol: AnyObject {
    /// Current owner identifier.
    /// v1:   device-stable UUID from PreAuthIdentity
    /// v1.5: Supabase auth.uid()
    var userId: String { get }

    /// False in v1 (no real auth). True after sign-in in v1.5.
    var isAuthenticated: Bool { get }

    func signInWithApple() async throws
    func signInWithGoogle() async throws
    func signInWithEmail(_ email: String, password: String) async throws
    func signOut()
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case notImplemented
    case signInFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:    return "Auth not yet implemented in v1."
        case .signInFailed(let msg): return "Sign-in failed: \(msg)"
        }
    }
}

// MARK: - v1 NoOp implementation

/// v1 — no network calls.
/// Replace with SupabaseAuthService in v1.5.
final class LocalAuthService: AuthServiceProtocol {

    static let shared = LocalAuthService()
    private init() {}

    var userId: String { PreAuthIdentity.stableId }
    var isAuthenticated: Bool { false }

    func signInWithApple() async throws { throw AuthError.notImplemented }
    func signInWithGoogle() async throws { throw AuthError.notImplemented }
    func signInWithEmail(_ email: String, password: String) async throws { throw AuthError.notImplemented }
    func signOut() {}
}
