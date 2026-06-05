// BookCoverData.swift
// SourceBible
//
// Static data for book covers: canonical section labels, chapter counts,
// and optional Doré engraving image asset names.
//
// Adding a new cover image:
//   1. Add PNG to Assets.xcassets as "cover_{bookId_lowercased}" (e.g. cover_exo)
//   2. Add the asset name to coverImages below.

import Foundation

enum BookCoverData {

    // MARK: - Public types

    struct CoverInfo {
        /// Two-line section label shown bottom-left (e.g. "THE\nLAW")
        let sectionText: String
        /// Right-side metadata shown bottom-right (e.g. "50\nCHAPTERS")
        let rightMetadata: String
        /// xcassets name for the Doré engraving, or nil if not yet available.
        /// BookCoverView checks UIImage(named:) so missing assets are handled gracefully.
        let imageName: String?
    }

    // MARK: - Public API

    static func info(for bookId: String, chapterCount: Int) -> CoverInfo {
        let section = sectionText(for: bookId)
        let right   = rightMeta(for: bookId, chapterCount: chapterCount)
        let image   = coverImages[bookId]
        return CoverInfo(sectionText: section, rightMetadata: right, imageName: image)
    }

    // MARK: - Image assets
    // Add entries here as new Doré engravings are added to xcassets.

    private static let coverImages: [String: String] = [
        "GEN": "genesis_header",
        "PSA": "psalms_header",
        // Future covers — add xcassets entry + uncomment:
        // "EXO": "cover_exo",
        // "JOS": "cover_jos",
        // "AMO": "cover_amo",
    ]

    // MARK: - Section labels
    // Per PDR-Book-Covers: Protestant canonical groupings, displayed in two lines.

    private static func sectionText(for bookId: String) -> String {
        switch bookId {
        // The Law
        case "GEN", "EXO", "LEV", "NUM", "DEU":
            return "THE\nLAW"
        // Historical Books
        case "JOS", "JDG", "RUT", "1SA", "2SA",
             "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST":
            return "HISTORICAL\nBOOKS"
        // Poetry & Wisdom
        case "JOB", "PSA", "PRO", "ECC", "SNG":
            return "POETRY &\nWISDOM"
        // Major Prophets
        case "ISA", "JER", "LAM", "EZK", "DAN":
            return "MAJOR\nPROPHETS"
        // Minor Prophets
        case "HOS", "JOL", "AMO", "OBA", "JON",
             "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL":
            return "MINOR\nPROPHETS"
        // The Gospels
        case "MAT", "MRK", "LUK", "JHN":
            return "THE\nGOSPELS"
        // Acts
        case "ACT":
            return "ACTS"
        // Paul's Letters
        case "ROM", "1CO", "2CO", "GAL", "EPH",
             "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM":
            return "PAUL'S\nLETTERS"
        // General Letters
        case "HEB", "JAS", "1PE", "2PE", "1JN", "2JN", "3JN", "JUD":
            return "GENERAL\nLETTERS"
        // Prophecy
        case "REV":
            return "PROPHECY"
        default:
            return ""
        }
    }

    // MARK: - Right-side metadata
    // Psalms shows "BOOK ONE / PSALMS 1–41" for ch.1 instead of chapter count.
    // All other books: "N\nCHAPTERS" (or "1\nCHAPTER" for single-chapter books).

    private static func rightMeta(for bookId: String, chapterCount: Int) -> String {
        if bookId == "PSA" {
            return "PSALMS\n1–41"
        }
        let label = chapterCount == 1 ? "CHAPTER" : "CHAPTERS"
        return "\(chapterCount)\n\(label)"
    }
}
