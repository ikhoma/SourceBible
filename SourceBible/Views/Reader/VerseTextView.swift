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
    let isHighlighted: Bool
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
        tv.attributedText = buildAttributedString()
        tv.invalidateIntrinsicContentSize()
        context.coordinator.parsed        = parsed
        context.coordinator.isHighlighted = isHighlighted
        context.coordinator.onVerseTap    = onVerseTap
        context.coordinator.onWordTap     = onWordTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parsed: parsed, isHighlighted: isHighlighted,
                    onVerseTap: onVerseTap, onWordTap: onWordTap)
    }

    // MARK: sizeThatFits

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .infinity else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    // MARK: NSAttributedString builder

    func buildAttributedString() -> NSAttributedString {
        let result   = NSMutableAttributedString()
        let baseFont = UIFont.preferredFont(forTextStyle: .body)

        // Знаходимо індекс виділеного сегмента один раз
        let selectedIndex: Int? = selectedSegment.flatMap { seg in
            parsed.segments.firstIndex { $0.text == seg.text && $0.strongs == seg.strongs }
        }

        for (index, seg) in parsed.segments.enumerated() {

            // Paragraph break — невидимий
            if seg.isParagraphBreak { continue }

            // Line break
            if seg.isLineBreak {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: baseFont,
                    .verseSegmentIndex: index
                ]))
                continue
            }

            // Footnote anchor — superscript "†"
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

            var attrs: [NSAttributedString.Key: Any] = [
                .font:             resolveFont(baseFont, styles: seg.styles),
                .foregroundColor:  resolveColor(seg.styles),
                .verseSegmentIndex: index
            ]

            // Blue background for selected word (no handles — just highlight)
            if let selIdx = selectedIndex, index == selIdx {
                attrs[.backgroundColor] = UIColor.systemBlue.withAlphaComponent(0.2)
            }

            result.append(NSAttributedString(string: seg.text, attributes: attrs))
        }

        // Green highlight for bookmarked verse
        if isHighlighted && result.length > 0 {
            // Only add green where there's no word selection highlight
            result.enumerateAttribute(.backgroundColor,
                                      in: NSRange(location: 0, length: result.length)) { value, range, _ in
                if value == nil {
                    result.addAttribute(.backgroundColor,
                                        value: UIColor.systemGreen.withAlphaComponent(0.12),
                                        range: range)
                }
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

        var parsed:        ParsedVerse
        var isHighlighted: Bool
        var onVerseTap:    () -> Void
        var onWordTap:     (VerseSegment) -> Void

        init(parsed: ParsedVerse, isHighlighted: Bool,
             onVerseTap: @escaping () -> Void,
             onWordTap:  @escaping (VerseSegment) -> Void) {
            self.parsed        = parsed
            self.isHighlighted = isHighlighted
            self.onVerseTap    = onVerseTap
            self.onWordTap     = onWordTap
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
                            isHighlighted: verse.isHighlighted,
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
