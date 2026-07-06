# ADR-026: Reader Chapter Paging via `TabView(.page)`

**Status:** Deferred to V1.5 (Phase-1 spike validated the feel, 2026-07-03)
**Date:** 2026-07-03
**Related:** ux-003 (smooth chapter transition), ux-001 (edge-only swipe / PDR-Page-Turn-Gesture-Zone), ADR-021 (Study-Mode scroll pinning), ADR-014 (VerseTextView cache invalidation), ADR-016 (word tagging)

## Context

The reader currently renders a chapter as a `ScrollView` + `ForEach` over verses.
Chapter navigation via the ‹ › chevrons calls `prevChapter()/nextChapter()`
(`ReaderViewModel.swift` 534–544), which just mutate `currentChapter` and call
`loadChapter()`. There is **no transition** — the chapter content swaps instantly and
the scroll jumps to top.

Tester feedback (ux-003, with video) asks for a smoother chapter transition "like
Apple Books". Research (see ux-003 on the board): Apple Books' Curl/Slide styles are
for **paginated fixed pages** (curl = UIKit `UIPageViewController.pageCurl`).
SourceBible chapters **scroll** and are variable-length, so page-curl doesn't fit; the
Books-equivalent for a scrolling reader is a horizontal **Slide** — exactly what
SwiftUI `TabView` with `.page` style provides natively.

Adopting paging also gives **native horizontal swipe** between chapters for free, which
addresses ux-001 (users expect a full-surface swipe; today paging is edge-only by
design to avoid gesture clashes — see PDR-Page-Turn-Gesture-Zone).

## Decision

Restructure the reader container as a **`TabView` in `.page` style**, one page per
chapter, bound to a chapter selection. Chevrons and swipe both change the selection and
get the native animated slide transition. Each page keeps the **existing** per-chapter
content view unchanged (same `VerseTextView`, covers, headings, pinning).

- iOS 26 value-based `TabView` selection; **guard with `#available(iOS 26, *)` + an
  iOS 18 fallback** (per the deployment-target rule; the current reader path is the
  fallback).
- Chevron buttons stay; they drive the same selection binding (bounds/disabled logic
  unchanged: `currentChapter <= 1` / `>= chapterCount`).
- **Lazy mounting:** only current ± 1 chapter pages are realised (avoid loading the
  whole book); reuse the existing per-chapter load path.

## Scope

**In scope (may change):** the reader's chapter container in `ReaderView.swift`; how
`currentChapter` maps to a `TabView` selection; chevron actions bound to selection;
adjacent-chapter prefetch.

**Out of scope (must NOT change):** the per-verse content view and word/verse
interactions (ADR-016), the DB, `sourcebible.db`, Study-Mode business logic, cross-ref
back-stack (ADR-024), analytics.

**Must be preserved (hard "don't regress"):**
- ADR-021 Study-Mode scroll pinning + sheet sizing rules (verse pin, no top inset,
  clamp, interactive dismiss). Study Mode's ‹ › retarget to prev/next verse/word — this
  ADR only changes **reader-level** chapter paging, not the in-sheet chevrons.
- ADR-014 `.id()` cache invalidation keyed on `verseId+translationId+highlightColor`.
- Book covers (ADR-017) and chapter headings render per page as today.
- Verse anchor restore (`pendingRestoreAnchorId`) and reading-position save.

## Non-goals

- UIKit page-curl (unsuitable for scrolling, variable-length chapters).
- Changing the edge-only vs full-surface swipe *policy* beyond what native paging
  gives; if native full-surface swipe now conflicts with word tap / long-press /
  selection, that conflict must be evaluated (may require gating) — record as an
  amendment, don't silently ship a regression. Update PDR-Page-Turn-Gesture-Zone if the
  edge-only decision is superseded.

## Plan (phased, to de-risk)

**Phase 1 — Spike (throwaway, on an isolated branch/worktree).** Wrap only the plain
reader (non-Study) chapters in `TabView(.page)` with the chevron/selection binding and
current±1 lazy mounting. Goal: validate the **feel** of the animation on real content
and the interaction with scrolling. Deliver a diff + a short note. **User signs off on
feel before Phase 2.**

**Phase 2 — Full integration.** Study-Mode coexistence (ADR-021), covers/headings,
anchor restore, gesture-conflict check (word tap / long-press / selection vs swipe),
performance on large chapters (e.g. Ps 119), iOS 18 fallback path, Swift 6 clean.

## Acceptance criteria

- Chevron tap **and** horizontal swipe animate the chapter change (native slide).
- New chapter starts at a sane scroll position (top, or restored anchor when applicable).
- Study Mode unaffected: ADR-021 pinning/sizing rules still hold; in-sheet ‹ › still do
  prev/next verse/word.
