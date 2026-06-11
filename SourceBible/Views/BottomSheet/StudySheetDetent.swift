// StudySheetDetent.swift
// SourceBible
//
// Custom presentation detent for the Study Mode sheet (spec-study-mode-redesign.md R3).
//
// WHY a custom detent and not .height(value):
// 1. The .sheet(item:) content closure in ReaderView is NOT re-evaluated when
//    the presenter's @State changes — any .height(x) passed from there froze
//    at presentation time.
// 2. Even with the detent declared inside the sheet content, replacing the
//    detents SET ([.height(old)] → [.height(new)]) proved unreliable for an
//    already-presented sheet on device.
// With a custom detent the SET never changes — it is always
// [.custom(StudySheetDetent.self)] — and the system re-RESOLVES height(in:)
// on presentation layout updates. The desired height is delivered through the
// SwiftUI environment (the documented dynamic channel for custom detents:
// `Context` exposes the environment, which is how e.g. dynamicTypeSize-aware
// detents update while the sheet is open).

import SwiftUI

extension EnvironmentValues {
    /// Desired Study Mode sheet height, computed by ReaderViewModel and
    /// injected by VerseBottomSheetView. Read by StudySheetDetent's resolver.
    @Entry var studySheetHeight: CGFloat = 400
}

struct StudySheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.studySheetHeight, context.maxDetentValue)
    }
}

// MARK: - UIKit re-resolution helper

/// SwiftUI re-resolves custom detents lazily — on device the open sheet did
/// not pick up environment-value changes. This zero-size representable digs
/// out the hosting UISheetPresentationController via the responder chain and
/// calls `invalidateDetents()` inside `animateChanges` whenever the desired
/// height changes, forcing an immediate, animated re-resolution of
/// StudySheetDetent (which then reads the fresh environment value).
struct StudySheetDetentInvalidator: UIViewRepresentable {
    let height: CGFloat

    func makeUIView(context: Context) -> InvalidatorView {
        let v = InvalidatorView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: InvalidatorView, context: Context) {
        uiView.invalidate(for: height)
    }

    final class InvalidatorView: UIView {
        private var lastHeight: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // First chance the responder chain reaches the presented VC.
            invalidate(for: lastHeight, force: true)
        }

        func invalidate(for height: CGFloat, force: Bool = false) {
            if !force {
                guard abs(height - lastHeight) > 0.5 else { return }
            }
            lastHeight = height
            guard let sheet = sheetController() else { return }
            sheet.animateChanges {
                sheet.invalidateDetents()
            }
        }

        private func sheetController() -> UISheetPresentationController? {
            var responder: UIResponder? = self
            while let r = responder {
                if let vc = r as? UIViewController {
                    return vc.sheetPresentationController
                }
                responder = r.next
            }
            return nil
        }
    }
}
