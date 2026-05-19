# Implementation Plan: UI Localization (i18n)

**Spec:** `specs/localization-spec.md`  
**Last updated:** 2026-05-23  
**Estimated total:** ~5–7 days

---

## Component Map

```
┌─────────────────────────────────────────────────────────────┐
│                        SourceBibleApp                        │
│  @AppStorage("appLanguage")  ──►  .id(appLanguage) on root  │
└──────────────────────────┬──────────────────────────────────┘
                           │ re-renders on language change
┌──────────────────────────▼──────────────────────────────────┐
│                        ContentView                           │
│  Tab labels: String(localized:)  ◄── LocalizedBundle        │
└──────────────────────────┬──────────────────────────────────┘
                           │
          ┌────────────────┴────────────────┐
          │                                 │
┌─────────▼──────────┐           ┌──────────▼──────────┐
│   All SwiftUI Views│           │  MorphologyDecoder   │
│  String(localized:)│           │  (no string literals)│
│  via LocalizedBundle│          │         │            │
└────────────────────┘           │  TranslationProvider │
                                 │  (protocol)          │
                                 └──────────┬───────────┘
                                            │
                              ┌─────────────▼──────────────┐
                              │   BundleTranslationProvider │ ← MVP
                              │   (reads .xcstrings)        │
                              └─────────────────────────────┘
                              ┌─────────────────────────────┐
                              │   DBTranslationProvider     │ ← Future
                              │   RemoteTranslationProvider │ ← Future
                              └─────────────────────────────┘

Storage layer:
  Localizable.xcstrings
  ├── en  (English — baseline, 100% complete)
  └── uk  (Ukrainian — migration of existing hardcoded strings)
```

---

## Data Flow: Language Switch

```
User taps language in Settings
        │
        ▼
@AppStorage("appLanguage") = "en" | "uk"
        │
        ├── LocalizedBundle.current is updated
        │   (loads correct .lproj at runtime)
        │
        └── SourceBibleApp.body re-renders via .id(appLanguage)
                │
                └── All String(localized:) calls pick up new language
                    immediately — no restart required
```

---

## Implementation Order

Steps are sequenced so each one is independently shippable and testable.
Never break the build between steps.

---

### Step 1 — `LocalizedBundle` infrastructure (2–3h)

**New file:** `SourceBible/Services/LocalizedBundle.swift`

Strategy: **swizzle `Bundle.main`** via `object_setClass` so that `Text("key")`, `String(localized: "key")`, and `NSLocalizedString` all automatically use the override — zero changes needed at call sites. See ADR-001 for why explicit `bundle: .localized` was rejected.

```swift
import Foundation

/// Replaces Bundle.main's runtime class so all localization calls (Text("key"),
/// String(localized:), NSLocalizedString) automatically use the active language
/// without needing an explicit bundle parameter at every call site.
///
/// Activated once at app launch via object_setClass(Bundle.main, LocalizedBundle.self).
/// Language is changed at runtime via LocalizedBundle.activate(language:).
final class LocalizedBundle: Bundle, @unchecked Sendable {

    // MARK: - Language management

    private static var _language: String = "en"
    /// Cache: lang code → lproj Bundle, to avoid Bundle(path:) on every string lookup.
    private static var _bundleCache: [String: Bundle] = [:]

    static func activate(language: String) {
        _language = language
        // Pre-warm cache for the new language
        if _bundleCache[language] == nil,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let b = Bundle(path: path) {
            _bundleCache[language] = b
        }
    }

    // MARK: - Override

    override func localizedString(forKey key: String,
                                  value: String?,
                                  table tableName: String?) -> String {
        // Look up in the active language bundle; fall back to super (which is
        // also Bundle.main, so this returns the development region translation).
        Self._bundleCache[Self._language]?
            .localizedString(forKey: key, value: value, table: tableName)
            ?? super.localizedString(forKey: key, value: value, table: tableName)
    }
}
```

