// EntryShareFormatter.swift
// SourceBible
//
// Plain-text share strings for the Entries tab swipe action «Поділитись»
// (notes and bookmarks). Mirrors the attribution conventions of
// VerseShareFormatter (verse) and CommentaryQuoteShareFormatter (quote) so a
// verse shared from Entries reads the same as one shared from Study Mode.
//
// Note  → its blocks in position order: verse / quote blocks with attribution,
//         then the user's own text (Ivan, 2026-09-23: «вірш + текст нотатки»).
// Bookmark → exactly what BookmarkCardView shows: the ACTIVE translation, with the
//         verse_org hop + renumbering for bookmarks whose creation translation is
//         known and differs (bug-037). The resolution logic below deliberately
//         duplicates BookmarkCardView.loadVerseText() — keep the two in sync.

import Foundation

@MainActor
enum EntryShareFormatter {

    // MARK: - Note

    /// nil when the note has nothing shareable (all blocks empty).
    static func format(note item: NoteWithBlocks, readerVM: ReaderViewModel) -> String? {
        let decoder = JSONDecoder()
        var parts: [String] = []

        for block in item.blocks.sorted(by: { $0.position < $1.position }) {
            let data = Data(block.content.utf8)
            switch block.type {
            case .verse:
                guard let c = try? decoder.decode(VerseBlockContent.self, from: data),
                      !c.text.isEmpty else { continue }
                var ref = reference(for: c.verseId, readerVM: readerVM)
                if !c.translationId.isEmpty { ref += " (\(c.translationId))" }
                parts.append("\"\(c.text)\"\n\n— \(ref)")

            case .quote:
                guard let c = try? decoder.decode(QuoteBlockContent.self, from: data),
                      !c.text.isEmpty else { continue }
                let name = Theologian.all.first(where: { $0.id == c.theologianId })?.shortName
                    ?? c.theologianId.capitalized
                parts.append(CommentaryQuoteShareFormatter.format(
                    quote: c.text,
                    theologianShortName: name,
                    ref: reference(for: c.verseId, readerVM: readerVM)))

            case .text:
                guard let c = try? decoder.decode(TextBlockContent.self, from: data) else { continue }
                let body = c.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { parts.append(body) }

            case .word, .ai:
                // No UI creates these in v1 — nothing to share yet.
                continue
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Bookmark

    /// nil when the verse text can't be resolved in the active translation.
    static func format(bookmark item: BookmarkWithVerses, readerVM: ReaderViewModel) -> String? {
        guard let first = item.verseIds.first else { return nil }
        let p = first.split(separator: "|")
        guard p.count == 3, let chapter = Int(p[1]), let verse = Int(p[2]) else { return nil }
        let bookId = String(p[0])
        let target = readerVM.currentTranslation.id

        var ref  = (bookId: bookId, chapter: chapter, verse: verse)
        var text: String?

        if let source = item.verseTranslations[first], source != target,
           let hop = DatabaseService.shared.loadHoppedVerse(
               bookId: bookId, chapter: chapter, verse: verse,
               source: source, target: target) {
            ref  = (hop.bookId, hop.chapter, hop.verse)
            text = hop.text
        } else {
            text = DatabaseService.shared.loadVerseText(
                bookId: bookId, chapter: chapter, verse: verse, translation: target)
        }

        guard let text, !text.isEmpty else { return nil }
        let refString = "\(longBookName(ref.bookId, readerVM: readerVM)) \(ref.chapter):\(ref.verse) (\(target))"
        return "\"\(text)\"\n\n— \(refString)"
    }

    // MARK: - Helpers

    /// "PSA|50|3" → "Псалми 50:3" (long name, same as VerseShareFormatter callers).
    private static func reference(for verseId: String, readerVM: ReaderViewModel) -> String {
        let p = verseId.split(separator: "|")
        guard p.count == 3 else { return verseId }
        return "\(longBookName(String(p[0]), readerVM: readerVM)) \(p[1]):\(p[2])"
    }

    private static func longBookName(_ bookId: String, readerVM: ReaderViewModel) -> String {
        readerVM.translationBookNames[bookId]?.long ?? BibleBookNames.full(for: bookId)
    }
}

/// Identifiable wrapper so a share string can drive `.sheet(item:)`.
struct EntryShareItem: Identifiable {
    let id = UUID()
    let text: String
}
