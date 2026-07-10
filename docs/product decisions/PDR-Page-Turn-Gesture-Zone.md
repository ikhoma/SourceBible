# PDR: Page-Turn Swipe Zone

**Status:** Amended 2026-07-10 → **full-surface swipe** (was: edge-only, accepted 2026-06-23)
**Date:** 2026-06-23 (original) · 2026-07-10 (amendment)

## Decision (current, 2026-07-10)

Turning pages by swipe in the reader is active across the **full width** of the
reading surface, delivered natively by `TabView(.page)` chapter paging (ADR-026).
A horizontal swipe anywhere on the page turns the chapter. This **supersedes** the
original edge-only decision below.

**Rollback clause:** this is a reversible product call. If full-surface swipe proves
to clash with word tap / long-press Word tab / text selection in real device use, we
revert to edge-only (`EdgeSwipeNavigator`) and this PDR flips back. The ADR-026
Phase-2 gesture-conflict check on device is the gate; a confirmed regression there
triggers the rollback.

**Gate passed (2026-07-10):** ADR-026 Phase 2 shipped full-surface swipe via
`UIPageViewController(.scroll)`; device check by Ivan found no clash with word
tap / long-press / selection. ux-001 closed (`docs/ux/done/ux-001.md`). The
rollback clause stays available but is not armed. Note: chapter pages always
reopen at their top (production semantics) — see ADR-026 `willTransitionTo`
note for the alternative "keep my place when peeking back" behavior.
Edge-only remains only on the iOS 18 fallback path until Phase B.

### Why the change
The ADR-026 Phase-1 spike (2026-07-03) shipped full-width `TabView(.page)` swipe and,
on real content, gestures did **not** noticeably conflict with tappable words,
long-press, or selection — while directly fixing the discoverability problem that
edge-only created (ux-001: users naturally swipe anywhere and conclude paging is
broken). Discoverability + native feel outweigh the (unobserved-so-far) gesture-clash
risk, provided the rollback clause stands and the device check in ADR-026 Phase 2
validates it.

---

## Original decision (edge-only, 2026-06-23 — SUPERSEDED)

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

## Open question (resolved 2026-07-10)

Edge-only paging was a **discoverability** problem — users naturally swipe
anywhere and conclude paging is broken (tracked in `docs/ux/new/ux-001.md`). The
two candidate directions were:

1. Widen the swipe-active band (verify no clash with word tap / long-press / selection).
2. Keep edge-only and add a visible affordance (page-edge indicator / chevrons / one-time hint).

**Resolution:** direction 1, taken to its full extent (full-surface swipe via
`TabView(.page)`, ADR-026), subject to the rollback clause above. ux-001's
discoverability concern is addressed by this change; close ux-001 once ADR-026
Phase 2 lands on device.

## Related

- `docs/ux/new/ux-001.md` — discoverability UX item (reclassified from bug-004)
- Reader gesture model: tappable words, long-press Word tab, text selection