**Wire into `SourceBibleApp.swift`:**

```swift
@main
struct SourceBibleApp: App {
    // NOTE: default = "en" for P0. P1.1 adds system-locale detection.
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    init() {
        // Swizzle Bundle.main BEFORE any view is rendered.
        // After this line, Text("key") and String(localized: "key")
        // both use LocalizedBundle's override automatically.
        object_setClass(Bundle.main, LocalizedBundle.self)
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        LocalizedBundle.activate(language: stored)

        // ... existing store/migration init below ...
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // .id() forces a full view-tree re-render on language change.
                // Trade-off: drops all navigation state (scroll, sheets, stack).
                // Acceptable for a rare Settings action — same behavior as Telegram.
                // See ADR-001 for alternatives considered.
                .id(appLanguage)
                .onChange(of: appLanguage) { _, lang in
                    LocalizedBundle.activate(language: lang)
                }
        }
    }
}
```

**Call sites — no change needed anywhere in the codebase:**
```swift
// All of these automatically use the active language after swizzling:
Text("tab.bible")                        // ✅ LocalizedStringKey → Bundle.main (swizzled)
String(localized: "word.tab.meaning")   // ✅ hits Bundle.main (swizzled)
NSLocalizedString("key", comment: "")   // ✅ also Bundle.main
```

**Verify:** app builds and runs. No visible change yet — strings still hardcoded.

---

### Step 2 — `Localizable.xcstrings` + `Info.plist` (1–2h)

1. In Xcode: **File → New → File → String Catalog** → name it `Localizable`.  
   This creates `SourceBible/Localizable.xcstrings`.

2. In `Info.plist`, add:
   ```xml
   <key>CFBundleLocalizations</key>
   <array>
       <string>en</string>
       <string>uk</string>
   </array>
   <key>CFBundleDevelopmentRegion</key>
   <string>en</string>
   ```

3. Verify `en.lproj/Localizable.strings` and `uk.lproj/Localizable.strings`
   are generated when building (Xcode derives them from `.xcstrings`).

**Verify:** build succeeds, zero warnings about missing localizations.

---

### Step 3 — `MorphKey` + `TranslationProvider` (3–4h)

**New file:** `SourceBible/Services/Localization/MorphKey.swift`

