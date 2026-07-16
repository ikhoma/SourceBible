// StudyScrollApplier.swift
// SourceBible
//
// Deterministic Study-Mode scroll positioning — atomic version.
//
// HISTORY (debug 2026-06-16):
//  1. SwiftUI scrollTo(anchor:.top) raced the top-inset commit → "verse jumps
//     up then down" jerk.
//  2. A separate measure-probe (SwiftUI) + offset-applier (UIKit) fixed the
//     jerk and first-tap, but re-selecting the same verse used a verse position
//     and a contentOffset sampled at DIFFERENT instants → wrong delta.
//  3. Reverting to scrollTo landed the verse too high (it ignores the inset the
//     way the explicit offset did not).
//
// THIS version removes the cross-layer skew: a single UIView is installed as the
// SELECTED verse's `.background`, so its own frame == the verse's frame. In one
// layout pass it reads BOTH its global top AND the enclosing scroll view's
// contentOffset, then sets the exact offset:
//     newOffset.y = contentOffset.y + (verseGlobalTop − anchorY)
// Because both reads happen in the same call, they're always consistent — first
// tap, re-select, and chevron alike.

import SwiftUI
import UIKit

struct StudyPinView: UIViewRepresentable {
    /// Bumped on every tap / chevron move — the "perform a pin scroll" signal.
    let trigger: Int
    /// Global Y where the verse top should land (toolbarBottom + toolbarGap).
    let anchorY: CGFloat
    /// True only in Study Mode.
    let active: Bool

    func makeUIView(context: Context) -> PinView {
        let v = PinView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: PinView, context: Context) {
        uiView.configure(trigger: trigger, anchorY: anchorY, active: active)
    }

    @MainActor
    final class PinView: UIView {
        private var trigger = 0
        private var anchorY: CGFloat = 0
        private var active = false
        private var lastHandled = -1

        func configure(trigger: Int, anchorY: CGFloat, active: Bool) {
            self.trigger = trigger
            self.anchorY = anchorY
            self.active = active
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            pinIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pinIfNeeded()
        }

        private func pinIfNeeded() {
            guard active,
                  trigger != lastHandled,
                  anchorY > 0,
                  let window = window,
                  let scrollView = enclosingScrollView()
            else { return }

            // self is installed as the selected verse's background → self.frame
            // IS the verse row's frame. Read verse position AND the scroll offset
            // in the same call: no cross-layer sampling skew.
            //
            // "Not laid out yet" must be a SIZE check, not a position check: a verse
            // row ABOVE the current viewport has a NEGATIVE global minY — valid
            // geometry (delta < 0 → pin scrolls UP). The old `minY > 0` guard read
            // "above viewport" as "not laid out", so an upward pin (e.g. cross-ref
            // «Назад» to an earlier verse of the SAME chapter) silently never fired.
            guard bounds.height > 0 else { return }     // not laid out yet
            let verseGlobalMinY = convert(bounds, to: window).minY

            lastHandled = trigger

            let delta = verseGlobalMinY - anchorY
            var target = scrollView.contentOffset
            target.y += delta

            // Keep the offset valid so a later layout pass can't re-clamp it.
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(minY,
                           scrollView.contentSize.height
                           + scrollView.adjustedContentInset.bottom
                           - scrollView.bounds.height)
            target.y = min(max(target.y, minY), maxY)

            // Animate on the NEXT runloop, not here: a contentOffset animation
            // started inside layoutSubviews is swallowed and applies instantly
            // (the "verse snaps" regression). Scroll is locked in Study Mode, so
            // the captured target stays valid until this runs. 0.5 s critically-
            // damped (no overshoot) ≈ the system sheet spring, so verse + sheet
            // travel together.
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.5, delay: 0,
                               usingSpringWithDamping: 1.0, initialSpringVelocity: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    scrollView.contentOffset = target
                }
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView { return sv }
                v = cur.superview
            }
            return nil
        }
    }
}

// MARK: - Resume-position restore pin

