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

// MARK: - UIKit detent applier

/// Drives the sheet height at the UIKit level, bypassing SwiftUI's detent
/// plumbing entirely. On device, neither replacing a SwiftUI .height set nor
/// invalidateDetents()-driven re-resolution of a custom detent resized the
/// open sheet — so this zero-size representable finds the hosting
/// UISheetPresentationController via the responder chain and SETS
/// `sheet.detents` directly to a UIKit custom detent with the desired height,
/// animated via animateChanges. The only dependency left is the verse
/// measurement itself.
struct StudySheetDetentApplier: UIViewRepresentable {
    let height: CGFloat

    func makeUIView(context: Context) -> ApplierView {
        let v = ApplierView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ApplierView, context: Context) {
        uiView.desiredHeight = height
    }

    @MainActor
    final class ApplierView: UIView {
        var desiredHeight: CGFloat = 0 {
            didSet {
                guard abs(desiredHeight - oldValue) > 0.5 else { return }
                apply(animated: true)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // First moment the responder chain reaches the presented VC.
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard desiredHeight > 0, let sheet = sheetController() else { return }
            let h = desiredHeight
            let detent = UISheetPresentationController.Detent.custom(
                identifier: .init("studySheet")
            ) { context in
                let resolved = min(h, context.maximumDetentValue)
                // DIAGNOSTIC (debug session 2026-06-12): trace the ~16 pt gap loss.
                let screenH = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? -1
                let insets = sheet.containerView?.safeAreaInsets
                let containerH = sheet.containerView?.bounds.height ?? -1
                // The sheet's ACTUAL view frame in container coords — ground truth
                // for where the top really lands (vs the computed containerH-resolved).
                let realTop = sheet.presentedView?.frame.minY ?? -1
                print("""
                [SHEET] desiredH=\(h) resolved=\(resolved) maxDetent=\(context.maximumDetentValue) \
                screenH=\(screenH) containerH=\(containerH) \
                safeArea top=\(insets?.top ?? -1) bottom=\(insets?.bottom ?? -1) \
                computedTopY=\(containerH - resolved) REAL_sheetTopY=\(realTop)
                """)
                return resolved
            }
            if animated {
                sheet.animateChanges { sheet.detents = [detent] }
            } else {
                sheet.detents = [detent]
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
