// ThemedListBackground.swift
// SourceBible
//
// Single place that maps a ColorTheme onto a List/Form-based screen.
//
// Why this exists: a bare `List` paints itself with the system grouped colors
// (systemGroupedBackground + secondarySystemGroupedBackground rows). Those are
// correct for the Paper theme by coincidence — they are what the asset catalog
// was matched to — but they ignore Incunable entirely, so every screen that
// forgot to theme itself kept the cold grey system palette while the reader went
// warm (bug: Menu subpages in old colors, 2026-07-14).
//
// Use `.themedList(colorTheme)` on the List/Form, and `.themedRow(colorTheme)`
// on its rows. Screens that are not lists (plain content pushed onto the stack)
// use `.themedScreen(colorTheme)`.

import SwiftUI

extension View {

    /// List/Form container: hide the system scroll background, paint the theme's
    /// app background behind it.
    func themedList(_ theme: ColorTheme) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(theme.appBackground.ignoresSafeArea())
    }

    /// List/Form row surface.
    func themedRow(_ theme: ColorTheme) -> some View {
        listRowBackground(theme.cardBackground)
    }

    /// Non-list screen (plain pushed content): theme background edge to edge.
    func themedScreen(_ theme: ColorTheme) -> some View {
        background(theme.appBackground.ignoresSafeArea())
    }

    /// Sheet content: paints the SHEET surface (not the content view), so it also
    /// covers the strip behind the nav bar and the safe-area insets. Apply to the
    /// root of a .sheet's content — a plain .background() there leaves the system
    /// sheet surface visible around the edges.
    ///
    /// Apply inside the presented view itself, not at the call site, when a view is
    /// presented from more than one place (NoteEditorView is presented from both the
    /// Notes tab and the study sheet — a call-site fix only covers one).
    func themedSheet(_ theme: ColorTheme) -> some View {
        presentationBackground(theme.sheetBackground)
    }
}
