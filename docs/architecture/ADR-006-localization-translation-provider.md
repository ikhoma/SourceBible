# ADR-006: Morphology Translation Provider & In-App Language Switching

**Status:** Accepted  
**Date:** 2026-05-23  
**Deciders:** Ivan Khoma  
**Related spec:** `specs/localization-spec.md`  
**Related plan:** `specs/localization-implementation-plan.md`

---

## Context

`MorphologyDecoder` in `WordTabContent.swift` currently contains ~60 hardcoded string literals in two languages: Ukrainian in `decodeFull()` and English in `decode()`. This creates three problems:

1. **Inconsistency** — the Оригінал pill shows English labels ("Noun"), Значення shows Ukrainian ("Іменник") for the same word, regardless of any user preference.
2. **No localization path** — adding a third language requires editing Swift source and shipping a new app binary.
3. **No fix-without-release** — a mistranslated grammatical term (e.g. wrong Ukrainian for "cohortative") can only be corrected via App Store update.

The broader localization initiative (spec P0) also requires choosing a strategy for **in-app language switching** — iOS does not support this natively via `Bundle.localizations` without a restart.

Two decisions are coupled:

- **Decision A** — where do morphology label translations live, and what is the interface between `MorphologyDecoder` and that storage?
- **Decision B** — how does the app switch language at runtime without restart?

---

## Decision A: Morphology Translation Storage

### Options Considered

#### Option A1 — Hardcoded string literals in Swift (status quo)

```swift
case "V": m.partOfSpeech = "Дієслово"  // or "Verb"
```

| Dimension | Assessment |
|---|---|
| Complexity | None |
| Correctness | Broken — two languages, no switcher |
| Updateability | App Store release required per fix |
| Testability | None — output language depends on which branch was written |
| Future scalability | 0 — each new language = code change |

**Rejected.** Status quo is the problem, not an option.

---

#### Option A2 — `.xcstrings` (String Catalog) via `TranslationProvider` protocol — **Chosen for MVP**

`MorphologyDecoder` emits semantic keys (`MorphKey.posVerb`, `MorphKey.stemQal`). A `TranslationProvider` protocol resolves keys to strings. The MVP implementation (`BundleTranslationProvider`) reads from `Localizable.xcstrings` via `Bundle`. Future implementations can swap in DB or remote without touching decoder logic.

```swift
protocol TranslationProvider {
    func string(for key: String) -> String
}

struct BundleTranslationProvider: TranslationProvider {
    func string(for key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
        // Bundle.main is swizzled at launch — see Decision B
    }
}

enum MorphologyDecoder {
    static func decodeFull(
        _ code: String,
        using provider: TranslationProvider = BundleTranslationProvider()
    ) -> FullMorphology? { ... }
}
```

| Dimension | Assessment |
|---|---|
| Complexity | Low — standard iOS tooling |
| Data size | ~60 keys × N languages × ~25 chars ≈ trivial |
| Updateability | App release required (acceptable for MVP) |
| Testability | ✅ inject `MockTranslationProvider` |
| Future scalability | ✅ swap provider without touching decoder |
| Team familiarity | High — Xcode String Catalog is standard |

**Pros:**
- Zero new infrastructure — `.xcstrings` is built into Xcode 15.
- Ukrainian strings already exist in code — migration is copy-paste, not translation work.
- `TranslationProvider` protocol creates the seam for future storage changes.
- Default parameter means zero changes to existing View call sites.

**Cons:**
- Fixing a translation error requires App Store release.
- Data and code in separate places (`.xcstrings` vs `MorphKey` constants) — must keep in sync.

---

#### Option A3 — Local SQLite table `morphology_labels(code TEXT, lang TEXT, label TEXT)`

Add a table to `sourcebible.db`. `BundleTranslationProvider` is replaced with `DBTranslationProvider` that queries the DB.

