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
//         known and differs (bug-037). Both go through BookmarkVerseResolver, so the
//         card and the share text cannot drift apart.

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

    /// The bookmarked verse in the active translation. When that translation has no
    /// verse for it (merge gap, bug-037), shares it in the translation it was SAVED
    /// under — the label names which — rather than the neighbouring verse that carries
    /// the same number. nil only when the text can't be found at all.
    static func format(bookmark item: BookmarkWithVerses, readerVM: ReaderViewModel) -> String? {
        guard let first = item.verseIds.first else { return nil }
        let target = readerVM.currentTranslation.id
        let source = item.verseTranslations[first]

        let ref: BookmarkVerseResolver.Ref
        let translation: String
        switch BookmarkVerseResolver.resolve(verseId: first, savedIn: source,
                                             activeTranslation: target) {
        case .verse(let r):
            ref = r
            translation = target
        case .noCounterpart:
            guard let source, let stored = BookmarkVerseResolver.Ref(verseId: first) else { return nil }
            ref = stored
            translation = source
        case nil:
            return nil
        }

        guard let text = DatabaseService.shared.loadVerseText(
                  bookId: ref.bookId, chapter: ref.chapter, verse: ref.verse,
                  translation: translation),
              !text.isEmpty else { return nil }
        let refString = "\(longBookName(ref.bookId, readerVM: readerVM)) \(ref.chapter):\(ref.verse) (\(translation))"
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
