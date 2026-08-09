// String+BibleMarkup.swift
// SourceBible
//
// Зняття розмітки над ФРАГМЕНТАМИ вірша. Не над віршем.
//
// ⛔ ПРАВИЛО (ADR-034, чинне з 2026-08-07) — протилежне до того, що стояло тут раніше:
//
//     Плоский текст ЦІЛОГО вірша для показу береться з колонки `verse.text_clean`.
//     У рантаймі розмітка з вірша НЕ знімається.
//
// Стара редакція цієї шапки казала «any place that needs display-ready verse text calls
// .strippingBibleMarkup()». Саме та функція й видалена: вона була другою реалізацією
// правил поряд з `build_db.py::_search_text()`, копії роками розходились, і на 2026-08-07
// заміряно 261 вірш, що просочував СЛОВО з багатономерного тега, і 1 330 — маркер `[2]`.
// Биті були концорданс, крос-рефи, паралельні й сніпет пошуку; рідер лишався правильним,
// бо йде через `VerseParser`, — тому дефект і прожив місяці непоміченим.
//
// Що лишилось у цьому файлі й чому саме воно:
//   • strippingBibleMarkupKeepingSpaces() — працює над СЕГМЕНТАМИ `VerseParser`, а не над
//     віршем, тож колонкою не замінюється. Єдиний виклик — WordTabContent.
//   • strippingFootnoteHTML()             — тіла приміток із таблиці `footnote` — це HTML,
//     а не розмітка вірша; колонки для них немає.
//
// Місця, яким потрібна структура токенів/сегментів, як і раніше йдуть у VerseParser.parse().

import Foundation

extension String {

    // ⛔ `strippingBibleMarkup()` ВИДАЛЕНО (ADR-034) — цілий вірш для показу більше не
    // очищається в рантаймі. Його чотири виклики (концорданс, крос-рефи, паралельні,
    // сніпет пошуку) читають `verse.text_clean` із бази.
    //
    // Не повертати як «зручний хелпер»: саме зручність зробила з нього другу реалізацію
    // правил розмітки, яка розійшлася з `build_db.py::_search_text()` (261 вірш просочував
    // слово, 1 330 — маркер виноски `[2]`).
    //
    // Нижче лишилась ОДНА функція, і лишилась вона не з інерції: вона працює над
    // ФРАГМЕНТАМИ вірша (сегментами `VerseParser`), а не над віршем, тож колонкою не
    // замінюється. Єдиний виклик — `WordTabContent.highlightedVerseText`.

