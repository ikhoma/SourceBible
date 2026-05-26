# Verse Versification System Design

Canonical mapping між схемами нумерації віршів у SourceBible iOS app.

---

## Проблема

У Біблії різні традиції нумерації віршів. Три таблиці в app мають різні системи відліку:

| Таблиця | Схема нумерації |
|---------|----------------|
| `word`  | Macula / MT (Масоретський текст) |
| `verse` (KJV) | KJV versification |
| `verse` (RST) | RST versification (LXX-based для ОЗ) |

**Відомі зсуви:**
- `KJV → MT`: Псалми ×62 розділи (+1 або +2 вірші через заголовки)
- `RST → MT`: Псалми + деякі книги (+1)
- `UBT → MT`: аналогічно RST
- `LXX`: окрема схема нумерації

**Відомі зовнішні сервіси та їх схеми:**
- BibleGateway → KJV versification
- YouVersion → KJV versification
- API.Bible → залежить від перекладу
- Синодальний сайт → RST versification

---

## Архітектура (4 шари)

```
BUILD TIME  →  STORAGE  →  RUNTIME SERVICE  →  CONSUMERS
```

---

## Шар 1: Build Time

### Джерела даних

**Paratext `.vrs` файли** — industry standard для versification mapping:
- `kjv.vrs` — KJV схема
- `rst.vrs` — RST / Synodal схема  
- `ubt.vrs` — UBT схема
- `lxx.vrs` — LXX схема

Формат: кожен рядок описує відповідність книга/глава/вірш між двома схемами.

### build_verse_map.py

Читає `.vrs` файли → генерує SQL INSERT в `verse_map`.

```
Paratext .vrs files → build_verse_map.py → verse_map table
                    ↘ Manual overrides    ↗
                      verse_map_patch.sql
```

**`verse_map_patch.sql`** — ручні правки для edge cases, що не покриваються автоматикою (виняткові вірші, помилки в `.vrs` файлах тощо).

**Покриття (Псалми):** 62 розділи × кількість перекладів ≈ 500+ рядків тільки для Псалмів.

> **Запускати**: при додаванні нового перекладу або оновленні `.vrs` файлів.

---

## Шар 2: Storage — `verse_map` (SQLite)

### DDL

```sql
CREATE TABLE verse_map (
    from_vsn  TEXT NOT NULL,  -- схема-джерело (напр. 'kjv', 'rst')
    book      TEXT NOT NULL,  -- book_id (напр. 'PSA', 'ROM')
    ch        INT  NOT NULL,  -- номер глави
    from_v    INT  NOT NULL,  -- вірш у схемі-джерелі
    to_vsn    TEXT NOT NULL,  -- схема-ціль (напр. 'mt', 'lxx')
    to_v      INT  NOT NULL,  -- відповідний вірш у схемі-цілі
    PRIMARY KEY (from_vsn, book, ch, from_v, to_vsn)
    -- SVG діаграма показує PK як (from+book+ch+v) — 4 поля.
    -- to_vsn додано у PK щоб підтримувати кілька цільових схем
    -- (наприклад, kjv→mt і kjv→lxx одночасно).
);

CREATE INDEX idx_verse_map ON verse_map(from_vsn, book, ch);
```

> ⚠️ **Поточна реалізація в DB** використовує інші назви колонок:
> `translation`, `book_id`, `chapter`, `trans_verse`, `macula_verse` (без `to_vsn`, завжди MT).
> При рефакторингу до повного дизайну — мігрувати схему.

### Приклади рядків

| from_vsn | book | ch | from_v | to_vsn | to_v |
|----------|------|----|--------|--------|------|
| `kjv`    | PSA  | 3  | 2      | mt     | 3    |
| `rst`    | PSA  | 51 | 1      | mt     | 3    |
| `kjv`    | ROM  | 16 | 24     | mt     | —    |

> Зберігати **тільки non-identity** рядки (де `from_v != to_v`). Якщо рядка немає → identity mapping (вірш однаковий в обох схемах).

---

## Шар 3: Runtime — `VersificationService`

Окремий сервісний шар (не вбудований у ViewModel).

### Swift API

```swift
protocol VersificationServiceProtocol {
    /// Повертає номер вірша у схемі `to`, що відповідає вірші `verse` у схемі `from`.
    /// Якщо маппінг не знайдений — повертає identity (той самий номер).
    func resolve(verse: Int, book: String, chapter: Int,
                 from: Versification, to: Versification) -> Int
}

enum Versification: String {
    case mt   = "mt"    // Macula / Масоретський текст
    case kjv  = "kjv"
    case rst  = "rst"
    case ubt  = "ubt"
    case lxx  = "lxx"
}
```

### Реалізація (три рівні)