- No regression to covers, headings, word tap/long-press, selection, cross-ref stack.
- Swift 6 strict-concurrency clean; iOS 26 paging behind `#available` with iOS 18
  fallback; any `#Preview` using sample data wrapped in `#if DEBUG`.
- Builds **and Archives** (Release) on the Mac; Clean Build Folder before verifying.

## Risks

- Study-Mode scroll pinning is the app's most delicate subsystem (ADR-021 lists hard
  don't-regress rules) — paging must not perturb it.
- `TabView(.page)` lazy loading / memory with very long chapters.
- Native full-surface swipe may clash with tappable words / long-press Word tab / text
  selection — the very reason paging was edge-only. Needs explicit evaluation in Phase 2.
- iOS 26-only value-based `TabView` selection needs a clean iOS 18 fallback.

## Alternatives considered

- **Opt 1 — `withAnimation` + `.transition` on the content swap** (≈ Fast Fade/Slide):
  cheapest, but no swipe and doesn't address ux-001. Kept as the fallback path.
- **Opt 3 — UIKit `UIPageViewController(.pageCurl)`**: authentic Books curl, but for
  fixed paginated pages; wrong fit for a scrolling reader. Rejected.

---

## Phase-1 spike outcome (2026-07-03) — DEFERRED to V1.5

A throwaway spike was built on branch `reader-tabview-paging` (DEBUG-only,
opt-in via `adr026_paging_spike`, new `ChapterPagerView.swift`). **Do not merge it**
— it is a reference/feel-check only.

### Findings
- **Animation feel: good.** The native `TabView(.page)` slide reads well for chapter
  navigation, from both chevrons and swipe.
- **Full-surface swipe worked better than feared.** `TabView(.page)` gives a
  full-width horizontal swipe (this *supersedes* the edge-only gesture in
  `EdgeSwipeNavigator`). In the spike, gestures did **not** noticeably conflict with
  tappable words / long-press / selection, and it felt usable. This is a genuine
  signal — but it **contradicts PDR-Page-Turn-Gesture-Zone** (edge-only was a
  deliberate decision). It must be a conscious product call in V1.5, and if adopted,
  **PDR-Page-Turn-Gesture-Zone must be superseded/amended**, not silently overridden.

### Decision
**Cosmetic gain vs. heavy cost — defer to V1.5.** This is a polish item, but the
reader is the app's most delicate subsystem (Study-Mode pinning ADR-021, cache
invalidation ADR-014, covers ADR-017, resume-position). A correct implementation
pulls in a lot of work and regression surface, not justified before V1.5.

### How NOT to implement it (lessons from the spike)
- **Do NOT re-implement the chapter content view.** The spike wrote a fresh
  `ChapterPage` from scratch; it immediately drifted from the tuned reader — the book
  cover lost its offset / `ignoresSafeArea(.top)` bleed and rendered under the toolbar,
  headings/anchor logic were absent. **V1.5 must page the REAL classic chapter content**
  (the existing view with its covers, offsets, safe-area handling) — only the container
  changes to a pager. Re-inventing pixels is the wrong path.
- **Do NOT drop or "simplify" tuned UI** (cover bleed, negative paddings, offsets,
  Study-Mode geometry) as a spike convenience. Those are product-owned and finely
  tuned; removing them silently is not acceptable and broke the cover here.
- **Do NOT run `loadChapter()` (or any `@Published` re-map) during the page
  transition** — it janked the first slide. Keep per-page data local; sync VM state
  off the animation frame.
- **Check uncommitted ADRs before numbering** — this ADR first collided with an
  in-progress `ADR-025` (app-preferences) and had to be renumbered to 026.
- **Get sign-off before removing/altering existing behavior** — don't decide unilaterally
  what to strip from the reader.

### Phase-2 (V1.5) requirements
1. Page the **real** classic chapter view (covers, offsets, `ignoresSafeArea` bleed,
   headings, anchor restore, resume-position) — no reimplementation.
2. Study-Mode coexistence per ADR-021 (pinning/sizing/clamp) — the pager must not
   perturb it; in-sheet ‹ › still do prev/next verse/word.
3. Lazy **current ± 1** prewarming to kill the first-transition cold UITextView layout.
4. Explicit decision on full-surface vs edge swipe → reconcile with / supersede
   PDR-Page-Turn-Gesture-Zone; validate the gesture-conflict finding properly on device.
5. iOS 26 value-based `TabView` selection behind `#available` + iOS 18 fallback.
6. Swift 6 clean; builds **and Archives** (Release); Clean Build before verifying.
