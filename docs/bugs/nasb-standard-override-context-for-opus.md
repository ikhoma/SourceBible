# Контекст для Opus — NASB↔Macula Strong's mismatch fix

## Проблема

Два пов'язаних баги в Prov 24:17 (системні по всьому ОТ):

1. **H341 non-clickable** у Verse Lexicon — NASB тегує "enemy" як `<S>340</S>`, Macula як `H341` → `isClickable()` повертає false
2. **Long-tap показує H340 замість H341** у NASB тексті — `tapWord(_ segment:)` шукає Macula word з `base == "340"`, не знаходить (там `"341"`) → falls back на NASB lexical entry (verb "be hostile") замість Macula (noun "enemy")

## Архітектура (ADR-016)

`nasbVerseStrongs: Set<String>` — base-номери з NASB `<S>NNN</S>` тегів для поточного вірша. `isClickable()` перевіряє чи є Macula word's base в цьому set.

Вже є `NASBExtendedOverride` (391 записів) для H9000+ NASB proprietary номерів — цей патерн треба розширити для стандартних H→H розбіжностей.

`baseStrongsNumber(_ id: String)` — стрипає H/G prefix і letter suffix: "H341" → "341", "H871a" → "871".

## Дані зі скрипту (find_nasb_macula_mismatches.py — вже запущено)

### Section A — Standard H→H, БЕЗПЕЧНІ записи (verb→noun/adj пари)

| NASB num | Macula base | Значення | Misses | Miss% | Conf |
|----------|-------------|----------|--------|-------|------|
| 340 | 341 | אָיַב "to be hostile" → אוֹיֵב "enemy" | 280 | 100% | 70% |
| 7534 | 7535 | lean/only variants | 109 | 100% | 69% |
| 7945 | 7578 | name variants (Shealtiel) | 138 | 99% | 61% |
| 7462 | 7473 | "to pasture" → "shepherd" | 82 | 99% | 63% |
| 3372 | 3373 | "to fear" → "fearing/reverent" | 62 | 100% | 66% |
| 2181 | 2185 | "to fornicate" → "harlotries" | 33 | 100% | 64% |

### Section A — НЕ додавати (небезпечні)

- `"430": "4210"` і `"430": "4905"` — H430 = Elohim (~9000 OT verses). Mapping до музичних термінів (Maskil/Maschil) = false positive скрізь. Плюс дубльований ключ у словнику (Swift dictionary literal — останній перезапише перший мовчки).
- H413→H935, H1931→H3117, H2063→H2088 — шум, потребують мануальної перевірки.

### Section B — Extended override gaps (нові, безпечні)

| NASB num | Macula base | Misses | Conf |
|----------|-------------|--------|------|
| 9111 | 2254 | 17 | 62% |
| 9478 | 6728 | 6 | 60% |

### Section C — Particles (нічого не міняти)

H4480 (5838 misses), H3808, H3588, H859, H589 тощо — справжні частки, очікувано non-clickable.

## Що треба реалізувати

### 1. Новий файл `SourceBible/Services/NASBStandardOverride.swift`

За зразком `NASBExtendedOverride.swift`:

```swift
// NASBStandardOverride.swift
// Auto-generated from find_nasb_macula_mismatches.py (2026-06-19)
// Maps NASB standard H-numbers → Macula base numbers where NASB and Macula
// systematically assign different (but related) Strong's numbers to the same word form.
// Pattern: NASB uses verbal root, Macula uses derived noun/participle entry.
//
// DO NOT ADD entries where the NASB key is a very common word (H430, H3068, etc.)
// — that would create false positives across thousands of unrelated verses.

extension ReaderViewModel {
    static let nasbStandardOverride: [String: String] = [
        "340": "341",   // אָיַב (verb "be hostile") → אוֹיֵב (noun "enemy")       280 misses
        "7534": "7535", // רַק variants                                              109 misses
        "7945": "7578", // שְׁאֵלְתִּיאֵל name variants                              138 misses
        "7462": "7473", // רָעָה (verb "to pasture") → רֹעֶה (noun "shepherd")      82 misses
        "3372": "3373", // יָרֵא (verb "to fear") → יָרֵא (adj "fearing")           62 misses
        "2181": "2185", // זָנָה (verb "to fornicate") → זְנוּנִים (noun "harlotry") 33 misses
    ]
}
```

