# Post-Pull Manual Patches

Changes that exist locally but may not be in the remote branch.
Re-apply these after `git pull` if they get overwritten.

---

## 1. `SourceBible/Services/DatabaseService.swift` — `loadWords()` SQL

**Why:** `xlitSimple` needs a `LEFT JOIN` to `strongs` for `s.xlit_simple` fallback when Macula `xlit` is NULL.

### Current correct code (re-apply if overwritten):

```swift
// word.gloss: short form from Macula TSV english field (e.g. "created", "beginning")
// word.gloss_macula: extended form from Macula XML (e.g. "he.created") — fallback only
// word.xlit: per-occurrence transliteration from Macula (TSV + XML translit attribute).
// s.xlit_simple: TBESH lemma transliteration — fallback when Macula xlit is NULL.
// This ensures every word with a Strong's ID shows some transliteration in WordRow.
let sql = """
    SELECT w.id, w.surface, w.strongs_id, w.morph,
           COALESCE(w.gloss, w.gloss_macula) AS display_gloss,
           w.xlit,
           w.syntax_role, w.greek, w.greek_strong,
           w.after_char, w.lexical_class,
           s.xlit_simple
    FROM word w
    LEFT JOIN strongs s ON s.id = w.strongs_id
    WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
    ORDER BY w.position
    """
query(sql, bindings: [bookId, chapter, verse]) { stmt in
    let id           = string(stmt, 0)
    let surface      = string(stmt, 1)
    let strongsId    = optString(stmt, 2)
    let morph        = optString(stmt, 3)
    let gloss        = optString(stmt, 4)   // Macula contextual gloss
    let xlit         = optString(stmt, 5)   // Macula per-occurrence xlit
    let syntaxRole   = optString(stmt, 6)   // Macula syntactic role
    let greek        = optString(stmt, 7)   // LXX Greek word
    let greekStrong  = optString(stmt, 8)   // LXX Greek Strong's
    let afterChar    = optString(stmt, 9)   // Macula trailing char (maqaf ־, sof pasuq ׃, etc.)
    let lexicalClass = optString(stmt, 10)  // Macula lexical class (noun/verb/ij/intj/…)
    let xlitSimple   = optString(stmt, 11)  // TBESH lemma xlit — fallback when xlit is NULL
    words.append(BibleWord(id: id, text: surface, strongsId: strongsId,
                           morphology: morph, gloss: gloss,
                           xlitSimple: xlitSimple, xlit: xlit,
                           syntaxRole: syntaxRole, greek: greek, greekStrong: greekStrong,
                           afterChar: afterChar, lexicalClass: lexicalClass))
}
```

---

## 2. `SourceBible/Models/StrongsModels.swift` — comment on `transliteration` field

**Why:** Clarifies that `transliteration` duplicates `xlitSimple` and is kept only for
backward compatibility with `headerSection`.

### Find this (old code):

```swift
struct StrongsEntry: Identifiable {
    let id: String
    let originalWord: String
    let transliteration: String
    let xlitSimple: String      // simplified xlit (STEPBible TBESH/TBESG): reshit
```

### Replace with (new code):

```swift
struct StrongsEntry: Identifiable {
    let id: String
    let originalWord: String
    let transliteration: String // same as xlitSimple; kept for fallback in headerSection
    let xlitSimple: String      // simplified xlit (STEPBible TBESH/TBESG): reshit
```

---

## Verification after re-applying

Build and run. Open any verse in the Lexicon tab — every Hebrew word should show a
transliteration (e.g. `reshit`, `hagah`, `yomam`). Before this fix, words without a
Macula occurrence xlit showed nothing.
