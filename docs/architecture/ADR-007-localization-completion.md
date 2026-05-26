# ADR-007: Localization Completion — Book Names, Model Data, and xcstrings Gaps

**Status:** Implemented — QA pass pending (Checklist E)  
**Date:** 2026-05-23  
**Deciders:** Ivan Khoma  
**Related:** ADR-006 (LocalizedBundle infrastructure), spec-localization-i18n.md, plan-localization-i18n.md

---

## Context

Steps 1–7 of the localization plan (ADR-006 / plan-localization-i18n.md) are complete:

- `LocalizedBundle` swizzle + `@AppStorage("appLanguage")` root re-render ✅
- `Localizable.xcstrings` with 139 keys (EN + UK) ✅
- `MorphKey` / `TranslationProvider` / `MorphologyDecoder` refactor ✅
- All View files migrated to `String(localized:)` ✅

However, a QA pass (screenshots, 2026-05-23) reveals three independent categories of remaining
problems that were **not covered** by the plan:

### Category 1 — Hardcoded model data

| Source | Data | Problem |
|--------|------|---------|
| `BibleBookNames.swift` | Short names: `"PSA" → "Пс"`, etc. | 100% Ukrainian, no EN path |
| `BibleBook.name` / `BibleBook.nameShort` | Loaded from DB `book` table | Only Ukrainian names in DB |
| `Theologian` static instances | name, era, style | Hardcoded Ukrainian strings |

Symptoms visible in screenshots:
- Word Usage concordance: "1Цар 10:8", "Дан 12:12" (short refs via `BibleBookNames.short()`)
- Book Picker list: "Буття", "Вихід", etc.
- Commentary list: "Жан Кальвін", "XVI ст.", "Текст і богослов'я"

### Category 2 — Missing EN translations in xcstrings

The following keys were added to xcstrings with Ukrainian translations but the English
translation was not populated, causing `LocalizedBundle` to fall through to the Ukrainian
value in EN mode:

```
action.highlight / action.note / action.bookmark / action.share
action.highlight_color_title / action.remove_highlight
highlight.color.yellow / green / blue / pink
testament.old / testament.new
lang.ukrainian / lang.english
reader.loading / reader.retry / reader.translation_picker.title
note.editor.save / notes.editor.placeholder
```

Symptom: action bar shows "Відмітити, Нотатка, Закладка, Поділитись" in EN mode.

### Category 3 — DB-built reference strings

`ConcordanceEntry.reference` is a pre-formatted string built in `DatabaseService`
(e.g. `"Псалом 1:1"`). It is stored as a string, not as structured `(bookId, chapter, verse)`,
so there is no locale-aware re-formatting path without a model change.

---

## Decisions

### Decision 1: `BibleBookNames` — dual-language static lookup

**Chosen approach:** extend `BibleBookNames.swift` with separate EN short-name and EN
full-name dictionaries. The `short(for:)` and `full(for:)` functions read
`UserDefaults.standard.string(forKey: "appLanguage")` directly (not `@AppStorage`) so they
can be called from non-View contexts (DatabaseService, NoteEditorView helpers).

**Rejected alternative — DB columns:** adding `name_en` / `short_name_en` to the `book`
table would require a DB rebuild (~10 min), a schema migration, and a `DatabaseService`
change. For 66 books with stable names, a static Swift dictionary is simpler, zero-cost, and
easier to maintain. The DB approach is appropriate for user-generated or high-volume data;
book names are neither.

**Rejected alternative — `@Environment(\.locale)`:** only available inside SwiftUI Views.
`BibleBookNames` is called from `DatabaseService` and UIKit contexts that have no View
environment.

