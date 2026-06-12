// BookCoverView.swift
// SourceBible
//
// Full-bleed book cover shown at the top of every book's first chapter.
// Design (Figma node 982:2471): a pre-composited 402×402 blue Doré cover image,
// rendered full-bleed in a 402×302 frame. The extra 100pt of image height is the
// headroom for a parallax effect on scroll. A black bottom gradient keeps the
// bottom-left title + subtitle legible. Always blue — identical in light/dark mode.

import SwiftUI

struct BookCoverView: View {

    let bookId: String
    let bookName: String
    let chapterCount: Int

    // Visible cover height (frame). The Figma frame is 402×302.
    private let coverHeight: CGFloat = 302
    // Extra image height beyond the frame, used as parallax headroom.
    // Image is rendered at (coverHeight + parallaxRange) and translated within it.
    private let parallaxRange: CGFloat = 60
    // How much the image lags the scroll. 0 = pinned, 1 = moves with content.
    private let parallaxFactor: CGFloat = 0.35

    // #3085CF — brand blue, fallback cover for books without an image asset.
    private let brandBlue = Color(red: 0.188, green: 0.522, blue: 0.812)
    // #FBFAF9 — warm near-white, matches Figma text color.
    private let textColor = Color(red: 0.984, green: 0.980, blue: 0.973)

    private var coverData: BookCoverData.CoverInfo {
        BookCoverData.info(for: bookId, chapterCount: chapterCount)
    }

    var body: some View {
        // Local copies of layout constants — captured as values by the escaping
        // `visualEffect` closure (Swift 6 forbids implicit `self` capture there).
        let frameHeight = coverHeight
        let range = parallaxRange
        let factor = parallaxFactor

        return ZStack(alignment: .bottomLeading) {

            // ── Background fallback (brand blue, shows for image-less books) ─────
            brandBlue

            // ── Pre-composited cover image, full-bleed + parallax ───────────────
            if let assetName = coverData.imageName,
               UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    // Render taller than the visible frame so there is room to
                    // translate the image as the page scrolls (the parallax gap).
                    .frame(maxWidth: .infinity)
                    .frame(height: frameHeight + range)
                    .clipped()
                    .visualEffect { effect, geometry in
                        // minY in scroll space:
                        //   = 0   at rest (cover top flush with scroll top)
                        //   > 0   overscroll / pull-down  → gentle zoom
                        //   < 0   scrolled up (reading)    → parallax shift up
                        let minY = geometry.frame(in: .scrollView).minY
                        let shift = minY < 0
                            ? min(-minY * factor, range)
                            : 0
                        let zoom = minY > 0
                            ? 1 + (minY / max(frameHeight, 1)) * 0.6
                            : 1
                        return effect
                            .scaleEffect(zoom, anchor: .top)
                            .offset(y: -shift)
                    }
                    // Visible window: top-aligned so the parallax shift reveals the
                    // lower part of the image as the user scrolls.
                    .frame(height: frameHeight, alignment: .top)
                    .clipped()
            }

            // ── Black bottom gradient (Figma: clear → 18.87% → black 50%) ───────
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0),   location: 0.0),
                    .init(color: .black.opacity(0),   location: 0.1887),
                    .init(color: .black.opacity(0.5), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // ── Title + subtitle (bottom-leading) ───────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("The Book of \(bookName)")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(0.4)
                    .lineSpacing(-6)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(textColor)

                Text(coverData.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .foregroundStyle(textColor)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: frameHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 0) {
            BookCoverView(bookId: "GEN", bookName: "Genesis",         chapterCount: 50)
            BookCoverView(bookId: "PSA", bookName: "Psalms",          chapterCount: 150)
            BookCoverView(bookId: "MAT", bookName: "Matthew",         chapterCount: 28)
            BookCoverView(bookId: "REV", bookName: "Revelation",      chapterCount: 22)
            BookCoverView(bookId: "ECC", bookName: "Ecclesiastes",    chapterCount: 12)
            BookCoverView(bookId: "SNG", bookName: "Song of Solomon", chapterCount: 8)
        }
    }
    .ignoresSafeArea(edges: .top)
}
