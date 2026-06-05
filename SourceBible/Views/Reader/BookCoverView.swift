// BookCoverView.swift
// SourceBible
//
// Full-bleed book cover displayed at the top of every book's first chapter.
// Design: Doré engraving on a blue gradient background with typographic overlay.
// The cover is always blue — it looks the same in light and dark mode.

import SwiftUI

struct BookCoverView: View {

    let bookId: String
    let bookName: String
    let chapterCount: Int

    // MARK: - Derived data

    private var coverData: BookCoverData.CoverInfo {
        BookCoverData.info(for: bookId, chapterCount: chapterCount)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottomLeading) {

            // ── Blue gradient background ────────────────────────────────
            // Approximates the diamond gradient in the Figma design:
            // center #3085CF → edges #25659D
            RadialGradient(
                colors: [Color(red: 0.188, green: 0.522, blue: 0.812),
                         Color(red: 0.145, green: 0.396, blue: 0.616)],
                center: .center,
                startRadius: 0,
                endRadius: 260
            )
            .ignoresSafeArea(edges: .top)

            // ── Doré engraving (if asset exists for this book) ──────────
            // HARD_LIGHT blend mode lets the blue bg show through the image,
            // giving the characteristic blue-tinted engraving look.
            if let assetName = coverData.imageName,
               UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 210)
                    .clipped()
                    .blendMode(.hardLight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 32)
            }

            // ── Text overlay ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {

                // "THE BOOK OF" — spaced small caps
                Text("THE BOOK OF")
                    .font(.system(size: 15, weight: .bold, design: .default))
                    .tracking(8)
                    .foregroundStyle(Color(red: 0.984, green: 0.980, blue: 0.973)) // #FBFAF9

                // Large book name — shrinks for long names (Ecclesiastes, Lamentations…)
                Text(bookName.uppercased())
                    .font(.system(size: 58, weight: .bold, design: .default))
                    .minimumScaleFactor(0.35)
                    .lineLimit(1)
                    .foregroundStyle(Color(red: 0.984, green: 0.980, blue: 0.973))

                // Bottom row: section (left) · metadata (right)
                HStack(alignment: .top) {
                    Text(coverData.sectionText)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Text(coverData.rightMetadata)
                        .multilineTextAlignment(.trailing)
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.984, green: 0.980, blue: 0.973))
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .clipShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        BookCoverView(bookId: "GEN", bookName: "Genesis")
        BookCoverView(bookId: "PSA", bookName: "Psalms")
        BookCoverView(bookId: "MAT", bookName: "Matthew")
    }
}