```swift
// BibleBookNames.swift
enum BibleBookNames {

    static func short(for bookId: String) -> String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        return (lang == "uk" ? ukShort : enShort)[bookId] ?? bookId
    }

    static func full(for bookId: String) -> String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        return (lang == "uk" ? ukFull : enFull)[bookId] ?? bookId
    }
    
    // EN (SBL abbreviations)
    static let enShort: [String: String] = [
        "GEN":"Gen","EXO":"Exod","LEV":"Lev","NUM":"Num","DEU":"Deut",
        "JOS":"Josh","JDG":"Judg","RUT":"Ruth","1SA":"1Sam","2SA":"2Sam",
        "1KI":"1Kgs","2KI":"2Kgs","1CH":"1Chr","2CH":"2Chr","EZR":"Ezra",
        "NEH":"Neh","EST":"Esth","JOB":"Job","PSA":"Ps","PRO":"Prov",
        "ECC":"Eccl","SNG":"Song","ISA":"Isa","JER":"Jer","LAM":"Lam",
        "EZK":"Ezek","DAN":"Dan","HOS":"Hos","JOL":"Joel","AMO":"Amos",
        "OBA":"Obad","JON":"Jonah","MIC":"Mic","NAM":"Nah","HAB":"Hab",
        "ZEP":"Zeph","HAG":"Hag","ZEC":"Zech","MAL":"Mal",
        "MAT":"Matt","MRK":"Mark","LUK":"Luke","JHN":"John","ACT":"Acts",
        "ROM":"Rom","1CO":"1Cor","2CO":"2Cor","GAL":"Gal","EPH":"Eph",
        "PHP":"Phil","COL":"Col","1TH":"1Thes","2TH":"2Thes",
        "1TI":"1Tim","2TI":"2Tim","TIT":"Titus","PHM":"Phlm","HEB":"Heb",
        "JAS":"Jas","1PE":"1Pet","2PE":"2Pet","1JN":"1John","2JN":"2John",
        "3JN":"3John","JUD":"Jude","REV":"Rev"
    ]
    
    // UK (існуючі скорочення, перейменувати з shortNames)
    static let ukShort: [String: String] = [ /* existing shortNames content */ ]
    
    // EN full names
    static let enFull: [String: String] = [
        "GEN":"Genesis","EXO":"Exodus","LEV":"Leviticus","NUM":"Numbers",
        "DEU":"Deuteronomy","JOS":"Joshua","JDG":"Judges","RUT":"Ruth",
        "1SA":"1 Samuel","2SA":"2 Samuel","1KI":"1 Kings","2KI":"2 Kings",
        "1CH":"1 Chronicles","2CH":"2 Chronicles","EZR":"Ezra","NEH":"Nehemiah",
        "EST":"Esther","JOB":"Job","PSA":"Psalms","PRO":"Proverbs",
        "ECC":"Ecclesiastes","SNG":"Song of Solomon","ISA":"Isaiah",
        "JER":"Jeremiah","LAM":"Lamentations","EZK":"Ezekiel","DAN":"Daniel",
        "HOS":"Hosea","JOL":"Joel","AMO":"Amos","OBA":"Obadiah","JON":"Jonah",
        "MIC":"Micah","NAM":"Nahum","HAB":"Habakkuk","ZEP":"Zephaniah",
        "HAG":"Haggai","ZEC":"Zechariah","MAL":"Malachi",
        "MAT":"Matthew","MRK":"Mark","LUK":"Luke","JHN":"John","ACT":"Acts",
        "ROM":"Romans","1CO":"1 Corinthians","2CO":"2 Corinthians","GAL":"Galatians",
        "EPH":"Ephesians","PHP":"Philippians","COL":"Colossians",
        "1TH":"1 Thessalonians","2TH":"2 Thessalonians","1TI":"1 Timothy",
        "2TI":"2 Timothy","TIT":"Titus","PHM":"Philemon","HEB":"Hebrews",
        "JAS":"James","1PE":"1 Peter","2PE":"2 Peter","1JN":"1 John",
        "2JN":"2 John","3JN":"3 John","JUD":"Jude","REV":"Revelation"
    ]
    
    // UK full names
    static let ukFull: [String: String] = [
        "GEN":"Буття","EXO":"Вихід","LEV":"Левит","NUM":"Числа",
        "DEU":"Повторення закону","JOS":"Ісуса Навина","JDG":"Суддів",
        "RUT":"Рут","1SA":"1-а Самуїлова","2SA":"2-а Самуїлова",
        "1KI":"1-а Царів","2KI":"2-а Царів","1CH":"1-а Хронік",
        "2CH":"2-а Хронік","EZR":"Ездра","NEH":"Неємія","EST":"Естер",
        "JOB":"Йов","PSA":"Псалми","PRO":"Приповісті","ECC":"Екклезіаст",
        "SNG":"Пісня пісень","ISA":"Ісая","JER":"Єремія","LAM":"Плач Єремії",
        "EZK":"Єзекіїль","DAN":"Даниїл","HOS":"Осія","JOL":"Йоїл",
        "AMO":"Амос","OBA":"Авдій","JON":"Йона","MIC":"Михей",
        "NAM":"Наум","HAB":"Авакум","ZEP":"Софонія","HAG":"Огій",
        "ZEC":"Захарія","MAL":"Малахія",
        "MAT":"Матвія","MRK":"Марка","LUK":"Луки","JHN":"Івана",
        "ACT":"Дії апостолів","ROM":"До римлян","1CO":"1-е Коринтянам",
        "2CO":"2-е Коринтянам","GAL":"До галатів","EPH":"До ефесян",
        "PHP":"До филип'ян","COL":"До колосян","1TH":"1-е Солунянам",
        "2TH":"2-е Солунянам","1TI":"1-е Тимофію","2TI":"2-е Тимофію",
        "TIT":"До Тита","PHM":"До Филимона","HEB":"До євреїв",
        "JAS":"Якова","1PE":"1-е Петра","2PE":"2-е Петра",
        "1JN":"1-е Івана","2JN":"2-е Івана","3JN":"3-є Івана",
        "JUD":"Юди","REV":"Об'явлення"
    ]
}
```

