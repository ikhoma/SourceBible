# Verse Sharing — System Design

**Status:** Draft  
**Date:** 2026-06-06

---

## 1. Functional Requirements

- User can share any Bible verse via the iOS native share sheet (Messages, Mail, copy to clipboard, AirDrop, third-party apps, etc.)
- Shared payload contains:
  - Verse text (plain text, no markup tags)
  - Full reference: Book name · Chapter · Verse number
  - Translation abbreviation (e.g. "KJV", "RST")
- Share is triggered from the verse bottom sheet (primary) and optionally from the verse row long-press context menu (secondary, P1)
- No network calls required — all data is already in memory at trigger time

---

## 2. Non-Functional Requirements

- Zero latency — share sheet opens instantly; no DB query at share time
- No new dependencies — uses SwiftUI `ShareLink` (available iOS 16+, safe for iOS 18 target)
- Localized book name — respects the active UI language (BibleBookNames dual-lang already implemented)

---

## 3. Data Available at Share Time

All required data is already loaded in `ReaderViewModel` when a verse is selected:

| Field | Source |
|---|---|
| Verse plain text | `BibleVerse.text` |
| Book name (localized) | `ReaderViewModel.currentBook.name` |
| Chapter | `BibleVerse.chapter` |
| Verse number | `BibleVerse.number` |
| Translation abbreviation | `ReaderViewModel.currentTranslation.id` (e.g. "KJV") |
| Translation full name | `ReaderViewModel.currentTranslation.name` |

No additional DB query is needed.

---

## 4. Share Text Format

```
{verse text}

— {Book} {chapter}:{verse} ({translation id})
```

**Example:**

```
In the beginning God created the heavens and the earth.

— Genesis 1:1 (KJV)
```

**Rationale:**
- Em dash attribution is a widely recognized quote convention
- Translation ID (not full name) keeps the reference line short — "KJV" reads better than "King James Version" in a shared message
- Two newlines before the attribution give visual breathing room in all share targets (Messages, Notes, etc.)

---

## 5. Components

### 5.1 `VerseShareFormatter` (new file)

Pure value type — no state, no imports beyond Foundation.

```swift
// SourceBible/Services/VerseShareFormatter.swift

struct VerseShareFormatter {
    /// Formats a verse into a shareable plain-text string.
    static func format(
        verse: BibleVerse,
        bookName: String,
        translationId: String
    ) -> String {
        let ref = "\(bookName) \(verse.chapter):\(verse.number) (\(translationId))"
        return "\(verse.text)\n\n— \(ref)"
    }
}
```

Keeping it `static func` (not a computed property on `BibleVerse`) avoids coupling the model to formatting logic and keeps the model layer lean.

### 5.2 Share trigger — bottom sheet (P0)

Add a share button to `VerseBottomSheetView` (or equivalent verse detail view). When the user has a verse selected and taps share:

```swift
// Inside the verse bottom sheet header/toolbar area
if let verse = viewModel.selectedVerse {
    let text = VerseShareFormatter.format(
        verse: verse,
        bookName: viewModel.currentBook.name,
        translationId: viewModel.currentTranslation.id
    )
    ShareLink(item: text) {
        Label("Share", systemImage: "square.and.arrow.up")
    }
}
```

`ShareLink` with a `String` item uses `Transferable` conformance built into `String` — no custom `Transferable` implementation needed.

### 5.3 Share trigger — verse row context menu (P1)

Long-press context menu on a `VerseRow` in the reader list. Lower priority because the bottom sheet is the primary interaction pattern for verse-level actions.

```swift
// On VerseRow
.contextMenu {
    ShareLink(item: VerseShareFormatter.format(
        verse: verse,
        bookName: bookName,
        translationId: translationId
    )) {
        Label("Share", systemImage: "square.and.arrow.up")
    }
}
```

`bookName` and `translationId` need to be passed down or accessed via environment — see §6 for options.

---

## 6. Data Flow

```
ReaderViewModel
  ├── currentBook.name        ─┐
  ├── currentTranslation.id   ─┤──► VerseShareFormatter.format() ──► String ──► ShareLink
  └── selectedVerse           ─┘
```

For the bottom sheet, all three are available directly on `viewModel` — no threading concern, everything is `@MainActor`.

For the context menu in the reader list, `VerseRow` receives `verse` and `bookName`/`translationId` as parameters (already passed down for rendering).

---

## 7. File Placement

```
SourceBible/
└── Services/
    └── VerseShareFormatter.swift    ← new file
```

The formatter lives in `Services/` (pure logic, no UI), not in `Views/` or `Models/`.

---

## 8. iOS API Notes

- `ShareLink` — SwiftUI native, iOS 16+. Safe for iOS 18 deployment target. No `#available` guard needed.
- `ShareLink(item: String)` opens `UIActivityViewController` under the hood. Works with all system share destinations including copy, AirDrop, Messages, Mail, third-party apps.
- Do NOT use `UIActivityViewController` directly — `ShareLink` is the correct SwiftUI API and handles presentation context automatically (avoids the "sourceView for iPad" boilerplate).
- Do NOT wrap in a `Button` + `.sheet` — `ShareLink` is itself a `View` that acts as a button.

---

## 9. Trade-offs

| Decision | Alternative | Reason for choice |
|---|---|---|
| Plain text only | Image card (verse on background) | Image requires async render + export; plain text is instant, works everywhere, indexable |
| Translation abbreviation in ref | Full translation name | "KJV" is shorter and more recognizable than "King James Version" in quoted context |
| Static formatter in Services/ | Computed var on BibleVerse | Keeps model clean; formatting is a presentation concern, not a model concern |
| ShareLink over UIActivityViewController | UIActivityViewController | ShareLink handles iPad popover anchor automatically; idiomatic SwiftUI |

### Future: image card sharing (v1.5 candidate)
A `VerseCardRenderer` could generate a UIImage (verse text + reference on a styled background) for visually rich shares to Instagram Stories, etc. This would be additive — the plain-text share path remains the default.

---

## 10. Out of Scope

- Deep link URL in share payload (requires URL scheme design — separate ADR)
- Per-translation full name in share text (can be toggled via Settings in future)
- Multiple verse selection share (future)
- Image card generation (v1.5)
