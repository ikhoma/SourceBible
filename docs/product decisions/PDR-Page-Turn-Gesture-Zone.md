# PDR: Page-Turn Swipe Is Edge-Only (Not a Bug)

**Status:** Accepted
**Date:** 2026-06-23

## Decision

Turning pages by swipe in the reader is intentionally active **only in the
left/right edge zones** of the screen, not across the full width. A horizontal
swipe over the center of the page (i.e. over the verse text) does **not** turn
the page by design.

## Rationale

The reading surface is interactive: original-language words are tappable, a
long-press opens the Word tab, and the text supports selection. A full-width
horizontal swipe would collide with those gestures. Restricting page-turn to the
edge bands keeps the core word-study interactions unambiguous.

## Why this PDR exists

A beta tester (iPhone 11, iOS 26.5, build 1.0) reported "swiping doesn't turn
pages." Investigation + retest showed paging works — the tester was swiping over
the center. This is **working as designed**, so it is not a defect.

This document is the canonical "by design" record so the same report does not get
re-investigated from scratch each time it arrives. On a repeat report, triage
links it to the open UX item instead of opening a new bug.

## Open question (tracked separately, not a bug)

Edge-only paging is a **discoverability** problem — users naturally swipe
anywhere and conclude paging is broken. That UX concern is tracked in
`docs/ux/new/ux-001.md`, with two candidate directions:

1. Widen the swipe-active band (verify no clash with word tap / long-press / selection).
2. Keep edge-only and add a visible affordance (page-edge indicator / chevrons / one-time hint).

This PDR records *why it is the way it is*; `ux-001` records *what, if anything,
we change*. If a future report claims paging is genuinely broken (not the
center-swipe misunderstanding), that would be a new defect — re-open then.

## Related

- `docs/ux/new/ux-001.md` — discoverability UX item (reclassified from bug-004)
- Reader gesture model: tappable words, long-press Word tab, text selection
