# ADR-025 — App Preferences Storage Layer

**Status:** Accepted (proposed 2026-07-02)
**Context tags:** UserDefaults, @AppStorage, settings, data hygiene
**Related:** ADR-012 (unified user data layer — GRDB), `spec-reader-resume-position.md`, PDR-Analytics-Mixpanel (consent)

---

## Контекст

Застосунок зберігає ~9+ дрібних значень у `UserDefaults` через `@AppStorage` та прямі
виклики. Імена ключів — stringly-typed і **продубльовані** по файлах:

- `"appLanguage"` — сирим рядком у `MenuView`, `LanguageSettingsView`, `BibleBookNames`, `SourceBibleApp` (4 місця)
- `"defaultTranslationId"` — у `ReaderViewModel`, `MenuView`
- `"analyticsEnabled"` — у `SourceBibleApp`, `MenuView`, `SearchView`, `AnalyticsConsentCard`

Проблеми:
1. **Друкарський одрук у ключі → тихий баг** (нове значення замість читання наявного).
2. Немає єдиного місця, де видно **що взагалі зберігається**.
3. Немає принципової межі для майбутньої фічі «очистити дані»: значення різні за
   природою й **не всі можна безпечно чистити**.

`spec-reader-resume-position.md` додає ще 4 ключі (`launchBehavior`, `lastRead*`) —
без централізації дублювання лише зростає.

## Рішення

**Легкий типізований фасад над `UserDefaults`** — БЕЗ окремої БД, БЕЗ заміни
`@AppStorage` (його реактивність зберігаємо).

### 1. `AppStorageKeys` — єдине джерело імен

`enum AppStorageKeys` зі `static let` константами. Усі `@AppStorage(...)` та прямі
`UserDefaults` виклики переходять на ці константи. `@AppStorage(AppStorageKeys.appLanguage)`
компілюється так само, але одрук неможливий.

### 2. Категорії за життєвим циклом

| Категорія | Ключі | Чистити? |
|---|---|---|
| **Appearance / preference** | `isDarkMode`, `hideBookCovers`, `redLetters`, `defaultTranslationId`, `appLanguage` | reset до дефолтів |
| **Reading / navigation (ephemeral)** | `lastReadBookId`, `lastReadChapter`, `lastReadVerseAnchorId`, `searchRecentQueries` | ✅ так |
| **Launch preference** | `launchBehavior` | reset до дефолту (`resume`) |
| **Consent (sensitive)** | `analyticsEnabled`, `analyticsConsentShown` | ⛔ НІКОЛИ |
| **Migration bookkeeping** | `migrationHighlightsDone`, legacy `highlightedVerseIds` | ⛔ НІКОЛИ |

### 3. Scoped clear — НЕ nuclear reset

`enum AppPreferences` з операціями, що чистять **тільки свою категорію**:

- `clearReadingHistory()` — reading position + search history.
- `resetAppearanceToDefaults()` — appearance/preference ключі (падають у дефолти).

**Consent і migration не входять у жоден clear** — за дизайном. Blanket
`removePersistentDomain` заборонено (знесе consent → повторний промпт + юр. ризик;
знесе migration-флаг → повторна міграція highlights).

## Чому не так

- **Окрема БД (GRDB) для налаштувань** — надлишково: значення дрібні, одиничні, часто
  перезаписувані; durability БД не потрібна. GRDB лишається для user-authored даних
  (ADR-012). Reading-position → GRDB тільки якщо зʼявиться крос-девайс синк (окремий етап).
- **Заміна `@AppStorage` на власний wrapper** — втрата нативної SwiftUI-реактивності
  заради нуля користі. Тримаємо `@AppStorage`, міняємо лише джерело ключа.
- **Nuclear `UserDefaults` reset** — небезпечний (див. вище).

## Наслідки

**+** Один список усього, що зберігається. Немає дублювання ключів. Є принципова,
безпечна межа для майбутньої фічі «Clear reading history» / «Restore defaults».
**−** Легкий разовий рефакторинг усіх `@AppStorage` call-site'ів. `@AppStorage` вимагає
константу відомою на етапі компіляції — `static let` це задовольняє.

## Обсяг реалізації

- Новий `Services/AppPreferences.swift` — `AppStorageKeys` + `AppPreferences` scoped clears.
- Рефактор call-site'ів: `MenuView`, `LanguageSettingsView`, `BibleBookNames`,
  `SourceBibleApp`, `SearchViewModel`, `ReaderViewModel`, `AnalyticsConsentCard`, `MigrationService`.
- `spec-reader-resume-position.md` `ReadingPositionStore` використовує `AppStorageKeys`.
- UI для scoped-clear (кнопки в Меню) — **поза** цим ADR (додається за потреби; API вже готове).