```swift
/// Semantic keys for all morphology labels.
/// MorphologyDecoder uses ONLY these constants — never string literals.
enum MorphKey {

    // MARK: Parts of speech
    static let posVerb          = "morph.pos.verb"
    static let posNoun          = "morph.pos.noun"
    static let posAdjective     = "morph.pos.adjective"
    static let posPronoun       = "morph.pos.pronoun"
    static let posPreposition   = "morph.pos.preposition"
    static let posConjunction   = "morph.pos.conjunction"
    static let posAdverb        = "morph.pos.adverb"
    static let posParticle      = "morph.pos.particle"
    static let posInterjection  = "morph.pos.interjection"
    static let posPronSuffix    = "morph.pos.pronominal_suffix"
    static let posDirObjSuffix  = "morph.pos.direct_object_suffix"
    static let posSuffix        = "morph.pos.suffix"
    static let posArticle       = "morph.pos.article"
    static let posRelPronoun    = "morph.pos.relative_pronoun"
    static let posNegParticle   = "morph.pos.negative_particle"
    static let posInterrogative = "morph.pos.interrogative"

    // MARK: Hebrew verbal stems (Binyanim)
    static let stemQal          = "morph.stem.qal"
    static let stemNiphal       = "morph.stem.niphal"
    static let stemPiel         = "morph.stem.piel"
    static let stemPual         = "morph.stem.pual"
    static let stemHiphil       = "morph.stem.hiphil"
    static let stemHophal       = "morph.stem.hophal"
    static let stemHithpael     = "morph.stem.hithpael"
    static let stemPoel         = "morph.stem.poel"

    // MARK: Hebrew verbal aspects / forms
    static let aspectPerfect         = "morph.aspect.perfect"
    static let aspectImperfect       = "morph.aspect.imperfect"
    static let aspectWayyiqtol       = "morph.aspect.wayyiqtol"
    static let aspectJussive         = "morph.aspect.jussive"
    static let aspectCohortative     = "morph.aspect.cohortative"
    static let aspectImperative      = "morph.aspect.imperative"
    static let aspectPartActiveHeb   = "morph.aspect.participle_active"
    static let aspectPartPassiveHeb  = "morph.aspect.participle_passive"
    static let aspectInfAbsolute     = "morph.aspect.infinitive_absolute"
    static let aspectInfConstruct    = "morph.aspect.infinitive_construct"

    // MARK: Person
    static let person1          = "morph.person.1"
    static let person2          = "morph.person.2"
    static let person3          = "morph.person.3"

    // MARK: Gender
    static let genderMasculine  = "morph.gender.masculine"
    static let genderFeminine   = "morph.gender.feminine"
    static let genderCommon     = "morph.gender.common"

    // MARK: Number
    static let numberSingular   = "morph.number.singular"
    static let numberPlural     = "morph.number.plural"
    static let numberDual       = "morph.number.dual"

    // MARK: State (Hebrew nouns)
    static let stateAbsolute    = "morph.state.absolute"
    static let stateConstruct   = "morph.state.construct"
    static let stateDetermined  = "morph.state.determined"

    // MARK: Section labels (WordMeaningView)
    static let sectionMorphology    = "morph.section.morphology"
    static let sectionLexical       = "morph.section.lexical"
    static let sectionFormInContext  = "morph.section.form_in_context"  // uses %@ for ref
    static let sectionGreekEquiv    = "morph.section.greek_equivalent"
    static let rowPartOfSpeech      = "morph.row.part_of_speech"
    static let rowStem              = "morph.row.stem"
    static let rowAspect            = "morph.row.aspect"
    static let rowGrammaticalForm   = "morph.row.grammatical_form"
    static let rowSyntaxRole        = "morph.row.syntax_role"
    static let rowWord              = "morph.row.word"
    static let rowTransliteration   = "morph.row.transliteration"
    static let rowStrongs           = "morph.row.strongs"

    // MARK: Syntax roles
    static let syntaxPredicate      = "morph.syntax.predicate"
    static let syntaxPredicateNom   = "morph.syntax.predicate_nominal"
    static let syntaxSubject        = "morph.syntax.subject"
    static let syntaxObject         = "morph.syntax.object"
    static let syntaxCircumstance   = "morph.syntax.circumstance"
    static let syntaxAdverb         = "morph.syntax.adverb"
}
```

**New file:** `SourceBible/Services/Localization/TranslationProvider.swift`

```swift
import Foundation

// MARK: - Protocol

protocol TranslationProvider {
    func string(for key: String) -> String
    /// Variant with format arguments, e.g. "Form in %@" → "Form in Gen 1:1"
    func string(for key: String, _ args: CVarArg...) -> String
}

extension TranslationProvider {
    func string(for key: String, _ args: CVarArg...) -> String {
        String(format: string(for: key), arguments: args)
    }
}

// MARK: - MVP implementation (reads from .xcstrings via LocalizedBundle)

struct BundleTranslationProvider: TranslationProvider {
    func string(for key: String) -> String {
        Bundle.localized.localizedString(forKey: key, value: key, table: nil)
        // Falls back to the key itself if translation is missing —
        // visible in UI during development, never an empty string.
    }
}

// MARK: - Test stub

#if DEBUG
struct MockTranslationProvider: TranslationProvider {
    /// Returns the key as-is so tests assert on semantic keys, not translated text.
    func string(for key: String) -> String { key }
}
#endif
```

**Verify:** files compile, no usages yet. Unit test: `MockTranslationProvider().string(for: MorphKey.posVerb) == "morph.pos.verb"`.

---

