# Feature Spec: UI Localization & Internationalization (i18n)

**Status:** Draft  
**Author:** Ivan Khoma  
**Last updated:** 2026-05-23  
**Version:** 0.1

---

## Problem Statement

SourceBible's UI strings are entirely hardcoded in Swift — currently a mix of Ukrainian (`decodeFull()`, section labels, tab names) and English (`decode()` short morphology labels, BDB definitions). There is no localization infrastructure. This blocks the app from reaching non-Ukrainian audiences and creates an inconsistent experience even for Ukrainian users. As the app prepares for multi-market expansion (Russian, Spanish, German, Polish, etc.), every new language without a proper i18n foundation requires a code change rather than a content update.

---

## Goals

1. **G1 — Infrastructure first**: Introduce Apple's `.xcstrings` (String Catalog) system so any future language is a content addition, not a code change.
2. **G2 — English as the default baseline**: All UI strings exist in English; English works 100% without gaps.
3. **G3 — Ukrainian parity**: Ukrainian translation covers 100% of UI strings for MVP.
4. **G4 — Language is user-controlled**: User can select app language in Settings, independent of system locale.
5. **G5 — Morphology consistency**: Both the Оригінал pill and the Значення pill display morphology labels in the active app language (currently they are split: EN in Оригінал, UA in Значення).

---

## Non-Goals

