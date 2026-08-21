# ADR-021 — Study Mode: Verse Pinning & Sheet Sizing (Scroll Positioning)

**Status:** Accepted — covers-OFF (Stage 1) and covers-ON (Stage 2) both done, 2026-06-17; **amended 2026-08-18** (bug-031: `detentTopOffset` device validation closed — per-platform constant + runtime self-calibration; the 20 pt equal-gap wish consciously declined).
**Related:** `spec-study-mode-redesign.md` (R1/R3), ADR-017 (Book Covers), ADR-010 (BottomSheet split).

## Context

In Study Mode, tapping a verse must:
1. Pin the selected verse's top a fixed gap below the toolbar (reader scroll locked).
2. Slide a dynamic-height sheet up so its top sits a fixed gap below the verse's bottom.
3. Do both as one smooth motion, consistently for first-tap, re-select, and chevron nav.

This turned out to be a deep iOS-layout problem (SwiftUI scroll vs UIKit, async geometry, custom sheet detents). This ADR records the **decision trail** so future changes can trace *why* the current design exists and not re-introduce fixed bugs.

## The two gaps are decoupled

| Constant | Value | Meaning | Notes |
|---|---|---|---|
| `ReaderViewModel.toolbarGap` | 0 | toolbar bottom → verse top | Separate from `sheetGap` because `toolbarBottomY` (NavBarBottomReader) is the nav-bar **frame** bottom, ~4 pt below the **visible** floating capsule — so the on-screen gap reads ~4 pt larger than the constant. Tuned to taste (16→12→8→4→2→0); 0 gives a visible ~4–8 pt that balances the bottom gap. |
| `ReaderViewModel.sheetGap` | 8 | verse bottom → sheet top | The sheet's frame top is exact, so this maps 1:1. Kept **below ~12** so the next row's content (its ~12 pt top padding) is hidden behind the sheet — at 16 a ~4 pt sliver of the next verse peeked and the ±1 px height wobble made it flicker. |
| `ReaderViewModel.detentTopOffset` | **16 (iOS 26) / 34 (iOS 18)**, self-calibrating | compensation | A UIKit custom-detent sheet lands higher than `containerHeight − detentHeight`. **Amended 2026-08-18 (bug-031):** the correction is NOT one number — it is per-platform, and it is now measured at runtime rather than hardcoded. See «Amendment 2026-08-18» below. |

`pinnedTopAnchorY = toolbarBottomY + toolbarGap`. Because positioning is exact (`StudyPinView`), each knob maps 1:1 to on-screen points.

## Decision 1 — Verse positioning: atomic UIKit pin, not SwiftUI scrollTo

**Final:** `StudyPinView` (in `Views/Reader/StudyScrollApplier.swift`) — a zero-size `UIViewRepresentable` installed as the **selected verse's `.background`**, so *its own frame is the verse's frame*. In one layout pass it reads its global top **and** the enclosing `UIScrollView.contentOffset`, then sets:

```
newOffset.y = contentOffset.y + (verseGlobalTop − pinnedTopAnchorY)
```

clamped to the valid range, animated on the **next runloop** (a critically-damped 0.5 s spring ≈ the system sheet spring).

**Why — the path that got here:**

1. **SwiftUI `scrollTo(id, anchor: .top)`** + a top safe-area inset that toggled `0 → studyTopInset` on entry. The inset commit *raced* the scroll → the verse visibly jumped up then settled down ("rubber-band / page dragged down"). A second non-animated correction pass was bolted on to hide it. Rejected: timing-dependent, jerky.
2. **Deterministic offset via a separate probe + applier.** A SwiftUI `onGeometryChange` probe measured the verse's global top; a separate UIKit view read `contentOffset` and applied the delta. Fixed first-tap, but the two reads happened in **different layers at different instants**. On re-select the scroll had moved between them, so `delta` was computed against an inconsistent state and the verse landed wrong. The smoking gun: `K = verseGlobalTop + contentOffset` should be invariant per verse but was 118.67 on first tap and 52.67 on re-select. Rejected: cross-layer sampling skew.
3. **Revert to native `scrollTo(.top)` with a constant inset.** `scrollTo(.top)` did **not** respect the inset the way the explicit offset did — verse landed too high (under the toolbar). Rejected.
4. **`StudyPinView` (final).** Both reads happen in the same layout callback on one view → no skew. Reset-proof and consistent across first-tap / re-select / chevron.

