# Система вирівнювання нумерації віршів (Verse Versification)

## Проблема

В iOS Bible app (SwiftUI, SQLite, без ORM) є дві таблиці з різною нумерацією:

- **`word`** — слова оригінальної мови з бази Macula Hebrew (OSHB). Нумерація по Масоретському тексту (MT).
- **`verse`** — текст перекладів (KJV, RST тощо). Нумерація по кожному перекладу.

У 459 розділах нумерація розходиться. Найбільше — в Псалмах (62 розділи), також в RST/SNG/ZEC/ROM.

**Конкретний приклад — Псалом 3:**
| Переклад | Вірш 1 | Вірш 2 |
|----------|--------|--------|
| Macula (MT) | «Господи, як зросли мої вороги» (заголовок = вірш 1) | «Багато хто говорить...» |
| KJV | (заголовок пропущений) | «Господи, як зросли мої вороги» |

Коли користувач тапає на KJV вірш 1 → код завантажує Macula слова для вірша 1 → показує слова заголовку, а не тексту. Потрібен мепінг: `KJV вірш 1` → `Macula вірш 2`.

---

## Рішення: таблиця `verse_map`

Pre-computed mapping будується один раз окремим Python-скриптом при зміні перекладів у DB.

### DDL

```sql
CREATE TABLE verse_map (
    translation  TEXT NOT NULL,
    book_id      TEXT NOT NULL,
    chapter      INT  NOT NULL,
    trans_verse  INT  NOT NULL,   -- номер вірша в перекладі
    macula_verse INT  NOT NULL,   -- відповідний номер вірша в Macula (word таблиця)
    PRIMARY KEY (translation, book_id, chapter, trans_verse)
);

CREATE INDEX idx_verse_map ON verse_map(translation, book_id, chapter);
```

**Зберігаємо тільки non-identity рядки** (де `trans_verse != macula_verse`). Це мінімізує розмір таблиці.

---

## Алгоритм побудови (Python, `build_verse_map.py`)

```python
# 1. Знаходимо розділи де кількість віршів відрізняється між перекладом і Macula
SELECT DISTINCT v.book_id, v.chapter, MAX(v.verse) AS tv_max, MAX(w.verse) AS mv_max
FROM verse v
JOIN word w ON w.book_id = v.book_id AND w.chapter = v.chapter
WHERE v.translation = ?
GROUP BY v.book_id, v.chapter
HAVING MAX(v.verse) != MAX(w.verse)

# 2. Для кожного такого розділу — greedy Strong's overlap alignment:
#    a. Збираємо Strong's номери для кожного Macula-вірша (з word таблиці)
#    b. Парсимо <S>N</S> теги з тексту перекладу для кожного translation-вірша
#    c. Для кожного translation-вірша знаходимо Macula-вірш з максимальним overlap
#    d. Зберігаємо тільки якщо overlap >= 2 і trans_verse != macula_verse
```

---

## Swift: три рівні пошуку (`ReaderViewModel.findBestMaculaVerse`)

```swift
private func findBestMaculaVerse(for verse: BibleVerse) -> Int {
    // Рівень 1: DB lookup — O(1) індексований запит
    if let mapped = db.findMaculaVerse(bookId: verse.bookId,
                                       chapter: verse.chapter,
                                       translationVerse: verse.number,
                                       translation: currentTranslation.id) {
        return mapped
    }

    // Рівень 2: Identity — більшість розділів не потребують корекції
    // Перевіряємо через Strong's overlap (мінімум 2 збіги)
    let prefix = (allBooks.first { $0.id == verse.bookId }?.testament == .new) ? "G" : "H"
    let parsedStrongs = Set(
        verse.parsed?.segments.flatMap(\.strongs).map { id in
            id.hasPrefix("S") ? prefix + id.dropFirst() : id
        } ?? []
    )
    guard parsedStrongs.count >= 2 else { return verse.number }

    let exactWords = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: verse.number)
    let exactStrongs = Set(exactWords.compactMap(\.strongsId))
    if parsedStrongs.intersection(exactStrongs).count >= 2 { return verse.number }

    // Рівень 3: Heuristic fallback ±2 вірші
    var bestVerse = verse.number
    var bestOverlap = parsedStrongs.intersection(exactStrongs).count
    for delta in [-1, 1, -2, 2] {
        let candidate = verse.number + delta
        guard candidate > 0 else { continue }
        let words = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: candidate)
        let overlap = parsedStrongs.intersection(Set(words.compactMap(\.strongsId))).count
        if overlap > bestOverlap { bestOverlap = overlap; bestVerse = candidate }
    }
    return bestVerse
}
```

---

## DatabaseService: `findMaculaVerse`

```swift
func findMaculaVerse(bookId: String, chapter: Int,
                     translationVerse: Int, translation: String) -> Int? {
    guard isAvailable else { return nil }
    var result: Int?
    let sql = """
        SELECT macula_verse FROM verse_map
        WHERE translation = ? AND book_id = ? AND chapter = ? AND trans_verse = ?
        """
    query(sql, bindings: [translation, bookId, chapter, translationVerse]) { stmt in
        result = Int(sqlite3_column_int(stmt, 0))
    }
    return result
}
```

---

## Де викликається

В `loadWordsForSelectedVerse()`:

```swift
func loadWordsForSelectedVerse() {
    guard let verse = selectedVerse else { return }
    let maculaVerse = findBestMaculaVerse(for: verse)   // ← тут
    let words = db.loadWords(bookId: verse.bookId, chapter: verse.chapter, verse: maculaVerse)
    // ... оновлення verses[] і selectedVerse
}
```

---

## Масштаб

- **7 292 рядки** в `verse_map` (non-identity mappings)
- **459 розділів** де є зсув (з усіх ~1 189 розділів Біблії)
- Переклади з найбільшою кількістю зсувів: RST (Синодальний), KJV
- Книги: Псалми (62 розділи), Пісня пісень, Захарія, Римляни

---

## Файли в проекті

| Файл | Роль |
|------|------|
| `build_verse_map.py` | Build-time скрипт, запускати при додаванні нових перекладів |
| `SourceBible/Services/DatabaseService.swift` | `findMaculaVerse()` метод |
| `SourceBible/ViewModels/ReaderViewModel.swift` | `findBestMaculaVerse()` + `loadWordsForSelectedVerse()` |

---

## Важливо для агента-імплементатора

1. `verse_map` зберігає **тільки non-identity** мепінги. Якщо вірш не знайдено в таблиці — використовується identity (trans_verse == macula_verse).
2. Strong's ID в parsed verse мають префікс `S` (наприклад `S1234`) — це placeholder. Перед порівнянням треба замінити на `H` (OT) або `G` (NT).
3. `DatabaseService` використовує сирий SQLite3 C API (без ORM), тому `findMaculaVerse` використовує `query()` хелпер і `sqlite3_column_int`.
4. `loadWordsForSelectedVerse()` оновлює і `verses[idx]` і `selectedVerse` щоб SwiftUI побачив зміни через `@Published`.
