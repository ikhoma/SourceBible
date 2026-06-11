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