| Dimension | Assessment |
|---|---|
| Complexity | Medium — new DB table, query layer, in-memory cache needed |
| Data size | Trivial (~50KB per language) |
| Updateability | DB rebuild required — still needs app update in current setup |
| Testability | ✅ via provider protocol |
| Future scalability | ✅ same table structure works for BDB definitions |

**Why not for MVP:** Adds DB infrastructure for data that's trivially small and already sitting in Swift code. No updateability advantage over `.xcstrings` until remote DB sync exists. Overhead without current benefit. **Valid as a future upgrade path** when DB content delivery (BDB, glosses) is being designed — at that point, moving morphology labels to the same table is a natural consolidation.

---

#### Option A4 — Remote JSON (CDN / API)

Translations fetched on first launch / language switch, cached locally. No app release to update content.

| Dimension | Assessment |
|---|---|
| Complexity | High — CDN/API, offline fallback, cache invalidation |
| Data size | 5–10KB per language — minimal benefit |
| Updateability | ✅ content fixes without release |
| Offline behavior | Requires local fallback (which negates the "no local copy" argument) |
| Infrastructure cost | Non-trivial for ~50KB of morphology data |

**Why not for MVP:** The data volume doesn't justify the infrastructure. Remote delivery makes strong sense for BDB/gloss data (~10–20MB per language). For morphology labels, the ratio of infrastructure cost to benefit is poor. **Defer to the same initiative that designs remote content delivery for lexical data.**

---

### Decision A — Summary

**Use Option A2 (`.xcstrings` via `TranslationProvider` protocol) for MVP.**

The `TranslationProvider` abstraction is the key investment — it is the seam that makes all future storage options (A3, A4) non-breaking changes. The MVP implementation is `.xcstrings` because it requires no new infrastructure and the data is small. The protocol is what matters long-term, not which concrete provider is behind it.

**Upgrade path:**  
`BundleTranslationProvider` → `DBTranslationProvider` → `RemoteTranslationProvider`  
Each transition requires only a new concrete type + wiring. `MorphologyDecoder` and all Views are untouched.

---

## Decision B: In-App Language Switching Without Restart

### Options Considered

#### Option B1 — Bundle.main swizzling via `object_setClass` — **Chosen**

Replace `Bundle.main`'s runtime class with a `LocalizedBundle` subclass at app launch. The subclass overrides `localizedString(forKey:value:table:)` to load the correct `.lproj` based on a stored language preference.

```swift
final class LocalizedBundle: Bundle, @unchecked Sendable {

    static func activate(language: String) {
        // Called once at launch and on every language change
        Self._language = language
    }

    private static var _language: String = "en"

    private var overrideBundle: Bundle? {
        guard
            let path = Bundle.main.path(forResource: Self._language, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)   // cached — see implementation note
    }

    override func localizedString(forKey key: String,
                                  value: String?,
                                  table tableName: String?) -> String {
        overrideBundle?.localizedString(forKey: key, value: value, table: tableName)
            ?? super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// In SourceBibleApp.init():
object_setClass(Bundle.main, LocalizedBundle.self)
LocalizedBundle.activate(language: storedLanguage)
```

Root view re-renders via `.id(appLanguage)`:

```swift
// SourceBibleApp.body:
ContentView(store: store)
    .id(appLanguage)
    .onChange(of: appLanguage) { _, lang in
        LocalizedBundle.activate(language: lang)
    }
```

**Why swizzle Bundle.main instead of a separate `LocalizedBundle.shared`:**  
Passing `bundle: .localized` explicitly to every `String(localized:)` call is error-prone — any missed call silently falls through to the wrong language. SwiftUI's `Text("key")` uses `LocalizedStringKey` which always hits `Bundle.main` regardless of an explicit bundle parameter at a higher level. Swizzling `Bundle.main` means `Text("key")`, `String(localized: "key")`, and `String(localized: "key", bundle: .localized)` all behave correctly with zero changes to existing call sites.

