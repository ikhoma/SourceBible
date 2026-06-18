// HighlightColor.swift
// SourceBible
//
// Type-safe highlight color tokens. rawValue is persisted in SQLite.
// Do NOT pass raw color strings beyond the store layer — use this enum everywhere.
//
// Study Mode redesign (spec-study-mode-redesign.md R8):
// The picker palette is Purple/Pink/Orange/Mint/Blue (`pickerCases`).
// `yellow` and `green` are legacy cases — they MUST stay in the enum so that
// highlights already saved in the user DB keep decoding and rendering
// (user-data invariant: no migration, no data loss). They are simply not
// offered in the new picker UI.

import UIKit
import SwiftUI

enum HighlightColor: String, CaseIterable, Codable {
    // Legacy cases — kept for decoding/rendering saved highlights only.
    case yellow
    case green
    // Current palette (Study Mode picker).
    case purple
    case pink
    case orange
    case mint
    case blue

    /// Cases exposed in the highlight color picker UI (Study Mode context menu).
    /// Intentionally excludes legacy `yellow`/`green` — see header comment.
    static let pickerCases: [HighlightColor] = [.purple, .pink, .orange, .mint, .blue]

    /// Adaptive background color for use in UIKit (VerseTextView).
    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor.systemYellow.withAlphaComponent(0.40)
        case .green:  return UIColor.systemGreen.withAlphaComponent(0.35)
        case .purple: return UIColor.systemPurple.withAlphaComponent(0.30)
        case .pink:   return UIColor.systemPink.withAlphaComponent(0.30)
        case .orange: return UIColor.systemOrange.withAlphaComponent(0.32)
        case .mint:   return UIColor.systemMint.withAlphaComponent(0.32)
        case .blue:   return UIColor.appBlue.withAlphaComponent(0.28)
        }
    }

    /// SwiftUI Color equivalent for use in native SwiftUI views.
    var color: Color {
        switch self {
        case .yellow: return Color.yellow.opacity(0.40)
        case .green:  return Color.green.opacity(0.35)
        case .purple: return Color.purple.opacity(0.30)
        case .pink:   return Color.pink.opacity(0.30)
        case .orange: return Color.orange.opacity(0.32)
        case .mint:   return Color.mint.opacity(0.32)
        case .blue:   return Color.appBlue.opacity(0.28)
        }
    }

    /// Fully-opaque dot color for menu/picker swatches.
    var dotUIColor: UIColor {
        switch self {
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .purple: return .systemPurple
        case .pink:   return .systemPink
        case .orange: return .systemOrange
        case .mint:   return .systemMint
        case .blue:   return .appBlue
        }
    }

    /// Localized display name for the color picker.
    var label: String {
        switch self {
        case .yellow: return String(localized: "highlight.color.yellow")
        case .green:  return String(localized: "highlight.color.green")
        case .purple: return String(localized: "highlight.color.purple")
        case .pink:   return String(localized: "highlight.color.pink")
        case .orange: return String(localized: "highlight.color.orange")
        case .mint:   return String(localized: "highlight.color.mint")
        case .blue:   return String(localized: "highlight.color.blue")
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

// MARK: - Primary brand blue (#3085CF)

extension ShapeStyle where Self == Color {
    /// Primary brand blue (#3085CF) — the app's accent. Usable anywhere a ShapeStyle
    /// is expected (`.foregroundStyle`, `.tint`, `.fill`) and as `Color.appBlue`.
    /// Single source of truth; the AccentColor asset is set to the same hex for
    /// system chrome (`.tint(.accentColor)`, default control tints).
    static var appBlue: Color { Color(red: 48 / 255, green: 133 / 255, blue: 207 / 255) }
}

extension UIColor {
    /// UIKit equivalent of the primary brand blue (#3085CF).
    static let appBlue = UIColor(red: 48 / 255, green: 133 / 255, blue: 207 / 255, alpha: 1)
}

extension Color {
    /// Background tint for word-level highlights (SwiftUI Text / AttributedString).
    static let wordHighlight = Color.appBlue.opacity(0.15)
}

extension UIColor {
    /// UIKit equivalent for word-level highlights (NSAttributedString / UITextView).
    static let wordHighlight = UIColor.appBlue.withAlphaComponent(0.2)

    /// Accent tint applied to the *text* of the selected word in the reader
    /// (foregroundColor, not background).
    static let wordSelectionTint = UIColor.appBlue
}
