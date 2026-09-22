// BookmarkCardView.swift
// SourceBible
//
// Card component for the Bookmarks list.
// Design: squircle card (cornerRadius 32, .continuous), padding 16, gap 8.
// Structure: header (ref + bookmark.fill icon) → verse text with left accent bar.
//
// Verse text is loaded lazily from DatabaseService using the reader's ACTIVE
// translation, since BookmarkWithVerses stores only the verseId, not a text snapshot.
// bug-026: this used DatabaseService.defaultFallbackTranslation ("KJV"), so a bookmark
// added while reading RST rendered its preview in English — reported as "bookmark saved
// against EN instead of RST".
//
// bug-037 (fixed 2026-09-22): a plain identity lookup (same chapter/verse number in the
// new translation) is wrong whenever the two translations use different versification
// schemes — Ivan hit it live switching UBIO → KJV: Пс 3:6 showed KJV's DIFFERENT verse
// (off by one — KJV folds the Psalm superscription into verse 1, UBIO numbers it
// separately) and Пс 4:9 showed NOTHING (KJV's Psalm 4 has no verse 9 at all). Since
// v3 (BookmarkWithVerses.verseTranslations), a bookmark stores the translation it was
// created in, and loadVerseText() hops book/chapter/verse → verse_org original →
// target's own ref (same two curated hops as loadParallelVerseTexts, bug-036) whenever
// the active translation differs from it. The reference in the header RENUMBERS along
// with the hop (Ivan's decision) — the bookmark points at a verse of Scripture, and the
// number is just that verse's spelling in whichever translation is open right now.
// Legacy bookmarks saved before v3 have no stored translation and keep the old identity
// lookup untouched — Ivan's call: never guess which translation they were made in.

import SwiftUI

struct BookmarkCardView: View {
    let item: BookmarkWithVerses

    @EnvironmentObject private var readerVM: ReaderViewModel
    @Environment(\.colorTheme) private var colorTheme

    @State private var verseText: String?
    /// Verse reference actually shown/looked-up — may differ from the raw stored
    /// numbers when a translation hop (bug-037) renumbered it. nil until first load.
    @State private var resolvedRef: (bookId: String, chapter: Int, verse: Int)?

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
            RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous)
                .fill(colorTheme.cardBackground)
        )
        .onAppear {
            guard verseText == nil else { return }
            loadVerseText()
        }
        // Re-render the preview when the reader switches translation (bug-026).
        .onChange(of: readerVM.currentTranslation.id) { _, _ in
            loadVerseText()
        }
    }

    // MARK: - Derived values

    /// "John 3:16" — locale-aware short name. Renumbers once `resolvedRef` is loaded
    /// (bug-037: e.g. RST Пс 50:1 reads as "Пс 51:1" once KJV is the active translation).
    /// Before the first load (or for a verseId we can't parse), falls back to the raw
    /// stored numbers — same as before this fix.
    private var verseRef: String {
        guard let first = item.verseIds.first else {
            return NSLocalizedString("bookmarks.row.default_title", comment: "")
        }
        if let resolvedRef {
            return "\(readerVM.shortBookName(for: resolvedRef.bookId)) \(resolvedRef.chapter):\(resolvedRef.verse)"
        }
        let parts = first.split(separator: "|")
        guard parts.count == 3 else { return first }
        return "\(readerVM.shortBookName(for: String(parts[0]))) \(parts[1]):\(parts[2])"
    }

    /// Fetch verse text synchronously from DB using the reader's active translation.
    /// Consistent with how ReaderViewModel accesses DatabaseService from MainActor.
    ///
    /// bug-037: when this bookmark's own creation translation is known AND differs from
    /// the active one, hop through verse_org (same two curated hops as
    /// DatabaseService.loadParallelVerseTexts, bug-036) so the reference and text both
    /// track the same verse of Scripture instead of the same number. Legacy bookmarks
    /// (translation unknown) and same-translation reads keep the old identity lookup.
    private func loadVerseText() {
        guard let first = item.verseIds.first else { return }
        let parts = first.split(separator: "|")
        guard parts.count == 3,
              let chapter = Int(parts[1]),
              let verse   = Int(parts[2])
        else { return }
        let bookId = String(parts[0])
        let target = readerVM.currentTranslation.id

        if let source = item.verseTranslations[first], source != target,
           let hop = DatabaseService.shared.loadHoppedVerse(
               bookId: bookId, chapter: chapter, verse: verse,
               source: source, target: target) {
            resolvedRef = (hop.bookId, hop.chapter, hop.verse)
            verseText   = hop.text
            return
        }

        // Legacy (no stored translation), already on the creation translation, or the
        // hop came back empty (no verse_org row / no original counterpart / target has
        // no verse for it) — identity lookup, same as before this fix. An empty result
        // here is an honest gap, not a regression: it's the same case loadHoppedVerse
        // itself falls back from.
        resolvedRef = (bookId, chapter, verse)
        verseText = DatabaseService.shared.loadVerseText(
            bookId: bookId, chapter: chapter, verse: verse, translation: target
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
