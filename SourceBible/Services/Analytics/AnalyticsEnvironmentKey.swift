// AnalyticsEnvironmentKey.swift
// SourceBible
//
// SwiftUI Environment injection for AnalyticsService and SessionTracker.
// Views/VMs access analytics via: @Environment(\.analytics) private var analytics
// Views/VMs access the tracker via: @Environment(\.sessionTracker) private var tracker

import SwiftUI

// MARK: - Analytics Environment Key

private struct AnalyticsEnvironmentKey: EnvironmentKey {
    // nonisolated required: EnvironmentKey.defaultValue is nonisolated by protocol
    // contract. With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the compiler would
    // otherwise infer @MainActor here and emit a conformance conflict error.
    nonisolated static let defaultValue: any AnalyticsService = NoopAnalytics.shared
}

extension EnvironmentValues {
    var analytics: any AnalyticsService {
        get { self[AnalyticsEnvironmentKey.self] }
        set { self[AnalyticsEnvironmentKey.self] = newValue }
    }
}

// MARK: - SessionTracker Environment Key
//
// Default is the shared no-op tracker (`SessionTracker.noop`) — a nonisolated(unsafe)
// static only accessed from @MainActor call sites. Using the shared instance avoids
// allocating a separate fallback tracker here.
private struct SessionTrackerEnvironmentKey: EnvironmentKey {
    nonisolated static let defaultValue: SessionTracker = .noop
}

extension EnvironmentValues {
    var sessionTracker: SessionTracker {
        get { self[SessionTrackerEnvironmentKey.self] }
        set { self[SessionTrackerEnvironmentKey.self] = newValue }
    }
}
