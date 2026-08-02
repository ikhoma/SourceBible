// VerseTextView.swift
// SourceBible
//
// UIViewRepresentable що рендерить ParsedVerse через UITextView.
//
// Жести:
//   tap          → onVerseTap()   (відкриває bottom sheet у verse mode)
//   long press   → onWordTap(_:)  (відкриває bottom sheet у word mode для тапнутого слова)
//
// Розмір: isScrollEnabled = false → UITextView сам розраховує висоту за вмістом.
// SwiftUI ScrollView керує скролом.

import SwiftUI
import UIKit

// MARK: - Custom NSAttributedString key

extension NSAttributedString.Key {
    /// Зберігає індекс сегмента у ParsedVerse.segments для reverse lookup при long press
    static let verseSegmentIndex = NSAttributedString.Key("com.sourcebible.segmentIndex")
}

// MARK: - HighlightableTextView

/// UITextView subclass that draws per-line background highlights in draw(_:).
///
/// Problem with alternatives:
///   • tv.backgroundColor        → fills the entire frame width; short last lines look wrong
///   • NSAttributedString .backgroundColor → fills only glyph bounds, leaving inter-line
///                                          gaps equal to the font leading
///
/// This subclass solves both:
///   • draws usedRect.width per line   → no trailing colour on short/last lines
///   • draws lineFragRect.height per line → no gaps between wrapped lines
///
/// draw(_:) and NSLayoutManager are both @MainActor on iOS 26 SDK → zero Swift 6 issues.
private final class HighlightableTextView: UITextView {

    var highlightColor: UIColor? {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        if let color = highlightColor {
            color.setFill()
            let dx = textContainerInset.left
            let dy = textContainerInset.top
            let fullRange = layoutManager.glyphRange(for: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: fullRange) { lineFragRect, usedRect, _, _, _ in
                let fill = CGRect(
                    x: usedRect.minX + dx,
                    y: lineFragRect.minY + dy,
                    width: usedRect.width,
                    height: lineFragRect.height
                )
                UIBezierPath(rect: fill).fill()
            }
        }
        super.draw(rect)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if highlightColor != nil { setNeedsDisplay() }
    }
}

// MARK: - VerseTextView

struct VerseTextView: UIViewRepresentable {

    let parsed: ParsedVerse
    /// rawValue of HighlightColor, or nil if not highlighted.
    var highlightColor: String? = nil
    /// Сегмент що зараз виділений (word mode). nil — виділення знято.
    var selectedSegment: VerseSegment? = nil
    /// When false, Jesus' words render in the normal label color (red-letter mode off).
    var redLetters: Bool = false
    var onVerseTap: () -> Void
    var onWordTap: (VerseSegment) -> Void

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let tv = HighlightableTextView()
        tv.isEditable        = false
        tv.isSelectable      = false
        tv.isScrollEnabled   = false
        tv.backgroundColor   = .clear
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0

        // Tap → verse mode
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tv.addGestureRecognizer(tap)

        // Long press → word mode
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        tv.addGestureRecognizer(longPress)

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator

        // Detect selection changes BEFORE mutating coordinator state so we can
        // accurately track whether this updateUIView call needs to redraw.
        //
        // Case A — segment changed from outside (‹ › chevron navigation or verse tap):
        //   selectedSegment?.id ≠ coord.selectedSegmentId → clear stored word range
        //   so applySelection() falls back to full-segment highlight.
        // Case B — same segment, same word (no-op re-render from parent): both IDs match,
        //   the stored word range is still valid — leave it alone.
        // Case C — handleLongPress fired: it already updated coord.selectedSegmentId
        //   and coord.selectedWordRange before onWordTap (and therefore before this
        //   updateUIView call), so the IDs will match and we'll detect the word range
        //   change below instead.
        let selectionChanged = coord.selectedSegmentId != selectedSegment?.id
        if selectionChanged {
            coord.selectedWordRange  = nil
            coord.selectedSegmentId  = selectedSegment?.id
        }