| Dimension | Assessment |
|---|---|
| Complexity | Medium — `object_setClass` is ObjC runtime, unfamiliar to some |
| Call site impact | ✅ Zero — existing `Text("key")` continues to work |
| Correctness | ✅ Covers SwiftUI Text, String(localized:), NSLocalizedString |
| Risk | Low — this pattern is production-proven (Telegram, many others) |
| Testability | Moderate — swizzling in unit tests needs care |

**Implementation note on caching:** `Bundle(path: path)` should be cached per-language (not recreated on every `localizedString` call). A simple `[String: Bundle]` dict keyed by language code is sufficient.

---

#### Option B2 — Explicit `bundle: .localized` parameter everywhere

Keep `Bundle.main` untouched. Use a separate `LocalizedBundle.shared` instance. Pass it explicitly: `String(localized: "key", bundle: .localized)`.

```swift
// Every string call becomes:
Text(verbatim: String(localized: "key", bundle: .localized))
// instead of:
Text("key")
```

**Why rejected:**
- `Text("key")` (LocalizedStringKey) always uses `Bundle.main` — can't be overridden without swizzling. Would need to replace every `Text("...")` with `Text(verbatim: String(localized:...))`.
- Any missed call silently shows the wrong language — invisible bug.
- More verbose at every call site with no upside.

---

#### Option B3 — `@Environment(\.locale)` propagation

Set `.environment(\.locale, Locale(identifier: appLanguage))` at root. SwiftUI `Text` uses this for `LocalizedStringKey`.

**Why rejected:**  
Works for SwiftUI `Text("key")` but does **not** affect `String(localized: "key")` in view models, `MorphologyDecoder`, or `BundleTranslationProvider`. Two separate systems would need to stay in sync. Complexity without full coverage.

---

#### Option B4 — App restart required

Show a dialog: "Restart the app to apply language change."

**Why rejected:**  
Universally poor UX. iOS apps like Telegram, Duolingo, and others demonstrate instant switching is achievable. Restart is not acceptable per product decision (see spec OQ2 resolution).

---

### Decision B — Summary

**Use Option B1 (Bundle.main swizzling + `.id(appLanguage)` re-render).**

Swizzling is the only approach that makes all localization call sites correct by default — including SwiftUI `Text`, `String(localized:)`, and any future code that doesn't explicitly pass a bundle. The `.id(appLanguage)` modifier on the root view forces a full re-render on language change, which is acceptable for a rare action.

**Known trade-off:** `.id()` drops all navigation state (scroll position, open sheets, navigation stack) when language is changed. This is the same behavior as Telegram. Users changing language in Settings expect the app to "reset" visually — this is not surprising UX. If this becomes a complaint, the mitigation is to close sheets and reset navigation explicitly before switching, rather than relying on `.id()`.

---

## Consequences

**What becomes easier:**
- Adding language N (Russian, Spanish, etc.) requires only: adding locale to `CFBundleLocalizations` + filling a new column in `.xcstrings`. Zero Swift changes.
- Unit testing `MorphologyDecoder` with `MockTranslationProvider` — no Bundle involvement.
- Fixing a mistranslated UI string via OTA content update (once remote provider ships).
- Morphology labels are now consistent — same language in both Оригінал and Значення pills.

**What becomes harder:**
- Bundle swizzling (`object_setClass`) is an Objective-C runtime technique. Any developer unfamiliar with it will need to understand the pattern before modifying `SourceBibleApp.swift`.
- `.id(appLanguage)` re-render clears all view state. Tabs reset to their root view. If deep navigation or an open sheet was present, it disappears. Document this in code comments.
- `MorphKey` constants and `.xcstrings` keys must stay in sync manually — if a key is added to `MorphKey` but not to `.xcstrings`, the fallback (key shown as-is) is the symptom. Consider a unit test that exhaustively resolves all `MorphKey` constants and asserts they don't return their own key name.

