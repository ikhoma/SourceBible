// AnalyticsService.swift
// SourceBible
//
// Single-layer analytics abstraction.
// All event tracking goes through this protocol — no Mixpanel imports outside
// of MixpanelAnalytics.swift. Pattern mirrors TranslationProvider / UserDataStoreProtocol.
//
// Slice 1: protocol + event enum + environment key.
// Slices 2–3: call-site instrumentation.

import Foundation

// MARK: - Protocol

/// Thread-safe analytics abstraction. Sendable so it can be passed across actors.
protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent)
    func identify(distinctId: String)
    func flush()
}

// MARK: - Feature Adoption Taxonomy (ADR-022)
//
// Adding a new study tool = one new case here.
// SessionTracker.recordFeatureUse(_:) and studySessionSummary's
// per-feature loop both pick it up automatically via allCases.

enum AnalyticsFeature: String, CaseIterable, Sendable {
    case original                                       // OriginalWordsView — original-language word list
    case lexicon                                        // WordMeaningView — Strong's definition of a word
    case concordance                                    // ConcordanceView — word usage across the Bible
    case commentary
    case crossReference         = "cross_reference"
    case parallelTranslation    = "parallel_translation"
}

// MARK: - Event Taxonomy
//
// All events and their properties live here.
// Mapping  enum case → (eventName, [String: any MixpanelType])  happens in
// AnalyticsEvent.nameAndProperties below — one place to change naming.
//
// Props use basic Swift types (String, Int, Bool, Double).
// MixpanelAnalytics casts them to MixpanelType at the boundary.

enum AnalyticsEvent: Sendable {

    // ── Session / engagement ─────────────────────────────────────────────────
    case appOpened

    /// Emitted once per session on background + grace (ADR-022 §Depth signals).
    /// Per-feature view counts are folded in via the AnalyticsFeature.allCases loop
    /// in SessionTracker.flush() so adding a new feature requires no changes here.
    case studySessionSummary(
        durationSeconds:    Int,
        versesOpened:       Int,
        wordNavCount:       Int,
        verseNavCount:      Int,
        searchesCount:      Int,
        annotationsCreated: Int,
        featureCounts:      [AnalyticsFeature: Int]   // keyed by allCases
    )

    // ── Search behaviour ─────────────────────────────────────────────────────
    case searchCommitted(
        resultsCount: Int,
        hadZeroResults: Bool,
        translation: String,
        testamentFilter: String?      // "OT" | "NT" | nil (all)
    )

    case searchResultOpened(
        resultsCount: Int,
        position: Int
    )

    // ── Feature adoption (ADR-022: once per session, via SessionTracker) ─────
    /// Emitted once per feature per session (first use). Name: feature_adopted_<rawValue>.
    case featureAdopted(AnalyticsFeature)

    // ── Kept discrete (low-volume, high-value) ────────────────────────────────
    case translationSwitched(from: String, to: String)
    case noteCreated
    case highlightCreated(color: String)
    case bookmarkCreated

    // ── Deferred (slice 4 — cards/folders not yet built) ─────────────────────
    // case verseCardAdded
    // case wordCardAdded
    // case folderCreated
    // case tagAdded
}

// MARK: - Event → name + properties mapping

extension AnalyticsEvent {

    /// Returns the Mixpanel event name and a flat [String: Any] property dict.
    /// One place for all string names and property keys.
    var nameAndProperties: (name: String, props: [String: Any]) {
        switch self {

        case .appOpened:
            return ("app_opened", [:])

        case let .studySessionSummary(dur, verses, wordNav, verseNav, searches, annots, featureCounts):
            var props: [String: Any] = [
                "duration_s":          dur,
                "verses_opened":       verses,
                "word_nav_count":      wordNav,
                "verse_nav_count":     verseNav,
                "searches_count":      searches,
                "annotations_created": annots
            ]
            // Per-feature view counts (ADR-022 §Depth signals):
            // e.g. "lexicon_views_count", "commentary_views_count", …
            for f in AnalyticsFeature.allCases {
                props["\(f.rawValue)_views_count"] = featureCounts[f] ?? 0
            }
            return ("study_session_summary", props)

        case let .searchCommitted(count, zero, translation, filter):
            var props: [String: Any] = [
                "results_count":    count,
                "had_zero_results": zero,
                "translation":      translation
            ]
            if let f = filter { props["testament_filter"] = f }
            return ("search_committed", props)

        case let .searchResultOpened(count, pos):
            return ("search_result_opened", [
                "results_count": count,
                "position":      pos
            ])

        case let .featureAdopted(feature):
            return ("feature_adopted_\(feature.rawValue)", [:])

        case let .translationSwitched(from, to):
            return ("translation_switched", ["from": from, "to": to])

        case .noteCreated:
            return ("note_created", [:])

        case let .highlightCreated(color):
            return ("highlight_created", ["color": color])

        case .bookmarkCreated:
            return ("bookmark_created", [:])
        }
    }
}
