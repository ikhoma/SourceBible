// BookCoverData.swift
// SourceBible
//
// Static data for book covers: canonical section labels, subtitle line,
// and optional Doré engraving image asset names.
//
// Adding a new cover image:
//   1. Export the pre-composited 402×402 blue cover PNG from Figma (@3x = 1206×1206)
//   2. Add to Assets.xcassets (e.g. "exodus_header")
//   3. Add one entry to coverImages below — no other changes needed

import Foundation

enum BookCoverData {

    // MARK: - Public type

    struct CoverInfo {
        /// Single subtitle line, e.g. "Wisdom & Poetry · 150 Chapters"
        let subtitle: String
        /// xcassets name for the pre-composited cover image,
        /// nil = brand-blue fallback cover (graceful fallback)
        let imageName: String?
    }

    // MARK: - Public API

    static func info(for bookId: String, chapterCount: Int) -> CoverInfo {
        CoverInfo(
            subtitle:  subtitle(for: bookId, chapterCount: chapterCount),
            imageName: coverImages[bookId]
        )
    }

    // MARK: - Image assets
    // Add entries here as new pre-composited cover images are added to xcassets.
    // Legacy names (genesis_header, psalms_header) kept as-is to avoid asset rename.

    private static let coverImages: [String: String] = [
        "GEN": "genesis_header",
        "PSA": "psalms_header",
        // Uncomment / add as cover images are added to xcassets:
        // "EXO": "exodus_header",
        // "JOS": "joshua_header",
        // "AMO": "amos_header",
    ]

    // MARK: - Subtitle ("<Section> · <N> Chapters")

    private static func subtitle(for bookId: String, chapterCount: Int) -> String {
        let unit    = chapterCount == 1 ? "Chapter" : "Chapters"
        let chapters = "\(chapterCount) \(unit)"
        let section = sectionTitle(for: bookId)
        return section.isEmpty ? chapters : "\(section) · \(chapters)"
    }

    // MARK: - Section labels (Protestant canonical groupings per PDR-Book-Covers)
    // Title case, single line — matches the new cover subtitle format.

    private static func sectionTitle(for bookId: String) -> String {
        switch bookId {
        case "GEN", "EXO", "LEV", "NUM", "DEU":
            return "The Law"
        case "JOS", "JDG", "RUT", "1SA", "2SA",
             "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST":
            return "Historical Books"
        case "JOB", "PSA", "PRO", "ECC", "SNG":
            return "Wisdom & Poetry"
        case "ISA", "JER", "LAM", "EZK", "DAN":
            return "Major Prophets"
        case "HOS", "JOL", "AMO", "OBA", "JON",
             "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL":
            return "Minor Prophets"
        case "MAT", "MRK", "LUK", "JHN":
            return "The Gospels"
        case "ACT":
            return "Acts"
        case "ROM", "1CO", "2CO", "GAL", "EPH",
             "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM":
            return "Paul's Letters"
        case "HEB", "JAS", "1PE", "2PE", "1JN", "2JN", "3JN", "JUD":
            return "General Letters"
        case "REV":
            return "Prophecy"
        default:
            return ""
        }
    }
}
