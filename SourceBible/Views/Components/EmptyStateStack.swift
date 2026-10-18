// EmptyStateStack.swift
// SourceBible
//
// Icon + text empty state whose TEXT sits at the optical centre of the container,
// with the icon "hanging" above it (decided 2026-10-17). A plain VStack centres
// icon+text as one block, which reads as sitting too low.
//
// How: an invisible copy of the icon goes below the content, so the block is
// symmetric around the text — same size and spacing as the visible icon, with no
// magic numbers to keep in sync with icon sizes or Dynamic Type.

import SwiftUI

struct EmptyStateStack<Icon: View, Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: spacing) {
            icon
            content
            icon
                .hidden()
                .accessibilityHidden(true)
        }
    }
}
