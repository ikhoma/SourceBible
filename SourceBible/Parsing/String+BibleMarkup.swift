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
        //
        //    FTS5 snippet() cuts at token boundaries, which may fall *inside* a <S>N</S>
        //    span. This produces three partial-tag fragment forms that the complete-tag
        //    regex won't match. Handle all four cases here:
        //
        //      Complete:       <S>1818</S>  → ""   (normal in full-verse display)
        //      Open orphan:    <S>1818      → ""   (close tag beyond snippet window)
        //      Close orphan:   1818</S>     → ""   (open tag before snippet window)
        //      '<' orphan:     S>1818       → ""   ('< ' was replaced by ellipsis)
        //      '</' orphan:    S>           → ""   ('</' was replaced by ellipsis,
        //                                           no digits follow the closing tag)
        //
        //    The last two cases both start with "S>" — differ only in whether digits
        //    follow. Using \d* (zero-or-more) covers both with one pass.
        //
        s = s.replacingOccurrences(of: #"<S>\d+[a-z]?</S>"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"<S>\d+[a-z]?"#,      // orphaned open tag
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\d+[a-z]?</S>"#,     // orphaned close tag
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"S>\d*[a-z]?"#,       // '<' or '</' cut (with or without digits)
                                   with: "",
                                   options: .regularExpression)

        // 1b. Partial-tag stubs where the FTS5 snippet window cuts *before* '>'.
        //     The four patterns above handle every case where '>' is present.
        //     These two catch the remaining stubs that end mid-tag:
        //       "covenant</S…"  → close-tag stub ('>' cut)
        //       "flesh<S…"      → open-tag stub  ('>', digits, and close-tag all cut)
        s = s.replacingOccurrences(of: "</S", with: "")
        s = s.replacingOccurrences(of: "<S",  with: "")

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

    /// Like `strippingBibleMarkup()` but **skips the final whitespace trim**.
    ///
    /// Use this when processing one KJV text chunk at a time (e.g. the per-segment
    /// loop in `highlightedVerseText`). The KJV source encodes inter-word spacing as
    /// a *leading* space on each segment (e.g. `"lodged<S>3885</S> round<S>…`).
    /// Calling the trimming variant per-segment strips those leading spaces, so words
    /// run together when the segments are concatenated: "lodgedround aboutthe…".
    /// Keeping the spaces preserves natural word separation.
    ///
    /// Callers that process a whole verse (cross-refs, search snippets) should
    /// continue using `strippingBibleMarkup()` which trims the final result.
    func strippingBibleMarkupKeepingSpaces() -> String {
        var s = self

        s = s.replacingOccurrences(of: #"<S>\d+[a-z]?</S>"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"<S>\d+[a-z]?"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\d+[a-z]?</S>"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"S>\d*[a-z]?"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "</S", with: "")
        s = s.replacingOccurrences(of: "<S",  with: "")

        s = s.replacingOccurrences(of: #"<n>(.*?)</n>"#,
                                   with: "($1)",
                                   options: .regularExpression)

        s = s.replacingOccurrences(of: #"<(br|pb)\s*/>"#,
                                   with: " ",
                                   options: [.regularExpression, .caseInsensitive])

        s = s.replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "",
                                   options: .regularExpression)

        s = s.replacingOccurrences(of: #" {2,}"#,
                                   with: " ",
                                   options: .regularExpression)

        // No trimmingCharacters — leading/trailing spaces are word separators
        // and must be preserved when segments are concatenated by the caller.
        return s
    }
}
