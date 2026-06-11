// EdgeSwipeNavigator.swift
// SourceBible
//
// Transparent full-screen overlay that captures UIScreenEdgePanGestureRecognizer
// events for chapter navigation.
//
// Why not DragGesture?
// VerseTextView uses UITextView underneath, which consumes all touch events.
// SwiftUI's DragGesture never fires over UITextView content — only over padding.
// UIScreenEdgePanGestureRecognizer is a UIKit recognizer that fires from the
// hardware screen edge regardless of what is displayed on screen.
//
// Edge mapping (mirrors Safari / iOS back/forward gesture UX):
//   Left  edge pan  →  previous chapter
//   Right edge pan  →  next chapter
//
// Visibility note:
// EdgeOnlyView is private to this file. UIViewRepresentable infers UIViewType from
// makeUIView's return type — which would make both protocol methods fileprivate, causing
// a conflict with the internal conformance. Solution: explicitly declare
//   typealias UIViewType = UIView
// so the protocol methods use the public UIView type. EdgeOnlyView is still created
// internally and cast where needed.

import SwiftUI
import UIKit

// UIView subclass that only hit-tests within a narrow strip along the left/right edges.
// All other touches fall through to views below, so vertical scrolling is unaffected.
private final class EdgeOnlyView: UIView {
    static let edgeWidth: CGFloat = 20

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard point.x <= Self.edgeWidth || point.x >= bounds.width - Self.edgeWidth else {
            return nil   // pass through — ScrollView handles this touch
        }
        return super.hitTest(point, with: event)
    }
}

struct EdgeSwipeNavigator: UIViewRepresentable {

    // Explicit UIViewType = UIView prevents Swift from inferring EdgeOnlyView
    // as the associated type, which would force protocol methods to be fileprivate.
    typealias UIViewType = UIView

    var onPrevChapter: () -> Void   // left edge swipe  → prev
    var onNextChapter: () -> Void   // right edge swipe → next

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevChapter: onPrevChapter, onNextChapter: onNextChapter)
    }

    func makeUIView(context: Context) -> UIView {
        let view = EdgeOnlyView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let leftEdge = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLeftEdge(_:))
        )
        leftEdge.edges = .left
        view.addGestureRecognizer(leftEdge)

        let rightEdge = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightEdge(_:))
        )
        rightEdge.edges = .right
        view.addGestureRecognizer(rightEdge)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPrevChapter = onPrevChapter
        context.coordinator.onNextChapter = onNextChapter
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var onPrevChapter: () -> Void
        var onNextChapter: () -> Void

        init(onPrevChapter: @escaping () -> Void, onNextChapter: @escaping () -> Void) {
            self.onPrevChapter = onPrevChapter
            self.onNextChapter = onNextChapter
        }

        @objc func handleLeftEdge(_ gr: UIScreenEdgePanGestureRecognizer) {
            guard gr.state == .began else { return }
            onPrevChapter()
        }

        @objc func handleRightEdge(_ gr: UIScreenEdgePanGestureRecognizer) {
            guard gr.state == .began else { return }
            onNextChapter()
        }
    }
}