        // Detect word-range changes within the same segment (user long-pressed a
        // different word inside an already-selected multi-word segment).
        let newRange = coord.selectedWordRange
        let wordRangeChanged: Bool = {
            switch (coord.lastRenderedWordRange, newRange) {
            case (.none, .none):            return false
            case (.some, .none), (.none, .some): return true
            case (.some(let a), .some(let b)): return a.location != b.location || a.length != b.length
            }
        }()

        // Rebuild attributed string only when verse content, highlight colour, or the
        // red-letter setting changed. redLetters is deliberately handled HERE and not
        // via .id() in VerseRowView: putting a global setting in the row identity makes
        // SwiftUI destroy + recreate every UITextView in the chapter on each toggle
        // (new coordinator, new gesture recognizers, full TextKit layout ×N verses),
        // which froze the reader for ~1s. Updating in place is an order cheaper.
        let contentChanged = coord.parsed.verseId != parsed.verseId
                          || coord.highlightColor  != highlightColor
                          || coord.redLetters      != redLetters
        if contentChanged || tv.attributedText == nil || tv.attributedText.length == 0 {
            coord.baseAttributedString = buildBaseAttributedString()
        }

        // Verse-level highlight: drawn in HighlightableTextView.draw(_:) which fills
        // lineFragRect.height (no inter-line gaps) but only usedRect.width (no trailing
        // colour past the text on short/last lines).
        (tv as? HighlightableTextView)?.highlightColor = highlightColor.map {
            HighlightColor.from($0).uiColor.withAlphaComponent(0.22)
        }

        // Only assign attributedText when something actually changed.
        //
        // UIKit resolves dynamic (adaptive) colors — UIColor.label, UIColor.systemRed, etc. —
        // in UITextView.attributedText automatically via traitCollectionDidChange when the
        // color scheme flips light ↔ dark. We must NOT re-set attributedText on color-scheme
        // changes alone: doing so forces a full text-layout pass on every visible VerseTextView
        // simultaneously, which is what caused the freeze on the first theme switch when a
        // chapter with many verses (e.g. Genesis 1 with 31 verses) is open.
        if contentChanged || selectionChanged || wordRangeChanged
                || tv.attributedText == nil || tv.attributedText.length == 0 {
            tv.attributedText = applySelection(to: coord.baseAttributedString,
                                               wordRange: coord.selectedWordRange)
            tv.invalidateIntrinsicContentSize()
            coord.lastRenderedWordRange = coord.selectedWordRange
        }

