# ADR-005: Architecture Review — Highlights, Bookmarks, Notes Update

**Status:** Accepted with amendments  
**Date:** 2026-05-22  
**Deciders:** Ivan  
**Reviews:** Implementation plan `implementation-plan-highlights-bookmarks-notes.md`

---

## Context

The implementation plan covers three concurrent feature updates to a SwiftUI iOS app. This ADR evaluates the four key architectural decisions in the plan, flags risks, and records the accepted approach for each.

---

## Decision 1: Cross-Tab Navigation via `AppNavigationRouter`

### The Proposal

A new `@StateObject` owned by `ContentView` holds a `pendingVerseId: String?`. Any view sets it; `ContentView.onChange` switches the tab and calls `readerVM.navigateToVerse(id:)`.

### Options Considered

| Dimension | `AppNavigationRouter` (proposed) | `NotificationCenter` | Direct ViewModel reference |
|-----------|----------------------------------|----------------------|---------------------------|
| Coupling | None between features | None, but untyped | Strong — breaks layering |
| Testability | High — injectable `@EnvironmentObject` | Low — global bus | Low |
| Discoverability | High — explicit SwiftUI graph | Low — invisible at call site | Medium |
| Thread safety | `@MainActor` enforced by SwiftUI | Requires manual dispatch | Depends on ViewModel |
| Extensibility | Add any `pending*` property as needed | Add any notification key | Requires new injection |

### Trade-off Analysis

`AppNavigationRouter` is the correct choice for this app's scale. It leverages SwiftUI's own environment propagation rather than fighting it. The only real downside is that every sheet presenting `NoteEditorView` must explicitly pass `.environmentObject(router)` — easy to forget and fails silently (the tap does nothing; no crash). This is mitigated by adding a `#if DEBUG` assertion in `AppNavigationRouter` that fires if `pendingVerseId` is set from outside the environment.

**Amendment:** The plan says `ContentView.onChange` should call `readerVM.navigateToVerse` directly. This is correct, but the navigation must happen *after* the tab animation completes, otherwise the Reader view may not yet be in the hierarchy when `scrollTo` fires. Add a one-frame delay:

```swift
.onChange(of: router.pendingVerseId) { verseId in
    guard let verseId else { return }
    selectedTab = .bible
    // Reader's onAppear may not have fired yet — defer by one runloop
    Task { @MainActor in
        readerVM.navigateToVerse(id: verseId)
        router.pendingVerseId = nil
    }
}
```

Using `Task { @MainActor in }` schedules after the current runloop pass without a hardcoded delay.

### Decision

✅ **Accept `AppNavigationRouter` as proposed, with the `Task { @MainActor }` deferral amendment.**

---

## Decision 2: `highlightColors: [String: String]` replacing `Set<String>`

### The Proposal

`ReaderViewModel` changes its highlight state from `Set<String>` (verseIds) to `[String: String]` (verseId → colorToken). `VerseTextView` changes `isHighlighted: Bool` to `highlightColor: String?`.

### Options Considered

| Dimension | `[String: String]` dict | `[String: Highlight]` struct dict | Keep `Set<String>` + separate color lookup |
|-----------|------------------------|-----------------------------------|--------------------------------------------|
| Simplicity | High | Medium | Low — two data structures to keep in sync |
| Type safety | Low (stringly typed color) | High | N/A |
| Memory | O(highlights) | O(highlights) | O(highlights) × 2 |
| View update granularity | Full dict publish | Full dict publish | Two publishes |

### Trade-off Analysis

The `[String: String]` approach is pragmatic for the current scale (hundreds of highlights at most). The stringly-typed color token is a real weakness — a typo in `"yelo"` silently renders as the default color. 

**Amendment:** Define the color palette as an enum or static constants, not raw strings passed around:

