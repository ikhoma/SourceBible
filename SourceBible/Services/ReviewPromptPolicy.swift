// ReviewPromptPolicy.swift
// SourceBible
//
// pos-012 (decisions 2026-10-22): when to show the system App Store rating prompt.
//
// "Study day" = a calendar day on which a session reached the local Meaningful Study
// Session proxy (SessionTracker.isMeaningfulSessionReached, ADR-038 amendment
// 2026-09-01: ≥ 60 s AND word navigation or any study-tool view). Recorded by ReaderView
// when the study sheet is dismissed.
//
// Ask when, counting only study days since the last prompt:
//   • ≥ 3 study days                                  (daily users: wait a little longer), or
//   • ≥ 2 study days, first and last ≥ 5 days apart   (weekly users: returning after a gap
//                                                       is itself the value signal)
// and never more than once per app version, and at least 90 days after the previous
// request (Apple shows at most 3 prompts per 365 days per device; spacing our own calls
// ≈ quarterly keeps each call from being swallowed by that cap).
//
// Storefront, not UI language: ratings are counted per storefront. The Ukrainian
// storefront is excluded while study data (lexicon, interlinear glosses, commentaries)
// is English-only — a rating there would score the missing Ukrainian content, not the
// app. Unknown storefront → no prompt.
//
// Everything stays on the device (UserDefaults) and does not depend on analytics
// consent. Apple never shows the prompt in TestFlight; in an Xcode build it shows every
// time it's called. For QA in DEBUG, pass `-ReviewPromptStorefront USA` as a launch
// argument when StoreKit can't resolve the storefront.

import Foundation
import StoreKit

struct ReviewPromptPolicy {

    enum Trigger: String, Sendable {
        case threeDays     = "three_days"
        case twoDaysSpread = "two_days_spread"
    }

    static let dailyThreshold       = 3
    static let spreadThreshold      = 2
    static let minSpreadDays        = 5
    static let minIntervalDays      = 90
    /// ISO 3166-1 alpha-3, as returned by `Storefront.countryCode`.
    static let excludedStorefronts: Set<String> = ["UKR"]
    static let maxStoredDays        = 30

    private enum Key {
        static let studyDays       = "reviewPrompt.studyDays"
        static let promptedVersion = "reviewPrompt.promptedVersion"
        static let lastPromptDate  = "reviewPrompt.lastPromptDate"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Study days

    /// Calendar day as "yyyy-MM-dd" in the given calendar's time zone.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Study days since the last prompt, ascending.
    var studyDays: [String] {
        defaults.stringArray(forKey: Key.studyDays) ?? []
    }

    /// Record that today had a meaningful study session. Idempotent within a day.
    func recordStudyDay(_ date: Date = .now, calendar: Calendar = .current) {
        let today = Self.dayKey(date, calendar: calendar)
        var days = studyDays
        guard !days.contains(today) else { return }
        days.append(today)
        days.sort()
        if days.count > Self.maxStoredDays {
            days.removeFirst(days.count - Self.maxStoredDays)
        }
        defaults.set(days, forKey: Key.studyDays)
    }

    // MARK: Decision

    /// The rule that fires, or nil when we shouldn't ask now.
    func trigger(appVersion: String?,
                 storefrontCountry: String?,
                 now: Date = .now,
                 calendar: Calendar = .current) -> Trigger? {
        guard let appVersion, let storefrontCountry else { return nil }
        guard !Self.excludedStorefronts.contains(storefrontCountry.uppercased()) else { return nil }
        guard defaults.string(forKey: Key.promptedVersion) != appVersion else { return nil }
        if let last = defaults.object(forKey: Key.lastPromptDate) as? Date,
           let earliest = calendar.date(byAdding: .day, value: Self.minIntervalDays, to: last),
           now < earliest {
            return nil
        }

        let days = studyDays
        if days.count >= Self.dailyThreshold { return .threeDays }
        if days.count >= Self.spreadThreshold,
           let first = days.first.flatMap({ Self.date(fromDayKey: $0, calendar: calendar) }),
           let last  = days.last.flatMap({ Self.date(fromDayKey: $0, calendar: calendar) }),
           let spread = calendar.dateComponents([.day], from: first, to: last).day,
           spread >= Self.minSpreadDays {
            return .twoDaysSpread
        }
        return nil
    }

    /// After asking: remember the version and date, and start counting study days afresh.
    func markPrompted(appVersion: String, at date: Date = .now) {
        defaults.set(appVersion, forKey: Key.promptedVersion)
        defaults.set(date, forKey: Key.lastPromptDate)
        defaults.removeObject(forKey: Key.studyDays)
    }

    // MARK: Environment

    static var currentAppVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// nil when StoreKit can't tell (e.g. Simulator without a StoreKit configuration).
    static func currentStorefrontCountry() async -> String? {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "ReviewPromptStorefront") {
            return forced
        }
        #endif
        return await Storefront.current?.countryCode
    }
}