### 2. `SourceBible/Services/NASBExtendedOverride.swift` — додати 2 рядки

В існуючий словник `nasbExtendedOverride` додати:
```swift
"9111": "2254",  // NASB H9111 → Macula H2254  miss=17× conf=62%
"9478": "6728",  // NASB H9478 → Macula H6728  miss=6× conf=60%
```

### 3. `SourceBible/ViewModels/ReaderViewModel.swift` — 2 зміни

#### Зміна A: `loadNASBStrongs(for:)` (~line 550)

Після existing extended override block, додати standard override:

```swift
private func loadNASBStrongs(for verse: BibleVerse) {
    let raw = db.loadNASBStrongs(bookId: verse.bookId, chapter: verse.chapter, verse: verse.number)
    var bases = Set<String>()
    for num in raw {
        bases.insert(num)
        // Existing: extended override (H9000+ NASB proprietary numbers)
        if let maculaBase = Self.nasbExtendedOverride[num] {
            bases.insert(maculaBase)
        }
        // NEW: standard override (cases where NASB uses different standard H-number than Macula)
        if let maculaBase = Self.nasbStandardOverride[num] {
            bases.insert(maculaBase)
        }
    }
    nasbVerseStrongs = bases
}
```

#### Зміна B: `tapWord(_ segment:, in verse:)` (~line 643) — Bug 2 fix

Після першого base-number lookup (який дає `selectedWord = nil` для H340 vs H341), додати fallback через standard override:

```swift
func tapWord(_ segment: VerseSegment, in verse: BibleVerse) {
    // ... existing code ...
    if let raw = segment.strongs.first {
        let resolved = resolveStrongsId(raw, bookId: verse.bookId)
        let base = baseStrongsNumber(resolved)
        selectedWord = selectedVerse?.words.first {
            guard let sid = $0.strongsId else { return false }
            return baseStrongsNumber(sid) == base
        }
        // NEW: if no direct match, try standard override (e.g. NASB H340 → Macula H341)
        if selectedWord == nil, let maculaBase = Self.nasbStandardOverride[base] {
            selectedWord = selectedVerse?.words.first {
                guard let sid = $0.strongsId else { return false }
                return baseStrongsNumber(sid) == maculaBase
            }
        }
    }
    if let word = selectedWord {
        loadStrongs(for: word)
    } else {
        loadStrongs(for: segment, bookId: verse.bookId)
    }
}
```

## Scale

- H340→H341 ("enemy"): **280 verses** — Ps (72), 1Sam (20), Jer (18), 2Sam (16), Lam (15), ...
- Решта 5 пар: ще ~424 verses
- **Разом ~700+ OT verses** де clickability і/або long-tap поведінка виправляється

## Файли для читання

| Файл | Де шукати |
|------|-----------|
| `SourceBible/ViewModels/ReaderViewModel.swift` | `isClickable()` ~line 178, `loadNASBStrongs(for:)` ~line 550, `tapWord(_ segment:)` ~line 643 |
| `SourceBible/Services/NASBExtendedOverride.swift` | Зразок структури для нового файлу |
| `docs/architecture/ADR-016-original-pill-nasb-bridge.md` | Архітектурний контекст |
| `docs/bugs/bug-H341-not-clickable-nasb-gating.md` | Повний bug report з code paths |

## Swift 6 / iOS constraints

- Strict concurrency увімкнено
- `nasbStandardOverride` — static let на extension ReaderViewModel (MainActor) — OK, read-only
- Deployment target: iOS 18 мінімум (але код вище не використовує iOS 26-only API)
- Python скрипти — Python 3.9 (не релевантно для цього fix)
