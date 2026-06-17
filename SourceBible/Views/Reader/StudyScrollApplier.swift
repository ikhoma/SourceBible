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
            let verseGlobalMinY = convert(bounds, to: window).minY
            guard verseGlobalMinY > 0 else { return }   // not laid out yet

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
