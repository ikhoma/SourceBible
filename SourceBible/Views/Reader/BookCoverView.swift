// BookCoverView.swift
// SourceBible
//
// Full-bleed book cover shown at the top of every book's first chapter.
// Design: Doré engraving (HARD_LIGHT blend) on blue diamond gradient, typographic overlay.
// Always blue — identical in light and dark mode.

import SwiftUI

// MARK: - Diamond gradient background

/// Faithful recreation of Figma's Diamond gradient (#3085CF center → #25659D edges).
///
/// How it works: split the frame into 4 triangles from the center and fill each
/// with a LinearGradient from its edge midpoint (dark) to the center (light).
/// Adjacent triangles share the same gradient value along their shared diagonal,
/// so the join is seamless. The iso-color lines form perfect diamonds (L1 distance).
private struct DiamondGradientBackground: View {

    // Figma stops: 0% #3085CF (center/light) → 100% #25659D (edges/dark)
    private let centerColor = Color(red: 0.188, green: 0.522, blue: 0.812) // #3085CF
    private let edgeColor   = Color(red: 0.145, green: 0.396, blue: 0.616) // #25659D

    var body: some View {
        Canvas { ctx, size in
            let w  = size.width
            let h  = size.height
            let cx = w / 2
            let cy = h / 2
            let c  = CGPoint(x: cx, y: cy)

            // Triangle definitions: (corner A, corner B, gradient start, gradient end)
            // Gradient start points are pushed 50% of the half-dimension BEYOND the frame edge,
            // as if the gradient fills a 1.5× larger rectangle masked by this frame.
            // At each visible edge the gradient sits at t = 1/3 (not fully dark),
            // so the center light color fills most of the visible area.
            let triangles: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
                // Top
                (CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0),
                 CGPoint(x: cx, y: -cy * 0.5), c),
                // Right
                (CGPoint(x: w, y: 0), CGPoint(x: w, y: h),
                 CGPoint(x: w + cx * 0.5, y: cy), c),
                // Bottom
                (CGPoint(x: w, y: h), CGPoint(x: 0, y: h),
                 CGPoint(x: cx, y: h + cy * 0.5), c),
                // Left
                (CGPoint(x: 0, y: h), CGPoint(x: 0, y: 0),
                 CGPoint(x: -cx * 0.5, y: cy), c),
            ]

            // Non-linear stops: dark holds near edges, center color fills most of the space,
            // transition is soft (ease-in curve approximated with 4 stops)
            let gradient = Gradient(stops: [
                .init(color: edgeColor,                                              location: 0.00),
                .init(color: Color(red: 0.153, green: 0.420, blue: 0.655),          location: 0.25), // ~20% mixed
                .init(color: centerColor,                                            location: 0.65), // center reached early
                .init(color: centerColor,                                            location: 1.00),
            ])

            for (a, b, gradStart, gradEnd) in triangles {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: c)
                path.closeSubpath()

                ctx.fill(path, with: .linearGradient(
                    gradient,
                    startPoint: gradStart,
                    endPoint:   gradEnd
                ))
            }
        }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Cover view

struct BookCoverView: View {

    let bookId: String
    let bookName: String
    let chapterCount: Int

    private var coverData: BookCoverData.CoverInfo {
        BookCoverData.info(for: bookId, chapterCount: chapterCount)
    }

    // #FBFAF9 — warm near-white, matches Figma text color
    private let textColor = Color(red: 0.984, green: 0.980, blue: 0.973)

    var body: some View {
        ZStack(alignment: .bottomLeading) {

            // ── Diamond gradient background (faithful Figma recreation) ────────
            DiamondGradientBackground()

            // ── Doré engraving (HARD_LIGHT blend, gracefully absent if no asset) ─
            if let assetName = coverData.imageName,
               UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 168, height: 224) // 1:1 with @3x natural size (504÷3 × 672÷3)
                    .clipped()
                    .blendMode(.normal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
            }

            // ── Text overlay ──────────────────────────────────────────────────
            VStack(spacing: 12) {

                // Inner VStack: "THE BOOK OF" + book name
                VStack(spacing: 12) {
                    Text("THE BOOK OF")
                        .font(.system(size: 32, weight: .bold))
                        .tracking(10)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .capHeightLayout(fontSize: 32)

                    Text(bookName.uppercased())
                        .font(.system(size: 78, weight: .bold))
                        .minimumScaleFactor(0.35)
                        .lineLimit(1)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .capHeightLayout(fontSize: 78)
                }

                // Metadata row — 16pt Bold, tracking −0.43, SPACE_BETWEEN
                // lineSpacing = (16 × 0.96) − UIFont.lineHeight ≈ 15.36 − 19.09 = −3.73
                // matches Figma's 96 % line-height for 16 pt bold (San Francisco Text).
                HStack {
                    Text(coverData.sectionText)
                        .multilineTextAlignment(.center)
                    Spacer()
                    Text(coverData.rightMetadata)
                        .multilineTextAlignment(.center)
                }
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.43)
                .lineSpacing(-3.73)
                .foregroundStyle(textColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 37)
            .padding(.bottom, 32)
        }
        .frame(height: 302)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Cap-height layout helper

private extension View {
    /// Trims the built-in line-spacing SwiftUI adds around text glyphs so the
    /// view's layout height matches Figma's cap-height measurement (all-caps text
    /// has no ascenders above the cap line and no visible descenders).
    ///
    /// SwiftUI allocates the full UIFont line height (ascender + descender).
    /// For all-caps text this means:
    ///   - top padding   = ascender − capHeight  (space above cap letters)
    ///   - bottom padding = |descender|           (space below baseline)
    /// Negative padding on both sides collapses the view to cap height.
    func capHeightLayout(fontSize: CGFloat) -> some View {
        let font   = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let top    = -(font.ascender - font.capHeight)   // e.g. −18pt at 78pt
        let bottom = font.descender                      // already negative, e.g. −19pt at 78pt
        return self
            .padding(.top,    top)
            .padding(.bottom, bottom)
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
}
