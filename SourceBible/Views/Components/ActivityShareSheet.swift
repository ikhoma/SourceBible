// ActivityShareSheet.swift
// SourceBible
//
// SwiftUI-.sheet-хостований UIActivityViewController (системний Share Sheet).
// Презентується через UIViewControllerRepresentable, а не прямим UIKit
// .present(), тому iPad popoverPresentationController.sourceView/sourceRect
// anchoring не потрібно виставляти вручну — сам SwiftUI .sheet вже дає
// модальний контекст (ADR-037 §3).

import SwiftUI
import UIKit

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