**Hard rules (do not regress):**
- Do **not** start the `contentOffset` animation from inside `layoutSubviews` — UIKit swallows it and the verse *snaps* instead of gliding. Dispatch the animation to the next runloop. (Scroll is locked in Study Mode, so the captured target stays valid.)
- Do **not** re-introduce a separate measure-probe + applier; keep the measurement and the offset read on the **same** view.

## Decision 2 — No Study-Mode top inset at all (Stage 2)

There is **no top `safeAreaInset` for Study Mode** in either case. The evolution:
1. Original: toggled `0 → studyTopInset` on entry. The toggle was the entry jerk (covers-off) and, with the large covers-ON value, the **rubber-band on the bleeding cover content**.
2. Covers-off interim: a *constant* `toolbarGap` inset (no toggle) — fixed the jerk but, being always-present, shifted the reader down and made the first verse's short scroll feel like it "braked" at the scroll edge.
3. Final: **0 in both cases.** `StudyPinView` positions the verse by `contentOffset`, and the content above the topmost verse already provides the headroom — the book cover (covers-on) or the chapter heading (covers-off, which always leaves ≈ `anchorY − contentTop` of slack). Removing the inset entirely killed both the covers-on rubber-band and the first-verse "brake," and removed the on/off asymmetry.

Dead code removed with this: `ReaderViewModel.studyTopInset`, `ReaderViewModel.scrollContentTopY`, and the top-inset measurement probe.

## Decision 3 — Exit clamp for the last verse

Pinning the last verse(s) over-scrolls the content (the pin relies on the bottom inset `studyScrollRoom` for room). On exit that inset is removed but a *manually-set* `contentOffset` is not auto-clamped by SwiftUI → a stretched empty gap below the last verse. `StudyScrollClamper` (always present in the content) clamps an over-scrolled offset back to the valid max on the Study-Mode true→false transition.

## Decision 4 — Sheet sizing: intentional dual mechanism (kept)

The sheet height is driven by **both**:
- SwiftUI `CustomPresentationDetent` (`StudySheetDetent`, reading `\.studySheetHeight`), and
- the UIKit `StudySheetDetentApplier` that sets `sheet.detents` directly.

Code-review #3 flagged this as redundant scaffolding. **Experiment (2026-06-17):** `StudySheetDetent` was pinned to a fixed 450 while the applier kept computing the real height — the open sheet **still resized per verse**, proving the **UIKit applier drives the live resize**. The SwiftUI custom detent remains valuable for the **initial present size** (presents at the right height instead of opening large and snapping) and as the resizable-sheet baseline. Conclusion: complementary, not redundant — **kept both**. Do not delete either without verifying per-verse resize *and* the initial-present has no flash on a physical device.

## Decision 5 — Sheet dismiss: default interactive (custom gesture removed)

Earlier the sheet used `interactiveDismissDisabled(true)` plus a custom drag-to-close gesture confined to the header / grabber zone (to stop content scroll from dragging the whole sheet). In practice it dismissed ~1 in 5 tries. Reverted to the **default interactive dismiss** (swipe down on the sheet chrome or from the top of the content), removing `dismissDragGesture` and the grabber overlay. The "sometimes scrolls / sometimes dismisses" ambiguity is the same as Apple Maps' sheet and accepted as standard UX.

## Outstanding

- ~~**`detentTopOffset` device validation.**~~ **CLOSED 2026-08-18 (bug-031)** — both options taken: measured per platform AND made self-correcting. See «Amendment 2026-08-18» below.
- **Pre-merge:** strip remaining `[SHEET]` debug print from `StudySheetDetentApplier` if still present; delete the empty-stub history note in `StudyScrollApplier.swift` header if desired.

## Files

- `SourceBible/Views/Reader/StudyScrollApplier.swift` — `StudyPinView` + `StudyScrollClamper`.
- `SourceBible/Views/Reader/ReaderView.swift` — pin view as selected-verse background; clamper in content; constant top inset; `onChange(verseScrollTrigger)` (reader-mode fallback only).
- `SourceBible/Views/BottomSheet/StudySheetDetent.swift` — `StudySheetDetent` + `StudySheetDetentApplier`.
- `SourceBible/Views/BottomSheet/VerseBottomSheetView.swift` — dual-mechanism wiring + rationale comment.
- `SourceBible/ViewModels/ReaderViewModel.swift` — `toolbarGap`, `sheetGap`, `detentTopOffset`, `pinnedTopAnchorY`, `studySheetHeight`, `studyScrollRoom`.

