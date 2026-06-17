# ADR-021 — Study Mode: Verse Pinning & Sheet Sizing (Scroll Positioning)

**Status:** Accepted — covers-OFF (Stage 1) and covers-ON (Stage 2) both done, 2026-06-17.
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
| `ReaderViewModel.detentTopOffset` | 16 | compensation | A UIKit custom-detent sheet lands ~16 pt **higher** than `containerHeight − detentHeight` (sheet ends up ~16 pt taller than the value given). Measured on iPhone 17 sim: detent=628 → computedTop=246 but REAL top=230. (SE/non-island validation still outstanding.) |

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

- **`detentTopOffset` device validation.** 16 measured only on iPhone 17 sim (Dynamic Island). No SE simulator available. If on SE/older it tracks safe area rather than being constant, the verse↔sheet gap will drift. Options when SE/iOS-18 support lands: validate on hardware, or make the applier self-correct from `presentedView.frame.minY` instead of a constant.
- **Pre-merge:** strip remaining `[SHEET]` debug print from `StudySheetDetentApplier` if still present; delete the empty-stub history note in `StudyScrollApplier.swift` header if desired.

## Files

- `SourceBible/Views/Reader/StudyScrollApplier.swift` — `StudyPinView` + `StudyScrollClamper`.
- `SourceBible/Views/Reader/ReaderView.swift` — pin view as selected-verse background; clamper in content; constant top inset; `onChange(verseScrollTrigger)` (reader-mode fallback only).
- `SourceBible/Views/BottomSheet/StudySheetDetent.swift` — `StudySheetDetent` + `StudySheetDetentApplier`.
- `SourceBible/Views/BottomSheet/VerseBottomSheetView.swift` — dual-mechanism wiring + rationale comment.
- `SourceBible/ViewModels/ReaderViewModel.swift` — `toolbarGap`, `sheetGap`, `detentTopOffset`, `pinnedTopAnchorY`, `studySheetHeight`, `studyScrollRoom`.
