// SessionTracker.swift
// SourceBible
//
// Tracks the current study session and emits `study_session_summary` on background.
//
// Design (Slice 2 Work Order):
//   - All public API is @MainActor — counters and session state are only ever
//     read/written from the main thread.
//   - Mutable stored properties are nonisolated(unsafe) so the init can run from
//     a nonisolated context (required for EnvironmentKey.defaultValue under
//     SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor). The unsafe annotation is safe
//     here because every actual access of these properties is behind @MainActor.
//   - Injected `any AnalyticsService` — stays behind the abstraction layer.
//   - Grace period (~30s): quick foreground/background round-trips do NOT start
//     a new session or emit a duplicate summary.
//   - verses_read is tracked as a Set<String> of unique verseIds so repeated
//     views of the same verse don't inflate the count.
//
// Lifecycle (driven by SourceBibleApp scenePhase observer):
//   .active   → handleForeground()  →  cancel pending flush, begin() if not in grace
//   .background → handleBackground() →  schedule flush after ~30s grace

import Foundation
import Combine
import UIKit

// @unchecked Sendable: all mutable state is nonisolated(unsafe) and only ever
// touched on the main actor; the type is effectively main-confined. Needed so the
// background-task expiration handler can capture it (matches MixpanelAnalytics).
final class SessionTracker: ObservableObject, @unchecked Sendable {

    // MARK: - Dependencies

    // swiftlint:disable nonisolated_unsafe
    private nonisolated(unsafe) var _analytics: any AnalyticsService

    // MARK: - Session state
    // nonisolated(unsafe): all accesses occur from @MainActor methods (see public API below).
    // The unsafe annotation is required only to allow the nonisolated init to set defaults.

    private nonisolated(unsafe) var _startedAt: Date?
    private nonisolated(unsafe) var _uniqueVerseIds: Set<String> = []
    private nonisolated(unsafe) var _studyToolOpens:    Int = 0
    private nonisolated(unsafe) var _wordNavCount:      Int = 0
    private nonisolated(unsafe) var _verseNavCount:     Int = 0
    private nonisolated(unsafe) var _annotationsCreated: Int = 0
    private nonisolated(unsafe) var _searches:          Int = 0

    // MARK: - Grace period

    private nonisolated(unsafe) var _backgroundedAt: Date?
    private nonisolated(unsafe) var _pendingFlushTask: Task<Void, Never>?
    private nonisolated(unsafe) var _bgTaskId: UIBackgroundTaskIdentifier = .invalid
    // swiftlint:enable nonisolated_unsafe

    private let graceSeconds: TimeInterval = 30

    // MARK: - Shared no-op instance
    // Single throwaway tracker used as the default before the live one is injected
    // (EnvironmentKey default + VM property defaults). Avoids allocating a fresh
    // tracker per VM. nonisolated(unsafe): never mutated, only used from @MainActor.
    // swiftlint:disable:next nonisolated_unsafe
    nonisolated(unsafe) static let noop = SessionTracker(analytics: NoopAnalytics.shared)

    // MARK: - Init

