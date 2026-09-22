// TapVerseTip.swift
// SourceBible
//
// Minimal tap-to-study onboarding (docs/features/spec-minimal-tap-onboarding.md).
// One system TipKit popoverTip, anchored to Genesis 1:1 on first launch (the
// app's default cold-start target -- ReaderViewModel's "перший запуск" branch).
// Dismissed forever the instant the user taps ANY verse, via the Parameter
// below, donated from ReaderViewModel.tapVerse(_:) -- not re-implemented here.
//
// Deliberately NOT a TipGroup: this is the only tip planned for 20.09. A
// second tip (toolbar chevron nav in Study Mode) was discussed and deferred
// -- see spec Sec3/Sec6. If it ships later, migrate to TipGroup(.ordered)
// then, not before.

import SwiftUI
import TipKit

struct TapVerseTip: Tip {
    /// Flips true the instant the user taps ANY verse (donated in
    /// ReaderViewModel.tapVerse(_:)). Persisted by TipKit's own datastore --
    /// no separate AppStorage flag needed.
    @Parameter
    static var hasTappedAnyVerse: Bool = false

    /// Guards the "shown" analytics event so it fires at most once per
    /// install. `shouldDisplayUpdates` reflects ELIGIBILITY, not a single
    /// presentation -- ChapterScrollContent (and its host UIPageViewController
    /// page, ADR-026) is rebuilt on every chapter navigation/swipe, which
    /// re-subscribes the tracking `.task` and would otherwise re-fire the
    /// event on every rebuild while the tip is still eligible. (Caught in
    /// code review -- see docs/features/spec-minimal-tap-onboarding.md §6.)
    @Parameter
    static var hasShownTapHint: Bool = false

    var title: Text {
        Text("tip.tapVerse.title")
    }

    var message: Text? {
        Text("tip.tapVerse.message")
    }

    var image: Image? {
        Image(systemName: "hand.tap.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$hasTappedAnyVerse) { $0 == false }
    }

    var options: [Option] {
        MaxDisplayCount(1)
    }
}
