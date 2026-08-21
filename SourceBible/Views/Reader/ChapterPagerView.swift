// ChapterPagerView.swift
// SourceBible
//
// ADR-026 Phase 2: chapter paging via UIPageViewController(.scroll) — the
// Apple Books container. Used by ReaderView on iOS 26 (iOS 18 keeps the
// legacy single-scroll reader until the Phase-B compatibility sprint).
//
// Why UIPageViewController instead of TabView(.page) — verified empirically
// (sim iOS 26.5 + device, 2026-07-10; see ADR-026 implementation notes):
//   1. TabView clips its pages to the pager's safe-area frame, so a per-page
//      .ignoresSafeArea can't bleed the ch-1 book cover behind the status bar
//      (ADR-017), and
//   2. the navigation bar's scroll-edge effect (Liquid Glass blur) never
//      engages — the bar can't see a vertical scroll view nested inside the
//      SwiftUI pager, leaving an opaque toolbar and a hard content clip.
// UIKit pages lay out edge-to-edge under bars natively, and
// setContentScrollView(_:for:) is the official API to point the bar's
// scroll-edge machinery at a container's current scroll view.
//
// The page CONTENT is the real ChapterScrollContent (ADR-026 hard rule: the
// container may change, the chapter view must not be reimplemented).

import SwiftUI
import UIKit

/// Interactive chapter pager: one page per chapter, full-surface swipe
/// (PDR-Page-Turn-Gesture-Zone, full-surface since 2026-07-10) + chevron-driven
/// slides. Pure UIKit container — nothing iOS 26-specific, so a future single
/// path for iOS 18 is possible (Phase B).
struct ChapterPagerView: UIViewControllerRepresentable {