    // nonisolated: all stored properties are nonisolated(unsafe) so they can
    // be set here. Required to construct the EnvironmentKey defaultValue from
    // a nonisolated context under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    nonisolated init(analytics: any AnalyticsService) {
        _analytics = analytics
    }

    // MARK: - Lifecycle hooks (called from SourceBibleApp scenePhase observer)

    /// Called when scenePhase transitions to .active.
    /// Cancels any pending background flush and begins a new session unless
    /// we are returning within the grace window of the last background.
    @MainActor
    func handleForeground() {
        _pendingFlushTask?.cancel()
        _pendingFlushTask = nil

        let withinGrace: Bool
        if let bg = _backgroundedAt {
            withinGrace = Date().timeIntervalSince(bg) < graceSeconds
        } else {
            withinGrace = false
        }
        _backgroundedAt = nil

        if !withinGrace {
            begin()
        }
        // If within grace: session continues unchanged — no new begin(), no reset.
    }

    /// Called when scenePhase transitions to .background.
    /// Schedules a flush after the grace period; if the user returns before it
    /// fires, handleForeground() cancels the task.
    @MainActor
    func handleBackground() {
        _backgroundedAt = Date()
        _pendingFlushTask?.cancel()
        // iOS suspends the app shortly after backgrounding, so a plain Task.sleep
        // would never fire. A background-task assertion buys runtime so the grace
        // timer can complete and the summary flushes. If the system reclaims the
        // time BEFORE grace elapses, the expiration handler flushes early and ends
        // the assertion — otherwise iOS warns ("task still not ended") and may
        // terminate the app. flush()/endBackgroundTask() are idempotent, so the
        // expiration handler and the timer task can't double-send or double-end.
        _bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "study-session-flush") { [weak self] in
            MainActor.assumeIsolated {
                self?.flush()
                self?.endBackgroundTask()
            }
        }
        _pendingFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(graceSeconds))
            // Cancelled = user returned within grace → do NOT flush (session continues).
            if !Task.isCancelled { self.flush() }
            self.endBackgroundTask()
        }
    }

    // MARK: - Public API (all @MainActor)

    /// Start a new session. No-op if a session is already active.
    @MainActor
    func begin() {
        guard _startedAt == nil else { return }
        _startedAt         = Date()
        _uniqueVerseIds    = []
        _studyToolOpens    = 0
        _wordNavCount      = 0
        _verseNavCount     = 0
        _annotationsCreated = 0
        _searches          = 0
    }

    // All counters guard on an active session (`_startedAt != nil`): an increment
    // that arrives before begin() or after flush() is dropped rather than seeding
    // the next session's summary with orphan counts.

    /// Record a verse view. Tracks unique verse IDs so repeated views don't inflate count.
    @MainActor
    func incVersesRead(verseId: String) {
        guard _startedAt != nil else { return }
        _uniqueVerseIds.insert(verseId)
    }

    /// Increment word navigation counter (chevron between words in Bottom Sheet).
    @MainActor
    func incWordNav() {
        guard _startedAt != nil else { return }
        _wordNavCount += 1
    }

    /// Increment verse navigation counter (chevron between verses in Bottom Sheet).
    @MainActor
    func incVerseNav() {
        guard _startedAt != nil else { return }
        _verseNavCount += 1
    }

    /// Increment study tool open counter.
    /// Called by Slice 3 on original_opened / study_tab_switched / strongs_viewed /
    /// commentary_opened / crossref_opened / word_usage_opened.
    @MainActor
    func incStudyToolOpen() {
        guard _startedAt != nil else { return }
        _studyToolOpens += 1
    }

    /// Increment annotations counter.
    /// Called by Slice 3 on note_created / highlight_created / bookmark_created.
    @MainActor
    func incAnnotation() {
        guard _startedAt != nil else { return }
        _annotationsCreated += 1
    }

    /// Increment search counter. Called alongside search_committed event.
    @MainActor
    func incSearch() {
        guard _startedAt != nil else { return }
        _searches += 1
    }

    /// Emit `study_session_summary` and reset session state.
    /// No-op if no session is currently active.
    @MainActor
    func flush() {
        guard let start = _startedAt else { return }
        let durationSeconds = Int(Date().timeIntervalSince(start))
        _analytics.track(.studySessionSummary(
            durationSeconds:    durationSeconds,
            versesRead:         _uniqueVerseIds.count,
            studyToolOpens:     _studyToolOpens,
            wordNavCount:       _wordNavCount,
            verseNavCount:      _verseNavCount,
            annotationsCreated: _annotationsCreated,
            searches:           _searches
        ))
        resetState()
    }

    // MARK: - Private helpers

    @MainActor
    private func resetState() {
        _startedAt          = nil
        _uniqueVerseIds     = []
        _studyToolOpens     = 0
        _wordNavCount       = 0
        _verseNavCount      = 0
        _annotationsCreated = 0
        _searches           = 0
    }

    /// Ends the background-task assertion if one is active. Idempotent.
    @MainActor
    private func endBackgroundTask() {
        if _bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(_bgTaskId)
            _bgTaskId = .invalid
        }
    }
}
