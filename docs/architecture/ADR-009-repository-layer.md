# ADR-009: Введення Repository шару замість прямого доступу до даних у ViewModel

**Status:** Superseded  
**Date:** 2026-05-11  
**Deciders:** Ivan Khoma  
**Superseded by:** ADR-012 (highlights portion); BibleRepository concept abandoned — `DatabaseService` used directly throughout.  
**Note:** `HighlightRepository` was built then deleted. `BibleRepository`/`MockBibleRepository` were never built. Kept as a record of why this pattern was considered.

---

## Context

Поточна архітектура — MVVM. `ReaderViewModel` відповідає за:

- завантаження вірш/розділу (`loadChapter` — зараз `Task.sleep` mock)
- стан UI (isBottomSheetPresented, isBookPickerPresented, isTranslationPickerPresented)
- навігацію між віршами і словами
- завантаження Strong's лексикону
- highlights — зберігаються в `Set<String>` в пам'яті, **зникають після перезапуску**
- координацію між bottom sheet, verse picker, word mode

Два критичних наслідки:

1. **Баг**: highlights не персистуються — це вже помітно при тестуванні
2. **Блокер**: немає жодного місця щоб підключити реальне джерело даних (SQLite з текстом Біблії, Strongs concordance) — весь `loadChapter` тримається на `BibleVerse.sampleVerses`

---

## Decision

Вводимо два Repository-об'єкти між ViewModel і джерелами даних:

1. **`HighlightRepository`** — персистує highlights (v1: UserDefaults, v2: Core Data)
2. **`BibleRepository`** — абстракція над джерелом тексту Біблії (v1: SQLite bundle, v2: remote API)

`ReaderViewModel` делегує обом — сам залишається координатором UI state і не знає про деталі зберігання.

---

## Options Considered

### Option A: Repository pattern (обраний)

```
Views → ReaderViewModel → BibleRepository → SQLite / API
                        → HighlightRepository → UserDefaults / Core Data
```

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium — два нових файли, protocol + implementation |
| Testability | High — можна підмінити protocol mock-ом в тестах |
| Scalability | High — джерело даних можна замінити без змін у ViewModel |
| Team familiarity | High — стандартний iOS патерн |
| Time to implement | ~2–3 год на обидва repositories |

**Pros:**
- Fixes the highlight persistence bug
- Розблоковує підключення реального тексту Біблії
- ViewModel перестає знати про UserDefaults / SQLite
- Легко додати Notes, Bookmarks Repository в майбутньому за тим же контрактом

**Cons:**
- Додаткова абстракція для проекту який поки solo
- Protocol + concrete type — boilerplate якого не було

---

### Option B: Залишити всe в ViewModel, додати persistence inline

```swift
// В toggleHighlight():
UserDefaults.standard.set(Array(highlights), forKey: "highlights")
```

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — 3 рядки коду |
| Testability | Low — ViewModel прив'язаний до UserDefaults |
| Scalability | Low — при додаванні Notes/Bookmarks/Folders ViewModel стане ще більшим |
| Team familiarity | High |
| Time to implement | 15 хвилин |

**Pros:**
- Найшвидше закриває баг прямо зараз
- Нуль нових файлів

**Cons:**
- Persistence логіка в ViewModel — той самий god object антипатерн
- Коли додаватимемо кольори highlights або Notes — доведеться рефакторити все одно
- Не вирішує проблему BibleRepository взагалі

---

### Option C: SwiftData (iOS 17+)

```swift
@Model class Highlight { var verseId: String; var color: String }
```

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium-High — SwiftData має quirks з threading |
| Testability | Medium — ModelContext можна підміняти |
| Scalability | High — ORM, relationships, migrations |
| Team familiarity | Low — SwiftData ще молодий, багато edge cases |
| Time to implement | ~4–6 год з дебагом |

**Pros:**
- Готові relationships (Highlight → Note → Folder)
- Мінімум boilerplate для моделей
- Добре інтегрується з SwiftUI через `@Query`