**What we'll need to revisit:**
- When remote content delivery for BDB/gloss is designed, evaluate whether `morphology_labels` belongs in the same DB table (consolidation) or stays in `.xcstrings` (simplicity). Capture in a follow-up ADR.
- If offline fallback for remote `TranslationProvider` is needed, `BundleTranslationProvider` becomes the fallback layer — design this explicitly.
- `BibleBookNames.swift` — book name localization is deferred (P1.3) but should use the same `Bundle.main`-via-swizzle approach, not a separate path.

---

## Action Items

1. [x] Implement `LocalizedBundle` with `object_setClass` pattern (`Services/Localization/LocalizedBundle.swift` ✅)
2. [x] Add `overrideBundle` caching by language code (implemented with `_bundleCache` dict ✅)
3. [ ] Add unit test: all `MorphKey.*` constants resolve to non-key strings in both `en` and `uk`
4. [x] Add code comment on `.id(appLanguage)` in `SourceBibleApp` (implemented ✅)
5. [x] Update implementation plan Step 1 to use swizzle approach (`plan-localization-i18n.md` updated ✅)
6. [ ] Create follow-up ADR: "Long-term content delivery strategy for BDB/gloss translations"

> **Continued in ADR-007** — localization completion (book names, model data, xcstrings gaps found in QA).

---

## Appendix: Plan Review Notes

The implementation plan (`localization-implementation-plan.md`) is structurally sound with one issue to correct:

**Issue:** Step 1 and Step 6 propose `String(localized: "key", bundle: .localized)` and `Text(verbatim: String(localized:...))` everywhere. This is Option B2 above — rejected in favor of B1 (swizzling). The plan should be updated so Step 1 implements `object_setClass` swizzling and Step 6 uses plain `Text("key")` / `String(localized: "key")` without explicit bundle parameter.

Everything else in the plan — step ordering, `MorphKey` design, `TranslationProvider` protocol, `@AppStorage` + `.id()` wiring, QA checklists — is correct and optimal.

---

## Amendment 2026-08-03 — одна резолюція мови замість п'яти дефолтів

`appLanguage` пишеться в `UserDefaults` **лише коли користувач відкриє пікер
мови**. Доти ключа немає, і кожен call-site вирішував це по-своєму:

| місце | було | наслідок на українському телефоні |
|---|---|---|
| свізл бандла (`init`) | `?? defaultLanguage` (мова системи) | ✅ інтерфейс український |
| `AboutView`, `MenuView`, `LanguageSettingsView`, `PrivacyPolicyView` | `@AppStorage(...) = "en"` | ❌ англійський текст «Про застосунок» і політики; у пікері позначено English |
| `BibleBookNames.isUkrainian` | `string(forKey:) == "uk"` (`nil ≠ "uk"`) | ❌ англійські назви книг у фолбеку |

Тобто перший запуск був **змішаний за мовою**, і це не бачив ніхто, бо тестувати
починали вже після дотику до налаштувань.

**Рішення:** `AppLanguage` став єдиним джерелом.

- `resolved` — збережене (якщо валідне) → мова системи → звузити до `{en, uk}`.
  Для тих, хто читає стан сам (`init`, `ReadingPositionStore`, `BibleBookNames`).
- `narrowed(_:)` — звужує вже наявний рядок. Для call-site'ів, що тримають
  значення в руках (`@AppStorage`) і не мають перечитувати `UserDefaults`.

Усі `@AppStorage(appLanguage)` дефолтяться в `resolved`, а не в `"en"`.
`SourceBibleApp.defaultLanguage` прибрано як зайвого посередника.

⛔ **`?? default` тут недостатньо** — `??` ловить лише `nil`. Порожній або
невалідний збережений рядок проходив далі, і `.onChange(of: appLanguage)` мовчки
перевстановлював англійський бандл поверх правильної мови, обраної в `init`.
Тому обидва localization-call-site'и в `body` проганяють значення через
`narrowed`.

**Перевірено на симуляторі** (`-AppleLanguages`, ключ відсутній / порожній):
uk → український інтерфейс + UBIO; en → англійський + KJV; порожній збережений
рядок при системній uk → український (раніше давав англійський таб-бар).
