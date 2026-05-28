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

// MARK: - VerseTextView

struct VerseTextView: UIViewRepresentable {

    let parsed: ParsedVerse
    /// rawValue of HighlightColor, or nil if not highlighted.
    var highlightColor: String? = nil
    /// Сегмент що зараз виділений (word mode). nil — виділення знято.
    var selectedSegment: VerseSegment? = nil
    var onVerseTap: () -> Void
    var onWordTap: (VerseSegment) -> Void

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
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

        // Invalidate the stored word range whenever the selected segment changes from
        // outside this view (e.g. the user navigated via the ‹ › arrows in the bottom
        // sheet). In that case we fall back to highlighting the full segment run.
        // When the change originated from handleLongPress inside this view, the UUID
        // is already updated before onWordTap fires, so the range is preserved.
        if coord.selectedSegmentId != selectedSegment?.id {
            coord.selectedWordRange  = nil
            coord.selectedSegmentId  = selectedSegment?.id
        }

        // Rebuild attributed string only when the text content or highlight changes.
        // selectedSegment changes are handled cheaply via applySelection() below.
        let contentChanged = coord.parsed.verseId != parsed.verseId
                          || coord.highlightColor  != highlightColor
        if contentChanged || tv.attributedText == nil || tv.attributedText.length == 0 {
            coord.baseAttributedString = buildBaseAttributedString()
        }

        // Apply (or clear) selection highlight on top of the cached base string.
        tv.attributedText = applySelection(to: coord.baseAttributedString,
                                           wordRange: coord.selectedWordRange)
        tv.invalidateIntrinsicContentSize()

        coord.parsed         = parsed
        coord.highlightColor = highlightColor
        coord.onVerseTap     = onVerseTap
        coord.onWordTap      = onWordTap
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(parsed: parsed, highlightColor: highlightColor,
                                onVerseTap: onVerseTap, onWordTap: onWordTap)
        coord.baseAttributedString = buildBaseAttributedString()
        return coord
    }

    // MARK: sizeThatFits

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .infinity else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
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
                    .foregroundColor: UIColor.systemBlue,
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

        // Verse-level highlight background (does not include selection — that's added later)
        if let rawColor = highlightColor, result.length > 0 {
            let uiColor = HighlightColor.from(rawColor).uiColor.withAlphaComponent(0.22)
            result.addAttribute(.backgroundColor, value: uiColor,
                                range: NSRange(location: 0, length: result.length))
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
            result.addAttribute(.backgroundColor, value: UIColor.wordHighlight, range: wr)
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
                result.addAttribute(.backgroundColor, value: UIColor.wordHighlight, range: range)
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
        styles.contains(.jesusWords) ? .systemRed : .label
    }

    // MARK: Coordinator

    final class Coordinator: NSObject {

        var parsed:               ParsedVerse
        var highlightColor:       String?
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

        var selectedWordRange:  NSRange? = nil
        var selectedSegmentId:  UUID?    = nil

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

            // Find the word boundary around the tapped character.
            // NSString.enumerateSubstrings(byWords) skips spaces and punctuation,
            // so tapping "morning," highlights only "morning" (no trailing comma).
            // Store the result on the coordinator BEFORE calling onWordTap() so
            // that updateUIView() sees the matching (segmentId, wordRange) pair.
            var tappedWordRange: NSRange? = nil
            let nsStr = tv.attributedText.string as NSString
            nsStr.enumerateSubstrings(
                in: NSRange(location: 0, length: nsStr.length),
                options: .byWords
            ) { _, range, _, stop in
                if NSLocationInRange(charIdx, range) {
                    tappedWordRange = range
                    stop.pointee = true
                }
            }
            selectedWordRange = tappedWordRange
            selectedSegmentId = seg.id

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                .padding(.horizontal, 20)
                Divider().padding(.leading, 34).opacity(0.4)
            }
        }
        .padding(.vertical, 12)
    }
}
