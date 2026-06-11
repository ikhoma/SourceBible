// BookmarkCardView.swift
// SourceBible
//
// Card component for the Bookmarks list.
// Design: squircle card (cornerRadius 32, .continuous), padding 16, gap 8.
// Structure: header (ref + bookmark.fill icon) → verse text with left accent bar.
//
// Verse text is loaded lazily from DatabaseService using the default translation,
// since BookmarkWithVerses stores only the verseId, not a text snapshot.

import SwiftUI

struct BookmarkCardView: View {
    let item: BookmarkWithVerses

    @State private var verseText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header: verse reference + bookmark icon ──────────────────
            HStack(alignment: .center) {
                ReferenceLabel(verseRef)
                Spacer(minLength: 12)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }

            // ── Verse text with left accent bar ──────────────────────────
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
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color("cardBackground"))
        )
        .onAppear {
            guard verseText == nil else { return }
            loadVerseText()
        }
    }

    // MARK: - Derived values

    /// "John 3:16" — locale-aware short name, no translation suffix
    /// (translation is not stored on Bookmark).
    private var verseRef: String {
        guard let first = item.verseIds.first else {
            return String(localized: "bookmarks.row.default_title")
        }
        let parts = first.split(separator: "|")
        guard parts.count == 3 else { return first }
        return "\(BibleBookNames.short(for: String(parts[0]))) \(parts[1]):\(parts[2])"
    }

    /// Fetch verse text synchronously from DB using the app's default translation.
    /// Consistent with how ReaderViewModel accesses DatabaseService from MainActor.
    private func loadVerseText() {
        guard let first = item.verseIds.first else { return }
        let parts = first.split(separator: "|")
        guard parts.count == 3,
              let chapter = Int(parts[1]),
              let verse   = Int(parts[2])
        else { return }

        verseText = DatabaseService.shared.loadVerseText(
            bookId:      String(parts[0]),
            chapter:     chapter,
            verse:       verse,
            translation: DatabaseService.defaultFallbackTranslation
        )
    }
}

// MARK: - Preview

#Preview {
    let item = BookmarkWithVerses(
        bookmark: Bookmark(
            id: UUID().uuidString, userId: "preview",
            createdAt: Date(), updatedAt: Date(),
            deletedAt: nil, isDirty: false),
        verseIds: ["JHN|3|16"])

    ScrollView {
        BookmarkCardView(item: item)
            .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
