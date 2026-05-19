// String+BibleMarkup.swift
// SourceBible
//
// Single source of truth for stripping KJV inline Bible markup.
//
// Previously this logic was duplicated in four places:
//   • DatabaseService.stripBibleMarkup()       — concordance & cross-ref display
//   • DatabaseService.searchByText()           — search snippet (BUG: was missing, caused
//                                                <S>530</S> leaking into search results)
//   • WordTabContent.stripKJVSegment()         — concordance fallback in word tab
//   • VerseParser.stripTags()                  — plain-text extraction (still uses the full
//                                                token-aware parser; kept separate)
//
// Rule: any place that needs display-ready verse text calls .strippingBibleMarkup().
// Places that need the full token/segment structure still use VerseParser.parse().

import Foundation

extension String {

    /// Returns a display-ready version of a raw KJV verse by stripping all inline markup.
    ///
    /// Tag rules:
    ///   `<S>digits</S>`  — Strong's number  → removed entirely (tag + number)
    ///   `<n>text</n>`    — translator note  → content kept as (text)
    ///   `<i>…</i>`       — italics          → tags removed, text kept
    ///   `<br/>` `<pb/>`  — line breaks      → replaced with a single space
    ///   all other tags                      → tags stripped, inner content kept
    func strippingBibleMarkup() -> String {
        var s = self

        // 1. Strong's numbers: <S>530</S> → ""   (remove tag AND number)
        s = s.replacingOccurrences(of: #"<S>\d+[a-z]?</S>"#,
                                   with: "",
                                   options: .regularExpression)

        // 2. Translator notes: <n>content</n> → (content)
        s = s.replacingOccurrences(of: #"<n>(.*?)</n>"#,
                                   with: "($1)",
                                   options: .regularExpression)

        // 3. Void elements: <br/> <pb/> → space
        s = s.replacingOccurrences(of: #"<(br|pb)\s*/>"#,
                                   with: " ",
                                   options: [.regularExpression, .caseInsensitive])

        // 4. All remaining tags → strip, keep content
        s = s.replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "",
                                   options: .regularExpression)

        // 5. Collapse runs of spaces left by removed tags
        s = s.replacingOccurrences(of: #" {2,}"#,
                                   with: " ",
                                   options: .regularExpression)

        return s.trimmingCharacters(in: .whitespaces)
    }
}
