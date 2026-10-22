// ReviewPromptPolicyTests.swift
// SourceBibleTests
//
// pos-012: rating-prompt rule — 3 study days, or 2 study days ≥ 5 days apart; once per
// app version; ≥ 90 days between requests; study days reset after a request; never in
// the Ukrainian storefront or when the storefront/version is unknown.
//
// @MainActor: the app target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
// ReviewPromptPolicy is implicitly main-actor isolated; synchronous tests must be too.

import Foundation
import Testing
@testable import SourceBible

@MainActor
struct ReviewPromptPolicyTests {

    /// Runs `body` with a policy backed by a throwaway UserDefaults suite, and deletes
    /// the suite's plist afterwards so test runs don't pile up files on the simulator.
    private func withPolicy(_ body: (ReviewPromptPolicy) -> Void) {
        let suite = "ReviewPromptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(ReviewPromptPolicy(defaults: defaults))
    }

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ n: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 86_400)
    }

    private func trigger(_ p: ReviewPromptPolicy, now n: Int, version: String = "1.0",
                         storefront: String? = "USA") -> ReviewPromptPolicy.Trigger? {
        p.trigger(appVersion: version, storefrontCountry: storefront, now: day(n), calendar: utc)
    }

    @Test func sameDayCountsOnce() {
        withPolicy { p in
            p.recordStudyDay(day(0), calendar: utc)
            p.recordStudyDay(day(0).addingTimeInterval(3_600), calendar: utc)
            #expect(p.studyDays.count == 1)
        }
    }

    @Test func dailyUserAskedOnThirdDay() {
        withPolicy { p in
            p.recordStudyDay(day(0), calendar: utc)
            p.recordStudyDay(day(1), calendar: utc)
            #expect(trigger(p, now: 1) == nil)
            p.recordStudyDay(day(2), calendar: utc)
            #expect(trigger(p, now: 2) == .threeDays)
        }
    }

    @Test func weeklyUserAskedOnSecondDay() {
        withPolicy { p in
            p.recordStudyDay(day(0), calendar: utc)
            p.recordStudyDay(day(7), calendar: utc)
            #expect(trigger(p, now: 7) == .twoDaysSpread)
        }
    }

    @Test func twoCloseDaysAreNotEnough() {
        withPolicy { p in
            p.recordStudyDay(day(0), calendar: utc)
            p.recordStudyDay(day(4), calendar: utc)
            #expect(trigger(p, now: 4) == nil)
            p.recordStudyDay(day(5), calendar: utc)
            #expect(trigger(p, now: 5) == .threeDays)
        }
    }

    @Test func oncePerVersionAndCountersReset() {
        withPolicy { p in
            for n in 0..<3 { p.recordStudyDay(day(n), calendar: utc) }
            p.markPrompted(appVersion: "1.0", at: day(2))
            #expect(p.studyDays.isEmpty)
            for n in 3..<6 { p.recordStudyDay(day(n), calendar: utc) }
            #expect(trigger(p, now: 200, version: "1.0") == nil)
        }
    }

    @Test func atLeastNinetyDaysBetweenRequests() {
        withPolicy { p in
            p.markPrompted(appVersion: "1.0", at: day(0))
            for n in 10..<13 { p.recordStudyDay(day(n), calendar: utc) }
            #expect(trigger(p, now: 89, version: "1.1") == nil)
            #expect(trigger(p, now: 90, version: "1.1") == .threeDays)
        }
    }

    @Test func ukrainianStorefrontIsExcluded() {
        withPolicy { p in
            for n in 0..<3 { p.recordStudyDay(day(n), calendar: utc) }
            #expect(trigger(p, now: 2, storefront: "UKR") == nil)
            #expect(trigger(p, now: 2, storefront: "ukr") == nil)
        }
    }

    @Test func unknownStorefrontOrVersionNeverPrompts() {
        withPolicy { p in
            for n in 0..<3 { p.recordStudyDay(day(n), calendar: utc) }
            #expect(trigger(p, now: 2, storefront: nil) == nil)
            #expect(p.trigger(appVersion: nil, storefrontCountry: "USA", now: day(2), calendar: utc) == nil)
        }
    }

    @Test func storedDaysAreCapped() {
        withPolicy { p in
            for n in 0..<(ReviewPromptPolicy.maxStoredDays + 5) { p.recordStudyDay(day(n), calendar: utc) }
            #expect(p.studyDays.count == ReviewPromptPolicy.maxStoredDays)
        }
    }
}
