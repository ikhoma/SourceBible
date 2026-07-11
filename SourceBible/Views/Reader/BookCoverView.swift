// BookCoverView.swift
// SourceBible
//
// Full-bleed book cover shown at the top of every book's first chapter.
// Design: a pre-composited square (440×440) blue Doré cover image, rendered
// full-bleed in a PROPORTIONAL 4:3 window (height = width / (4:3), e.g. 440→330).
// The square asset is drawn `width` tall and center-cropped to the window, so the
// extra height is the parallax headroom (½ each side). A black bottom gradient keeps
// the bottom-left title + subtitle legible. Always blue — identical in light/dark mode.

import SwiftUI

struct BookCoverView: View {

    // Re-render on in-app language switch: BookCoverData returns an eagerly-resolved
    // String via NSLocalizedString, so the view must depend on \.locale to recompute
    // it when the language changes (mirrors EntriesView/MenuView .id(locale.identifier)).
    @Environment(\.locale) private var locale
    @Environment(\.titleFontStyle) private var titleFontStyle

    let bookId: String
    let bookName: String
    let chapterCount: Int

    // Cover aspect ratio (width : height). PROPORTIONAL across devices: the visible
    // window height = width / coverAspect (440→330, 402→301.5, 375→281), so the art
    // framing is consistent on every screen. (Previous approach: fixed 302 height.)
    private let coverAspect: CGFloat = 4.0 / 3.0
    // Height used only for the first layout pass, before the width is measured.
    private let fallbackHeight: CGFloat = 302
    // Measured full-bleed width (= screen width); drives the proportional height.
    @State private var coverWidth: CGFloat = 0
    // How much the image lags the scroll. 0 = pinned, 1 = moves with content.
    // Parallax travel is HALF the extra height ((width − windowHeight)/2): the square
    // asset renders `width` tall, centered, so reachable travel each way is half.
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
        let factor = parallaxFactor
        let frameHeight = coverWidth > 0 ? coverWidth / coverAspect : fallbackHeight

        return ZStack(alignment: .bottomLeading) {

            // ── Background fallback (brand blue, shows for image-less books) ─────
            brandBlue

            // ── Pre-composited cover image, full-bleed + parallax ───────────────
            if let assetName = coverData.imageName,
               UIImage(named: assetName) != nil {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height                 // = coverHeight (302)
                    // Center-aligned window: the image sits at rest with the extra height
                    // split evenly above/below, so the safe parallax travel in one
                    // direction is HALF the extra height — beyond that the window would
                    // run off the asset and expose an empty gap at the top.
                    let travel = max(0, (w - h) / 2)
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: w)          // natural square — no vertical crop
                        .visualEffect { effect, g in
                            // minY in scroll space:
                            //   = 0   at rest (cover top flush with scroll top)
                            //   > 0   overscroll / pull-down  → gentle zoom
                            //   < 0   scrolled up (reading)    → parallax shift down (flipped)
                            let minY = g.frame(in: .scrollView).minY
                            let shift = minY < 0 ? min(-minY * factor, travel) : 0
                            let zoom  = minY > 0 ? 1 + (minY / max(h, 1)) * 0.6 : 1
                            return effect
                                .scaleEffect(zoom, anchor: .bottom)
                                .offset(y: shift)
                        }
                        // Visible window: center-aligned → at rest the crop is split
                        // evenly (≈50pt top / 50pt bottom) rather than 100pt off the top;
                        // the parallax still reveals upward toward the top of the asset.
                        .frame(width: w, height: h, alignment: .center)
                        .clipped()
                }
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
                Text(bookName)
                    .font(titleFontStyle.coverTitleFont)
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
        .frame(maxWidth: .infinity)
        .frame(height: frameHeight)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
            if abs(coverWidth - w) > 0.5 { coverWidth = w }
        }
        .clipped()
        // Force rebuild on language change so BookCoverData re-reads NSLocalizedString.
        .id(locale.identifier)
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
