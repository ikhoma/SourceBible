# System Design: Book Covers

**Status:** Draft  
**Date:** 2026-06-05  
**Related:** PDR-Book-Covers.md, ReaderView.swift

---

## 1. Requirements

### Functional
- Show a full-bleed cover at the top of every book's **chapter 1 only**
- Cover: blue gradient background + optional Doré engraving + typographic overlay ("THE BOOK OF · BOOKNAME · SECTION · CHAPTER COUNT")
- Psalms special case: right metadata shows "PSALMS 1–41" (Book One subdivision) instead of chapter count
- User can **hide covers** via Menu → Reading toggle; reverts to the existing Large Title layout. Covers are **on by default** — the toggle is "Hide Book Covers", not "Show Book Covers"
- Works for **all 66 books** — books without a Doré image degrade gracefully to text-only cover
- Replaces the current Genesis-only test header (`genesis_header` + `.blendMode(.multiply)`)

### Non-functional
- Identical appearance in **light and dark mode** (cover is always blue — immune to color scheme)
- No layout jank: cover → chapter content transition must be seamless within the existing `VStack` scroll
- Adding a new Doré image for a book = drop PNG into xcassets, add one line to a dictionary. No code changes elsewhere.
- iOS 18 minimum; no iOS 26-exclusive APIs used in the cover

### Constraints
- SwiftUI, Swift 6 strict concurrency, `@MainActor` view layer
- DB-loaded `BibleBook.chapterCount` is the authoritative source for chapter counts — do not hardcode
- Existing scroll, sheet-open inset, and `ignoresSafeArea` logic in `ReaderView` must keep working

---

## 2. High-Level Design

```
ReaderView (existing)
  └── VStack (existing — plain, NOT lazy)
       ├── [chapter == 1] BookCoverView          ← NEW
       │     ├── ZStack
       │     │    ├── RadialGradient (blue bg)
       │     │    ├── Image(assetName)            ← optional, .hardLight blend
       │     │    └── VStack (text overlay)
       │     │         ├── "THE BOOK OF" (tracked)
       │     │         ├── BOOKNAME (scaled)
       │     │         └── HStack: section · right-meta
       │     └── .frame(height: 280)
       │
       └── [chapter == 1, cover OFF] Text(bookName) largeTitle (existing path)
```

**Control flow:**
1. `ReaderView` reads `@AppStorage("showBookCovers")` (default `true`)
2. If `true` AND `vm.currentChapter == 1` → show `BookCoverView`
3. `BookCoverView` queries `BookCoverData.info(for: bookId, chapterCount: vm.currentBook.chapterCount)` → `CoverInfo`
4. `CoverInfo.imageName` → `UIImage(named:)` guard → show image or skip silently
5. If cover is shown, `ScrollView` keeps `.ignoresSafeArea(.top)` so the cover bleeds behind the nav bar (same as Genesis header today)

**`ignoresSafeArea` invariant:** the flag must follow the cover state exactly. Currently `showsGenesisHeader` drives both the image render and the `ignoresSafeAreaIf`. Replacing it with `showsBookCover = showBookCovers && currentChapter == 1` preserves this invariant.

---

## 3. Component Design

### 3.1 `BookCoverView` — `Views/Reader/BookCoverView.swift`

```
BookCoverView
  props: bookId: String, bookName: String, chapterCount: Int
  
  body:
    ZStack(alignment: .bottomLeading)
      RadialGradient(#3085CF → #25659D, center, r=260)   // Figma diamond approx
        .ignoresSafeArea(edges: .top)                     // fills behind nav bar
      
      if imageName != nil && UIImage(named: imageName!) != nil:
        Image(imageName!)
          .resizable().scaledToFill()
          .frame(width: 160, height: 210).clipped()
          .blendMode(.hardLight)                          // Figma: HARD_LIGHT
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.bottom, 32)                           // clear bottom-text zone
      
      VStack(alignment: .leading, spacing: 2)
        Text("THE BOOK OF")                              // tracking: 8
          .font(.system(size: 15, weight: .bold))
        Text(bookName.uppercased())                      // minimumScaleFactor: 0.35
          .font(.system(size: 58, weight: .bold))
          .lineLimit(1)
        HStack
          Text(sectionText)    // left
          Spacer()
          Text(rightMeta)      // right, .trailing alignment
        .font(.system(size: 11, weight: .bold))
        .padding(.top, 4)
      .padding(.horizontal, 24).padding(.bottom, 20)
    
    .frame(height: 280).frame(maxWidth: .infinity)
```

