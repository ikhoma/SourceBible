# Системний дизайн: Уніфікований флоу Word Detail

**Status:** Draft (замінено `spec-original-nasb-bridge.md` — лишається як історія)

## Проблема

Два незалежних флоу відкривають «Слово / Значення» з різним вмістом:

| Джерело | Тип даних | Вміст |
|---|---|---|
| Оригінал pill → tap BibleWord card | `BibleWord` | Повний: морфологія, грецький, xlit, глоса |
| Переклад → long-press | `VerseSegment` | Обмежений: тільки Strong's lexical entry |

**Корінь причини:** `tapWord(_ segment:)` встановлює `selectedWord = nil`, тому `WordMeaningView` не має доступу до `BibleWord` і показує лише дані з `strongs` таблиці.

---

## Архітектура рішення

```
┌─────────────────────────────────────────────────────────────────┐
│                    Два джерела → один флоу                      │
│                                                                 │
│  Оригінал pill card tap          Translation long-press         │
│  tapWord(_ word: BibleWord)      tapWord(_ segment: VerseSegment)│
│          │                               │                      │
│          └──────────────────────────────┘                       │
│                           ↓                                     │
│             tapStrongsId(resolved: String, in: BibleVerse)      │
│                           ↓                                     │
│  1. loadWordsForSelectedVerse()   (if not already loaded)       │
│  2. selectedWord   = verse.words.first { $0.strongsId == id }   │
│  3. selectedSegment = verse.parsed?.segments.first              │
│                          { $0.strongs.contains(raw) }           │
│  4. loadStrongs(strongsId: resolved)                            │
│                           ↓                                     │
│               WordMeaningView (єдина реалізація)                │
│     [xlit] [морфологія] [глоса] [BDB def] [грецький еквів]     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Зміни (3 файли)

### 1. ReaderViewModel.swift — уніфікація tapWord

```swift
/// Called from VerseTextView long press — receives a VerseSegment.
/// Bridge: resolves Strong's ID → BibleWord so full morphology is shown.
func tapWord(_ segment: VerseSegment, in verse: BibleVerse) {
    selectedVerse = verse
    selectedSegment = segment
    bottomSheetMode = .word
    activeSheet = .verse

    // Ensure Macula BibleWord data is loaded for this verse
    if verse.words.isEmpty { loadWordsForSelectedVerse() }

    // Bridge: find matching BibleWord so WordMeaningView has full morphology/greek/xlit
    if let raw = segment.strongs.first {
        let resolved = resolveStrongsId(raw, bookId: verse.bookId)
        selectedWord = selectedVerse?.words.first { $0.strongsId == resolved }
    } else {
        selectedWord = nil
    }

    loadStrongs(for: segment, bookId: verse.bookId)
}

/// Called from OriginalWordsView (Оригінал pill) — receives a Macula BibleWord.
func tapWord(_ word: BibleWord, in verse: BibleVerse) {
    selectedVerse = verse
    selectedWord = word
    selectedSegment = nil
    bottomSheetMode = .word
    activeSheet = .verse
    // Sync segment so translation text highlights the same word
    syncSegment(for: word)
    loadStrongs(for: word)
}
```

**Ключова зміна в `tapWord(_ segment:)`:**
- `loadWordsForSelectedVerse()` якщо `verse.words.isEmpty`
- `resolveStrongsId(raw, bookId:)` → точно та сама функція що в `loadStrongs(for:segment:)`
- `selectedVerse?.words.first { $0.strongsId == resolved }` → підв'язуємо BibleWord

Після цього `WordMeaningView` отримує `vm.selectedWord != nil` і показує повний вміст незалежно від джерела.

---

### 2. VerseTextView.swift — non-clickable частки

Граматичні частки (прийменники בְּ, сполучники וְ, означений артикль הָ) мають Strong's sub-entry IDs: H871a, H2050b, H1886d тощо. Вони закінчуються на малу літеру після цифри.

```swift
/// Returns true if ALL Strong's IDs in this segment are grammatical particles
/// (sub-entry Strong's: H871a, H2050b — always ends with lowercase letter).
/// Particles have minimal info → don't open Word detail on tap/long-press.
private func isParticleSegment(_ strongs: [String]) -> Bool {
    guard !strongs.isEmpty else { return false }
    return strongs.allSatisfy { id in
        guard let last = id.last, last.isLetter, last.isLowercase else { return false }
        let withoutLast = id.dropLast()
        return withoutLast.last?.isNumber == true
    }
}
```

У `handleLongPress` (або там де викликається `onWordTap`):

```swift
let seg = parsed.segments[segIndex]
guard !seg.strongs.isEmpty,
      !isParticleSegment(seg.strongs) else { return }  // ← нова умова
