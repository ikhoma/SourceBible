// SessionTrackerTests.swift
// SourceBibleTests
//
// study_session_summary — the five SessionTracker defects (ADR-022 Amendment 2026-11-05,
// fix 5 added 2026-11-06). Each test drives the injected clock instead of sleeping and
// calls the lifecycle hooks in the order iOS would. Every test below would FAIL on the
// tracker before its fix:
//   1. duration counted the 30 s grace            → durationIsForegroundTimeOnly
//   2. (upload timing — needs a live SDK, not unit-testable here)
//   3. a kill inside grace lost the session       → killInsideGraceIsRecoveredNextLaunch
//   4. expiration-flush + return within grace     → returnAfterEarlyFlushStartsNewSession
//      dropped every later counter
//   5. no flush at all + return past grace merged → stillOpenSessionIsFlushedOnLateReturn
//      the stale session into the new one
//
// @MainActor: the app target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
// Sessions here never reach "meaningful" (no word nav, no feature use), so
// handleBackground() does not write a study day into UserDefaults.standard.

import Foundation
import Testing
@testable import SourceBible

/// Records every tracked event. nonisolated like NoopAnalytics: AnalyticsService is a
/// nonisolated Sendable protocol.
private final class SpyAnalytics: AnalyticsService, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var _events: [AnalyticsEvent] = []

    nonisolated var events: [AnalyticsEvent] { lock.withLock { _events } }
    nonisolated func track(_ event: AnalyticsEvent) { lock.withLock { _events.append(event) } }
    nonisolated func identify(distinctId: String) {}
    nonisolated func flush() {}
    nonisolated func flush(completion: @escaping @Sendable () -> Void) { completion() }
}

/// Manually advanced clock.
private final class TestClock: @unchecked Sendable {
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// The fields of a study_session_summary the tests assert on.
private struct Summary: Equatable {
    var duration: Int
    var verses: Int
    var recoveredEndedAt: Date?
}

private func summaries(_ spy: SpyAnalytics) -> [Summary] {
    spy.events.compactMap {
        if case let .studySessionSummary(d, v, _, _, _, _, _, rec) = $0 {
            return Summary(duration: d, verses: v, recoveredEndedAt: rec)
        }
        return nil
    }
}

@MainActor
struct SessionTrackerTests {

    /// Runs `body` with a throwaway UserDefaults suite (deleted afterwards).
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "SessionTrackerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func tracker(_ spy: SpyAnalytics, _ clock: TestClock,
                         _ defaults: UserDefaults?) -> SessionTracker {
        SessionTracker(analytics: spy, defaults: defaults, now: { clock.now })
    }

