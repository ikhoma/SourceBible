// CapsuleNavStyle.swift
// SourceBible
//
// ViewModifier that applies a capsule background to navigation button groups.
// iOS 26+: native Liquid Glass via .glassEffect.
// iOS 16–25: filled capsule with secondarySystemFill.

import SwiftUI

struct CapsuleNavGroupStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(Color(UIColor.secondarySystemFill))
                .clipShape(Capsule())
        }
    }
}

extension View {
    func capsuleNavGroupStyle() -> some View {
        modifier(CapsuleNavGroupStyle())
    }
}
