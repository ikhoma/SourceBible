// AppearanceSettings.swift
// SourceBible
//
// Appearance model layer: color scheme mode, color theme, reader title font.
// - AppearanceMode: Light / Dark / Match Device (replaces the old isDarkMode Bool).
// - ColorTheme: Paper (current asset-catalog colors) / Incunable (warm antique palette).
// - TitleFontStyle: Modern (system, current look) / Antique (Cormorant Bold, +2pt).
//
// Colors: Paper resolves through the existing asset catalog (zero visual diff);
// Incunable uses dynamic UIColor providers so light/dark follow the effective
// color scheme automatically (works with Match Device too).
//
// Figma source of truth for Incunable values: Source Bible App, node 1316-5520.

import SwiftUI
import CoreText

// MARK: - AppearanceMode (Light / Dark / Match Device)

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case matchDevice

    var id: String { rawValue }

    /// nil = follow the system appearance (Match Device).
    var colorScheme: ColorScheme? {
        switch self {
        case .light:       return .light
        case .dark:        return .dark
        case .matchDevice: return nil
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .light:       return "menu.appearance.light"
        case .dark:        return "menu.appearance.dark"
        case .matchDevice: return "menu.appearance.match_device"
        }
    }

    var systemImage: String {
        switch self {
        case .light:       return "sun.max"
        case .dark:        return "moon.stars"
        case .matchDevice: return "circle.lefthalf.filled"
        }
    }

    /// One-time migration from the legacy `isDarkMode` Bool. Runs at app init:
    /// if the new key is unset but the old one exists, carry the choice over.
    /// The legacy key is left in place (harmless) so downgrade builds still work.
    static func migrateFromLegacyDarkMode(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: AppStorageKeys.appearanceMode) == nil else { return }
        if let wasDark = defaults.object(forKey: AppStorageKeys.isDarkMode) as? Bool {
            defaults.set((wasDark ? AppearanceMode.dark : .light).rawValue,
                         forKey: AppStorageKeys.appearanceMode)
        }
    }
}

// MARK: - ColorTheme (Paper / Incunable)

enum ColorTheme: String, CaseIterable, Identifiable {
    case paper
    case incunable

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .paper:     return "menu.theme.paper"
        case .incunable: return "menu.theme.incunable"
        }
    }

    /// Main reader / screen background.
    var appBackground: Color {
        switch self {
        case .paper:     return Color("appBackground")
        case .incunable: return Self.dynamic(light: 0xEAE3DC, dark: 0x1E1C1A)
        }
    }

    /// Settings / list card rows (follows the sheet surface in Incunable).
    var cardBackground: Color {
        switch self {
        case .paper:     return Color("cardBackground")
        case .incunable: return Self.dynamic(light: 0xF7F5F2, dark: 0x2C2926)
        }
    }

    /// Bottom sheet surface.
    var sheetBackground: Color {
        switch self {
        case .paper:     return Color("sheetBackground")
        case .incunable: return Self.dynamic(light: 0xF7F5F2, dark: 0x2C2926)
        }
    }

    // MARK: Dynamic color helper

    /// ⚠️ Concurrency: the project compiles with SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor, so a plain closure literal here is inferred @MainActor — but
    /// UIKit resolves dynamic-provider colors on SwiftUI's AsyncRenderer thread,
    /// which trips dispatch_assert_queue (SIGILL crash, seen 2026-07-11). The
    /// closure MUST be @Sendable (→ nonisolated) and must not create colors
    /// inside; both variants are precomputed and captured immutably.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = UIColor(rgb: light)
        let darkColor  = UIColor(rgb: dark)
        return Color(UIColor { @Sendable trait in
            trait.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

// MARK: - TitleFontStyle (Modern / Antique)

enum TitleFontStyle: String, CaseIterable, Identifiable {
    case modern
    case antique

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .modern:  return "menu.title_font.modern"
        case .antique: return "menu.title_font.antique"
        }
    }

    /// PostScript name of the bundled antique face.
    static let antiqueFontName = "Cormorant-Bold"

    /// Book name on the Doré cover (fixed size — the cover doesn't scale).
    /// Modern 34 → Antique 36 (Cormorant is optically more compact).
    var coverTitleFont: Font {
        switch self {
        case .modern:  return .system(size: 34, weight: .bold)
        case .antique: return .custom(Self.antiqueFontName, fixedSize: 36)
        }
    }

    /// Book name shown when covers are hidden (Dynamic Type: large title slot).
    var bookLargeTitleFont: Font {
        switch self {
        case .modern:  return .largeTitle.bold()
        case .antique: return .custom(Self.antiqueFontName, size: 36, relativeTo: .largeTitle)
        }
    }

    /// Chapter heading inside the reading flow (Dynamic Type: title slot).
    var chapterHeadingFont: Font {
        switch self {
        case .modern:  return .title.bold()
        case .antique: return .custom(Self.antiqueFontName, size: 30, relativeTo: .title)
        }
    }

    /// Register bundled fonts with Core Text (process scope, no Info.plist entry
    /// needed). Called once from SourceBibleApp.init. Looks in the bundle root
    /// first (Xcode 16 synchronized folders copy resources flat), then in the
    /// Fonts/ subdirectory as a fallback.
    static func registerBundledFonts() {
        let url = Bundle.main.url(forResource: antiqueFontName, withExtension: "ttf")
            ?? Bundle.main.url(forResource: antiqueFontName, withExtension: "ttf", subdirectory: "Fonts")
        guard let url else {
            assertionFailure("Cormorant-Bold.ttf missing from bundle")
            return
        }
        CTFontManagerRegisterFontURLs([url] as CFArray, .process, true, nil)
    }
}

// MARK: - Environment plumbing

private struct ColorThemeKey: EnvironmentKey {
    static let defaultValue: ColorTheme = .paper
}

private struct TitleFontStyleKey: EnvironmentKey {
    static let defaultValue: TitleFontStyle = .modern
}

extension EnvironmentValues {
    /// Active color theme; injected at the app root from @AppStorage.
    var colorTheme: ColorTheme {
        get { self[ColorThemeKey.self] }
        set { self[ColorThemeKey.self] = newValue }
    }

    /// Active reader title font style; injected at the app root from @AppStorage.
    var titleFontStyle: TitleFontStyle {
        get { self[TitleFontStyleKey.self] }
        set { self[TitleFontStyleKey.self] = newValue }
    }
}

// MARK: - UIColor hex helper

private extension UIColor {
    // nonisolated: must be callable from the @Sendable dynamic-provider path
    // (file compiles under default MainActor isolation).
    nonisolated convenience init(rgb: UInt32) {
        self.init(red:   CGFloat((rgb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((rgb >> 8)  & 0xFF) / 255.0,
                  blue:  CGFloat(rgb         & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}
