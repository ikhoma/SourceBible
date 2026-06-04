# Spec: Original Pill ↔ NASB Bridge

**Status:** Draft  
**Supersedes / extends:** `unified_word_lookup_system_design.md`

---

## Problem summary

Three related issues, one shared root:

| # | Problem | Root cause |
|---|---------|------------|
| 1 | All words in Original pill are tappable, including particles (בַּ, הָ, וּ) | `WordRow` wraps every word in a `Button` regardless of lexical weight |
| 2 | Tapping a word in Original pill shows fuller info than long-pressing the same word in verse text | `tapWord(_ segment:)` sets `selectedWord = nil`, so `WordMeaningView` gets no morphology/xlit/greek |
| 3 | Chevron navigation cycles all Macula words; selected word is not highlighted in verse text | `verseWordsWithStrongs` uses `strongsId != nil` (particles pass through); `tapWord(_ word:)` sets `selectedSegment = nil` instead of calling `syncSegment` |

---

## Data foundation: NASB as clickability signal

From the Psalm 1:1 analysis, the 21 Macula words split into two groups:

| Macula Strong | Category | NASB tag | Clickable |
|---|---|---|---|
| H835a, H376, H834, H1980, H6098, H7563, H3808×3, H5975, H1870, H2400, H3427, H4186, H3887a | Meaningful words | Yes (14 tags) | ✅ |
| H1886a (הָ), H871a×3 (בְּ), H2050b×2 (וְ) | Grammatical particles | No | ❌ |

**Why not match by NASB base number directly:**  
H3887a (לֵצִים, "mockers") has NASB tag H9238 — a Lockman-proprietary extended number. Base-number matching ("3887" ≠ "9238") would wrongly mark this word as non-clickable. Using morphology codes is both simpler and more accurate.

**Particle detection via morphology (primary criterion):**

| Morph first char | Part of speech | Clickable |
|---|---|---|
| `R` | Preposition | ❌ |
| `C` | Conjunction | ❌ |
| `T` | Particle / article | ❌ |
| `V`, `N`, `A`, `P`, `D`, `S`, `I` | Verb / Noun / Adj / Pronoun / Adverb / Suffix / Interjection | ✅ |

This exactly maps to the NASB clickable set for Ps 1:1 and generalises correctly across the OT.

---

## Design

### Shared helper — `baseStrongsNumber`

Both `syncSegment` and `selectedWordDisplayText` need to match Macula sub-entry IDs (H835**a**) against NASB base numbers (H835). Add one helper in `ReaderViewModel`:

```swift
/// Extracts the numeric core from a Strong's ID.
/// "H835a" → "835", "H3808" → "3808", "G2316" → "2316"
private func baseStrongsNumber(_ id: String) -> String {
    let digits = id.drop(while: { !$0.isNumber })
    return String(digits.prefix(while: { $0.isNumber }))
}
```

---

### Component 1 — Clickability (`ReaderViewModel.swift`)

Replace `verseWordsWithStrongs` with two properties:

```swift
/// All Macula words for the focused verse that have any Strong's ID.
/// Used to populate OriginalWordsView rows (particles included as non-interactive).
var verseWordsAll: [BibleWord] {
    selectedVerse?.words ?? []
}

/// Subset of verseWordsAll that are lexically meaningful (non-particle).
/// Used for: (a) chevron navigation in word mode, (b) disabling in WordRow.
var nasbClickableWords: [BibleWord] {
    verseWordsAll.filter { !isParticle($0) }
}

/// True when this word's morphology marks it as a grammatical particle
/// (preposition, conjunction, article/particle).
/// These map exactly to the words NASB leaves untagged.
func isParticle(_ word: BibleWord) -> Bool {
    guard let morph = word.morphology, let first = morph.first else { return false }
    return first == "R" || first == "C" || first == "T"
}
```

Update chevron navigation to use the new list:

```swift
func navigateToPreviousWord() {
    let words = nasbClickableWords          // ← was verseWordsWithStrongs
    guard let word = selectedWord,
          let idx = words.firstIndex(where: { $0.id == word.id }),
          idx > 0 else { return }
    let newWord = words[idx - 1]
    selectedWord = newWord
    syncSegment(for: newWord)
    loadStrongs(for: newWord)
}

func navigateToNextWord() {
    let words = nasbClickableWords          // ← was verseWordsWithStrongs
    guard let word = selectedWord,
          let idx = words.firstIndex(where: { $0.id == word.id }),
          idx < words.count - 1 else { return }
    let newWord = words[idx + 1]
    selectedWord = newWord
    syncSegment(for: newWord)
    loadStrongs(for: newWord)
}
```

