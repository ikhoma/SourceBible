// SessionTracker.swift
// SourceBible
//
// Tracks the current study session and emits `study_session_summary` on background.
//
// Design (Slice 2 + Slice 3 / ADR-022):
//   - All public API is @MainActor — counters and session state are only ever
//     read/written from the main thread.
//   - Mutable stored properties are nonisolated(unsafe) so the init can run from
//     a nonisolated context (required for EnvironmentKey.defaultValue under
//     SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor). The unsafe annotation is safe
//     here because every actual access of these properties is behind @MainActor.
//   - Injected `any AnalyticsService` — stays behind the abstraction layer.
//   - Grace period (~30s): quick foreground/background round-trips do NOT start
//     a new session or emit a duplicate summary.
//   - versesOpened is tracked as a Set<String> of unique verseIds so repeated
//     views of the same verse don't inflate the count.
//
// ADR-022 generic model:
//   - featureCounts: [AnalyticsFeature: Int] — per-feature view counts rolled
//     into study_session_summary; adding a new AnalyticsFeature case requires
//     no changes here (allCases loop).
//   - adopted: Set<AnalyticsFeature> — once-per-session adoption guard; emits
//     feature_adopted_<raw> on first use, then only counts thereafter.
//   - recordFeatureUse(_ f:) is the single call site for study-tool views.
//
// Lifecycle (driven by SourceBibleApp scenePhase observer):
//   .active   → handleForeground()  →  cancel pending flush, begin() if not in grace
//   .background → handleBackground() →  snapshot session, schedule flush after ~30s grace
//
// Undercount fixes (2026-11-05, measured in prod Mixpanel the same day):
//   1. duration_s counted the 30s grace (and any earlier background gaps): it was
//      `flushTime − startedAt`. A session with 20s of use reported 50s, an open-and-
//      leave reported 30s — and the Mixpanel MSS rule is `duration_s >= 60`. Now
//      duration = FOREGROUND time only (`_activeSeconds`).
//   2. The summary was tracked 30s after backgrounding, i.e. AFTER Mixpanel's own
//      on-background upload, so it sat in the SDK queue until the next app open.
//      Now flush() is followed by an explicit upload, and the background-task
//      assertion is held until that upload finishes.
//   3. A process killed inside the grace window (swipe from the app switcher) never
//      ran flush() — the whole session vanished. Now every backgrounding writes a
//      snapshot (AppStorageKeys.pendingStudySession); flush() deletes it; a snapshot
//      still present at the next begin() is sent as a recovered summary.
//   4. If the expiration handler flushed early and the user came back "within grace",
//      no new session began and every counter until the next cold launch was dropped
//      (all increments guard on `_startedAt`). handleForeground() now begins a session
//      whenever none is active.

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
    /// Where the pending-session snapshot lives. nil = no persistence (the `.noop`
    /// tracker must never write to, or recover from, the real defaults).
    private nonisolated(unsafe) var _defaults: UserDefaults?
    /// Injectable clock — tests drive the grace / duration logic without sleeping.
    private nonisolated(unsafe) var _now: @Sendable () -> Date

    // MARK: - Session state
    // nonisolated(unsafe): all accesses occur from @MainActor methods (see public API below).
    // The unsafe annotation is required only to allow the nonisolated init to set defaults.

    private nonisolated(unsafe) var _startedAt: Date?
    /// Foreground time of the session so far, excluding the segment in progress.
    private nonisolated(unsafe) var _activeSeconds: TimeInterval = 0
    /// Start of the current foreground segment; nil while backgrounded.
    private nonisolated(unsafe) var _foregroundSince: Date?
    private nonisolated(unsafe) var _uniqueVerseIds: Set<String> = []
    private nonisolated(unsafe) var _wordNavCount:    Int = 0
    private nonisolated(unsafe) var _verseNavCount:      Int = 0
    private nonisolated(unsafe) var _annotationsCreated: Int = 0
    private nonisolated(unsafe) var _searches:           Int = 0

    // ADR-022: generic feature adoption + depth counters
    private nonisolated(unsafe) var _featureCounts: [AnalyticsFeature: Int] = [:]
    private nonisolated(unsafe) var _adopted: Set<AnalyticsFeature> = []

    // MARK: - Grace period

    private nonisolated(unsafe) var _backgroundedAt: Date?
    private nonisolated(unsafe) var _pendingFlushTask: Task<Void, Never>?
    private nonisolated(unsafe) var _bgTaskId: UIBackgroundTaskIdentifier = .invalid
    // swiftlint:enable nonisolated_unsafe

    private let graceSeconds: TimeInterval = 30

    /// Mixpanel's /track endpoint rejects events older than 5 days; a snapshot older
    /// than this is dropped instead of being sent with a timestamp ingestion refuses.
    private let maxRecoveryAge: TimeInterval = 5 * 86_400 - 3_600

    // MARK: - Shared no-op instance
    // Single throwaway tracker used as the default before the live one is injected
    // (EnvironmentKey default + VM property defaults). Avoids allocating a fresh
    // tracker per VM.
    //
    // `nonisolated`, NOT `nonisolated(unsafe)`, and NOT bare — all three differ:
    //   bare                 → under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor this
    //                          static let is inferred @MainActor, and
    //                          AnalyticsEnvironmentKey's `nonisolated static let
    //                          defaultValue: SessionTracker = .noop` then fails with
    //                          "main actor-isolated default value in a nonisolated
    //                          context". Measured 2026-08-26 — this is a build error.
    //   nonisolated(unsafe)  → works, but the compiler flags the `(unsafe)` as
    //                          needless: SessionTracker is @unchecked Sendable, so
    //                          the unchecked variant buys nothing.
    //   nonisolated          → what we want. Severs the @MainActor inference, keeps
    //                          the Sendable check. Clean build, no warning.
    // The compiler's fix-it ("consider removing it") is half right: drop `(unsafe)`,
    // keep `nonisolated`. Taking the fix-it literally breaks the build.
    nonisolated static let noop = SessionTracker(analytics: NoopAnalytics.shared, defaults: nil)

    // MARK: - Init

    // nonisolated: all stored properties are nonisolated(unsafe) so they can
    // be set here. Required to construct the EnvironmentKey defaultValue from
    // a nonisolated context under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    nonisolated init(
        analytics: any AnalyticsService,
        defaults: UserDefaults? = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        _analytics = analytics
        _defaults = defaults
        _now = now
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
            withinGrace = _now().timeIntervalSince(bg) < graceSeconds
        } else {
            withinGrace = false
        }
        _backgroundedAt = nil

        // `_startedAt == nil` despite grace: the expiration handler already flushed
        // the session — continuing it would silently drop every counter (fix 4).
        if !withinGrace || _startedAt == nil {
            begin()
        } else if _foregroundSince == nil {
            // Within grace: same session, new foreground segment.
            _foregroundSince = _now()
        }
    }

    /// Called when scenePhase transitions to .background.
    /// Schedules a flush after the grace period; if the user returns before it
    /// fires, handleForeground() cancels the task.
    @MainActor
    func handleBackground() {
        let now = _now()
        closeForegroundSegment(at: now)
        _backgroundedAt = now
        // pos-012: MSS is otherwise only checked when the study sheet closes, so a session
        // that reaches 60 s AFTER the last dismissal would not count as a study day.
        // Record here too (idempotent per day). Prompting stays tied to sheet dismissal.
        if isMeaningfulSessionReached {
            ReviewPromptPolicy().recordStudyDay()
        }
        // Fix 3: survive a kill inside the grace window.
        writePendingSnapshot(endedAt: now)

        _pendingFlushTask?.cancel()
        // A previous assertion still held (left and came back within grace, now leaving
        // again): end it here — its cancelled timer won't, see endBackgroundTask(_:).
        endBackgroundTask(_bgTaskId)
        // iOS suspends the app shortly after backgrounding, so a plain Task.sleep
        // would never fire. A background-task assertion buys runtime so the grace
        // timer can complete and the summary flushes. If the system reclaims the
        // time BEFORE grace elapses, the expiration handler flushes early and ends
        // the assertion — otherwise iOS warns ("task still not ended") and may
        // terminate the app. The timer ends only the assertion it was created for,
        // so a stale timer can't end a newer one.
        // The expiration handler can only reach the CURRENT assertion (its own id isn't
        // known until beginBackgroundTask returns); an older one was ended just above.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "study-session-flush") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush()
                self.endBackgroundTask(self._bgTaskId)
            }
        }
        _bgTaskId = assertion
        _pendingFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(graceSeconds))
            // Cancelled = user returned within grace → do NOT flush (session continues).
            guard !Task.isCancelled else {
                self.endBackgroundTask(assertion)
                return
            }
            self.flush()
            // Fix 2: upload now, while we still hold background time, instead of
            // leaving the summary queued until the next app open.
            self._analytics.flush { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.endBackgroundTask(assertion) }
            }
        }
    }

    // MARK: - Public API (all @MainActor)

    /// Start a new session. No-op if a session is already active.
    @MainActor
    func begin() {
        guard _startedAt == nil else { return }
        // A snapshot that survived to here belongs to a session whose process was
        // killed before it could flush — send it before the new session starts.
        recoverPendingSession()
        let now = _now()
        _startedAt       = now
        _foregroundSince = now
        _activeSeconds   = 0
        resetState()
    }

    // All counters guard on an active session (`_startedAt != nil`): an increment
    // that arrives before begin() or after flush() is dropped rather than seeding
    // the next session's summary with orphan counts.

    // MARK: Local Meaningful Study Session proxy (ADR-038 amendment 2026-09-01)

    /// True once the current session has ≥ 60 s of FOREGROUND time AND a depth signal:
    /// word chevron navigation or any study-tool view. Annotations deliberately don't
    /// count (every Bible app has notes/highlights). Coarser than the Mixpanel MSS Custom
    /// Event, but evaluated on-device, so it works without analytics consent. Used by the
    /// rating prompt (pos-012).
    @MainActor
    var isMeaningfulSessionReached: Bool {
        guard _startedAt != nil else { return false }
        return activeSecondsNow() >= 60
            && (_wordNavCount > 0 || !_featureCounts.isEmpty)
    }

    // MARK: ADR-022 Generic Feature Use

    /// Record one view of a study tool (ADR-022 generic model).
    /// - On first call for a feature this session: emits `feature_adopted_<raw>` discrete event.
    /// - Every call (including first): increments the per-feature view counter for the summary.
    /// - No-op when no session is active (guards orphaned counts).
    @MainActor
    func recordFeatureUse(_ f: AnalyticsFeature) {
        guard _startedAt != nil else { return }
        if _adopted.insert(f).inserted {
            _analytics.track(.featureAdopted(f))
        }
        _featureCounts[f, default: 0] += 1
    }

    // MARK: Navigation / search counters

    /// Record a verse view. Tracks unique verse IDs so repeated views don't inflate count.
    @MainActor
    func incVersesOpened(verseId: String) {
        guard _startedAt != nil else { return }
        _uniqueVerseIds.insert(verseId)
    }

    /// Increment word navigation counter (chevron between words in the Word tab).
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

    /// Increment annotations counter.
    /// Called alongside discrete note_created / highlight_created / bookmark_created events.
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

    // MARK: Flush

    /// Emit `study_session_summary` and reset session state.
    /// No-op if no session is currently active.
    @MainActor
    func flush() {
        guard _startedAt != nil else { return }
        _analytics.track(.studySessionSummary(
            durationSeconds:    Int(activeSecondsNow()),
            versesOpened:       _uniqueVerseIds.count,
            wordNavCount:       _wordNavCount,
            verseNavCount:      _verseNavCount,
            searchesCount:      _searches,
            annotationsCreated: _annotationsCreated,
            featureCounts:      _featureCounts
        ))
        // Sent → the kill-recovery snapshot must not resend it.
        _defaults?.removeObject(forKey: AppStorageKeys.pendingStudySession)
        _startedAt       = nil
        _foregroundSince = nil
        _activeSeconds   = 0
        resetState()
    }

    // MARK: - Private helpers

    @MainActor
    private func resetState() {
        _uniqueVerseIds     = []
        _wordNavCount    = 0
        _verseNavCount      = 0
        _annotationsCreated = 0
        _searches           = 0
        _featureCounts      = [:]
        _adopted            = []
    }

    /// Foreground time of the current session including the segment in progress.
    @MainActor
    private func activeSecondsNow() -> TimeInterval {
        let running = _foregroundSince.map { max(0, _now().timeIntervalSince($0)) } ?? 0
        return _activeSeconds + running
    }

    @MainActor
    private func closeForegroundSegment(at now: Date) {
        guard let since = _foregroundSince else { return }
        _activeSeconds += max(0, now.timeIntervalSince(since))
        _foregroundSince = nil
    }

    /// Ends `id` if it is still the assertion currently held. Idempotent, and a no-op
    /// for an assertion already ended or replaced by a newer backgrounding.
    @MainActor
    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid, id == _bgTaskId else { return }
        UIApplication.shared.endBackgroundTask(id)
        _bgTaskId = .invalid
    }

    // MARK: Kill recovery (fix 3)

    /// Counters-only copy of a session at the moment it went to background.
    private struct PendingSnapshot: Codable {
        var endedAt:            Date
        var activeSeconds:      TimeInterval
        var versesOpened:       Int
        var wordNavCount:       Int
        var verseNavCount:      Int
        var searchesCount:      Int
        var annotationsCreated: Int
        var featureCounts:      [String: Int]   // AnalyticsFeature.rawValue → count
    }

    @MainActor
    private func writePendingSnapshot(endedAt: Date) {
        guard let defaults = _defaults, _startedAt != nil else { return }
        let snapshot = PendingSnapshot(
            endedAt:            endedAt,
            activeSeconds:      _activeSeconds,
            versesOpened:       _uniqueVerseIds.count,
            wordNavCount:       _wordNavCount,
            verseNavCount:      _verseNavCount,
            searchesCount:      _searches,
            annotationsCreated: _annotationsCreated,
            featureCounts:      Dictionary(uniqueKeysWithValues:
                                    _featureCounts.map { ($0.key.rawValue, $0.value) })
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: AppStorageKeys.pendingStudySession)
        }
    }

    @MainActor
    private func recoverPendingSession() {
        guard let defaults = _defaults,
              let data = defaults.data(forKey: AppStorageKeys.pendingStudySession)
        else { return }
        // Remove first: a snapshot is sent at most once, even if decoding fails.
        defaults.removeObject(forKey: AppStorageKeys.pendingStudySession)
        guard let s = try? JSONDecoder().decode(PendingSnapshot.self, from: data) else { return }
        let age = _now().timeIntervalSince(s.endedAt)
        // Too old for Mixpanel /track, or from the future (clock change) → drop.
        guard age >= 0, age <= maxRecoveryAge else { return }
        var features: [AnalyticsFeature: Int] = [:]
        for (raw, count) in s.featureCounts {
            if let f = AnalyticsFeature(rawValue: raw) { features[f] = count }
        }
        _analytics.track(.studySessionSummary(
            durationSeconds:    Int(s.activeSeconds),
            versesOpened:       s.versesOpened,
            wordNavCount:       s.wordNavCount,
            verseNavCount:      s.verseNavCount,
            searchesCount:      s.searchesCount,
            annotationsCreated: s.annotationsCreated,
            featureCounts:      features,
            recoveredEndedAt:   s.endedAt
        ))
    }
}