    // Fix 1 — 20 s on screen, 30 s grace, then the grace timer flushes → 20, not 50.
    @Test func durationIsForegroundTimeOnly() {
        withDefaults { d in
            let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, d)
            t.handleForeground()
            t.incVersesOpened(verseId: "JHN|3|16")
            clock.advance(20); t.handleBackground()
            clock.advance(30); t.flush()                       // what the grace timer does
            #expect(summaries(spy) == [Summary(duration: 20, verses: 1, recoveredEndedAt: nil)])
        }
    }

    // Fix 1 — back within grace continues the session; only the two foreground
    // segments count (20 + 15), not the 10 s away nor the final 30 s grace.
    @Test func foregroundSegmentsAddUp() {
        withDefaults { d in
            let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, d)
            t.handleForeground()
            clock.advance(20); t.handleBackground()
            clock.advance(10); t.handleForeground()            // within grace
            clock.advance(15); t.handleBackground()
            clock.advance(30); t.flush()
            #expect(summaries(spy).map(\.duration) == [35])
        }
    }

    // Fix 4 — the expiration handler flushed early; the user returns "within grace".
    // The old code continued a session that no longer existed and dropped every counter.
    @Test func returnAfterEarlyFlushStartsNewSession() {
        withDefaults { d in
            let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, d)
            t.handleForeground()
            t.incVersesOpened(verseId: "GEN|1|1")
            clock.advance(10); t.handleBackground()
            clock.advance(5);  t.flush()                       // expiration handler
            clock.advance(5);  t.handleForeground()            // 10 s < 30 s grace
            t.incVersesOpened(verseId: "GEN|1|2")
            clock.advance(12); t.handleBackground()
            clock.advance(30); t.flush()
            #expect(summaries(spy) == [
                Summary(duration: 10, verses: 1, recoveredEndedAt: nil),
                Summary(duration: 12, verses: 1, recoveredEndedAt: nil),
            ])
        }
    }

    // Fix 5 — nothing flushed while backgrounded (no background time granted); the user
    // returns long after grace. The old session must report on its own and the new one
    // must count its foreground time. Before the fix: no event on return, then ONE
    // merged summary with the new foreground time missing.
    @Test func stillOpenSessionIsFlushedOnLateReturn() {
        withDefaults { d in
            let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, d)
            t.handleForeground()
            t.incVersesOpened(verseId: "PSA|23|1")
            clock.advance(20);  t.handleBackground()
            clock.advance(200); t.handleForeground()           // past grace, never flushed
            #expect(summaries(spy) == [Summary(duration: 20, verses: 1, recoveredEndedAt: nil)])
            t.incVersesOpened(verseId: "PSA|23|2")
            clock.advance(30); t.handleBackground()
            clock.advance(30); t.flush()
            #expect(summaries(spy).last == Summary(duration: 30, verses: 1, recoveredEndedAt: nil))
            #expect(summaries(spy).count == 2)
        }
    }

    // .inactive → .active blips (Control Center, notification shade, permission dialogs,
    // keyboard pre-warm right after launch) call handleForeground() WITHOUT a background
    // in between. They must not end the session. Regression 2026-11-06: the first fix-5
    // version treated "no background recorded" as "past grace" and flushed a live
    // session 3 s after launch (device log: duration_s = 3, recovered = 0).
    @Test func foregroundWithoutBackgroundKeepsSession() {
        withDefaults { d in
            let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, d)
            t.handleForeground()                               // cold launch (.task)
            t.incVersesOpened(verseId: "JHN|1|1")
            clock.advance(3);  t.handleForeground()            // .inactive → .active
            #expect(summaries(spy).isEmpty)
            t.incVersesOpened(verseId: "JHN|1|2")
            clock.advance(10); t.handleBackground()
            clock.advance(30); t.flush()
            #expect(summaries(spy) == [Summary(duration: 13, verses: 2, recoveredEndedAt: nil)])
        }
    }

    // Fix 3 — swipe-kill inside grace: nothing flushed in that process. The next launch
    // (a NEW tracker on the same defaults) sends it, timestamped when it went to background.
    @Test func killInsideGraceIsRecoveredNextLaunch() {
        withDefaults { d in
            let clock = TestClock()
            let first = SpyAnalytics(), a = tracker(first, clock, d)
            a.handleForeground()
            a.incVersesOpened(verseId: "ROM|8|28")
            clock.advance(25); a.handleBackground()
            let wentToBackground = clock.now
            #expect(summaries(first).isEmpty)                  // process dies here

            clock.advance(3_600)
            let second = SpyAnalytics(), b = tracker(second, clock, d)
            b.handleForeground()
            #expect(summaries(second) == [
                Summary(duration: 25, verses: 1, recoveredEndedAt: wentToBackground)
            ])
            b.flush()                                          // the new session itself
            #expect(summaries(second).count == 2)
            #expect(summaries(second).last?.recoveredEndedAt == nil)
        }
    }

    // Control — a session that WAS flushed must not come back as "recovered".
    @Test func flushedSessionIsNotResent() {
        withDefaults { d in
            let clock = TestClock()
            let first = SpyAnalytics(), a = tracker(first, clock, d)
            a.handleForeground()
            clock.advance(25); a.handleBackground()
            clock.advance(30); a.flush()
            #expect(summaries(first).count == 1)

            let second = SpyAnalytics(), b = tracker(second, clock, d)
            clock.advance(60); b.handleForeground()
            #expect(summaries(second).isEmpty)
        }
    }

    // Mixpanel /track rejects events older than 5 days → such a snapshot is dropped.
    @Test func snapshotOlderThanFiveDaysIsDropped() {
        withDefaults { d in
            let clock = TestClock()
            let a = tracker(SpyAnalytics(), clock, d)
            a.handleForeground()
            clock.advance(25); a.handleBackground()

            clock.advance(5 * 86_400)
            let second = SpyAnalytics(), b = tracker(second, clock, d)
            b.handleForeground()
            #expect(summaries(second).isEmpty)
            #expect(d.data(forKey: AppStorageKeys.pendingStudySession) == nil)
        }
    }

    // The shared `.noop` tracker passes defaults: nil — it must never persist a snapshot.
    @Test func noDefaultsMeansNoSnapshot() {
        let spy = SpyAnalytics(), clock = TestClock(), t = tracker(spy, clock, nil)
        t.handleForeground()
        clock.advance(25); t.handleBackground()
        let fresh = SpyAnalytics(), u = tracker(fresh, clock, nil)
        clock.advance(60); u.handleForeground()
        #expect(summaries(fresh).isEmpty)
    }
}