```swift
func resolve(verse: Int, book: String, chapter: Int,
             from: Versification, to: Versification) -> Int {

    // Рівень 1: швидкий O(1) lookup у verse_map
    if let mapped = db.findVerseMap(from: from, book: book, chapter: chapter,
                                    fromVerse: verse, to: to) {
        return mapped
    }

    // Рівень 2: identity — більшість розділів не мають зсуву
    // Перевіряємо Strong's overlap (≥2 збіги) щоб підтвердити
    if strongsOverlapConfirmsIdentity(verse: verse, book: book, chapter: chapter) {
        return verse
    }

    // Рівень 3: heuristic fallback ±2 вірші по Strong's overlap
    return strongsOverlapSearch(verse: verse, book: book, chapter: chapter,
                                range: [-1, 1, -2, 2])
}
```

### DatabaseService метод

```swift
func findVerseMap(from: Versification, book: String, chapter: Int,
                  fromVerse: Int, to: Versification) -> Int? {
    let sql = """
        SELECT to_v FROM verse_map
        WHERE from_vsn = ? AND book = ? AND ch = ? AND from_v = ? AND to_vsn = ?
        """
    // ... query execution
}
```

---

## Шар 4: Consumers

### 1. `loadWordsForSelectedVerse` (реалізовано)

Конвертує вірш поточного перекладу → MT вірш → завантажує Macula слова.

```swift
func loadWordsForSelectedVerse() {
    guard let verse = selectedVerse else { return }
    let maculaVerse = versificationService.resolve(
        verse: verse.number, book: verse.bookId, chapter: verse.chapter,
        from: currentTranslation.versification,  // .kjv / .rst / ...
        to: .mt
    )
    let words = db.loadWords(bookId: verse.bookId, chapter: verse.chapter,
                             verse: maculaVerse)
    // оновити verses[] та selectedVerse
}
```

### 2. `ExternalLinkBuilder` (не реалізовано)

Відкриває вірш у зовнішніх сервісах з правильною нумерацією.

```swift
struct ExternalLinkBuilder {
    func bibleGatewayURL(for verse: BibleVerse, translation: Translation) -> URL {
        // Конвертуємо поточний переклад → KJV versification (BibleGateway)
        let kjvVerse = versificationService.resolve(
            verse: verse.number, book: verse.bookId, chapter: verse.chapter,
            from: translation.versification,
            to: .kjv
        )
        return URL(string: "https://www.biblegateway.com/passage/?search=\(verse.bookId)+\(verse.chapter):\(kjvVerse)&version=KJV")!
    }

    func youVersionURL(for verse: BibleVerse, translation: Translation) -> URL {
        let kjvVerse = versificationService.resolve(...)
        // YouVersion також використовує KJV versification
    }
}
```

### 3. `CrossRef Resolver` (не реалізовано)

Нормалізує cross-references між перекладами. Cross-references в DB зберігаються в одній схемі (MT або KJV), але потрібно показувати вірш у поточному перекладі користувача.

```swift
struct CrossRefResolver {
    func resolveReference(_ ref: CrossReference,
                          targetVersification: Versification) -> CrossReference {
        let targetVerse = versificationService.resolve(
            verse: ref.verse, book: ref.bookId, chapter: ref.chapter,
            from: .mt,  // cross-refs зберігаються в MT схемі
            to: targetVersification
        )
        return ref.with(verse: targetVerse)
    }
}
```

---

## Що реалізовано зараз

| Компонент | Статус |
|-----------|--------|
| `verse_map` DDL і наповнення | ✅ реалізовано (Strong's overlap алгоритм) |
| `DatabaseService.findMaculaVerse()` | ✅ реалізовано |
| `ReaderViewModel.findBestMaculaVerse()` | ✅ реалізовано (3 рівні) |
| `Paratext .vrs` як джерело | ⬜ не реалізовано (зараз Strong's overlap) |
| `VersificationService` як окремий сервіс | ⬜ логіка вбудована у ViewModel |
| `ExternalLinkBuilder` | ⬜ не реалізовано |
| `CrossRef Resolver` | ⬜ не реалізовано |
| `verse_map_patch.sql` | ⬜ не реалізовано |

---

## Файли проекту

| Файл | Роль |
|------|------|
| `build_verse_map.py` | Build-time: наповнення verse_map (запускати при зміні перекладів) |
| `verse_map_patch.sql` | Ручні override для edge cases |
| `SourceBible/Services/DatabaseService.swift` | `findVerseMap()` метод |
| `SourceBible/Services/VersificationService.swift` | Сервісний шар (до реалізації) |
| `SourceBible/ViewModels/ReaderViewModel.swift` | `loadWordsForSelectedVerse()` |
| `SourceBible/Utils/ExternalLinkBuilder.swift` | URL для зовнішніх сервісів (до реалізації) |

---

## Важливо для імплементатора

1. `verse_map` зберігає **тільки non-identity** рядки. Відсутній рядок = identity mapping.
2. Схема таблиці **bidirectional** (`from_vsn` → `to_vsn`). Один рядок покриває один напрямок. Для зворотного напрямку потрібен окремий рядок або reverse lookup.
3. `VersificationService` має бути **singleton** або **injected dependency** (не створювати на кожен запит через SQLite overhead).
4. Strong's overlap fallback в рівні 3 — **пробабілістичний**, не гарантований. Для production краще покладатись на `.vrs` файли.
5. Зовнішні сервіси (BibleGateway, YouVersion) використовують **KJV versification**, не MT.