    @EnvironmentObject var vm: ReaderViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll,
                                       navigationOrientation: .horizontal)
        pvc.view.backgroundColor = .clear
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        context.coordinator.vm = vm
        context.coordinator.pageVC = pvc
        context.coordinator.showPage(at: vm.currentGlobalChapterIndex,
                                     animated: false, direction: .forward)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let co = context.coordinator
        co.vm = vm

        // Study Mode locks chapter paging (product decision N1).
        co.setPagingEnabled(vm.activeSheet != .verse)

        // External chapter change (chevron / book picker / cross-ref / resume):
        // animate the native slide for a ±1 step, snap for far jumps.
        // ux-020: the comparison is on the CANON-WIDE index, so the last chapter of a book
        // and the first of the next differ by exactly 1 and get the same animated slide.
        // ⛔ bug-043 — the request is DEFERRED, never dropped. See `requestPage`.
        co.requestPage(vm.currentGlobalChapterIndex)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {

        weak var pageVC: UIPageViewController?
        var vm: ReaderViewModel?
        /// Canon-wide index of the page the page VC shows (may lead the VM for one
        /// tick while a swipe commit syncs it). ux-020: an INDEX over all chapters of
        /// the canon, not a chapter number inside the current book.
        var displayedIndex: Int = -1
        /// True while setViewControllers' programmatic animation is in flight —
        /// updateUIViewController must not re-enter showPage mid-slide.
        var isTransitioning = false

        /// True between a swipe starting (`willTransitionTo`) and settling
        /// (`didFinishAnimating`). Programmatic navigation must NOT call
        /// setViewControllers while a gesture is live — that is the suspected trigger
        /// for the swallowed completion in bug-042.
        private var isInteracting = false

        /// Canon-wide index the VM asked for while a transition or swipe was in flight.
        /// Replayed once the way is clear (bug-043) — the request waits, it is not lost.
        private var pendingTarget: Int?

        /// Monotonic id of the in-flight INTERACTIVE swipe (bug-043 watchdog).
        private var interactionToken: UInt64 = 0

        /// Monotonic id of the in-flight programmatic transition (bug-042 watchdog).
        /// Lets a late watchdog tell "my transition is still stuck" from "a newer
        /// transition has since started", so it never clears someone else's latch.
        private var transitionToken: UInt64 = 0

        /// Hosting page for one canon position; nil past Gen 1 / Rev 22 — that nil is
        /// what makes the pager stop cleanly at the ENDS OF THE CANON (before ux-020 it
        /// stopped at every book boundary, which is exactly what testers hit).
        func hosting(for globalIndex: Int) -> UIViewController? {
            guard let vm, let ref = vm.chapterRef(atGlobalIndex: globalIndex) else { return nil }
            let host = UIHostingController(
                rootView: ChapterScrollContent(ref: ref).environmentObject(vm)
            )
            host.view.backgroundColor = .clear
            host.view.tag = globalIndex      // page identity for the dataSource
            return host
        }

        /// Single entry point for VM-driven navigation.
        ///
        /// ⛔ bug-043 — if a transition or an interactive swipe is in flight, the target
        /// is REMEMBERED and replayed, not discarded. Before this, `updateUIViewController`
        /// simply skipped the call: the VM had already moved (cross-ref, book picker,
        /// search result), the page had not, and nothing ever reconciled them. The user
        /// tapped a reference and silently stayed put.
        func requestPage(_ target: Int) {
            guard displayedIndex != target else { return }
            guard !isTransitioning, !isInteracting else {
                pendingTarget = target
                return
            }
            let delta = target - displayedIndex
            showPage(at: target,
                     animated: abs(delta) == 1,
                     direction: delta > 0 ? .forward : .reverse)
        }

        /// Replay a target parked by `requestPage`. Called from every place a latch
        /// comes down — completion, watchdog, swipe settle — so no path leaves it stuck.
        private func flushPending() {
            guard let target = pendingTarget else { return }
            pendingTarget = nil
            requestPage(target)
        }

        func showPage(at globalIndex: Int, animated: Bool, direction: UIPageViewController.NavigationDirection) {
            guard let pageVC, let page = hosting(for: globalIndex) else { return }
            displayedIndex = globalIndex
            isTransitioning = animated

            // ⛔ bug-042 — the latch MUST have a way down that does not depend on UIKit.
            //
            // `isTransitioning` was raised here and lowered ONLY in the completion below.
            // UIPageViewController is known to skip that completion when
            // setViewControllers lands during an in-flight interactive gesture, or when
            // the container is off-window. One missed completion and the latch stays up
            // for the rest of the session: `updateUIViewController` then drops EVERY
            // programmatic navigation through `!co.isTransitioning` — cross-refs, the
            // book picker, search results, resume-position. The VM updates, the page does
            // not, and there is no error to see. It reads as "the app froze on this
            // chapter".
            //
            // The watchdog trades a rare, recoverable glitch for an unrecoverable one:
            // if it fires while the slide really is still running, the worst case is a
            // re-entered showPage mid-slide (a visual stutter). A stuck latch has no
            // worst case — it never heals. 1 s is far above the ~300 ms page animation,
            // so a healthy transition always completes first.
            if animated {
                transitionToken &+= 1
                let token = transitionToken
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isTransitioning, self.transitionToken == token else { return }
                    self.isTransitioning = false
                    self.flushPending()
                }
            }

            pageVC.setViewControllers([page], direction: direction, animated: animated) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isTransitioning = false
                    self?.attachContentScrollView()
                    self?.flushPending()
                }
            }
            if !animated { attachContentScrollView() }
        }

        // MARK: DataSource — lazy current ± 1 (ADR-026 adjacent prefetch)

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            hosting(for: viewController.view.tag - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            hosting(for: viewController.view.tag + 1)
        }

        // MARK: Delegate — swipe starting / settled

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            // Production semantics: a chapter page always OPENS at its top.
            // UIPageViewController may hand back a CACHED neighbor with its old
            // scroll offset (device-observed: Ps 119 scrolled → 120 → back kept
            // the offset), so reset the pending page's vertical scroll before it
            // becomes visible. Programmatic chevron jumps always build a fresh
            // page (top), so this covers the interactive-swipe path only.
            // NOTE (product): delete this hook to get "peek forward, come back
            // to where you were" instead — record in PDR if ever wanted.
            // Only a GESTURE marks interaction. `willTransitionTo` also fires for
            // programmatic transitions on some iOS versions, and those never get a
            // `didFinishAnimating` — setting the flag there would strand it (the very
            // shape of bug-042).
            //
            // ⛔ This latch needs its OWN way down, and it cannot borrow the one in
            // `showPage`. Found in review 2026-08-21, before the first commit: if
            // `didFinishAnimating` never arrives, `isInteracting` stays raised →
            // `requestPage` parks every target instead of calling `showPage` → the
            // programmatic watchdog is never scheduled → nothing can lower the latch.
            // A deadlock identical in shape to bug-042, under a new name.
            //
            // 3 s, not 1: an interactive swipe legitimately outlasts the ~300 ms
            // programmatic animation, and firing early would let programmatic
            // navigation cut into a live gesture — the thing this flag exists to stop.
            if !isTransitioning {
                isInteracting = true
                interactionToken &+= 1
                let token = interactionToken
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.isInteracting, self.interactionToken == token else { return }
                    self.isInteracting = false
                    self.flushPending()
                }
            }

            for vc in pendingViewControllers {
                if let scroll = Self.findVerticalScrollView(in: vc.view) {
                    scroll.setContentOffset(
                        CGPoint(x: scroll.contentOffset.x,
                                y: -scroll.adjustedContentInset.top),
                        animated: false)
                }
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isInteracting = false
            guard completed,
                  let current = pageViewController.viewControllers?.first,
                  let vm else { flushPending(); return }
            let index = current.view.tag
            displayedIndex = index

            // ⛔ bug-043 — a target that arrived DURING the swipe outranks the swipe.
            // Committing the swiped index here would overwrite the newer intent: the
            // user taps a cross-reference mid-gesture and lands on the neighbouring
            // chapter instead, with nothing to suggest the tap was discarded.
            if pendingTarget != nil {
                flushPending()
                return
            }

            guard index != vm.currentGlobalChapterIndex,
                  let ref = vm.chapterRef(atGlobalIndex: index) else { return }
            // Commit the page now; defer the loadChapter @Published re-map one
            // runloop tick so it never runs during the settle (ADR-026 hard rule —
            // the page already renders its own prefetched verses).
            // ux-020: the commit carries the BOOK too — a settle can land in the next one.
            vm.commitPagedChapter(ref)
            DispatchQueue.main.async { [weak self] in
                self?.vm?.loadChapter()
                self?.attachContentScrollView()
            }
        }

        // MARK: Scroll-edge effect plumbing

        /// Point the navigation bar's scroll-edge machinery (Liquid Glass blur)
        /// at the CURRENT page's vertical scroll view. setContentScrollView is
        /// the official API for container VCs whose content scroll view the bar
        /// cannot auto-detect. Called on every page settle.
        func attachContentScrollView() {
            guard let pageVC,
                  let pageView = pageVC.viewControllers?.first?.view,
                  let scroll = Self.findVerticalScrollView(in: pageView) else { return }
            // The bar observes the navigation controller's TOP view controller —
            // climb to the ancestor sitting directly under the UINavigationController.
            var top: UIViewController = pageVC
            while let parent = top.parent, !(parent is UINavigationController) {
                top = parent
            }
            top.setContentScrollView(scroll, for: .top)
        }

        /// Depth-first search for the page's vertical scroll view (skips any
        /// paging-enabled scroll views, i.e. the pager's own).
        static func findVerticalScrollView(in view: UIView) -> UIScrollView? {
            if let sv = view as? UIScrollView, !sv.isPagingEnabled { return sv }
            for sub in view.subviews {
                if let found = findVerticalScrollView(in: sub) { return found }
            }
            return nil
        }

        /// Study-Mode swipe lock: UIPageViewController's own pan lives on its
        /// internal paging scroll view.
        func setPagingEnabled(_ enabled: Bool) {
            guard let pageVC else { return }
            for sub in pageVC.view.subviews {
                if let sv = sub as? UIScrollView {
                    if sv.isScrollEnabled != enabled { sv.isScrollEnabled = enabled }
                }
            }
        }
    }
}
