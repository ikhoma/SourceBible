# spec — Windowed Verse Rendering (Doom-style) for Fast Verse Open

**Status:** Draft / Proposed (fallback) — write only if the `setVerseHeight` hotfix (below) proves insufficient.
**Related:** ADR-021 (Study Mode — Verse Pinning & Sheet Sizing), ADR-024 (Cross-Reference Back-Stack), `ReaderView.swift`, `ReaderViewModel.swift`, `StudyScrollApplier.swift`, `StudySheetDetent.swift`.
**Inspiration:** Doom's pseudo-3D renderer — render only what the player can currently see, defer the rest.

---

## Problem

Opening a verse in **another chapter/book** (from Search) presents the Study sheet at the
`screenH * 0.45` fallback size ~2/3 of the time, instead of sizing to the focus verse.

Root cause is a layout-measurement race. The reader builds **every** verse row of the
chapter eagerly in a plain `VStack` (`ReaderView.swift` `ForEach(vm.verses)`), and each
row is a UITextView-backed renderer (`VerseRowView`). For a large chapter the eager
layout pass is slow — Ps 119 = **176 UITextViews** assembled before anything shows. The
Search path adds a tab switch (`ContentView.onChange(pendingVerseId)` → `selectedTab = .bible`)
plus a deferred `Task` before `navigateToVerse` presents the sheet, so the sheet resolves
its detent **before** the freshly-loaded rows are measured → `pinnedVerseHeight == 0` →
fallback. Severity scales with chapter size: worst on Ps 119, near-invisible on small
chapters (why warm cross-ref into a small chapter looked fine).

### Hotfix already applied (2026-06-22)

`ReaderViewModel.setVerseHeight(_:for:)` now calls `objectWillChange.send()` when the
row that just measured is the selected verse. This makes sheet sizing **independent of
layout timing** — the sheet self-corrects to the real height the instant the focus row
is measured, regardless of chapter size or entry path. This spec is the **next step** if
that correctness fix is not enough (e.g. the half-second wall-build itself is still too
slow / janky on large chapters and we want to cut the layout cost, not just tolerate it).

**Scope reminder:** this spec targets ONLY the "open a verse fast from another
chapter/book" case. In-chapter reading, tap-to-study, chevron nav, and cross-ref within
a loaded chapter already work and must not regress.

---

## Idea — render a window, not the whole wall

Instead of building the chapter from verse 1, build a small window around the focus verse
and present immediately; assemble the rest later, hidden under the sheet.

```
            ┌─ toolbar ──────────────┐
            │  (focus−2, focus−1)     │  ← tucked behind toolbar / status bar
focus ───▶  │  FOCUS VERSE (pinned)   │  ← only this must be correct on screen
            │  focus+1                 │
            │  …                       │  ← ~10–12 below = fills screen height
            │  focus+12                │
            └─ (sheet slides up) ──────┘
```

Window on open: roughly `[focus−2 … focus+12]` (tunable). Enough that:
- the focus verse can be pinned `toolbarGap` below the toolbar,
- the screen is filled below it before the sheet covers it,
- a couple of verses sit above (and behind the toolbar, so their exactness doesn't matter).

The **chapter title/heading is always rendered** as the topmost element — it provides the
headroom needed to scroll the focus verse up to the anchor even when the focus verse is
near the start of the chapter (mitigates the "not enough room above" concern; covers-on,
the book cover serves the same role on chapter 1).

After present (scroll is **locked** in Study Mode per ADR-021, so the rest of the chapter
is not needed while the sheet is open), assemble the remaining verses either:
- **(A) on sheet dismiss** — fully hidden under the dismiss animation, simplest; or
- **(B) in the background** while the sheet is open — needs the prepend-without-jump
  handling below, but makes an immediate post-dismiss scroll smooth.

Recommendation: start with **(A)**; only do (B) if post-dismiss scrolling feels unbuilt.

---

## Hard problems to solve (do not hand-wave)

1. **Pin headroom.** Pinning relies on content above the focus verse to absorb the scroll
   (ADR-021 Decision 2). The window keeps the chapter heading (+ book cover on ch.1) +
   1–2 verses, which should suffice — but the "focus verse is verse 1/2" and "title alone
   isn't tall enough to reach `pinnedTopAnchorY`" cases need an explicit clamp, or the
   verse lands too high under the toolbar.

2. **Prepend without scroll jump (only for option B / chevron-up growth).** Inserting
   verses *above* the current viewport shifts content down → the focus verse twitches
   unless `contentOffset` is compensated by the exact inserted height. SwiftUI `ScrollView`
   has no native "maintain position on prepend." Options: measure inserted block height and
   adjust offset on the same runloop; iOS 17 `scrollPosition(id:)` / `.defaultScrollAnchor`;
   or a UIKit-level offset compensation in the existing applier. The covering toolbar/sheet
   hides the reflow region, but the focus verse offset must still be compensated precisely.

3. **Chevron nav must stay inside the window.** Toolbar `‹ ›` verse nav (ADR-021/R5) walks
   within the chapter. The realized window must grow ahead of the cursor (e.g. when the
   user chevrons within N of an edge, extend that side), without a visible jump (see #2 for
   the upward case).

4. **Interaction with `StudyPinView` offset math.** `newOffset.y = contentOffset.y +
   (verseGlobalTop − pinnedTopAnchorY)` assumes the focus row exists and is measured. The
   window guarantees that. But `studyScrollRoom` (bottom inset for last-verse pinning) and
   the `StudyScrollClamper` exit clamp both assume full-chapter geometry — re-derive them
   for the windowed case so exit/last-verse behavior doesn't regress.

5. **`.id()` / recreation churn.** Rows use `.id(verse.id)` and the ScrollView resets via
   `.id(currentChapter)`. Growing the window must not retrigger the chapter-level `.id`
   reset (which would rebuild everything — defeating the point).

---

## Proposed model (sketch — to be detailed before implementation)

- `ReaderViewModel.renderedRange: Range<Int>` — indices into `verses` currently realized.
  Defaults to full range for normal reading; set to a window when entering via
  `navigateToVerse` from a cold/foreign chapter.
- `ForEach(vm.verses[vm.renderedRange])` (or a windowed slice helper) instead of all
  `vm.verses`; heading/cover always rendered above.
- On present: set window around focus, pin, present.
- On dismiss (option A): `renderedRange = verses.indices` → full chapter assembles under
  the dismiss animation.
- Chevron near edge: widen `renderedRange` on the relevant side; if widening upward, apply
  the prepend-offset compensation.

---

## Acceptance criteria

- Opening Ps 119:41 (or any verse) from Search in a different book/chapter sizes the sheet
  to the focus verse on the **first** present, every time (no 50% fallback), and faster
  than building the full chapter.
- Focus verse pins exactly `toolbarGap` below the toolbar — including when it is among the
  first verses of the chapter.
- No visible jump of the focus verse when the rest of the chapter assembles.
- Chevron `‹ ›` nav across the whole chapter still works; no jump when crossing the
  original window edge.
- Study-Mode exit (Back + swipe-down) leaves the reader correctly positioned with no empty
  gap (ADR-021 Decision 3 preserved).
- In-chapter tap-to-study and within-chapter cross-ref unchanged.

## Open questions

- Window sizes (`above`, `below`) — tune per device height; derive `below` from screen
  height / min row height so it always fills the screen.
- Option A vs B as the default assembly trigger.
- Does deferring assembly affect analytics (`incVersesOpened`) or word-loading timing?
- Memory/CPU win measurement: profile eager-176 vs windowed-14 on a real device.