    /// Тіло правил зняття розмітки. Обгортка наразі ОДНА —
    /// `strippingBibleMarkupKeepingSpaces()`.
    ///
    /// ⛔ Тримається окремо від обгортки навмисно, хоч виклик і один. Тут раніше було ДВІ
    /// копії цих правил, і саме дублювання розвело Swift із `build_db.py::_search_text()`
    /// на місяці: заміряно 2026-08-07 — 261 вірш просочував СЛОВО в концорданс, крос-рефи
    /// й паралельні, 761 — кому з цифрами. Наступна обгортка (якщо колись знадобиться)
    /// має викликати це тіло, а не переписувати правила поруч.
    ///
    /// Tag rules:
    ///   `<S>…</S>`       — Strong's         → removed entirely, tag AND content
    ///   `<f>…</f>`       — footnote anchor  → removed (the note lives in the `footnote`
    ///                                        table; the reader draws a † for it instead)
    ///   `<n>text</n>`    — translator note  → content kept as (text)
    ///   `<i>…</i>`       — italics          → tags removed, text kept
    ///   `<br/>` `<pb/>`  — line breaks      → replaced with a single space
    ///   all other tags                      → tags stripped, inner content kept
    private func strippingBibleMarkupCore() -> String {
        var s = self

        // 1. Strong's: the WHOLE element goes, whatever its content.
        //
        //    ⛔ `[^<]*`, NOT `\d+[a-z]?`. The narrow numeric form was correct for the
        //    documented shape and wrong for the shipped data: ASV/NASB carry 834
        //    multi-number tags and 281 with a WORD inside —
        //        <S>1487, 3361</S>   <S>8147, Joshua82</S>   <S>3739, Leviticus2</S>
        //    Unmatched here, they fell through to the generic tag strip at step 4, which
        //    removes only the angle brackets. The orphan rules below then ate the digits
        //    and left the rest as text, so a concordance row read
        //        "Thy two breasts are like two, Joshua fawns…"
        //    `VerseParser` was never affected — it buffers the element's content and splits
        //    it on commas — which is why this survived: the READER looked correct, and only
        //    concordance, cross-references, parallel translations and search snippets (the
        //    four `stripBibleMarkup` call sites) showed it.
        s = s.replacingOccurrences(of: #"<S>[^<]*</S>"#,
                                   with: "",
                                   options: .regularExpression)

        //    FTS5 snippet() cuts at token boundaries, which may fall *inside* an element.
        //    That produces partial-tag forms the complete-tag pattern cannot match:
        //
        //      Open orphan:    <S>1818      → ""   (close tag beyond the window)
        //      Close orphan:   1818</S>     → ""   (open tag before the window)
        //      '<' orphan:     S>1818       → ""   ('< ' was replaced by an ellipsis)
        //      '</' orphan:    S>           → ""   ('</' replaced, no digits follow)
        //
        //    The last two both start with "S>" and differ only in whether digits follow,
        //    so \d* (zero-or-more) covers them in one pass.
        s = s.replacingOccurrences(of: #"<S>[^<]*"#,          // orphaned open tag
                                   with: "",
                                   options: .regularExpression)
        //    ⛔ The close orphan stays anchored on a DIGIT and bounded to 24 characters.
        //    A tempting `[^<]*</S>` would match from the start of the string — the regex
        //    engine takes the leftmost match — and delete real words that merely happen to
        //    precede an orphan `</S>`. Deleting scripture to tidy a tag is the worse bug.
        //    Longest content observed in the corpus is 14 chars ("8147, Joshua82"), so 24
        //    covers the data with room to spare. Residual gap, deliberately left: an orphan
        //    whose visible remainder starts with a letter (", Leviticus2</S>") is not
        //    matched — reachable only via `snippet()`, and `searchByText` uses
        //    `highlight()`, which returns the whole column.
        s = s.replacingOccurrences(of: #"[0-9][^<]{0,24}</S>"#,   // orphaned close tag
                                   with: "",
                                   options: .regularExpression)
        // 1b. Partial-tag stubs where the snippet window cuts *before* '>'.
        //     The patterns above handle every case where '>' is present.
        //     These two catch the remaining stubs that end mid-tag:
        //       "covenant</S…"  → close-tag stub ('>' cut)
        //       "flesh<S…"      → open-tag stub  ('>', digits, and close-tag all cut)
        s = s.replacingOccurrences(of: "</S", with: "")
        s = s.replacingOccurrences(of: "<S",  with: "")

        // 2. Footnote anchors: <f>[2]</f> → "" (anchor + marker).
        //    Mirrors `_SEARCH_FOOTNOTE_RE` in build_db.py. Without this the generic strip at
        //    step 4 left a literal "[2]" mid-sentence — UBIO 1 329 anchors, RST 100.
        //    ⛔ Must run BEFORE the <n> rule and must not be merged with it: `<f>` content is
        //    a marker to discard, `<n>` content is real verse text to keep.
        s = s.replacingOccurrences(of: #"<f>[^<]*</f>"#,
                                   with: "",
                                   options: .regularExpression)

        // 3. Translator notes: <n>content</n> → (content)
        s = s.replacingOccurrences(of: #"<n>(.*?)</n>"#,
                                   with: "($1)",
                                   options: .regularExpression)

        // 4. Void elements: <br/> <pb/> → space
        s = s.replacingOccurrences(of: #"<(br|pb)\s*/>"#,
                                   with: " ",
                                   options: [.regularExpression, .caseInsensitive])

        // 5. All remaining tags → strip, keep content
        s = s.replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "",
                                   options: .regularExpression)