### Step 4 — Refactor `MorphologyDecoder` (3–4h)

Replace all string literals in `WordTabContent.swift` — both `decode()` and `decodeFull()` — with `MorphKey` constants resolved through `TranslationProvider`.

**Key change pattern:**

```swift
// BEFORE
case "V": m.partOfSpeech = "Дієслово"
case "q": return "Qal — проста активна"

// AFTER
case "V": m.partOfSpeech = provider.string(for: MorphKey.posVerb)
case "q": return provider.string(for: MorphKey.stemQal)
```

**Updated signatures:**

```swift
enum MorphologyDecoder {
    static func decodeFull(
        _ code: String,
        using provider: TranslationProvider = BundleTranslationProvider()
    ) -> FullMorphology? { ... }

    static func decode(
        _ code: String,
        using provider: TranslationProvider = BundleTranslationProvider()
    ) -> String? { ... }
}
```

Default argument = `BundleTranslationProvider()` → all existing call sites in Views require **zero changes**.

Also migrate in the same pass:
- `WordMeaningView.morphologyRows()` — row label strings like `"Частина мови"`, `"Основа (Біньян)"` → `MorphKey.rowPartOfSpeech`, `MorphKey.rowStem`
- `WordMeaningView.syntaxRoleLabel()` → `MorphKey.syntaxPredicate`, etc.
- `WordMeaningView.sectionLabel()` call sites — `"Морфологія"`, `"Лексичне значення"`, etc. → `MorphKey.sectionMorphology`, etc.

**Verify:** build succeeds. Run in English scheme — morphology shows English. Run in Ukrainian scheme — morphology shows Ukrainian. Compare output to old hardcoded values.

---

### Step 5 — Add morphology keys to `Localizable.xcstrings` (2–3h)

All `MorphKey.*` values need entries in both locales. This is the translation work — ~60 pairs.

**English (`en`):**

```
morph.pos.verb             = "Verb"
morph.pos.noun             = "Noun"
morph.pos.adjective        = "Adjective"
morph.pos.pronoun          = "Pronoun"
morph.pos.preposition      = "Preposition"
morph.pos.conjunction      = "Conjunction"
morph.pos.adverb           = "Adverb"
morph.pos.particle         = "Particle"
morph.pos.interjection     = "Interjection"
morph.pos.pronominal_suffix = "Pronominal suffix"
morph.pos.direct_object_suffix = "Direct object suffix"
morph.pos.suffix           = "Suffix"
morph.pos.article          = "Definite article"
morph.pos.relative_pronoun = "Relative pronoun"
morph.pos.negative_particle = "Negative particle"
morph.pos.interrogative    = "Interrogative particle"

morph.stem.qal       = "Qal — simple active"
morph.stem.niphal    = "Niphal — passive/reflexive"
morph.stem.piel      = "Piel — intensive active"
morph.stem.pual      = "Pual — intensive passive"
morph.stem.hiphil    = "Hiphil — causative active"
morph.stem.hophal    = "Hophal — causative passive"
morph.stem.hithpael  = "Hithpael — reflexive"
morph.stem.poel      = "Poel"

morph.aspect.perfect           = "Perfect (qatal)"
morph.aspect.imperfect         = "Imperfect (yiqtol)"
morph.aspect.wayyiqtol         = "Wayyiqtol (sequential)"
morph.aspect.jussive           = "Jussive"
morph.aspect.cohortative       = "Cohortative"
morph.aspect.imperative        = "Imperative"
morph.aspect.participle_active  = "Participle (active)"
morph.aspect.participle_passive = "Participle (passive)"
morph.aspect.infinitive_absolute  = "Infinitive absolute"
morph.aspect.infinitive_construct = "Infinitive construct"

morph.person.1       = "1st person"
morph.person.2       = "2nd person"
morph.person.3       = "3rd person"

morph.gender.masculine = "masc."
morph.gender.feminine  = "fem."
morph.gender.common    = "com."

morph.number.singular  = "sg."
morph.number.plural    = "pl."
morph.number.dual      = "dual"

morph.state.absolute   = "absolute"
morph.state.construct  = "construct"
morph.state.determined = "determined"

morph.section.morphology        = "Morphology"
morph.section.lexical           = "Lexical meaning"
morph.section.form_in_context   = "Form in %@"
morph.section.greek_equivalent  = "Greek equivalent (LXX)"
morph.row.part_of_speech        = "Part of speech"
morph.row.stem                  = "Stem (Binyan)"
morph.row.aspect                = "Tense / Aspect"
morph.row.grammatical_form      = "Grammatical form"
morph.row.syntax_role           = "Syntactic role"
morph.row.word                  = "Word"
morph.row.transliteration       = "Transliteration"
morph.row.strongs               = "Strong's"

morph.syntax.predicate          = "Predicate"
morph.syntax.predicate_nominal  = "Predicate (nominal)"
morph.syntax.subject            = "Subject"
morph.syntax.object             = "Object"
morph.syntax.circumstance       = "Circumstance"
morph.syntax.adverb             = "Adverb"
```