onWordTap(seg)
```

В `buildAttributedString` — частки отримують звичайний стиль (без underline-індикатора):

```swift
// Підкреслення тільки для кліковних слів (не частки, не порожні strongs)
let isClickable = !seg.strongs.isEmpty && !isParticleSegment(seg.strongs)
if isClickable {
    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
    attrs[.underlineColor] = UIColor.label.withAlphaComponent(0.3)
}
```

---

### 3. WordMeaningView (WordTabContent.swift) — xlit пріоритет (вже є логіка)

```swift
// headerSection — pріоритет (вже є в коді, переконатись що застосований):
let xlit: String = {
    if let ctx = vm.selectedWord?.xlit, !ctx.isEmpty { return ctx }   // Macula — завжди вірний
    if !entry.xlitSimple.isEmpty { return entry.xlitSimple }           // TBESH lemma
    return entry.transliteration                                        // Academic fallback
}()
```

Після уніфікації `tapWord`, `vm.selectedWord?.xlit` завжди буде заповнений (якщо Macula має дані для слова), навіть при long-press на переклад.

---

## Non-functional: NASB як canonical markup (roadmap)

**Проблема:** KJV/ASV мають неповну розмітку Strong's у MyBible форматі → деякі слова не кліковні.

**Поточний стан:** `parsed` будується in-app з raw MyBible тексту через `VerseParser`. Кожен переклад має свою розмітку.

**Рішення (окремий DB спринт):**

```sql
-- Нова таблиця в build_db.py:
CREATE TABLE verse_markup (
    book_id  TEXT NOT NULL,
    chapter  INTEGER NOT NULL,
    verse    INTEGER NOT NULL,
    -- JSON-encoded list of {text, strongs, isParticle}
    -- populated from NASB (найповніша розмітка)
    canonical_markup TEXT,
    PRIMARY KEY (book_id, chapter, verse)
);
```

В `DatabaseService.loadChapter()`:
```swift
// При завантаженні будь-якого перекладу — overlay Strong's з canonical_markup
// де власна розмітка перекладу порожня
let canonicalSegments = db.loadCanonicalMarkup(bookId, chapter, verse)
// Merge: для кожного слова в parsed, якщо strongs.isEmpty → взяти з canonical
```

**Trade-off:** NASB текст ≠ KJV текст, тому alignment не ідеальний. Overlay підходить для Strong's-тільки (без вирівнювання тексту). Повний alignment (NLP-based) — окремий проєкт.

---

## Перевірка після імплементації

| Сценарій | Очікуваний результат |
|---|---|
| Long-press "Blessed" (KJV Ps 1:1) | WordMeaningView: אָשֵׁר, xlit "ʾāšer", морфологія, BDB def, грецький εὐδαίμων |
| Tap H835 card в Оригінал pill | Ідентичний вміст як вище |
| Long-press "the" або "and" | Нічого не відбувається (частка, non-clickable) |
| Стрілки ← → в word mode | Навігація по Macula словах вірша (вже є) |
| Змінити переклад → назад до слова | Вміст оновлюється (concordance перезавантажується) |

---

## Файли

| Файл | Зміна |
|---|---|
| `ViewModels/ReaderViewModel.swift` | `tapWord(_ segment:)` — bridge до BibleWord |
| `Views/Reader/VerseTextView.swift` | `isParticleSegment()` + guard у long-press handler |
| `Views/BottomSheet/WordTabContent.swift` | xlit пріоритет (вже частково є) |
| `scripts/build_db.py` | (roadmap) `verse_markup` canonical table з NASB |