        // 5b. `S>` debris — the '<' or '</' half was eaten by an ellipsis.
        //
        //     ⛔ MUST run AFTER the generic tag strip above, not before it. Running it first
        //     was a real bug (2 of the 3 remaining Python↔Swift divergences, ADR-034): NASB
        //     ships doubled closing tags — `demon<S>1140-</S></S> possessed` — and this
        //     pattern matched the `S>` inside a legitimate `</S>`, leaving `</`, which is not
        //     a tag any more and therefore survived every later rule:
        //         "…the sayings of one demon</ possessed."
        //     After the generic strip, whole tags are already gone and only true debris is
        //     left, so the pattern can only hit what it is meant for.
        s = s.replacingOccurrences(of: #"S>\d*[a-z]?"#,
                                   with: "",
                                   options: .regularExpression)

        // 6. Collapse runs of spaces left by removed tags, and the ", ," / " ," debris a
        //    removed multi-number tag leaves behind mid-sentence.
        s = s.replacingOccurrences(of: #"\s+([,;.!?])"#,
                                   with: "$1",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #" {2,}"#,
                                   with: " ",
                                   options: .regularExpression)

        return s
    }

    /// Plain text of a translator footnote from the `footnote` table.
    ///
    /// Separate from `strippingBibleMarkup()` on purpose: footnote bodies are HTML, not verse
    /// markup. Measured on the bundled data (2026-08-07): every UBIO note is wrapped in
    /// `<span class="reference-text">`, 194 of them carry `<a class='B' href='B:20 25:1'>`
    /// cross-reference links (287 in total), and RST notes use `<b>` to lead with the word
    /// being explained.
    ///
    /// Tags go, content stays — the link TEXT is a readable reference ("2М. 25") and must
    /// survive even though the href does nothing yet. Wiring those 287 links into
    /// `AppNavigationRouter` needs a MyBible-book-number → OSIS mapping and is deliberately
    /// left for later; dropping the text now would make the notes read as if words were
    /// missing.
    ///
    /// `&`-entities are decoded last, after tag removal, so an escaped `&lt;b&gt;` in the
    /// source cannot turn into a tag that then gets stripped.
    func strippingFootnoteHTML() -> String {
        var s = self

        // <br> inside a note is a real line break in a two-part gloss.
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        for (entity, char) in [("&nbsp;", "\u{00A0}"), ("&amp;", "&"), ("&quot;", "\""),
                               ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }

        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Знімає розмітку з ОДНОГО сегмента вірша, **без фінального тримінгу пробілів**.
    ///
    /// Для посегментного циклу в `highlightedVerseText`. Джерело кодує міжслівний пробіл
    /// як *провідний* пробіл сегмента (`"lodged<S>3885</S> round<S>…`), тож тримінг на
    /// кожному сегменті склеїв би слова при конкатенації: "lodgedround aboutthe…".
    ///
    /// ⛔ Для цілого вірша цієї функції НЕ існує — і не заводити. Плоский текст вірша
    /// читається з `verse.text_clean` (ADR-034). Це не «поки не написали», а рішення:
    /// друга реалізація правил уже одного разу розійшлася з `build_db.py`.
    ///
    /// Відома межа посегментного шляху: крок 6 у `strippingBibleMarkupCore()` прибирає
    /// пробіл перед розділовим знаком, але бачить лише свій сегмент. Якщо пробіл лишився
    /// у кінці одного сегмента, а кома відкриває наступний, вони не схлопнуться — на
    /// відміну від `text_clean`, який обробляє вірш цілим. Лишено свідомо: альтернатива
    /// (зшивати сегменти перед очищенням) повертає роботу з цілим віршем у рантайм, тобто
    /// саме те, що ADR-034 прибрав.
    func strippingBibleMarkupKeepingSpaces() -> String {
        // Same rules, no trim — leading/trailing spaces are word separators and must survive
        // when the caller concatenates per-segment results.
        //
        // ⛔ Do not re-inline the rule list here. This function used to hold a second copy of
        // it, the two copies drifted, and the multi-number `<S>` defect had to be fixed in
        // both places at once (2026-08-07).
        strippingBibleMarkupCore()
    }
}