Update disabled state in `VerseBottomSheetView`:

```swift
private var isPrevDisabled: Bool {
    if vm.bottomSheetMode == .verse { ... }
    else {
        guard let w = vm.selectedWord else { return true }
        return vm.nasbClickableWords.first?.id == w.id   // ← was verseWordsWithStrongs
    }
}

private var isNextDisabled: Bool {
    if vm.bottomSheetMode == .verse { ... }
    else {
        guard let w = vm.selectedWord else { return true }
        return vm.nasbClickableWords.last?.id == w.id    // ← was verseWordsWithStrongs
    }
}
```

Update `autoSelectFirstWordIfNeeded`:

```swift
func autoSelectFirstWordIfNeeded() {
    guard selectedWord == nil && selectedSegment == nil else { return }
    if let firstWord = nasbClickableWords.first {    // ← was verseWordsWithStrongs
        selectedWord = firstWord
        syncSegment(for: firstWord)
        loadStrongs(for: firstWord)
    }
}
```

---

### Component 2 — Unified word page (`ReaderViewModel.swift`)

#### Fix `tapWord(_ word: BibleWord)` — highlight on Original pill tap

Currently sets `selectedSegment = nil`, so verse text gets no highlight.

```swift
func tapWord(_ word: BibleWord, in verse: BibleVerse) {
    selectedVerse = verse
    selectedWord = word
    bottomSheetMode = .word
    activeSheet = .verse
    syncSegment(for: word)          // ← was selectedSegment = nil
    loadStrongs(for: word)
}
```

#### Fix `tapWord(_ segment: VerseSegment)` — bridge to BibleWord for full morphology

Currently sets `selectedWord = nil`, so `WordMeaningView` shows no morphology/xlit/greek.

```swift
func tapWord(_ segment: VerseSegment, in verse: BibleVerse) {
    selectedVerse = verse
    selectedSegment = segment
    bottomSheetMode = .word
    activeSheet = .verse

    if verse.words.isEmpty { loadWordsForSelectedVerse() }

    // Bridge: find the matching BibleWord so WordMeaningView gets full data
    if let raw = segment.strongs.first {
        let resolved = resolveStrongsId(raw, bookId: verse.bookId)
        let base = baseStrongsNumber(resolved)
        selectedWord = selectedVerse?.words.first {
            guard let sid = $0.strongsId else { return false }
            return baseStrongsNumber(sid) == base
        }
    } else {
        selectedWord = nil
    }

    loadStrongs(for: segment, bookId: verse.bookId)
}
```

#### Fix `syncSegment` — base-number matching

Currently compares `word.strongsId` ("H835a") against `segment.strongs` ("H835") — exact match fails for sub-entries.

```swift
private func syncSegment(for word: BibleWord) {
    guard let strongsId = word.strongsId,
          let segments = selectedVerse?.parsed?.segments else {
        selectedSegment = nil
        return
    }
    let base = baseStrongsNumber(strongsId)
    selectedSegment = segments.first { seg in
        seg.strongs.contains { baseStrongsNumber($0) == base }
    }
}
```

#### Fix `selectedWordDisplayText` — base-number segment lookup

Same mismatch in the title lookup:

```swift
var selectedWordDisplayText: String? {
    if let seg = selectedSegment {
        let t = seg.text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
    }
    if let word = selectedWord,
       let strongsId = word.strongsId,
       let parsed = selectedVerse?.parsed {
        let base = baseStrongsNumber(strongsId)           // ← was direct contains check
        if let segText = parsed.segments
            .first(where: { $0.strongs.contains { baseStrongsNumber($0) == base } })?
            .text.trimmingCharacters(in: .whitespaces),
           !segText.isEmpty {
            return segText
        }
    }
    return selectedWord?.text.trimmingCharacters(in: .whitespaces)
}
```

---

### Component 3 — Original pill rows (`VerseTabContent.swift` + `WordTabContent.swift`)

#### OriginalWordsView — show all words, pass clickability

```swift
struct OriginalWordsView: View {
    @EnvironmentObject var vm: ReaderViewModel

    // Show all Macula words (particles appear as non-interactive rows)
    private var words: [BibleWord] {
        vm.selectedVerse?.words ?? []
    }

    var body: some View {
        PillSection(title: sectionTitleKey) {
            if words.isEmpty {
                Text("verse.original.empty")...
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(words.enumerated()), id: \.element.id) { i, word in
                        WordRow(
                            word: word,
                            isSelected: vm.selectedWord?.id == word.id,
                            isClickable: !vm.isParticle(word)       // ← new param
                        ) {
                            if let verse = vm.selectedVerse {
                                vm.tapWord(word, in: verse)
                            }
                        }
                        if i < words.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}
```