---

## Amendment 2026-08-18 (bug-031) — `detentTopOffset` measured, self-calibrating; equal 20 pt gaps declined

### The Outstanding item is closed — and it was hiding a real defect

This ADR asked whether the 16 pt correction is constant or tracks safe area, and offered two
options: validate on hardware, or make the applier self-correct from `presentedView.frame.minY`.
**Both were done.** The measurement also uncovered a defect the original wording could not
have predicted.

Method: a temporary probe in `StudySheetDetentApplier` computed `containerH`, the requested
detent, `computedTop = containerH − requested`, and the REAL top of the presented view, and
rendered the difference as a label over the sheet (Xcode runtime logs are unreachable from the
agent environment). Probe removed after measuring.

| runtime | requested | computedTop | realTop | **Δ** |
|---|---|---|---|---|
| iOS 26.5 / iPhone 17 | 599 | 275 | 258 | **16.8** |
| iOS 18.0 / iPhone 16 Pro | 680 | 193 | 159 | **34.0** |
| iOS 18.0 / iPhone 16 Pro | 614 | 259 | 225 | **34.0** |

**Method validated by the old number:** on iOS 26 the probe independently reproduced ≈16.8,
confirming the historical 16. So 34.0 on iOS 18 is a real platform difference, not measurement
noise.

**Answer to this ADR's question: the correction is CONSTANT within a platform** — two different
detent heights (680 and 614) produced the same Δ. It does not need to be derived from safe area.
It simply differs per platform.

### The defect this exposed

Visible gap = `sheetGap + detentTopOffset − Δ`.

| | calculation | visible gap |
|---|---|---|
| iOS 26 | 8 + 16 − 16.8 | ≈ 7 pt ✅ |
| iOS 18 (before fix) | 8 + 16 − 34 | **−10 pt** ⛔ |

On iOS 18 the sheet **covered** the bottom ~10 pt of the pinned verse card. It ate no text (the
card's internal padding absorbed it), so it read as "tight" rather than as a defect — which is
why it went unnoticed. Not a consequence of the target flip as such: it existed for exactly as
long as the app could theoretically launch on iOS 18.

### Applied

- `detentTopOffset` split per platform: 16 on iOS 26, 34 on iOS 18. Visible gap on 18 became
  8 + 34 − 34 = **8 pt**, as intended. iOS 26 untouched.
- **Runtime self-calibration with persistence.** On iPhone SE (3rd gen) the real Δ differs from
  the platform seed; calibration caught it, but only from the SECOND sheet presentation — so the
  first frame of every launch was wrong. The measurement is now persisted
  (`AppStorageKeys.sheetDetentTopOffset` + `…OSBuild`) and keyed to the OS version, deliberately:
  a system update can change sheet layout, and a stale measurement must be discarded rather than
  carried forward. Resolution order: `measured ?? persisted ?? seeded`. At most the very first
  sheet after install can be wrong. Verified by cold start on SE.

This also closes this ADR's "SE-validation pending" note.

### Decision — equal 20 pt gaps around the card: NOT doing it

The original request behind bug-031 was cosmetic: 20 pt above and below the pinned verse card,
so its frame reads evenly against the reader's horizontal padding. **Declined for v1.0, and
closed as a decision rather than deferred work** (Ivan, 2026-08-18).

**It is not reachable by changing constants.** The gap is not empty — live reader content runs
underneath it. 20 pt at the top exposes the tail of the PREVIOUS verse (confirmed by zoom on
Jas 1:19: the tail of Jas 1:18 is visible in the gap); at the bottom, anything above ~12 pt lets
the next verse peek out from under the sheet — the warning already recorded in this ADR. Equal
gaps therefore require an opaque or blurred underlay beneath the card, i.e. a change to Study
Mode's composition.

**Why that is expensive here specifically.** It touches the geometry this ADR exists to protect
(no Study-Mode top inset, no entry jerk, no covers-on rubber band) plus ADR-024's cross-ref
invariant, and it carries an unresolved question of its own: what to fill the underlay with.
`colorTheme.appBackground` is clean over the ordinary background but wrong over a book cover
(ADR-017 bleed); `.ultraThinMaterial` works over both but may show a seam under the solid
iOS 18 bar. That is open-ended work in the most expensive part of the app, for a difference
nobody currently reads as a defect.

**If this is ever revisited,** the entry point is variant A in `docs/bugs/done/bug-031.md`, and
the fill question must be settled BEFORE any code.