**NG1 — Translating lexical DB content (BDB / Thayer's) for MVP.**  
`shortDefinition`, `fullDefinition`, and the `gloss` field in the `word` table are English source data from STEPBible. Translating ~8,600+ Strong's entries + 450k+ word glosses requires professional biblical-linguistic validation. This is a separate initiative (see P2 below).

**NG2 — RTL language support.**  
Arabic, Hebrew UI (as distinct from displaying Hebrew *text*) is out of scope. RTL layout for UI chrome is not planned in any near-term market.

**NG3 — Translating Bible verse text or cross-references.**  
Verse translations (KJV, RST, etc.) are sourced datasets, not UI strings. Adding new Bible translation datasets is a separate track.

**NG4 — In-app translation / auto-translation via LLM.**  
Per the project's LLM trust policy, lexical definitions require human-authored sources. AI-generated translations of biblical terminology are not acceptable for MVP.

**NG5 — Russian as part of this spec.**  
Russian is listed as a future market. It will use the same infrastructure once it's built, but is explicitly not in this delivery.

---

## Current State Audit

This section captures what actually exists today — critical context for estimation.

### Hardcoded strings (all require extraction)

| Location | Count (approx.) | Language | Notes |
|---|---|---|---|
| `WordTabContent.swift` — `WordMeaningView` section labels | ~10 | Ukrainian | "Морфологія", "Лексичне значення", "Форма у...", "Грецький еквівалент (LXX)", etc. |
| `WordTabContent.swift` — `MorphologyDecoder.decodeFull()` | ~40 | Ukrainian | Part-of-speech, stems, aspects, grammatical forms, all Ukrainian |
| `WordTabContent.swift` — `MorphologyDecoder.decode()` | ~20 | **English** | Short labels in Оригінал pill: "Noun", "Verb · Qal", "Adj.", "Prep.", etc. |
| `WordTabContent.swift` — `WordSubTab.label` | 2 | Ukrainian | "Значення", "Вживання" |
| `WordTabContent.swift` — empty state | 2 | Ukrainian | "Дані мови недоступні...", "Натисніть на слово..." |
| `WordTabContent.swift` — `WordUsageView` | 1 | Ukrainian | "входжень у Біблії" |
| `WordTabContent.swift` — `syntaxRoleLabel()` | ~6 | Ukrainian | "Присудок", "Підмет", "Додаток", etc. |
| Other views (Reader, Search, Bookmarks, Notes, etc.) | TBD | Ukrainian | Full audit needed |

**Total estimate**: ~100–150 hardcoded strings across the app.

### DB content (not extractable to `.strings`)

| Field | Source | Language | Localizable? |
|---|---|---|---|
| `strongs.shortDefinition` | STEPBible TBESH/TBESG | English | P2 — needs translation + human validation |
| `strongs.fullDefinition` | BDB / Abbott-Smith | English | P2 — significant effort, biblical scholarship required |
| `word.gloss` | Macula Hebrew/Greek | English | P2 — 450k rows, but ~few thousand unique values |
| `word.xlit` | Macula | Transliteration (language-neutral) | Not applicable |

### Missing infrastructure
- No `.lproj` directories exist.
- No `Localizable.xcstrings` file.
- No `Bundle.localizations` or `CFBundleLocalizations` in `Info.plist`.
- No language preference stored in `UserDefaults`.

---

## User Stories

**As an English-speaking user**, I want the entire SourceBible UI to appear in English so that I can use the app without encountering Ukrainian text I don't understand.

**As a Ukrainian-speaking user**, I want to switch the app to Ukrainian in Settings so that all labels, morphology terms, and UI chrome appear in my language regardless of my phone's system language.

**As a user studying Hebrew morphology in the Оригінал pill**, I want the morphology label ("Noun", "Verb · Qal") to appear in the same language as the rest of the UI so that the experience is consistent — currently it shows English even when the app is set to Ukrainian.

**As a power user who uses multiple devices**, I want my language preference to persist across app launches so that I don't have to reset it every time.

**As a developer adding a third language later**, I want to add a new `.strings` file without touching Swift code or database schemas so that new markets are additive, not invasive.

---

## Requirements

### P0 — Must-Have (MVP)

**P0.1 — String Catalog infrastructure**  
Introduce `Localizable.xcstrings` (Xcode 15+ String Catalog format). All UI strings extracted from Swift using `String(localized: "key", bundle: .main)` or the `LocalizedStringKey` SwiftUI init. English and Ukrainian locales included from day one.

*Acceptance criteria:*
- [ ] Build succeeds with `SWIFT_STRICT_CONCURRENCY` and no localization warnings.
- [ ] Changing scheme language to "en" shows English throughout; "uk" shows Ukrainian throughout.
- [ ] No hardcoded Ukrainian or English string literals remain in any View or ViewModel.

**P0.2 — MorphologyDecoder: source-agnostic architecture**  
`MorphologyDecoder` is refactored so that it emits **semantic keys** (`MorphKey` constants), never raw translated strings. A `TranslationProvider` protocol defines the interface for resolving keys to human-readable labels. The decoder depends on `TranslationProvider`, not on any specific storage (Swift, DB, remote). For MVP the concrete implementation reads from `.xcstrings` via `Bundle`; future implementations can swap in a DB or remote provider without touching decoder logic. See Architecture Notes below.

*Acceptance criteria:*
- [ ] `MorphologyDecoder` contains zero hardcoded translated strings (no Ukrainian, no English labels).
- [ ] All ~60 morphology keys are defined as constants in `MorphKey` (or equivalent enum/struct).
- [ ] `BundleTranslationProvider` (MVP implementation) resolves all keys from `.xcstrings` for both `en` and `uk`.
- [ ] `decode()` and `decodeFull()` produce correct localized output for both languages.
- [ ] Replacing `BundleTranslationProvider` with a stub in unit tests requires no changes to `MorphologyDecoder`.
- [ ] Both EN and UK translations are complete and reviewed for all ~60 morphology keys.

**P0.3 — Language setting in Settings tab**  
A Settings tab (or Settings section if the tab already exists) contains a "Language" / "Мова" picker with at minimum: English, Українська. Selection is stored in `UserDefaults` and immediately applies to the app without requiring a restart.

*Acceptance criteria:*
- [ ] Language picker shows all supported languages.
- [ ] Selecting a language immediately re-renders the active view in the new language.
- [ ] Selected language persists across app launches.
- [ ] If no language is set, app defaults to system language if supported, otherwise English. The derived default is not persisted — only a manual pick is stored (OQ1 resolved as B; see P1.1).

**P0.4 — English 100% complete**  
Every string in the app has an English translation with no missing keys. English is the fallback language — no string ever falls through to an untranslated key.

*Acceptance criteria:*
- [ ] Zero "missing translation" warnings in Xcode build log for `en` locale.
- [ ] QA pass: complete walk-through of all screens in English with no Ukrainian leakage.

**P0.5 — Ukrainian 100% complete**  
Ukrainian translation covers all strings. Since most strings are currently hardcoded Ukrainian, this is primarily a migration/extraction task.

*Acceptance criteria:*
- [ ] Zero missing keys for `uk` locale.
- [ ] QA pass: complete walk-through in Ukrainian with no English leakage (except BDB definitions — which are explicitly P2).

---

---

## Architecture Notes: MorphologyDecoder Data Source Abstraction

### Rationale

Morphology label text (~60 keys, ~50KB per language) is small enough that local storage is never a device-space problem. However, two concerns justify an abstraction layer now rather than later:

1. **Update without App Store release** — a mistranslated morphology term (e.g., wrong grammatical terminology) currently requires a full app release to fix. With an external provider this becomes a content update.
2. **Future DB/remote content delivery** — BDB definitions and `gloss` translations will eventually live in a remote-fetchable store (too large to ship for all languages). `MorphologyDecoder` should be on the same architectural track as those richer content types, even if the MVP implementation is simpler.

### Pattern

```swift
// 1. Semantic keys — the only thing MorphologyDecoder knows about
enum MorphKey {
    // Parts of speech
    static let posVerb      = "morph.pos.verb"
    static let posNoun      = "morph.pos.noun"
    static let posAdjective = "morph.pos.adjective"
    static let posPronoun   = "morph.pos.pronoun"
    static let posPrep      = "morph.pos.preposition"
    static let posConj      = "morph.pos.conjunction"
    static let posAdverb    = "morph.pos.adverb"
    static let posParticle  = "morph.pos.particle"
    static let posInterj    = "morph.pos.interjection"
    static let posPronSuffix = "morph.pos.pronominal_suffix"
    // Hebrew stems
    static let stemQal      = "morph.stem.qal"
    static let stemNiphal   = "morph.stem.niphal"
    static let stemPiel     = "morph.stem.piel"
    static let stemPual     = "morph.stem.pual"
    static let stemHiphil   = "morph.stem.hiphil"
    static let stemHophal   = "morph.stem.hophal"
    static let stemHithpael = "morph.stem.hithpael"
    // Hebrew aspects
    static let aspectPerfect    = "morph.aspect.perfect"
    static let aspectImperfect  = "morph.aspect.imperfect"
    static let aspectWayyiqtol  = "morph.aspect.wayyiqtol"
    static let aspectJussive    = "morph.aspect.jussive"
    static let aspectCohortative = "morph.aspect.cohortative"
    static let aspectImperative = "morph.aspect.imperative"
    static let aspectPartActive = "morph.aspect.participle_active"
    static let aspectPartPassive = "morph.aspect.participle_passive"
    static let aspectInfAbs     = "morph.aspect.infinitive_absolute"
    static let aspectInfCon     = "morph.aspect.infinitive_construct"
    // Grammatical form components
    static let person1   = "morph.person.1"
    static let person2   = "morph.person.2"
    static let person3   = "morph.person.3"
    static let genderM   = "morph.gender.masculine"
    static let genderF   = "morph.gender.feminine"
    static let genderC   = "morph.gender.common"
    static let numberSg  = "morph.number.singular"
    static let numberPl  = "morph.number.plural"
    static let numberDual = "morph.number.dual"
    static let stateAbs  = "morph.state.absolute"
    static let stateCon  = "morph.state.construct"
    static let stateDet  = "morph.state.determined"
    // ... (see Appendix for full key list)
}

// 2. Provider protocol — the seam between decoder and storage
protocol TranslationProvider {
    func string(for key: String) -> String
}

// 3. MVP implementation — reads from .xcstrings via Bundle
struct BundleTranslationProvider: TranslationProvider {
    func string(for key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .localizedBundle)
        // .localizedBundle = custom Bundle subclass for in-app language switching
    }
}

// 4. Future implementation (not built now) — reads from local DB cache or remote
// struct DBTranslationProvider: TranslationProvider { ... }
// struct RemoteTranslationProvider: TranslationProvider { ... }

// 5. MorphologyDecoder depends only on the protocol
enum MorphologyDecoder {
    static func decodeFull(_ code: String,
                           using provider: TranslationProvider = BundleTranslationProvider()) -> FullMorphology? {
        // emits MorphKey constants, never string literals
        var m = FullMorphology()
        // e.g.: m.partOfSpeech = provider.string(for: MorphKey.posVerb)
        return m
    }

    static func decode(_ code: String,
                       using provider: TranslationProvider = BundleTranslationProvider()) -> String? {
        // short label for Оригінал pill, same approach
    }
}
```

### What this buys immediately
- Unit-testable decoder: inject a `MockTranslationProvider` that returns keys as-is.
- Zero code change to swap storage: when DB-backed translations ship, only the concrete provider changes.
- Clear boundary: `MorphKey` constants are the contract between decoder logic and content.

### What this does NOT include (TBD in ADR)
- Decision on where morphology translations ultimately live long-term (`.xcstrings` vs. DB vs. remote).
- Strategy for BDB / `gloss` content delivery at scale.
- Offline fallback behavior when remote provider is unavailable.

---

### P1 — Nice-to-Have

**P1.1 — Default language logic: follow system locale** ✅ Resolved (OQ1 → B)  
On first launch, if the device locale is supported (`uk`), default to Ukrainian; otherwise default to English.

**Resolved behavior — follow system until manual override:** the derived language is **not** snapshotted to `UserDefaults` on first launch. `appLanguage` is only written once the user explicitly picks a language in Settings. Until then, the default is re-derived from the system locale on every launch.

- Rationale: a user changing their iOS interface language is a rare event, so the "snapshot on first launch" alternative added state for negligible benefit. Following the system is the natural behavior for the common case (system language never changes → identical to snapshot).
- Consequence (accepted): if a user changes their iOS system language and has **never** opened the in-app picker, the app language follows the system on next launch. Once they pick a language manually, that choice persists in `UserDefaults` and overrides the system permanently.

*Current implementation:* `SourceBibleApp.defaultLanguage` reads `Locale.preferredLanguages.first`, then falls back to `en` if not in `AppLanguage.supported`.

*Recommended refinement (non-blocking):* replace `Locale.preferredLanguages.first` + `.prefix(2)` with `Bundle.main.preferredLocalizations.first`. It negotiates against the user's full ordered language list and the bundle's available `.lproj`, and falls back to the development language automatically — more robust for multilingual users and scales to new locales without code changes.

**P1.2 — Language label in current language**  
In the language picker, each language is labeled in that language itself: "English", "Українська" — not "Ukrainian" / "Англійська". Standard iOS convention.

**P1.3 — Book names localized**  
`BibleBookNames.swift` contains book names (currently in one language). English and Ukrainian short/long names available and driven by active locale.

---

### P2 — Future / Out of Scope for This Spec

**P2.1 — Ukrainian lexical definitions (shortDefinition / fullDefinition)**  
Translating BDB and Abbott-Smith content for all ~8,600 Strong's entries into Ukrainian. This requires:
- Translation of source content (professional or community).
- Human validation by someone with biblical Hebrew/Greek knowledge.
- DB schema addition: `short_definition_uk TEXT`, `full_definition_uk TEXT` columns in `strongs` table.
- UI layer: `DatabaseService` and `StrongsEntry` model to return language-appropriate field based on active locale.

Estimated effort: **High** (weeks to months, content-heavy). Do not underestimate — BDB is a 1,900-page scholarly lexicon.

**P2.2 — Ukrainian gloss in word table**  
The `gloss` field (Macula English gloss, shown in `WordCard`) would need a `gloss_uk` column. ~450k rows, but unique glosses are far fewer (~5,000–10,000). Still requires validation.

**P2.3 — Additional languages (Russian, Spanish, German, Polish)**  
With P0 infrastructure in place, adding a new language is:
1. Add locale to `CFBundleLocalizations`.
2. Add a new column in the String Catalog (Xcode auto-generates the file).
3. Fill in translations (community/professional translator).
4. For lexical DB content: add language-specific columns to `strongs` (separate initiative).

No code changes required for UI strings.

---

## Implementation Complexity Estimate

| Component | Effort | Risk | Notes |
|---|---|---|---|
| Set up `.xcstrings` infrastructure | 1–2 hours | Low | Standard Xcode 15 workflow |
| Extract UI strings from all Swift files | 1–2 days | Low-Medium | ~100–150 strings; tedious but mechanical. Xcode has "Export for Localization" tooling. |
| Translate extracted strings to English | 0.5 days | Low | Most are already English-equivalent of current UA strings |
| Migrate hardcoded UA strings to catalog | 0.5 days | Low | Already have the Ukrainian text, just moving it |
| Refactor `MorphologyDecoder` — extract `MorphKey` + `TranslationProvider` | 0.5–1 day | Medium | Define ~60 key constants, protocol + `BundleTranslationProvider`, wire into both `decode()` and `decodeFull()`. Verify EN/UK accuracy. |
| Settings language picker + `@AppStorage` | 0.5 day | Low | Standard SwiftUI Picker + `@AppStorage("appLanguage")` |
| Instant language switch — custom `Bundle` subclass | 2–3 hours | Low-Medium | Override `localizedString(forKey:value:table:)`, load `.lproj` at runtime, trigger root view re-render via `@AppStorage`. Same pattern as Telegram. No restart. |
| QA both locales | 1 day | Low | Walk all screens in EN and UK |
| **Total (UI only, no DB content)** | **~5–7 days** | — | — |
| Ukrainian lexical definitions (P2.1) | Weeks–months | High | Content work, not just engineering |

**Recommendation for MVP**: Ship the infrastructure + English baseline + Ukrainian UI strings (P0.1–P0.5). This is ~5–7 engineering days and unlocks the ability to add any future language as a content task. Defer BDB/Thayer's translation entirely — it does not block launch and is a fundamentally different kind of work.

---

## Open Questions

| # | Question | Owner | Blocking? |
|---|---|---|---|
| OQ1 | ~~**Default language**: follow system locale (`.preferredLanguages[0]`) or a neutral English default?~~ **✅ Resolved (B — follow system):** default to the system locale if supported, else English. Do **not** persist the derived value on first launch — only a manual in-app pick is stored; until then the default re-derives from the system each launch. Rationale: changing iOS interface language is rare, so snapshot-and-persist added state for negligible benefit. See P1.1. | Ivan (product) | Resolved |
| OQ2 | ~~**In-app language switch without restart**~~ **✅ Resolved**: Use custom `Bundle` subclass that overrides `localizedString(forKey:value:table:)` and loads the correct `.lproj` at runtime. Root SwiftUI view re-renders via `@AppStorage("appLanguage")` change — same pattern as Telegram. No restart required. Estimated ~2–3h implementation. | Engineering | Resolved |
| OQ3 | **Morphology term accuracy**: Ukrainian morphological terminology in `decodeFull()` was written by a developer, not a linguist. Should these terms be reviewed by someone with Hebrew/Greek grammar background before locking the Ukrainian strings? (e.g., "Qal — проста активна" — acceptable?) | Ivan | No — can iterate post-launch |
| OQ4 | **`gloss` field language**: The `gloss` shown in `WordCard` (e.g., "king", "go") is English from Macula. In Ukrainian UI mode this looks inconsistent. Acceptable for MVP, or should this be hidden in UK mode until P2.2 ships? | Ivan (product) | No |
| OQ5 | **Settings tab**: Does a Settings tab already exist or does it need to be built? The codebase audit found no `SettingsView`. If it needs to be built, scope it here or as a separate ticket. | Engineering | Yes — language picker needs a home |

---

## Timeline Considerations

There are no hard external deadlines. Suggested phasing:

**Phase 1 — Infrastructure + English (1 week)**  
P0.1, P0.2, P0.4 + resolve OQ2 and OQ5. App fully works in English. Ukrainian is absent but planned.

**Phase 2 — Ukrainian completion (1 week)**  
P0.3, P0.5 — fill all Ukrainian strings, add Settings language picker, QA both locales. App ships bilingual.

**Phase 3 — Polish + P1 (0.5 week)**  
P1.1, P1.2, P1.3 — default locale logic, book names, language label convention.

**Phase 4 — First additional language (future)**  
Enabled by Phase 1–2 infrastructure. Adding Russian, Spanish, etc. becomes a translator task, not an engineering sprint.

---

## Appendix: Suggested String Key Naming Convention

```
// Format: feature_component_description
// Examples:
"word_tab_meaning"              // "Meaning" / "Значення"
"word_tab_usage"                // "Usage" / "Вживання"
"word_morph_section_title"      // "Morphology" / "Морфологія"
"word_morph_pos"                // "Part of speech" / "Частина мови"
"word_morph_stem"               // "Stem (Binyan)" / "Основа (Біньян)"
"word_morph_aspect"             // "Tense / Aspect" / "Час / Вид"
"word_morph_form"               // "Grammatical form" / "Граматична форма"
"word_morph_syntax_role"        // "Syntactic role" / "Синтаксична роль"
"word_morph_pos_verb"           // "Verb" / "Дієслово"
"word_morph_pos_noun"           // "Noun" / "Іменник"
"word_morph_stem_qal"           // "Qal — simple active" / "Qal — проста активна"
"word_empty_no_data"            // "Language data unavailable for this word"
"word_empty_tap_hint"           // "Tap a word to explore"
"word_lexical_section_title"    // "Lexical meaning" / "Лексичне значення"
"word_context_section_title %@" // "Form in %@" / "Форма у %@"  (with ref param)
"word_usage_count %lld"         // "%lld occurrences in the Bible"
```

Stem and aspect labels retain their Hebrew/Greek scholarly names (Qal, Niphal, Piel, etc.) in both languages — these are proper nouns in biblical scholarship and should not be translated.
