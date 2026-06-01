# ADR-014: VerseTextView Cache Invalidation via SwiftUI `.id()`

**Status:** Accepted  
**Date:** 2026-06-01  
**Deciders:** Ivan

---

## Context

`VerseTextView` is a `UIViewRepresentable` that renders `ParsedVerse` via `UITextView`. Its `Coordinator` caches `baseAttributedString` to avoid rebuilding the full attributed string on every SwiftUI update — in particular, word-selection highlight changes (frequent user action) should be cheap and not require a full rebuild.

The original cache invalidation heuristic in `updateUIView` was:

```swift
let contentChanged = coord.parsed.verseId != parsed.verseId
                  || coord.highlightColor  != highlightColor
```

**Bug:** `verseId` encodes `"BOOK|chapter|verse"` (e.g. `"PSA|1|1"`). It does not encode which translation is rendered. When the user switches translation via the picker, `verseId` and `highlightColor` are identical for every verse — so `contentChanged = false`, the cache is not invalidated, and stale text from the previous translation remains on screen.

**Attempted band-aid (rejected):** Adding `coord.parsed.plainText != parsed.plainText` to the heuristic. This computes a string join on every `updateUIView` call and is structurally wrong — it extends a fragile heuristic rather than eliminating it. Any future input that affects rendering (font size preference, RTL language, etc.) would require yet another line.

---

## Decision

Use SwiftUI's `.id()` modifier on `VerseTextView` to encode all content-identity inputs. When `.id()` changes, SwiftUI tears down the `UIViewRepresentable` entirely and creates a fresh one with a new `Coordinator` — no cache, no heuristic needed.

The `.id()` string encodes:
- `verse.id` — which verse
- `translationId` — which translation is rendered
- `verse.highlightColor` — highlight state (part of attributed string base)

```swift
VerseTextView(...)
    .id("\(verse.id)-\(translationId)-\(verse.highlightColor ?? "none")")
```

The `contentChanged` heuristic inside `updateUIView` is **retained** in its original two-line form for the case it was actually designed for: selection-state changes within the same content (word tap, ‹ › navigation). Since `.id()` guarantees the coordinator never sees a content change, the heuristic is always correct in the scope it now covers.

---

## Options Considered

### Option A: `.id()` on `VerseTextView` (chosen)

| Dimension | Assessment |
|-----------|------------|
| Correctness | Structurally correct — impossible to have stale content |
| Complexity | Low — three lines changed |
| Performance | Translation change: O(verses) UITextView recreations — acceptable, infrequent |
| Selection fast path | Preserved — `.id()` doesn't change on word tap |
| Future inputs | Any new content input goes into `.id()` string — one place |

**Pros:**
- Delegates content-identity tracking to SwiftUI, which is designed for it
- `updateUIView` heuristic becomes trivially correct (it only ever sees same-content updates)
- Adding a new rendering input (e.g. font size) requires one addition to the `.id()` string, not hunting through heuristic logic

**Cons:**
- Full `UITextView` recreation on translation change (vs. just rebuilding attributed string). In practice: ~30 verses per chapter, each recreation is trivial, and translation switching is a rare gesture.

### Option B: Add `plainText` to `contentChanged` heuristic (rejected band-aid)

| Dimension | Assessment |
|-----------|------------|
| Correctness | Fixes this specific bug but leaves the heuristic fundamentally fragile |
| Performance | Calls `.plainText` (string join) on every `updateUIView`, including word taps |
| Complexity | Extends wrong-shaped code |

**Rejected** — fixes a symptom, not the design.

### Option C: Remove the coordinator cache entirely — always rebuild

| Dimension | Assessment |
|-----------|------------|
| Correctness | Trivially correct |
| Performance | Rebuilds `NSAttributedString` on every word tap / selection change — perceptible lag on longer verses |

**Rejected** — the cache exists for a real reason. Word selection events fire frequently during long-press and tap interactions; rebuilding the attributed string on each one would cause visible jank.

---

## Trade-off Analysis

The key trade-off is between **correctness scope** and **recreation cost**:

- Option A pays the cost (UITextView recreation) only on translation change — rare, user-initiated, tolerable.
- Options B/C either pay it on every update (C) or leave correctness gaps (B).

Option A is the only choice that is both correct and performant under the actual usage pattern.

---

## Implementation

**`VerseRowView`** receives a new `translationId: String` parameter (default `""`):

```swift
struct VerseRowView: View {
    let verse: BibleVerse
    var translationId: String = ""
    ...
}
```

**Call site in `ReaderView`** passes `vm.currentTranslation.id`:

```swift
VerseRowView(
    verse: verse,
    translationId: vm.currentTranslation.id,
    ...
)
```

**`VerseTextView`** call site in `VerseRowView` applies `.id()`:

```swift
VerseTextView(...)
    .id("\(verse.id)-\(translationId)-\(verse.highlightColor ?? "none")")
```

**`VerseTextView.updateUIView`** reverted to original heuristic (two lines):

```swift
let contentChanged = coord.parsed.verseId != parsed.verseId
                  || coord.highlightColor  != highlightColor
```

---

## Consequences

**Easier:**
- Adding any new content-affecting input: one addition to `.id()` string
- Reasoning about `updateUIView` — it now only handles selection state changes
- Testing: translation switch is a guaranteed `UITextView` recreation, no edge cases

**No change:**
- Selection highlight fast path — `.id()` is stable during word taps
- Highlight color change — already in `.id()`, triggers recreation as before

**Watch:**
- If chapter navigation ever reuses `verse.id` across chapters (it doesn't currently — ids are `"BOOK|ch|verse"`), the `.id()` string would need `currentChapter` added. Not an issue today.
- If a future feature changes rendered text without changing translation (e.g. per-verse font size), that input must be added to `.id()`.

---

## Action Items

- [x] Revert `plainText` band-aid from `VerseTextView.updateUIView`
- [x] Add `translationId: String` to `VerseRowView`
- [x] Pass `vm.currentTranslation.id` at call site in `ReaderView`
- [x] Apply `.id()` modifier to `VerseTextView` in `VerseRowView`
- [ ] Verify fix in simulator: switch KJV → ASV → NASB → RST, confirm text updates immediately