**Cons:**
- **Передчасно**: для MVP з одним типом entity (highlight) це надмірно
- SwiftData на iOS 17 має реальні баги з migration і threading — додаткові ризики
- `@Query` прив'язує Views до конкретного storage, що обходить наш ViewModel
- Якщо в майбутньому захочемо CloudKit sync — SwiftData полегшить, але не гарантує

> **Вердикт по Option C**: правильний вибір для v2 коли матимемо Notes + Folders + sync. Для MVP — зарано.

---

## Trade-off Analysis

**Option A vs B**: B швидше зараз, але Option A займе ~2 год і закриє одразу два блокери (persistence + реальні дані). Якщо вибрати B — через місяць будемо все одно писати Repository коли підключатимемо SQLite.

**Option A vs C**: SwiftData — правильне довгострокове рішення, але занадто ранній вхід. Repository pattern з UserDefaults v1 → Core Data / SwiftData v2 — менший ризик при тій самій архітектурній чистоті.

---

## HighlightRepository — детальна специфікація

```swift
// Protocol — що ViewModel знає
protocol HighlightRepositoryProtocol {
    func isHighlighted(_ verseId: String) -> Bool
    func toggle(_ verseId: String)
    func loadAll() -> Set<String>
}

// v1 Implementation — UserDefaults
final class UserDefaultsHighlightRepository: HighlightRepositoryProtocol {
    private let key = "highlighted_verse_ids"
    private var cache: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        cache = Set(saved)
    }

    func isHighlighted(_ verseId: String) -> Bool { cache.contains(verseId) }

    func toggle(_ verseId: String) {
        if cache.contains(verseId) { cache.remove(verseId) }
        else { cache.insert(verseId) }
        UserDefaults.standard.set(Array(cache), forKey: key)
    }

    func loadAll() -> Set<String> { cache }
}
```

ViewModel приймає через ін'єкцію (DI через init), дефолтний — `UserDefaultsHighlightRepository()`.

---

## BibleRepository — детальна специфікація

```swift
protocol BibleRepositoryProtocol {
    func fetchChapter(bookId: String, chapter: Int, translation: String) async throws -> [BibleVerse]
    func fetchStrongs(id: String) async throws -> StrongsEntry
}

// v1: повертає sample data (= заміняє поточний Task.sleep mock)
final class MockBibleRepository: BibleRepositoryProtocol { ... }

// v2: читає з SQLite бандлу
final class SQLiteBibleRepository: BibleRepositoryProtocol { ... }
```

Перемикання між mock і real — в одному місці (`ContentView` або App entry point через environment).

---

## Що НЕ робимо зараз

| Ідея | Чому ні |
|------|---------|
| Виносити navigation state у `ReaderNavigationState` | 5 `@Published` змінних — не достатньо щоб виправдати другий ObservableObject і ускладнення bindings у Views |
| SwiftData | Передчасно для одного entity типу, ризики з iOS 17 quirks |
| Split BottomSheet на файли | Низький пріоритет — не впливає на функціональність, тільки організація |

---

## Consequences

**Стає простіше:**
- Підключити реальний SQLite з текстом Біблії — один файл, без змін у ViewModel
- Тестувати — MockBibleRepository підміняється в одному місці
- Додавати Notes/Bookmarks Repository — той самий патерн
- Highlights не зникають після перезапуску

**Стає складніше:**
- Новий розробник бачить protocol + implementation там де раніше були прямі виклики
- DI через init треба пам'ятати при Preview (`#Preview` потребує mock)

**Повернемося коли:**
- Додаємо Notes → вирішимо Core Data vs SwiftData по результатам v1
- Підключаємо CloudKit sync → переоцінимо SwiftData

---

## Action Items

1. [ ] Створити `HighlightRepository.swift` з протоколом та UserDefaults implementation
2. [ ] Оновити `ReaderViewModel` — прибрати `Set<String> highlights`, делегувати до repository
3. [ ] Створити `BibleRepository.swift` з протоколом та Mock implementation (замінює `Task.sleep`)
4. [ ] Оновити `loadChapter()` і `loadStrongs()` у ViewModel — через `BibleRepository`
5. [ ] Переконатися що `#Preview` в Views отримують mock versions (не ламаються)
6. [ ] (Optional) Split `VerseBottomSheetView.swift` → окремі файли в `Views/BottomSheet/`