**Ukrainian (`uk`):** migrate existing hardcoded strings from `decodeFull()` / `decode()` / `syntaxRoleLabel()` / `morphologyRows()` — all already exist in code, just being moved.

```
morph.pos.verb             = "Дієслово"
morph.pos.noun             = "Іменник"
morph.pos.adjective        = "Прикметник"
morph.pos.pronoun          = "Займенник"
morph.pos.preposition      = "Прийменник"
morph.pos.conjunction      = "Сполучник"
morph.pos.adverb           = "Прислівник"
morph.pos.particle         = "Частка"
morph.pos.interjection     = "Вигук"
morph.pos.pronominal_suffix    = "Займенниковий суфікс"
morph.pos.direct_object_suffix = "Прямий об'єкт суфікс"
morph.pos.suffix           = "Суфікс"
morph.pos.article          = "Означений артикль"
morph.pos.relative_pronoun = "Відносний займенник"
morph.pos.negative_particle = "Заперечна частка"
morph.pos.interrogative    = "Питальна частка"

morph.stem.qal       = "Qal — проста активна"
morph.stem.niphal    = "Niphal — пасивна/рефлексивна"
morph.stem.piel      = "Piel — інтенсивна активна"
morph.stem.pual      = "Pual — інтенсивна пасивна"
morph.stem.hiphil    = "Hiphil — каузативна активна"
morph.stem.hophal    = "Hophal — каузативна пасивна"
morph.stem.hithpael  = "Hithpael — рефлексивна"
morph.stem.poel      = "Poel"

morph.aspect.perfect           = "Досконалий (qatal)"
morph.aspect.imperfect         = "Недосконалий (yiqtol)"
morph.aspect.wayyiqtol         = "Wayyiqtol (послідовний)"
morph.aspect.jussive           = "Юссив"
morph.aspect.cohortative       = "Когортатив"
morph.aspect.imperative        = "Імператив"
morph.aspect.participle_active  = "Дієприкметник (активний)"
morph.aspect.participle_passive = "Дієприкметник (пасивний)"
morph.aspect.infinitive_absolute  = "Інфінітив абсолютний"
morph.aspect.infinitive_construct = "Інфінітив конструктус"

morph.person.1       = "1-а особа"
morph.person.2       = "2-а особа"
morph.person.3       = "3-я особа"

morph.gender.masculine = "чол. р."
morph.gender.feminine  = "жін. р."
morph.gender.common    = "заг. р."

morph.number.singular  = "одн."
morph.number.plural    = "мн."
morph.number.dual      = "двоїна"

morph.state.absolute   = "абсолютний"
morph.state.construct  = "конструктус"
morph.state.determined = "визначений"

morph.section.morphology        = "Морфологія"
morph.section.lexical           = "Лексичне значення"
morph.section.form_in_context   = "Форма у %@"
morph.section.greek_equivalent  = "Грецький еквівалент (LXX)"
morph.row.part_of_speech        = "Частина мови"
morph.row.stem                  = "Основа (Біньян)"
morph.row.aspect                = "Час / Вид"
morph.row.grammatical_form      = "Граматична форма"
morph.row.syntax_role           = "Синтаксична роль"
morph.row.word                  = "Слово"
morph.row.transliteration       = "Транслітерація"
morph.row.strongs               = "Strong's"

morph.syntax.predicate          = "Присудок"
morph.syntax.predicate_nominal  = "Присудок (іменний)"
morph.syntax.subject            = "Підмет"
morph.syntax.object             = "Додаток"
morph.syntax.circumstance       = "Обставина"
morph.syntax.adverb             = "Прислівник"
```

