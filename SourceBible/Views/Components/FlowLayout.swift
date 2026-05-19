// FlowLayout.swift
// SourceBible
//
// Reusable SwiftUI Layout that wraps children into rows like text (word-wrap).
// Used in WordUsageView (concordance chips) and any future tag/chip UI.

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
            .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews) {
            let h = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for sv in row {
                let s = sv.sizeThatFits(.unspecified)
                sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + spacing
        }
    }

    private func rows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var rowWidth: CGFloat = 0
        let max = proposal.width ?? 300
        for sv in subviews {
            let w = sv.sizeThatFits(.unspecified).width
            if rowWidth + w > max, !rows.last!.isEmpty { rows.append([]); rowWidth = 0 }
            rows[rows.count - 1].append(sv)
            rowWidth += w + spacing
        }
        return rows
    }
}
