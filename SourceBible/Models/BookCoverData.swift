// BookCoverData.swift
// SourceBible
//
// Static data for book covers: canonical section labels, right-side metadata,
// and optional Doré engraving image asset names.
//
// Adding a new cover image:
//   1. Export B&W Doré PNG from Figma (≥320×420px @2x)
//   2. Add to Assets.xcassets as "cover_{bookId_lowercased}" (e.g. cover_exo)
//   3. Add one entry to coverImages below — no other changes needed

import Foundation

enum BookCoverData {

    // MARK: - Public type

    struct CoverInfo {
        /// Two-line section label, bottom-left (e.g. "THE\nLAW")
        let sectionText: String
        /// Right-side metadata, bottom-right (e.g. "50\nCHAPTERS" or "PSALMS\n1–41")
        let rightMetadata: String
        /// xcassets name for the Doré engraving, nil = text-only cover (graceful fallback)
        let imageName: String?
    }

    // MARK: - Public API

    static func info(for bookId: String, chapterCount: Int) -> CoverInfo {
        CoverInfo(
            sectionText:   sectionText(for: bookId),
            rightMetadata: rightMeta(for: bookId, chapterCount: chapterCount),
            imageName:     coverImages[bookId]
        )
    }

    // MARK: - Image assets
    // Add entries here as new Doré engravings are added to xcassets.
    // Legacy names (genesis_header, psalms_header) kept as-is to avoid asset rename.

    private static let coverImages: [String: String] = [
        "GEN": "genesis_header",
        "PSA": "psalms_header",
        // Uncomment as images are added to xcassets:
        // "EXO": "cover_exo",
        // "JOS": "cover_jos",
        // "AMO": "cover_amo",
    ]

    // MARK: - Section labels (Protestant canonical groupings per PDR-Book-Covers)

    private static func sectionText(for bookId: String) -> String {
        switch bookId {
        case "GEN", "EXO", "LEV", "NUM", "DEU":
            return "THE\nLAW"
        case "JOS", "JDG", "RUT", "1SA", "2SA",
             "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST":
            return "HISTORICAL\nBOOKS"
        case "JOB", "PSA", "PRO", "ECC", "SNG":
            return "POETRY &\nWISDOM"
        case "ISA", "JER", "LAM", "EZK", "DAN":
            return "MAJOR\nPROPHETS"
        case "HOS", "JOL", "AMO", "OBA", "JON",
             "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL":
            return "MINOR\nPROPHETS"
        case "MAT", "MRK", "LUK", "JHN":
            return "THE\nGOSPELS"
        case "ACT":
            return "ACTS"
        case "ROM", "1CO", "2CO", "GAL", "EPH",
             "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM":
            return "PAUL'S\nLETTERS"
        case "HEB", "JAS", "1PE", "2PE", "1JN", "2JN", "3JN", "JUD":
            return "GENERAL\nLETTERS"
        case "REV":
            return "PROPHECY"
        default:
            return ""
        }
    }

    // MARK: - Right-side metadata

    private static func rightMeta(for bookId: String, chapterCount: Int) -> String {
        // Psalms ch.1 always falls in Book One (Psalms 1–41) per PDR-Book-Covers.
        // TODO: extend with chapterNumber param when Psalms sub-covers are needed.
        if bookId == "PSA" { return "PSALMS\n1–41" }
        let label = chapterCount == 1 ? "CHAPTER" : "CHAPTERS"
        return "\(chapterCount)\n\(label)"
    }
}
