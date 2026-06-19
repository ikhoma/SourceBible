// NoopAnalytics.swift
// SourceBible
//
// Zero-traffic implementation used in App Store release builds and when the
// user has opted out of analytics. No network calls, no allocations.

import Foundation

// nonisolated on every member: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// the class would otherwise be @MainActor, making `shared` inaccessible from
// the nonisolated EnvironmentKey.defaultValue context.
// NoopAnalytics has zero state, so nonisolated is semantically correct.
final class NoopAnalytics: AnalyticsService, Sendable {
    nonisolated static let shared = NoopAnalytics()
    nonisolated private init() {}

    nonisolated func track(_ event: AnalyticsEvent) {}
    nonisolated func identify(distinctId: String) {}
    nonisolated func flush() {}
}