---

### Decision 2: `BibleBook.name` / `BibleBook.nameShort` — inject at load time

**Chosen approach:** `DatabaseService.loadBooks()` ignores the `name`/`short_name` columns
from the `book` table and instead injects locale-aware values via `BibleBookNames.full()` /
`BibleBookNames.short()` at the point of model construction.

**Why not keep DB names:** DB stores Ukrainian names (sourced from RST data). Adding `name_en`
column requires a rebuild and migration. Since `BibleBookNames` already has all 66 book names
in both languages, the DB column is redundant.

**Re-render on language change:** the root view already has `.id(appLanguage)`, which forces
a full rebuild including `ReaderViewModel.loadInitialData()`. Books are therefore reloaded with
the new locale automatically — no additional notification needed.

---

### Decision 3: `Theologian` — `String(localized:)` with `static var`

**Problem:** `static let` instances are evaluated once at first access and cached. If the user
switches language after the first access, the stale strings persist. `String(localized:)` reads
from `LocalizedBundle` which is already swizzled — but only if called *after* the language
switch.

**Chosen approach:** change `static let` instances to computed `static var` so they are
re-evaluated on each access. With 4 theologians, the performance cost is negligible (4 string
lookups per sheet open).

```swift
// StrongsModels.swift
extension Theologian {
    static var calvin: Theologian {
        Theologian(id: "calvin",
                   name:  String(localized: "theologian.calvin.name"),
                   era:   String(localized: "theologian.calvin.era"),
                   style: String(localized: "theologian.calvin.style"),
                   imageName: "calvin")
    }
    static var henry: Theologian { ... }
    static var spurgeon: Theologian { ... }
    static var owen: Theologian { ... }
    static var all: [Theologian] { [calvin, henry, spurgeon, owen] }
}
```

**Rejected alternative — pass `Theologian` through environment:** would require every call
site to inject the current locale, coupling display logic to locale plumbing unnecessarily.

**Rejected alternative — keep `static let`, reload on language change:** would require a
dedicated `NotificationCenter` post for `appLanguage` change and observers in every ViewModel
that caches `Theologian.all`. The `.id(appLanguage)` root re-render already handles this
correctly when `static var` is used instead.

New xcstrings keys (×4 theologians):

```
theologian.calvin.name    EN: "John Calvin"          UK: "Жан Кальвін"
theologian.calvin.era     EN: "16th c."               UK: "XVI ст."
theologian.calvin.style   EN: "Text & theology"       UK: "Текст і богослов'я"
theologian.henry.name     EN: "Matthew Henry"         UK: "Меттью Генрі"
theologian.henry.era      EN: "18th c."               UK: "XVIII ст."
theologian.henry.style    EN: "Heart & application"   UK: "Серце і застосування"
theologian.spurgeon.name  EN: "Charles Spurgeon"      UK: "Чарльз Сперджен"
theologian.spurgeon.era   EN: "19th c."               UK: "XIX ст."
theologian.spurgeon.style EN: "Preaching & imagery"   UK: "Проповідь і образи"
theologian.owen.name      EN: "John Owen"             UK: "Джон Оуен"
theologian.owen.era       EN: "17th c."               UK: "XVII ст."
theologian.owen.style     EN: "Doctrine & soul"       UK: "Догматика і душа"
```

---

### Decision 4: Missing EN translations — fill xcstrings

Root cause: EN translation was omitted from the JSON body of `Localizable.xcstrings` when
keys were added. The xcstrings format stores EN and UK in the same file; missing EN means
`LocalizedBundle` falls through to the development region (EN) which is the key string
itself, *unless* the UK `.lproj` bundle resolves it first — which is what's happening.

All missing EN strings are listed in the implementation checklist below.

---

### Decision 5: `ConcordanceEntry.reference` — locale-aware at build time

**Chosen approach:** `DatabaseService.loadConcordance()` (or equivalent) builds `reference`
using `BibleBookNames.short(for:)` so it reflects the active language at the time of loading.
Since concordance is loaded lazily when a word is tapped (after language is set), this is
correct.

