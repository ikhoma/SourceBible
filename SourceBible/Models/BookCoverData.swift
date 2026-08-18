// BookCoverData.swift
// SourceBible
//
// Static data for book covers: canonical section labels, subtitle line,
// and optional Doré engraving image asset names.
//
// Adding a new cover image:
//   1. Export the pre-composited 440×440 blue cover PNG from Figma (@3x = 1320×1320)
//   2. Add to Assets.xcassets as "<usfmid>_header" (e.g. "exo_header")
//   3. Add one entry to coverImages below — no other changes needed
// Some books intentionally SHARE one cover (minor prophets, letter groups): several
// bookIds map to the same asset (e.g. HOS/JOL/OBA/ZEP/MAL → "hos_header").

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

    /// `locale` — мова ІНТЕРФЕЙСУ (`\.locale` з середовища, яку `SourceBibleApp` виставляє
    /// з `appLanguage`), а не системна. Потрібна для вибору форми множини: swizzle
    /// `LocalizedBundle` підміняє БАНДЛ, але не `Locale.current`, тож без явної локалі
    /// CLDR застосував би АНГЛІЙСЬКІ правила до українських рядків (bug-041).
    static func info(for bookId: String, chapterCount: Int, locale: Locale) -> CoverInfo {
        CoverInfo(
            subtitle:  subtitle(for: bookId, chapterCount: chapterCount, locale: locale),
            imageName: coverImages[bookId]
        )
    }

    // MARK: - Image assets
    // Add entries here as new pre-composited cover images are added to xcassets.
    // Legacy names (genesis_header, psalms_header) kept as-is to avoid asset rename.

    private static let coverImages: [String: String] = [
        // — Law —
        "GEN": "genesis_header",
        "EXO": "exo_header",
        "LEV": "lev_header",
        "NUM": "num_header",
        "DEU": "deu_header",
        // — History —
        "JOS": "jos_header",
        "JDG": "jdg_header",
        "RUT": "rut_header",
        "1SA": "1sa_header",
        "2SA": "2sa_header",
        "1KI": "1ki_header",
        "2KI": "2ki_header",
        "1CH": "1ch_header",
        "2CH": "2ch_header",
        "EZR": "ezr_header",
        "NEH": "neh_header",
        "EST": "est_header",
        // — Wisdom —
        "JOB": "job_header",
        "PSA": "psalms_header",
        "PRO": "pro_header",
        "ECC": "ecc_header",
        "SNG": "sng_header",
        // — Major Prophets —
        "ISA": "isa_header",
        "JER": "jer_header",
        "LAM": "lam_header",
        "EZK": "ezk_header",
        "DAN": "dan_header",
        // — Minor Prophets (HOS/JOL/OBA/ZEP/MAL share hos_header) —
        "HOS": "hos_header",
        "JOL": "hos_header",
        "AMO": "amo_header",
        "OBA": "hos_header",
        "JON": "jon_header",
        "MIC": "mic_header",
        "NAM": "nam_header",
        "HAB": "hab_header",
        "ZEP": "hos_header",
        "HAG": "hag_header",
        "ZEC": "zec_header",
        "MAL": "hos_header",
        // — Gospels —
        "MAT": "mat_header",
        "MRK": "mrk_header",
        "LUK": "luk_header",
        "JHN": "jhn_header",
        // — Acts —
        "ACT": "act_header",
        // — Pauline Letters (ROM/1CO/2CO/GAL/EPH → rom_header; PHP…HEB → php_header) —
        "ROM": "rom_header",
        "1CO": "rom_header",
        "2CO": "rom_header",
        "GAL": "rom_header",
        "EPH": "rom_header",
        "PHP": "php_header",
        "COL": "php_header",
        "1TH": "php_header",
        "2TH": "php_header",
        "1TI": "php_header",
        "2TI": "php_header",
        "TIT": "php_header",
        "PHM": "php_header",
        "HEB": "php_header",
        // — General Letters (1PE/2PE → 1pe_header; 1JN/2JN/3JN → 1jn_header) —
        "JAS": "jas_header",
        "1PE": "1pe_header",
        "2PE": "1pe_header",
        "1JN": "1jn_header",
        "2JN": "1jn_header",
        "3JN": "1jn_header",
        "JUD": "jud_header",
        // — Prophecy —
        "REV": "rev_header",
    ]

    // MARK: - Subtitle ("<Section> · <N> Chapters")

    /// bug-041: this was a `count == 1 ? singular : plural` ternary — the ENGLISH rule.
    /// Ukrainian has three forms, so 2/3/4 came out as «3 розділів» instead of «3 розділи».
    /// The form is now chosen by CLDR from the plural variations of `cover.chapters_count`
    /// in `Localizable.xcstrings`, not by an `if` here.
    ///
    /// ⛔ Не повертати тернар і не збирати рядок із числа та окремого слова: будь-яка нова
    /// мова (пол./рос./чеськ. — теж три форми) зламає його знову. Кількість → у plural-ключ.
    ///
    /// `NSLocalizedString` (not `String(localized:)`) because only that path goes through the
    /// `LocalizedBundle` swizzle and follows the in-app language — see bug-025.
    /// `String(format:locale:)` (NOT `String.localizedStringWithFormat`, and NOT
    /// `String(format:)`): the first argument-less form pins the rule engine to
    /// `Locale.current` = the SYSTEM language, and that measurably produced «3 розділу» —
    /// English rules (3 → other) applied to the Ukrainian table. The interface locale must
    /// be passed in. See bug-041.
    private static func subtitle(for bookId: String, chapterCount: Int, locale: Locale) -> String {
        let chapters = String(
            format: NSLocalizedString("cover.chapters_count", comment: "Cover subtitle: N chapters"),
            locale: locale,
            chapterCount)
        let section  = sectionTitle(for: bookId)
        return section.isEmpty ? chapters : "\(section) · \(chapters)"
    }

    // MARK: - Section labels (Protestant canonical groupings per PDR-Book-Covers)
    // Title case, single line — matches the new cover subtitle format.
    //
    // NSLocalizedString is used instead of String(localized:) because this is a
    // static Foundation method (not a SwiftUI View). Swift 5.9's String(localized:)
    // can bypass ObjC dispatch in non-View contexts, missing the LocalizedBundle swizzle.
    // NSLocalizedString always goes through Bundle.main.localizedString(forKey:value:table:).

    private static func sectionTitle(for bookId: String) -> String {
        switch bookId {
        case "GEN", "EXO", "LEV", "NUM", "DEU":
            return NSLocalizedString("cover.section.law", comment: "")
        case "JOS", "JDG", "RUT", "1SA", "2SA",
             "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST":
            return NSLocalizedString("cover.section.history", comment: "")
        case "JOB", "PSA", "PRO", "ECC", "SNG":
            return NSLocalizedString("cover.section.wisdom", comment: "")
        case "ISA", "JER", "LAM", "EZK", "DAN":
            return NSLocalizedString("cover.section.major_prophets", comment: "")
        case "HOS", "JOL", "AMO", "OBA", "JON",
             "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL":
            return NSLocalizedString("cover.section.minor_prophets", comment: "")
        case "MAT", "MRK", "LUK", "JHN":
            return NSLocalizedString("cover.section.gospels", comment: "")
        case "ACT":
            return NSLocalizedString("cover.section.acts", comment: "")
        case "ROM", "1CO", "2CO", "GAL", "EPH",
             "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM":
            return NSLocalizedString("cover.section.paul_letters", comment: "")
        case "HEB", "JAS", "1PE", "2PE", "1JN", "2JN", "3JN", "JUD":
            return NSLocalizedString("cover.section.general_letters", comment: "")
        case "REV":
            return NSLocalizedString("cover.section.prophecy", comment: "")
        default:
            return ""
        }
    }
}