**Text color:** `Color(red: 0.984, green: 0.980, blue: 0.973)` (`#FBFAF9`) — always, regardless of color scheme.

**Why no `.colorScheme(.light)` override?** The cover is already on a blue background that swallows any system tint. Forcing `.light` would cause issues if children ever inspect `colorScheme` for other purposes. Just use literal hex colors throughout.

**Size rationale (Figma → points):**
| Figma | Frame 402×302px (iPhone 17 @1x) | Scale | Points |
|---|---|---|---|
| Cover height | 302px | 1:1 | **302pt** |
| "the book of" | 32px, tracking 10 | 390/402 ≈ 1 | 15pt + tracking 8 |
| Book name | 78px | × 0.75 (visual fit) | 58pt + `minimumScaleFactor(0.35)` |
| Metadata | 16px | × 0.7 | 11pt |

`minimumScaleFactor(0.35)` covers the worst case: "SONG OF SOLOMON" at 58pt would be ~340pt wide; scaling to 0.35 fits it at ~119pt which still reads well. In practice most names scale to 0.5–0.8.

---

### 3.2 `BookCoverData` — `Models/BookCoverData.swift`

```swift
enum BookCoverData {
    struct CoverInfo {
        let sectionText: String   // e.g. "THE\nLAW"
        let rightMetadata: String // e.g. "50\nCHAPTERS" or "PSALMS\n1–41"
        let imageName: String?    // xcassets name, nil = text-only cover
    }

    static func info(for bookId: String, chapterCount: Int) -> CoverInfo

    private static let coverImages: [String: String]  // bookId → asset name
    private static func sectionText(for bookId: String) -> String
    private static func rightMeta(for bookId: String, chapterCount: Int) -> String
}
```

**Section map** — all 66 books, Protestant canonical groupings per PDR-Book-Covers:

| Section text | Books |
|---|---|
| `THE\nLAW` | GEN EXO LEV NUM DEU |
| `HISTORICAL\nBOOKS` | JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST |
| `POETRY &\nWISDOM` | JOB PSA PRO ECC SNG |
| `MAJOR\nPROPHETS` | ISA JER LAM EZK DAN |
| `MINOR\nPROPHETS` | HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL |
| `THE\nGOSPELS` | MAT MRK LUK JHN |
| `ACTS` | ACT |
| `PAUL'S\nLETTERS` | ROM 1CO 2CO GAL EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM |
| `GENERAL\nLETTERS` | HEB JAS 1PE 2PE 1JN 2JN 3JN JUD |
| `PROPHECY` | REV |

**Image assets (initial):**

| Book | Asset name | Status |
|---|---|---|
| Genesis | `genesis_header` | ✅ exists |
| Psalms | `psalms_header` | ✅ exists |
| Exodus | `cover_exo` | ⏳ pending |
| Joshua | `cover_jos` | ⏳ pending |
| Amos | `cover_amo` | ⏳ pending |
| All others | — | text-only |

**Psalms right metadata** is hardcoded to `"PSALMS\n1–41"` because chapter 1 always falls in Psalms Book One. Future: if a Psalms-subdivision cover is shown for chapter 42+, pass `chapterNumber` through and branch on the Psalms book ranges.

---

### 3.3 Changes to `ReaderView.swift`

**Replace:**
```swift
private var showsGenesisHeader: Bool {
    vm.currentBook.id == "GEN" && vm.currentChapter == 1
}
```
**With:**
```swift
@AppStorage("hideBookCovers") private var hideBookCovers = false

private var showsBookCover: Bool {
    !hideBookCovers && vm.currentChapter == 1
}
```

**Replace** the `if showsGenesisHeader { ... } Text(bookName)` block with:
```swift
if showsBookCover {
    BookCoverView(
        bookId: vm.currentBook.id,
        bookName: BibleBookNames.full(for: vm.currentBook.id),
        chapterCount: vm.currentBook.chapterCount
    )
    .padding(.top, -12)
    .padding(.horizontal, -20)
    .padding(.bottom, 20)
    .ignoresSafeArea(edges: .top)
} else {
    Text(BibleBookNames.full(for: vm.currentBook.id))
        .font(.largeTitle).bold()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 8)
}
```