/// One-shot restore positioner for resume-position (spec-reader-resume-position.md).
///
/// Installed as the `.background` of the verse being restored on launch (only while
/// `pendingRestoreAnchorId` matches that row). It lands the verse's TOP exactly at
/// `anchorY` — which the caller passes as `pinnedTopAnchorY`, i.e. just below the
/// floating iOS 26 toolbar — using the SAME offset math as `StudyPinView`, so a
/// restored verse sits on the identical line as a Focus (Study Mode) verse.
///
/// Two deliberate differences from `StudyPinView`:
///  1. It sets `contentOffset` WITHOUT animation — the verse must already be in
///     place on the first paint after relaunch, not slide in.
///  2. It fires `onPinned` once after applying, so the caller can clear the
///     pending-restore flag (which removes this view — it is truly one-shot).
///
/// Why not `proxy.scrollTo(anchor, anchor: .top)`: SwiftUI's `.top` aligns to the
/// scroll view's raw top, which sits UNDER the floating toolbar (the toolbar does
/// not reduce the SwiftUI safe area — the very reason `toolbarBottomY` is read from
/// UIKit). `.top` therefore lands the restored verse behind the toolbar/status bar.
struct RestorePinView: UIViewRepresentable {
    /// Global (window) Y where the verse top should land — pass `pinnedTopAnchorY`.
    let anchorY: CGFloat
    /// Called once, after the offset is applied, so the caller clears the pending flag.
    let onPinned: () -> Void

    func makeUIView(context: Context) -> PinView {
        let v = PinView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: PinView, context: Context) {
        uiView.configure(anchorY: anchorY, onPinned: onPinned)
    }

    @MainActor
    final class PinView: UIView {
        private var anchorY: CGFloat = 0
        private var onPinned: (() -> Void)?
        private var done = false

        func configure(anchorY: CGFloat, onPinned: @escaping () -> Void) {
            self.anchorY = anchorY
            self.onPinned = onPinned
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            pinIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pinIfNeeded()
        }

        private func pinIfNeeded() {
            // anchorY == 0 means toolbarBottomY hasn't been measured yet on cold launch;
            // stay armed (done == false) — a later layout pass, once the nav bar publishes
            // its frame, re-runs this and pins correctly.
            guard !done,
                  anchorY > 0,
                  let window = window,
                  let scrollView = enclosingScrollView()
            else { return }

            // self is the target verse row's background → self.frame IS the verse frame.
            // Read the verse's global top AND the scroll offset in the same pass (no skew).
            let verseGlobalMinY = convert(bounds, to: window).minY
            guard verseGlobalMinY > 0 else { return }   // not laid out yet

            done = true

            let delta = verseGlobalMinY - anchorY
            var target = scrollView.contentOffset
            target.y += delta

            // Clamp to the valid range so the offset survives a later layout pass.
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(minY,
                           scrollView.contentSize.height
                           + scrollView.adjustedContentInset.bottom
                           - scrollView.bounds.height)
            target.y = min(max(target.y, minY), maxY)

            scrollView.contentOffset = target   // instant — no animation on restore

            let callback = onPinned
            DispatchQueue.main.async { callback?() }   // clear pending after this pass
        }

        private func enclosingScrollView() -> UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView { return sv }
                v = cur.superview
            }
            return nil
        }
    }
}

// MARK: - Exit clamp

/// Pinning the LAST verse(s) over-scrolls the content (the pin offset relies on
/// the bottom inset / studyScrollRoom for the extra room). On exit that inset is
/// removed, but the manually-set contentOffset stays — leaving a stretched empty
/// gap below the last verse, because a directly-set UIScrollView offset is not
/// auto-clamped by SwiftUI. This view lives permanently in the scroll content and
/// clamps an over-scrolled offset back to the valid maximum when Study Mode exits.
struct StudyScrollClamper: UIViewRepresentable {
    /// True only in Study Mode. The clamp fires on the true→false transition.
    let active: Bool

    func makeUIView(context: Context) -> ClampView {
        let v = ClampView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ClampView, context: Context) {
        uiView.update(active: active)
    }

    @MainActor
    final class ClampView: UIView {
        private var wasActive = false

        func update(active: Bool) {
            let becameInactive = wasActive && !active
            wasActive = active
            guard becameInactive else { return }
            // Defer so SwiftUI has removed the bottom inset first; then the valid
            // max reflects the inset-less content and the clamp lands correctly.
            DispatchQueue.main.async { [weak self] in self?.clampIfOverscrolled() }
        }

        private func clampIfOverscrolled() {
            guard let scrollView = enclosingScrollView() else { return }
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(minY,
                           scrollView.contentSize.height
                           + scrollView.adjustedContentInset.bottom
                           - scrollView.bounds.height)
            guard scrollView.contentOffset.y > maxY + 0.5 else { return }
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 1.0, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                scrollView.contentOffset.y = maxY
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView { return sv }
                v = cur.superview
            }
            return nil
        }
    }
}