        coord.parsed         = parsed
        coord.highlightColor = highlightColor
        coord.redLetters     = redLetters
        coord.onVerseTap     = onVerseTap
        coord.onWordTap      = onWordTap
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(parsed: parsed, highlightColor: highlightColor,
                                onVerseTap: onVerseTap, onWordTap: onWordTap)
        coord.redLetters = redLetters
        coord.baseAttributedString = buildBaseAttributedString()
        return coord
    }

    // MARK: sizeThatFits

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .infinity else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // +1pt slack — ⚠️ DO NOT REMOVE.
        //
        // SwiftUI pixel-aligns the final frame: with any fractional content offset
        // above this view (e.g. Cormorant/Antique titles have non-integral line
        // heights) the assigned height can come out up to ~2/3 pt SHORT of what we
        // return (measured: sizeThatFits 66.0 → frame 65.667 on 3x). TextKit 2
        // (iOS 16+ UITextView) then drops the ENTIRE last line fragment that no
        // longer fully fits the text container — the verse renders with its last
        // line missing and a phantom gap below (bug: 2026-07-11, "порожні рядки в
        // рідері"). One extra point absorbs the worst-case rounding on any scale;
        // visually invisible between verses.
        return CGSize(width: width, height: size.height + 1)
    }

    // MARK: NSAttributedString builders

    /// Builds the base attributed string (text + styles + highlight color).
    /// Does NOT include the selection blue background — that is applied separately
    /// in applySelection() so we can cheaply update just the selection without
    /// rebuilding the whole string.
    func buildBaseAttributedString() -> NSAttributedString {
        let result   = NSMutableAttributedString()
        let baseFont = UIFont.preferredFont(forTextStyle: .body)

        for (index, seg) in parsed.segments.enumerated() {

            if seg.isParagraphBreak { continue }

            if seg.isLineBreak {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: baseFont,
                    .verseSegmentIndex: index
                ]))
                continue
            }

            if let anchorId = seg.footnoteAnchorId, seg.text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font:            UIFont.preferredFont(forTextStyle: .caption2),
                    .foregroundColor: UIColor.appBlue,
                    .baselineOffset:  NSNumber(value: 5),
                    .verseSegmentIndex: index,
                    NSAttributedString.Key("footnoteAnchorId"): anchorId
                ]
                result.append(NSAttributedString(string: "†", attributes: attrs))
                continue
            }

            guard !seg.text.isEmpty else { continue }

            let attrs: [NSAttributedString.Key: Any] = [
                .font:              resolveFont(baseFont, styles: seg.styles),
                .foregroundColor:   resolveColor(seg.styles),
                .verseSegmentIndex: index
            ]
            result.append(NSAttributedString(string: seg.text, attributes: attrs))
        }

        return result
    }

    /// Copies the base string and adds the word-selection background for the active segment.
    /// Returns the base string unchanged when nothing is selected.
    ///
    /// `wordRange` — when provided (set by a long-press inside this view), only that
    /// character range is highlighted. This narrows the visual to the specific tapped
    /// word, avoiding over-selection when a KJV segment spans multiple English words
    /// (e.g. "in the morning" for H1242 = בֹּקֶר).
    ///
    /// When `wordRange` is nil (word set via navigation arrows), the whole segment run
    /// is highlighted as a fallback so the user still sees which word is active.
    func applySelection(to base: NSAttributedString,
                        wordRange: NSRange? = nil) -> NSAttributedString {
        guard selectedSegment != nil, base.length > 0 else { return base }

        let result = NSMutableAttributedString(attributedString: base)

        // Fast path: we have a precise word range from the long-press.
        if let wr = wordRange,
           wr.location != NSNotFound,
           NSMaxRange(wr) <= result.length {
            result.addAttribute(.foregroundColor, value: UIColor.wordSelectionTint, range: wr)
            return result
        }

        // Fallback: highlight the whole segment (navigation-arrow word changes).
        let selectedIndex: Int? = selectedSegment.flatMap { seg in
            parsed.segments.firstIndex { $0.text == seg.text && $0.strongs == seg.strongs }
        }
        guard let selIdx = selectedIndex else { return base }

        result.enumerateAttribute(.verseSegmentIndex,
                                   in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let idx = value as? Int, idx == selIdx {
                result.addAttribute(.foregroundColor, value: UIColor.wordSelectionTint, range: range)
            }
        }
        return result
    }

    // MARK: Font & Color helpers

    private func resolveFont(_ base: UIFont, styles: SegmentStyle) -> UIFont {
        if styles.contains(.italic) && styles.contains(.jesusWords) {
            return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitItalic)
                          ?? base.fontDescriptor, size: base.pointSize)
        }
        if styles.contains(.italic)  { return UIFont.italicSystemFont(ofSize: base.pointSize) }
        if styles.contains(.emphasis) { return UIFont.boldSystemFont(ofSize: base.pointSize) }
        return base
    }

    private func resolveColor(_ styles: SegmentStyle) -> UIColor {
        (redLetters && styles.contains(.jesusWords)) ? .redLetterText : .label
    }

    // MARK: Coordinator

    final class Coordinator: NSObject {

        var parsed:               ParsedVerse
        var highlightColor:       String?
        /// Last-rendered red-letter setting; compared in updateUIView to know when the
        /// base attributed string must be rebuilt with/without the Jesus-words colour.
        var redLetters:           Bool = false
        var onVerseTap:           () -> Void
        var onWordTap:            (VerseSegment) -> Void
        /// Cached base string (text + styles + highlight). Rebuilt only when content changes.
        var baseAttributedString: NSAttributedString = NSAttributedString()

        // MARK: Word-range tracking
        //
        // Set by handleLongPress to the exact character range of the tapped word (as
        // determined by NSString word-boundary enumeration). This lets applySelection()
        // highlight just "morning" rather than the whole KJV segment "in the morning",
        // when a single Hebrew word is translated with multiple English words.
        //
        // selectedSegmentId mirrors the UUID of the segment for which wordRange was
        // computed. updateUIView() clears wordRange when a different segment becomes
        // active (e.g. user navigated via ‹ › arrows), falling back to full-segment
        // highlight for that case.

        var selectedWordRange:      NSRange? = nil
        var selectedSegmentId:      UUID?    = nil
        /// Tracks the word range used in the most recent attributedText assignment.
        /// Compared against selectedWordRange in updateUIView to detect intra-segment
        /// re-taps (different word, same segment UUID) that still need a redraw.
        var lastRenderedWordRange:  NSRange? = nil

        init(parsed: ParsedVerse, highlightColor: String?,
             onVerseTap: @escaping () -> Void,
             onWordTap:  @escaping (VerseSegment) -> Void) {
            self.parsed         = parsed
            self.highlightColor = highlightColor
            self.onVerseTap     = onVerseTap
            self.onWordTap      = onWordTap
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended else { return }
            onVerseTap()
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began,
                  let tv = gr.view as? UITextView else { return }

            let point   = gr.location(in: tv)
            let charIdx = charIndex(in: tv, at: point)
            guard charIdx < tv.attributedText.length else { return }

            var segAttrRange = NSRange(location: NSNotFound, length: 0)
            guard let segIndex = tv.attributedText.attribute(
                .verseSegmentIndex, at: charIdx, effectiveRange: &segAttrRange
            ) as? Int else { return }

            let seg = parsed.segments[segIndex]
            guard !seg.strongs.isEmpty else { return }

            // Highlight the WHOLE segment (phrase), not just the tapped word, so the
            // selection matches the chevron-nav behaviour and the Sheet title — both of
            // which show the full phrase (e.g. "In the beginning" for H7225 רֵאשִׁית).
            // Leaving selectedWordRange nil makes applySelection() fall through to the
            // full-segment highlight branch.
            //
            // We must NOT pre-assign selectedSegmentId here: the redraw in updateUIView()
            // is driven by `selectionChanged` (coord.selectedSegmentId ≠ new selectedSegment.id).
            // If we synced the id now, selectionChanged would be false and — with the word
            // range always nil — nothing would trigger the redraw, so the blue tint would
            // never get applied. Let onWordTap → selectedSegment update drive the redraw.
            selectedWordRange = nil

            Haptics.selectionChanged()
            // Highlight is applied via selectedSegment → applySelection() (SwiftUI re-render)
            onWordTap(seg)
        }

        private func charIndex(in tv: UITextView, at point: CGPoint) -> Int {
            guard let pos = tv.closestPosition(to: point) else { return 0 }
            return tv.offset(from: tv.beginningOfDocument, to: pos)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(BibleVerse.sampleVerses) { verse in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(verse.number)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)
                        .padding(.top, 3)
                    if let parsed = verse.parsed {
                        VerseTextView(
                            parsed: parsed,
                            highlightColor: verse.highlightColor,
                            onVerseTap: {},
                            onWordTap: { seg in print("Word tap: \(seg.text) → \(seg.strongs)") }
                        )
                    } else {
                        Text(verse.text).font(.body).lineSpacing(6)
                    }
                }
                .padding(.horizontal)
                Divider().padding(.leading, 34).opacity(0.4)
            }
        }
        .padding(.vertical, 12)
    }
}
#endif
