// HighlightColor.swift
// SourceBible
//
// Type-safe highlight color tokens. rawValue is persisted in SQLite.
// Do NOT pass raw color strings beyond the store layer — use this enum everywhere.

import UIKit
import SwiftUI

enum HighlightColor: String, CaseIterable, Codable {
    case yellow
    case green
    case blue
    case pink

    /// Adaptive background color for use in UIKit (VerseTextView).
    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor.systemYellow.withAlphaComponent(0.40)
        case .green:  return UIColor.systemGreen.withAlphaComponent(0.35)
        case .blue:   return UIColor.systemBlue.withAlphaComponent(0.28)
        case .pink:   return UIColor.systemPink.withAlphaComponent(0.30)
        }
    }

    /// SwiftUI Color equivalent for use in native SwiftUI views.
    var color: Color {
        switch self {
        case .yellow: return Color.yellow.opacity(0.40)
        case .green:  return Color.green.opacity(0.35)
        case .blue:   return Color.blue.opacity(0.28)
        case .pink:   return Color.pink.opacity(0.30)
        }
    }

    /// Localized display name for the color picker.
    var label: String {
        switch self {
        case .yellow: return String(localized: "highlight.color.yellow")
        case .green:  return String(localized: "highlight.color.green")
        case .blue:   return String(localized: "highlight.color.blue")
        case .pink:   return String(localized: "highlight.color.pink")
        }
    }

    /// Decode from a stored rawValue. Falls back to .yellow for unknown/corrupt values.
    static func from(_ rawValue: String) -> HighlightColor {
        HighlightColor(rawValue: rawValue) ?? .yellow
    }
}

// MARK: - Word-level selection tint

// Single source of truth for the transient word-selection highlight used in:
//   • VerseTextView (long-press selection)
//   • WordTabContent / highlightedVerseText (concordance / Usage tab)
//   • SearchView / parseSnippet (search result keyword)
//
// Using backgroundColor (not bold) everywhere keeps the three sites visually
// consistent and avoids line-reflow side-effects from font-weight changes.

extension Color {
    /// Background tint for word-level highlights (SwiftUI Text / AttributedString).
    static let wordHighlight = Color.blue.opacity(0.15)
}

extension UIColor {
    /// UIKit equivalent for word-level highlights (NSAttributedString / UITextView).
    static let wordHighlight = UIColor.systemBlue.withAlphaComponent(0.2)
}