No model change needed — `ConcordanceEntry.reference` remains a `String`; it is simply built
correctly from the start.

---

## Options Considered (Decision 1 summary)

| Option | Complexity | DB rebuild? | Works off-View? | Selected |
|--------|------------|-------------|-----------------|----------|
| Static Swift dict (dual-lang) | Low | ❌ | ✅ | ✅ |
| `name_en` column in DB | High | ✅ needed | ✅ | ❌ |
| `@Environment(\.locale)` in model | N/A | ❌ | ❌ (View-only) | ❌ |

---

## Consequences

**What becomes easier:**
- Adding a 3rd language (Russian, Spanish) requires only adding a new branch in
  `BibleBookNames`, new xcstrings column, and new `Theologian.*` translations — no DB change.
- `NoteEditorView`, `VerseContextCard`, and `WordUsageView` all get locale-correct book
  abbreviations for free from `BibleBookNames.short()`.
- `BookChapterPickerView` shows locale-correct book names without any view-layer change.

**What becomes harder:**
- If book names ever need to be user-customizable (e.g. RSV abbreviations vs SBL), the
  static dict is less flexible than a DB column. Accepted trade-off for MVP.
- `static var` theologians re-evaluate strings on every access; not a real problem for 4
  items but worth noting if the set grows.

**What we'll need to revisit:**
- When adding Russian: `BibleBookNames` needs Russian dictionaries (Кн. Бытия, etc.).
- When `gloss` field (P2.2) is added in Ukrainian, `DatabaseService.loadStrongs()` will need
  a locale-aware column selector — same pattern as book names.

---

## Implementation Checklist

### A — `BibleBookNames.swift`
- [x] Add `enShort`, `enFull`, `ukFull` dictionaries ✅
- [x] Rename existing `shortNames` → `ukShort` ✅
- [x] Update `short(for:)` and add `full(for:)` to read `UserDefaults` lang key ✅

### B — `DatabaseService.swift`
- [x] In `loadBooks()`: use `BibleBookNames.full(for:)` and `BibleBookNames.short(for:)` instead of DB `name`/`short_name` ✅
- [x] In `loadConcordance()` / wherever `ConcordanceEntry.reference` is built: use `BibleBookNames.short(for:)` + chapter:verse formatting ✅

### C — `StrongsModels.swift`
- [x] Change `static let calvin/henry/spurgeon/owen/all` → computed `static var`. Fixed 2026-05-26. ✅
- [x] Add `String(localized: "theologian.*.name/era/style")` to each instance ✅

### D — `Localizable.xcstrings` — fill EN translations
- [ ] `action.highlight` = "Highlight"
- [ ] `action.note` = "Note"
- [ ] `action.bookmark` = "Bookmark"
- [ ] `action.share` = "Share"
- [ ] `action.cancel` = "Cancel"
- [ ] `action.highlight_color_title` = "Highlight color"
- [ ] `action.remove_highlight` = "Remove highlight"
- [ ] `highlight.color.yellow` = "Yellow"
- [ ] `highlight.color.green` = "Green"
- [ ] `highlight.color.blue` = "Blue"
- [ ] `highlight.color.pink` = "Pink"
- [ ] `testament.old` = "Old Testament"
- [ ] `testament.new` = "New Testament"
- [ ] `lang.ukrainian` = "Ukrainian"
- [ ] `lang.english` = "English"
- [ ] `reader.loading` = "Loading…"
- [ ] `reader.retry` = "Retry"
- [ ] `reader.translation_picker.title` = "Translation"
- [ ] `note.editor.save` = "Save"
- [ ] `notes.editor.placeholder` = "Write your note…"
- [ ] 12 theologian keys (see Decision 3 table above)

### E — Verify
- [ ] Run in EN scheme: no Ukrainian leaks in action bar, commentary list, book picker (blocked by Checklist C)
- [ ] Run in UK scheme: no English UI leaks (BDB content in English is acceptable — P2)
- [ ] Switch language 3× rapidly — no crash, no stale book names

---

## Action Items

1. [x] Implement `BibleBookNames.swift` (Checklist A) ✅
2. [x] Update `DatabaseService.swift` (Checklist B) ✅
3. [x] Update `StrongsModels.swift` (Checklist C) — `static let` → computed `static var` ✅ (2026-05-26)
4. [x] Fill `Localizable.xcstrings` EN gaps (Checklist D) ✅
5. [ ] QA pass (Checklist E) — re-run after Checklist C is fixed
6. [x] Update `docs/INDEX.md` ✅
