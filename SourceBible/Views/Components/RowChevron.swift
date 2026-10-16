// RowChevron.swift
// SourceBible
//
// The trailing ">" of a tappable row, drawn by hand (rows that aren't NavigationLinks
// in a List — sheets, ScrollView lists). Single source so every hand-drawn chevron
// matches the system disclosure indicator that native List rows get for free
// (Menu): footnote-size, semibold, tertiary label colour. Before 2026-10-16 six
// copies drifted between .caption/.quaternary and .caption/.tertiary.

import SwiftUI

struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
