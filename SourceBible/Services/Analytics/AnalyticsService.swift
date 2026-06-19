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

    case studySessionSummary(
        durationSeconds: Int,
        versesRead: Int,
        studyToolOpens: Int,
        wordNavCount: Int,
        verseNavCount: Int,
        annotationsCreated: Int,
        searches: Int
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

    // ── Feature adoption ─────────────────────────────────────────────────────
    case originalOpened(bookId: Int)
    case studyTabSwitched(tab: String)   // "verse" | "word"
    case strongsViewed(strongsId: String)
    case commentaryOpened(author: String)
    case crossRefOpened
    case wordUsageOpened
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

        case let .studySessionSummary(dur, verses, tools, wordNav, verseNav, annots, searches):
            return ("study_session_summary", [
                "duration_s":          dur,
                "verses_read":         verses,
                "study_tool_opens":    tools,
                "word_nav_count":      wordNav,
                "verse_nav_count":     verseNav,
                "annotations_created": annots,
                "searches":            searches
            ])

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

        case let .originalOpened(bookId):
            return ("original_opened", ["book_id": bookId])

        case let .studyTabSwitched(tab):
            return ("study_tab_switched", ["tab": tab])

        case let .strongsViewed(id):
            return ("strongs_viewed", ["strongs_id": id])

        case let .commentaryOpened(author):
            return ("commentary_opened", ["author": author])

        case .crossRefOpened:
            return ("crossref_opened", [:])

        case .wordUsageOpened:
            return ("word_usage_opened", [:])

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