#### WordRow — conditional interactivity

```swift
struct WordRow: View {
    let word: BibleWord
    let isSelected: Bool
    let isClickable: Bool          // ← new
    let onTap: () -> Void

    var body: some View {
        Group {
            if isClickable {
                Button(action: onTap) { rowContent(showChevron: true) }
                    .buttonStyle(.plain)
            } else {
                rowContent(showChevron: false)   // no tap, no chevron
                    .foregroundStyle(.secondary) // visual dimming for particles
            }
        }
    }

    private func rowContent(showChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.displayText)
                        .font(.system(size: 26, weight: .light))
                    if let xlit = word.displayXlit, !xlit.isEmpty {
                        Text(xlit).font(.callout).foregroundStyle(.secondary)
                    }
                    if let sid = word.strongsId {
                        Text(sid)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(UIColor.secondarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let morph = word.morphology,
                       let label = MorphologyDecoder.decode(morph, using: t) {
                        Text(label).font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                if let gloss = word.gloss, !gloss.isEmpty {
                    Text(gloss).font(.callout)
                }
            }
            Spacer(minLength: 8)
            if showChevron {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
```

---

## Data flow diagram

```
Tap word in Original pill          Long-press word in verse text
tapWord(_ word: BibleWord)         tapWord(_ segment: VerseSegment)
         │                                    │
         │ syncSegment(for: word)             │ bridge: find BibleWord by base number
         │   └─ baseStrongsNumber match       │ selectedWord = verse.words.first { ... }
         │   └─ selectedSegment = segment     │ selectedSegment = segment
         │                                    │
         └────────────────┬───────────────────┘
                          ↓
                 selectedWord = BibleWord  (full morphology/xlit/greek)
                 selectedSegment = VerseSegment  (drives verse text highlight)
                          ↓
              WordMeaningView (same output both paths)
              VerseTextView highlights matching segment
              selectedWordDisplayText = segment.text  (translation word)

Chevron navigation (← →)
nasbClickableWords (morph-gated, no R/C/T)
         │
         ├─ selectedWord = prev/next BibleWord
         ├─ syncSegment(for: newWord)  → selectedSegment → verse highlight
         └─ loadStrongs(for: newWord)
```

---

## Files changed

| File | Change |
|---|---|
| `ViewModels/ReaderViewModel.swift` | `baseStrongsNumber()` helper; `isParticle()` and `nasbClickableWords`; fix `tapWord(_ word:)`, `tapWord(_ segment:)`, `syncSegment`, `selectedWordDisplayText`; update navigation and disabled logic |
| `Views/BottomSheet/VerseTabContent.swift` | `OriginalWordsView`: remove `strongsId != nil` filter, pass `isClickable` to `WordRow` |
| `Views/BottomSheet/WordTabContent.swift` | `WordRow`: add `isClickable` param; conditional `Button` wrapper and chevron |
| `Views/BottomSheet/VerseBottomSheetView.swift` | `isPrevDisabled`/`isNextDisabled`: use `nasbClickableWords` |

---

## Verification scenarios

| Scenario | Expected |
|---|---|
| Tap H835a (אַשְׁרֵי) in Original pill | Word detail opens; title = "How blessed" (NASB text); morphology, xlit, BDB def shown; "blessed" highlighted in verse |
| Tap H871a (בַּ) row in Original pill | Nothing happens; row shows Hebrew + xlit + morph label only, no chevron |
| Long-press "blessed" in NASB verse | Same word detail as tapping from Original pill |
| Chevron ← → in word mode | Navigates between 14 non-particle words (Ps 1:1); skips בַּ / הָ / וּ |
| Each chevron step | Corresponding word highlighted in verse text |
| Navigate from Original pill, then chevron | Highlight tracks correctly |
| `autoSelectFirstWordIfNeeded` | First clickable word selected (H835a, "How blessed") |

---

## Relation to `unified_word_lookup_system_design.md`

This spec supersedes that document for the `tapWord` bridge and `syncSegment` changes. The `verse_markup` canonical DB table remains valid as a long-term roadmap item (improves Strong's coverage for KJV/ASV/RST whose markup is sparser than NASB), but is not required for these three fixes.

The `isParticleSegment()` approach described in the old spec (sub-entry letter suffix heuristic) is **replaced** by the morphology-based `isParticle()` function, which correctly handles H3887a (לֵצִים, "mockers") — a sub-entry that IS clickable but would be wrongly excluded by the letter-suffix heuristic.
