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

        // Rebuild attributed string only when the text content or highlight changes.
        // selectedSegment changes are handled cheaply via applySelection() below.
        let contentChanged = coord.parsed.verseId != parsed.verseId
                          || coord.highlightColor  != highlightColor
        if contentChanged || tv.attributedText == nil || tv.attributedText.length == 0 {
            coord.baseAttributedString = buildBaseAttributedString()
        }

        // Apply (or clear) selection highlight on top of the cached base string.
        tv.attributedText = applySelection(to: coord.baseAttributedString)
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

    /// Copies the base string and adds the blue selection background for the active segment.
    /// Returns the base string unchanged when nothing is selected.
    func applySelection(to base: NSAttributedString) -> NSAttributedString {
        let selectedIndex: Int? = selectedSegment.flatMap { seg in
            parsed.segments.firstIndex { $0.text == seg.text && $0.strongs == seg.strongs }
        }
        guard let selIdx = selectedIndex, base.length > 0 else { return base }

        let result = NSMutableAttributedString(attributedString: base)
        result.enumerateAttribute(.verseSegmentIndex,
                                   in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let idx = value as? Int, idx == selIdx {
                result.addAttribute(.backgroundColor,
                                    value: UIColor.systemBlue.withAlphaComponent(0.2),
                                    range: range)
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

            var wordRange = NSRange(location: NSNotFound, length: 0)
            guard let segIndex = tv.attributedText.attribute(
                .verseSegmentIndex, at: charIdx, effectiveRange: &wordRange
            ) as? Int else { return }

            let seg = parsed.segments[segIndex]
            guard !seg.strongs.isEmpty else { return }

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // Blue highlight is applied via selectedSegment → buildAttributedString (SwiftUI re-render)
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