**Verify:** switch scheme to `en` → English morphology. Switch to `uk` → Ukrainian. Both Оригінал and Значення pills consistent.

---

### Step 6 — Audit and extract remaining UI strings (1–2 days)

This is the biggest surface area. Files to audit in order of surface-area impact:

| File | Known hardcoded strings | Action |
|---|---|---|
| `ContentView.swift` | "Біблія", "Записи", "Меню", "Пошук" (Tab labels ×2 for iOS<18 path too) | Extract |
| `WordTabContent.swift` | Empty states, `WordSubTab.label`, `WordUsageView` count | Extract |
| `VerseBottomSheetView.swift` | TBD | Audit |
| `VerseTabContent.swift` | TBD | Audit |
| `ReaderView.swift` | TBD | Audit |
| `SearchView.swift` | TBD | Audit |
| `BookmarksListView.swift` / `BookmarkEditorView.swift` | TBD | Audit |
| `NotesListView.swift` / `NoteEditorView.swift` | TBD | Audit |
| `EntriesView.swift` | TBD | Audit |
| `MenuView.swift` | TBD | Audit |
| `BibleBookNames.swift` | Book names | P1.3 — defer |

**Extraction pattern for every string:**

```swift
// BEFORE
Text("Натисніть на слово для вивчення")
Label("Біблія", systemImage: "book.fill")

// AFTER — plain standard syntax, no special bundle parameter needed
Text("reader.word.tap_hint")
Label(String(localized: "tab.bible"), systemImage: "book.fill")
```

Because `Bundle.main` is swizzled at launch (Step 1), all standard localization call forms work correctly with the active language:

```swift
Text("some.key")                      // ✅ LocalizedStringKey → Bundle.main (swizzled)
String(localized: "some.key")         // ✅
NSLocalizedString("some.key", ...)    // ✅
```

No `bundle: .localized` parameter needed anywhere. If you see it in old code, remove it — it's now redundant noise.

**Key naming convention** (from spec appendix, extended):

```
tab.bible / tab.entries / tab.menu / tab.search
reader.word.tap_hint
reader.word.no_data
reader.word.usage_count        // plural: "%lld occurrences in the Bible"
word.tab.meaning / word.tab.usage
settings.language.title
settings.language.english
settings.language.ukrainian
```

---

### Step 7 — Settings: Language Picker (2–4h)

**New file:** `SourceBible/Views/Settings/SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    private let supportedLanguages: [(code: String, label: String)] = [
        ("en", "English"),
        ("uk", "Українська"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "settings.section.language", bundle: .localized)) {
                    Picker(
                        String(localized: "settings.language.title", bundle: .localized),
                        selection: $appLanguage
                    ) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(String(localized: "settings.title", bundle: .localized))
        }
    }
}
```

**Wire into `ContentView.swift`** — add Settings tab (or add to existing Меню tab — TBD per OQ5):

```swift
// Option A: new Settings tab
Tab(String(localized: "tab.settings", bundle: .localized),
    systemImage: "gearshape.fill",
    value: AppTab.settings) {
    SettingsView()
}

// Option B: section inside existing MenuView
// NavigationLink → SettingsView()
```