```swift
// HighlightColor.swift (new small file)
enum HighlightColor: String, CaseIterable {
    case yellow, green, blue, pink
    
    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor.systemYellow.withAlphaComponent(0.35)
        case .green:  return UIColor.systemGreen.withAlphaComponent(0.30)
        case .blue:   return UIColor.systemBlue.withAlphaComponent(0.25)
        case .pink:   return UIColor.systemPink.withAlphaComponent(0.25)
        }
    }
    
    static let defaultColor = HighlightColor.yellow
}
```

The DB stores `rawValue` (String), so no schema change. `VerseTextView` accepts `HighlightColor?` instead of `String?`. `GRDBUserDataStore` decodes with `HighlightColor(rawValue:) ?? .defaultColor`. This makes the typo problem a compile-time issue.

The dict key is still `String` (verseId) — that's fine, verseIds are well-defined.

### Decision

✅ **Accept `[String: String]` dict approach. Amendment: introduce `HighlightColor` enum — do not pass raw color strings beyond the store layer.**

---

## Decision 3: Bookmark Save UX — Immediate vs. Editor Sheet

### The Proposal

After removing categories, `BookmarkEditorView` becomes near-empty. The plan says: evaluate whether to keep the sheet or save immediately. It recommends immediate save.

### Options Considered

| Dimension | Immediate save (no sheet) | Minimal confirmation sheet | Keep full editor |
|-----------|--------------------------|---------------------------|-----------------|
| Speed of action | Fast — one tap | Medium — two taps | Slow |
| Discoverability of undo | Low — need swipe-to-delete in list | Medium — Cancel button | High |
| Consistency with iOS patterns | High (like iOS Reminders quick-add) | Medium | Low |
| Scope of future additions | Hard to add fields later without a sheet | Easy — sheet already exists | Easy |

### Trade-off Analysis

Immediate save is the right call for a pure navigation tool. The bookmark was just created — the user knows what they did. Undo is via swipe-to-delete in the list, which is a standard iOS affordance.