**Replace** `ignoresSafeAreaIf(showsGenesisHeader, ...)` → `ignoresSafeAreaIf(showsBookCover, ...)`.

> ⚠️ The `BookCoverView` already calls `.ignoresSafeArea(edges: .top)` on the gradient background internally. The outer `.ignoresSafeArea(edges: .top)` on the view in `LazyVStack` is **not** redundant — the inner one fills the gradient, while the outer one tells the `ScrollView` that its content bleeds behind the nav bar so it doesn't add extra top padding. Both are needed.

---

### 3.4 Changes to `MenuView.swift`

Add to the Reading section:
```swift
@AppStorage("hideBookCovers") private var hideBookCovers = false

Toggle("menu.hide_book_covers", isOn: $hideBookCovers)
    .tint(.blue)
```

Add localization key `"menu.hide_book_covers"` to `Localizable.xcstrings`:
- EN: `"Hide Book Covers"`
- UK: `"Сховати обкладинки книг"`

Semantics: toggle is **off by default** (covers visible). Turning it on hides covers and shows Large Titles instead — the exact same layout as before this feature.

---

## 4. Image Management

### Naming convention
All cover images live in `Assets.xcassets` as `cover_{bookId_lowercased}`, **except** the two legacy assets which keep their existing names:
- `genesis_header` → mapped in `coverImages["GEN"]`
- `psalms_header` → mapped in `coverImages["PSA"]`

New images follow `cover_exo`, `cover_jos`, `cover_amo`, etc.

### Adding a new cover (no code changes needed)
1. Export the Doré engraving PNG (B&W, ~150×200pt @2x) from Figma
2. Add to `Assets.xcassets` with the appropriate name
3. Add one entry to `coverImages` in `BookCoverData.swift`
4. Clean Build Folder (⇧⌘K) — Xcode caches asset catalogs

### Image sizing guidance
The image frame in the view is `width: 150, height: 200pt` (matching the Figma source frame exactly) with `.scaledToFill().clipped()`. Provide PNGs at `@3x` → **450×600px**; that covers all Face ID iPhones. The HARD_LIGHT blend mode works best with B&W or desaturated images — saturated images will produce unexpected color mixing with the blue background.

---

## 5. Dark / Light Mode

The cover is intentionally **mode-agnostic**:
- Background: explicit `RadialGradient` with literal RGB values — not a semantic color
- Text: explicit `#FBFAF9` — not `.primary` or `.label`
- Image blend: `.hardLight` over blue background produces the same result in both modes

No `.environment(\.colorScheme, .light)` override is needed or desired.

The chapter content below the cover (verse list, headings) continues to respond to the system color scheme normally.

---

## 6. Trade-offs

| Decision | Alternative considered | Why chosen |
|---|---|---|
| `BookCoverData` as a plain `enum` with static data | DB table or JSON config | Zero runtime overhead; covers change on app releases not at runtime; trivial to extend |
| `UIImage(named:)` nil-check in view body | Computed in `BookCoverData` | View body is `@MainActor`; UIImage check is cheap; keeps `CoverInfo` a simple value type |
| Hardcode Psalms Book One metadata | Dynamic lookup by chapter | Chapter 1 always = Book One; adds no complexity now; easy to extend later with chapter param |
| 280pt fixed cover height | Dynamic / GeometryReader | Matches Figma design (302pt frame ≈ 280pt at iPhone safe areas); avoids layout instability during scroll |
| Inner + outer `ignoresSafeArea` | One or neither | Inner fills the gradient to screen edges; outer keeps `ScrollView` unaware of the nav bar height — both are load-bearing |

---

## 7. What to Revisit Later

- **Psalms subdivisions (Books 1–5):** Extend `BookCoverData.rightMeta` to accept an optional `chapterNumber` and return the correct Psalms range (1–41, 42–72, 73–89, 90–106, 107–150). Currently only relevant if we ever show covers mid-book (not the current use case).
- **Localization of section labels:** Currently hardcoded in English. When UK localization is complete, `sectionText(for:)` should read `appLanguage` from UserDefaults and return the Ukrainian equivalents.
- **Animation:** Toggling "Show Book Covers" in Settings has no animation when the user returns to chapter 1. If this feels jarring, a `.transition(.opacity)` on the cover block in `ReaderView` would smooth it.
- **More Doré images:** 5 books currently have assets (GEN, PSA pending 3 more). The `coverImages` dictionary is the only place that needs updating.
