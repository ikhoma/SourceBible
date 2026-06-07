// NoteCardView.swift
// SourceBible
//
// Card component for the Notes list.
// Design: squircle card (cornerRadius 32, .continuous), padding 16, gap 16.
// Structure: header (ref + date) → verse text snapshot → note text bubble.

import SwiftUI

struct NoteCardView: View {
    let item: NoteWithBlocks

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header: verse reference + date ──────────────────────────
            HStack(alignment: .firstTextBaseline) {
                Text(verseRef)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(dateLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }

            // ── Verse text snapshot with left accent bar ─────────────────
            if let text = verseText {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(.separator))
                        .frame(width: 4)
                        .padding(.vertical, 2)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }

            // ── Note text bubble ─────────────────────────────────────────
            if let note = noteBody {
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemFill))
                    )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Derived values

    /// "John 3:16 (KJV)" — locale-aware short name from the first verse block.
    private var verseRef: String {
        guard
            let block = item.blocks.first(where: { $0.type == .verse }),
            let c = try? JSONDecoder().decode(
                VerseBlockContent.self, from: Data(block.content.utf8))
        else { return String(localized: "notes.row.default_title") }

        let parts = c.verseId.split(separator: "|")
        guard parts.count == 3 else { return c.verseId }

        let ref = "\(BibleBookNames.short(for: String(parts[0]))) \(parts[1]):\(parts[2])"
        return c.translationId.isEmpty ? ref : "\(ref) (\(c.translationId))"
    }

    /// Verse text snapshot stored in the VerseBlock at note-creation time.
    private var verseText: String? {
        guard
            let block = item.blocks.first(where: { $0.type == .verse }),
            let c = try? JSONDecoder().decode(
                VerseBlockContent.self, from: Data(block.content.utf8)),
            !c.text.isEmpty
        else { return nil }
        return c.text
    }

    /// User-written note body, nil when empty.
    private var noteBody: String? {
        item.blocks
            .first(where: { $0.type == .text })
            .flatMap { try? JSONDecoder().decode(
                TextBlockContent.self, from: Data($0.content.utf8)) }
            .map(\.body)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "May 23, 2026" — locale-aware abbreviated date.
    private var dateLabel: String {
        item.note.updatedAt.formatted(
            .dateTime.month(.abbreviated).day().year()
        )
    }
}

// MARK: - Preview

#Preview {
    let store = InMemoryUserDataStore()
    let auth  = LocalAuthService.shared

    // Seed a sample note so the preview shows real card structure
    let noteId   = UUID().uuidString
    let now      = Date()
    let note     = Note(id: noteId, userId: "preview", folderId: nil,
                        createdAt: now, updatedAt: now, deletedAt: nil, isDirty: false)

    let verseContent = VerseBlockContent(
        verseId: "JHN|3|16",
        translationId: "KJV",
        text: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.")
    let verseJSON = (try? JSONEncoder().encode(verseContent))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let verseBlock = NoteBlock(id: UUID().uuidString, noteId: noteId, position: 0,
                               type: .verse, verseId: "JHN|3|16", strongsId: nil,
                               content: verseJSON, createdAt: now, updatedAt: now)

    let textContent = TextBlockContent(body: "God's love for mankind showed in Christ.")
    let textJSON = (try? JSONEncoder().encode(textContent))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let textBlock = NoteBlock(id: UUID().uuidString, noteId: noteId, position: 1,
                              type: .text, verseId: nil, strongsId: nil,
                              content: textJSON, createdAt: now, updatedAt: now)

    let item = NoteWithBlocks(note: note, blocks: [verseBlock, textBlock], verseIds: ["JHN|3|16"])

    ScrollView {
        NoteCardView(item: item)
            .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .environmentObject(NotesViewModel(store: store, authService: auth))
}