However, completely deleting `BookmarkEditorView.swift` now creates future friction if the product ever adds a bookmark label or note (which the spec explicitly non-goals but doesn't rule out forever). The safer move: **keep the file but make it a confirmation-only sheet** (shows verse ref, "Зберегти" / "Скасувати", no form fields). This costs one extra tap today but avoids rebuilding a sheet infrastructure later.

Given the Implementation Guide's strong "bookmarks are lightweight" stance and the explicit non-goal on labels, immediate save is defensible. The decision comes down to product confidence.

**Amendment:** If going immediate save, the bottom sheet highlight button row should give a transient visual confirmation (e.g., a brief `.overlay` checkmark or `UIImpactFeedbackGenerator`) so the user knows the action fired. Without this, silent saves feel broken.

### Decision

⚠️ **Design call — both options are architecturally valid. Engineering preference: immediate save with haptic/visual confirmation. Keep `BookmarkEditorView.swift` as a commented-out/archived stub if there's uncertainty.**

---

## Decision 4: `bookmark_categories` Schema Drop

### The Proposal (updated per user instruction)

Add GRDB migration `v2_drop_bookmark_categories` that drops the table and removes `category_id` from `bookmarks`. Safe because no users exist yet.

### Options Considered

| Dimension | Drop table + column (proposed) | Leave as dead schema |
|-----------|-------------------------------|---------------------|
| Schema cleanliness | ✅ Clean | ❌ Dead table forever |
| Risk | Minimal (no users) | None |
| Future confusion | None — table gone | High — future devs wonder why it exists |
| Reversibility | Not without a new migration | Trivially reversible |

### Trade-off Analysis

With no users, dropping is the correct call. Dead schema in SQLite accumulates over time and becomes a maintenance hazard — future migrations must avoid name collisions, future devs must understand why the table exists but is never written to.

**`ALTER TABLE bookmarks DROP COLUMN category_id`** requires SQLite 3.35+ (iOS 15.4+). If the deployment target is iOS 15.0, use a table-rebuild migration. If iOS 16+, `DROP COLUMN` is safe.

**Verify deployment target before writing the migration.** If `IPHONEOS_DEPLOYMENT_TARGET` in the Xcode project settings is 15.0 or 15.1–15.3, use the table-rebuild path. If 15.4+, `DROP COLUMN` is one line.

GRDB's `DatabaseMigrator` wraps each migration in a transaction — a failed migration rolls back and the app surfaces the error on next launch, which is acceptable for a pre-user release.

### Decision

✅ **Accept full schema drop. Verify iOS deployment target to determine `DROP COLUMN` vs. table-rebuild path before writing the migration.**

---

## Overall Plan Assessment

### What the Plan Gets Right

- **Phase sequencing is correct.** `AppNavigationRouter` as step 1 is exactly right — it's the shared infrastructure that every subsequent navigation step depends on. Doing it last would mean rewriting Bookmarks and Notes navigation twice.
- **Cleanup before features.** Phase 1 removes dead code before adding new code. This prevents the new code from inheriting legacy patterns.
- **Multi-verse guard as an explicit checklist item.** Architectural constraints that aren't user-visible often get skipped in code review. Making it a named checklist item with specific acceptance criteria is the right approach.
- **`HighlightColor` rendering via `NSBackgroundColorAttributeName`.** The plan correctly identifies that verse highlight background and word-selection foreground must use different attribute keys. This avoids a hard-to-debug rendering conflict.

### What Needs Attention

1. **`router` injection at sheet call sites** — `NoteEditorView` is presented as `.sheet` from three places: `NotesListView`, `VerseBottomSheetView`, and potentially `EntriesView`. Each `.sheet` must explicitly pass `.environmentObject(router)`. Missed injection = silent failure (tap does nothing). Consider adding a `#if DEBUG` assert in `NoteEditorView.onAppear` that checks `router` is non-nil.

2. **`ReaderViewModel.navigateToVerse(id:)` must handle invalid IDs.** The verseId format `"ROM|5|1"` is internal. If a note was created with a malformed ID (bug in an earlier version), parsing will fail. Add a guard with a silent return — do not crash.

3. **`allHighlightedVerseIds` call site in ReaderViewModel** — the existing method is still in `GRDBUserDataStore` and may still be called somewhere. When migrating to `highlightColors(translation:)`, ensure the old method is either removed or marked deprecated to avoid two sources of truth for highlight state.

4. **`VerseTextView` is a `UIViewRepresentable`** — updating attributed string colors in `updateUIView` must check whether `highlightColor` actually changed before re-applying attributes, otherwise every parent re-render causes a full attributed string rebuild. Add a guard:

   ```swift
   func updateUIView(_ uiView: UITextView, context: Context) {
       guard context.coordinator.lastHighlightColor != highlightColor else { return }
       // rebuild attributed string
       context.coordinator.lastHighlightColor = highlightColor
   }
   ```

5. **Phase ordering in the file change summary** — `GRDBUserDataStore.swift` appears under "CHANGED" once, but it receives changes in Phase 1 (remove category methods), Phase 1 (drop migration), and Phase 2 (`highlightColors()` method). Ensure these are done as a single coherent PR or clearly separated commits to avoid mid-state builds.

---

## Action Items

- [x] Add `HighlightColor` enum — do not pass raw color strings beyond store layer (`Models/HighlightColor.swift` ✅)
- [x] Add `Task { @MainActor }` deferral in `ContentView.onChange` for navigation (implemented ✅)
- [ ] Add `#if DEBUG` assert in `NoteEditorView` to catch missing `router` injection
- [ ] Add guard in `navigateToVerse(id:)` for malformed verseIds
- [ ] Add `updateUIView` change-guard in `VerseTextView` coordinator
- [x] Check `IPHONEOS_DEPLOYMENT_TARGET` before writing `v2_drop_bookmark_categories` — iOS 26.4, `DROP COLUMN` is safe ✅
- [ ] Remove or deprecate `allHighlightedVerseIds` when `highlightColors()` is added
- [ ] Decide: immediate-save bookmark with haptic feedback, or minimal confirmation sheet