**Verify:** tapping English → all UI switches to English instantly. Tapping Українська → switches back. Kill app, reopen → language persists.

---

### Step 8 — QA Pass (1 day)

Structured walkthrough — for each language:

**English checklist:**
- [ ] All tab labels in English
- [ ] Оригінал pill: morphology labels in English ("Noun", "Verb · Qal")
- [ ] Значення pill: all section labels, row labels, morphology values in English
- [ ] Empty states in English
- [ ] Search, Bookmarks, Notes views — no Ukrainian leakage
- [ ] BDB definitions — English (expected, P2)
- [ ] `gloss` field — English (expected, P2)

**Ukrainian checklist:**
- [ ] All tab labels in Ukrainian
- [ ] Оригінал pill: morphology labels in Ukrainian ("Іменник", "Дієслово · Qal")
- [ ] Значення pill: all section labels, row labels, morphology values in Ukrainian
- [ ] Empty states in Ukrainian
- [ ] Search, Bookmarks, Notes — no English UI leakage
- [ ] BDB definitions — English (acceptable for MVP, shown as-is)

**Regression:**
- [ ] Language preference survives app kill+restart
- [ ] Switching language 5× rapidly doesn't crash
- [ ] Switching mid-navigation (while a sheet is open) doesn't crash

---

## File Change Summary

| File | Change type | Step |
|---|---|---|
| `SourceBible/Services/LocalizedBundle.swift` | **New** | 1 |
| `SourceBibleApp.swift` | Modify: add `@AppStorage`, `.id()`, `.onChange` | 1 |
| `Localizable.xcstrings` | **New** | 2 |
| `Info.plist` | Modify: add `CFBundleLocalizations` | 2 |
| `SourceBible/Services/Localization/MorphKey.swift` | **New** | 3 |
| `SourceBible/Services/Localization/TranslationProvider.swift` | **New** | 3 |
| `SourceBible/Views/BottomSheet/WordTabContent.swift` | Modify: refactor decoder + section labels | 4 |
| `Localizable.xcstrings` | Populate ~60 morphology keys × 2 locales | 5 |
| All remaining View files (audit) | Modify: extract hardcoded strings | 6 |
| `SourceBible/Views/Settings/SettingsView.swift` | **New** | 7 |
| `ContentView.swift` | Modify: add Settings tab or wire MenuView | 7 |

**New files: 4. Modified files: ~10–15.**

---

## Trade-offs

| Decision | Alternative | Why this choice |
|---|---|---|
| `LocalizedBundle` subclass | `@Environment(\.locale)` + SwiftUI | `@Environment` works for SwiftUI `Text("key")` but not `String(localized:)` in view models or decoders. Subclass covers both. |
| `.id(appLanguage)` on root view | Manual `objectWillChange` notifications | `.id()` is a nuclear re-render — drops all view state. Fine for a language switch (rare action). Avoids complex notification plumbing. |
| Default parameter `BundleTranslationProvider()` in decoder | Inject via `@Environment` | Keeps decoder call sites unchanged. Downside: can't easily inject at call site without modifying callers. Acceptable since decoder is low-level. |
| `MorphKey` as `enum` with static `let` | `enum` with string `rawValue` | Static lets allow arbitrary strings (dotted namespacing). `rawValue` enums must map to their raw value which conflicts with the namespaced key format. |
| Settings as new tab | Settings inside MenuView | TBD (OQ5) — plan reserves both options; decision deferred to product |

---

## What's Not In This Plan (deferred)

- `BibleBookNames.swift` localization → P1.3, separate PR after MVP
- `shortDefinition` / `fullDefinition` Ukrainian → P2.1, content initiative
- `gloss` Ukrainian → P2.2, content initiative
- Remote/DB `TranslationProvider` → future ADR
- Russian / Spanish / German / Polish → reuse infrastructure, future sprints
