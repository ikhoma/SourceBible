# SourceBible Docs Audit — 2026-05-26

Cross-checked all ADRs, specs, plans, PDRs, reference docs against the actual Swift codebase. Findings are grouped by severity.

---

## 🔴 Critical — Contradictions and Misleading State

### 1. ADR Internal Numbers Don't Match File Names

This is the most confusing problem in the whole docs folder. Every older ADR has a title that says a completely different number than its filename:

| File name | Internal title says | Actual subject |
|---|---|---|
| `ADR-009-repository-layer.md` | **ADR-001** | Repository layer |
| `ADR-010-bottomsheet-file-split.md` | **ADR-002** | BottomSheet split |
| `ADR-011-notes-bookmarks-persistence.md` | **ADR-003** | UserDefaults persistence (superseded) |
| `ADR-012-unified-user-data-layer.md` | **ADR-004** | GRDB unified store |
| `ADR-005-highlights-bookmarks-notes.md` | **ADR-001** | Highlights/Bookmarks/Notes architecture |
| `ADR-013-ios-minimum-target.md` | **ADR-001** | iOS minimum target |

Three separate docs call themselves "ADR-001". Cross-references between docs are broken as a result.

**Concrete damage:** `plan-localization-i18n.md` says "See ADR-001 for why explicit `bundle: .localized` was rejected" — but there are three ADR-001s. It means ADR-006 (localization). Anyone reading the plan has no idea.

**Fix:** Align the internal `# ADR-NNN:` heading in each file with its filename. The file numbers are authoritative (they're in the INDEX). The internal headings need to be corrected.

---

### 2. ADR-013 (iOS Minimum Target) — Wrong Tech Stack, Superseded by Reality

**Status in doc:** Proposed  
**Actual status:** Obsolete — wrong stack, recommendation ignored

The entire document analyses React Native 0.76 version floors and recommends iOS 15.1. The project is a **native SwiftUI app** targeting **iOS 26.4** (`IPHONEOS_DEPLOYMENT_TARGET = 26.4` in `project.pbxproj`). React Native is not in the project at all.

This ADR was clearly written before the technology decision was made and was never updated or removed. It actively misleads because:
- It recommends iOS 15.1; code targets iOS 26.4
- All the analysis (RN version floors, `UISheetPresentationController` availability) is irrelevant
- It still says "Status: Proposed" implying the question is open

**Fix:** Delete this file and add a one-liner in INDEX: "iOS target: 26.4 (SwiftUI native). No ADR needed — platform was always clear."

---

### 3. ADR-007 Checklist Incomplete — `Theologian` Still Uses `static let`

**Status in doc:** Proposed  
**Actual status:** Partially implemented

ADR-007 explicitly requires changing `Theologian` instances from `static let` to `static var` so they re-evaluate strings after a language switch. In `StrongsModels.swift` right now:

```swift
static let calvin = Theologian(...)   // ← should be static var per ADR-007
static let henry  = Theologian(...)
static let spurgeon = Theologian(...)
static let owen   = Theologian(...)
static let all: [Theologian] = [...]
```

This means in the actual app, switching language does **not** update theologian names/eras in the commentary list — they stay in the language that was active on first access. The doc is correct; the code hasn't caught up.

The rest of ADR-007 (BibleBookNames dual-lang, DatabaseService injection, xcstrings EN gaps) appears to be implemented based on code inspection.

**Fix:** Implement `static var` for Theologian instances, mark checklist items done, update ADR-007 status to Accepted.

---

### 4. ADR-009 (Repository Layer) — Quietly Abandoned, Still "Proposed"

**Status in doc:** Proposed  
**Actual status:** Superseded (partially by ADR-012, partially just abandoned)

ADR-009 proposes two repositories:
- `HighlightRepository` → was built, is now marked `⛔ FILE SCHEDULED FOR DELETION` in code, replaced by GRDB
- `BibleRepository` → **was never built**. `DatabaseService.swift` is used directly throughout. No `BibleRepository` protocol, no `MockBibleRepository`, no `SQLiteBibleRepository` exists anywhere in the codebase.

All 6 action items in ADR-009 are unchecked, but the project moved on without them. ADR-012 supersedes the highlight part. The "BibleRepository" concept was simply abandoned in favour of `DatabaseService` directly.

**Fix:** Update status to "Superseded — highlights portion superseded by ADR-012; BibleRepository concept abandoned in favour of direct DatabaseService use. See ADR-012 for the actual persistence architecture."

---

## 🟡 Stale — Docs That Don't Reflect Current Code

### 5. ADR-010 (BottomSheet File Split) — Done, Still Says "Proposed"

**Status in doc:** Proposed  
**Actual status:** ✅ Implemented

The file split described in ADR-010 is fully done:
- `Views/BottomSheet/VerseBottomSheetView.swift` ✅
- `Views/BottomSheet/VerseTabContent.swift` ✅
- `Views/BottomSheet/WordTabContent.swift` ✅
- `Views/Components/FlowLayout.swift` ✅
- `Views/Components/CapsuleNavStyle.swift` ✅

The ADR also says "Execute AFTER ADR-001 (Repository layer)" — that dependency is now irrelevant since the split is done without BibleRepository ever existing. All action items can be checked off and the status updated to Accepted.

---

### 6. ADR-003 (File Modularity) — Done, Still Says "Proposed"

**Status in doc:** Proposed  
**Actual status:** ✅ Implemented

The larger modularity plan described in ADR-003 is complete:
- `Models/StrongsModels.swift` ✅
- `Models/UserDataModels.swift` ✅
- `Views/Menu/MenuView.swift` ✅
- All BottomSheet components (see ADR-010 above) ✅

Status should be updated to Accepted. The "what we'll revisit" item (SPM packages if a widget/test target is added) remains relevant as a future note.

---

### 7. ADR-005 (Highlights/Bookmarks/Notes Architecture) — Amendments Implemented, Status Not Updated

**Status in doc:** Accepted with amendments  
**Actual status:** ✅ Amendments implemented

The amendments in ADR-005 were all implemented:
- `HighlightColor` enum exists in `Models/HighlightColor.swift` ✅
- `Task { @MainActor }` deferral in `ContentView.onChange` is in the code ✅
- `highlightColors: [String: String]` dict in `ReaderViewModel` ✅

The 8 action items at the bottom are all unchecked (the doc was never updated after implementation). The doc should get a "✅ Implemented" note on the action items so it's clear what's done vs. genuinely open.

One item to verify: "Remove or deprecate `allHighlightedVerseIds` when `highlightColors()` is added" — worth a code search to confirm it's gone.

---

### 8. `HighlightRepository.swift` — Dead File on Disk

The file exists at `Services/HighlightRepository.swift` and contains only a comment: `⛔ FILE SCHEDULED FOR DELETION`. Nothing in the codebase references it. It's also not in `project.pbxproj` (no call sites found).

This means it was removed from the Xcode project but the file was left on disk. It's harmless but creates confusion for anyone doing `find . -name "*.swift"`.

**Fix:** Delete the file.

---

### 9. ADR-011 (Notes/Bookmarks Persistence — UserDefaults) — Status Is Correct

**Status in doc:** Superseded by ADR-004  
**Assessment:** ✅ Correctly marked. No action needed. Can stay as a record of why UserDefaults was rejected.

---

### 10. `plan-localization-i18n.md` — Step 7 Uses `bundle: .localized` Syntax

Step 7 (SettingsView) in the implementation plan has:
```swift
String(localized: "settings.section.language", bundle: .localized)
```

But the plan itself (Step 6 paragraph) says this syntax is now **redundant noise** since Bundle.main is swizzled. The plan contradicts itself. This is a copy-paste artifact from before the swizzle approach was settled.

Also the plan references "ADR-001" in two places when it means ADR-006 (the file numbering problem from issue #1 above).

---

## 🔵 Organisation — Structure Problems

### 11. BRD Folder Not Linked in INDEX

`docs/BRD/` contains 6 product documents (context, metrics, BRD, user flows, architecture diagram, team). They are listed in `INDEX.md` under `Product Docs (product/)` — but the actual path is `BRD/`, not `product/`. The INDEX uses the wrong folder name.

```
# INDEX says:
## Product Docs (`product/`)

# Actual path:
docs/BRD/01-context.md
```

Anyone trying to open files by following INDEX will hit a dead path. **Fix:** Change `Product Docs (\`product/\`)` to `Product Docs (\`BRD/\`)` in INDEX.md, or move the folder to `product/` to match the INDEX.

---

### 12. ADR-006 and ADR-007 Should Be Linked More Explicitly

ADR-006 (localization infrastructure) and ADR-007 (localization completion) are tightly coupled but a reader can't easily tell the sequence. ADR-007's header says "Related: ADR-006" but ADR-006 doesn't reference ADR-007 at all (it was written before ADR-007 existed).

The INDEX summary for ADR-007 says "Proposed" but much of it is implemented. The connection between the two ADRs is only obvious from reading both fully.

**Fix:** Add a "Continued in ADR-007" note at the bottom of ADR-006's Consequences section.

---

### 13. INDEX Statuses Are Inconsistent

Several ADR statuses in INDEX don't match what's in the actual files, and ADR-009/010/011/012 have no status column entry at all (`—`):

| ADR in INDEX | INDEX status | Actual doc status | Code status |
|---|---|---|---|
| ADR-003 | Proposed | Proposed | ✅ Done |
| ADR-009 | — | Proposed | Superseded |
| ADR-010 | — | Proposed | ✅ Done |
| ADR-011 | — | Superseded by ADR-004 | Correctly superseded |
| ADR-012 | — | Amended | Active/current |
| ADR-013 | Proposed | Proposed | Obsolete (wrong stack) |

The `—` entries add no information. INDEX should show real statuses.

---

### 14. Missing from INDEX: `docs/BRD/user-flows.html`

`docs/BRD/` contains a `user-flows.html` file that isn't listed anywhere in INDEX. Not a big deal but it's orphaned.

---

## 🟢 Gaps — Important Things Not Documented

### 15. No ADR for iOS 26 / SwiftUI Native Decision

The project uses SwiftUI + iOS 26 SDK. The CLAUDE.md mentions Swift 6 strict concurrency and iOS 26 SDK specifics (Bundle `@MainActor`, etc.). There's no ADR capturing:
- Why SwiftUI over React Native (the BRD still says React Native)
- Why iOS 26 as the target (not 15, 16, 17, or 18)
- The Swift 6 strict concurrency commitment

Anyone reading the docs folder sees a React Native BRD and a React Native iOS target ADR but a SwiftUI codebase. This is a significant context gap for any future contributor.

**Fix:** Create `ADR-001-platform-stack.md` (the first ADR that doesn't already have something using that name) documenting the SwiftUI + iOS 26 decision and superseding ADR-013.

---

### 16. No ADR for DatabaseService Architecture

`DatabaseService.swift` is one of the most critical files in the project — it's the direct SQLite access layer for the entire Bible database. Yet there's no ADR documenting:
- Why no ORM (the BRD mentions SQLite but no explicit no-ORM decision)  
- The read-only bundle + GRDB (writable user data) split
- Thread safety approach (why queries run where they run)
- The immutable=1 WAL setup

ADR-009 was supposed to cover data access but proposed a layer that was never built. The current actual approach (direct `DatabaseService`) is undocumented architecturally.

---

### 17. `docs/BRD/` Content Is Pre-SwiftUI and Partially Outdated

The BRD (03-brd.md) specifies React Native + Expo. The architecture diagram (05-architecture-diagram.md) likely shows a React Native architecture. These are product docs that haven't been updated to reflect the actual stack. They may still be useful for product/feature context but are misleading about tech.

---

## Summary Table

| # | File(s) | Issue | Action |
|---|---|---|---|
| 1 | All ADR-009 through ADR-013 | Internal ADR number ≠ filename | Fix internal headings to match filenames |
| 2 | `ADR-013-ios-minimum-target.md` | Wrong stack (React Native), iOS 15 rec vs iOS 26 actual | **Delete** |
| 3 | `ADR-007-localization-completion.md` | `Theologian` `static let` not yet `static var` | Fix code + mark done |
| 4 | `ADR-009-repository-layer.md` | BibleRepository never built; HighlightRepo superseded | Update status to Superseded |
| 5 | `ADR-010-bottomsheet-file-split.md` | Split is done | Update status to Accepted |
| 6 | `ADR-003-file-modularity.md` | Split is done | Update status to Accepted |
| 7 | `ADR-005-highlights-bookmarks-notes.md` | Amendments all implemented | Tick off action items |
| 8 | `Services/HighlightRepository.swift` | Dead file on disk | Delete the file |
| 9 | `plan-localization-i18n.md` | Step 7 uses deprecated `bundle: .localized` syntax; "ADR-001" references wrong doc | Fix references |
| 10 | `INDEX.md` | `product/` path should be `BRD/` | Fix folder path |
| 11 | `INDEX.md` | ADR-009/010/011/012/013 have `—` status; wrong statuses throughout | Update all status cells |
| 12 | `ADR-006-localization-translation-provider.md` | No forward link to ADR-007 | Add "Continued in ADR-007" note |
| 13 | Gap | No ADR for SwiftUI + iOS 26 decision | Create `ADR-001-platform-stack.md` |
| 14 | Gap | No ADR for DatabaseService direct-access architecture | Create `ADR-002-database-service.md` |
| 15 | `docs/BRD/` | BRD still says React Native | Note in BRD that stack changed to SwiftUI |

---

## Suggested Cleanup Order

**Quick wins (< 30 min total):**
1. Delete `ADR-013-ios-minimum-target.md` and its INDEX row
2. Delete `Services/HighlightRepository.swift` (disk only)
3. Fix `INDEX.md`: change `product/` → `BRD/`, fill in missing statuses
4. Update statuses in ADR-003, ADR-010 to Accepted
5. Update ADR-009 to Superseded

**One session (1–2 hours):**
6. Fix all internal ADR heading numbers to match filenames
7. Fix `plan-localization-i18n.md` Step 7 syntax + ADR references
8. Implement `static var` for Theologian + mark ADR-007 items done
9. Add "Continued in ADR-007" to ADR-006

**Bigger but important:**
10. Create `ADR-001-platform-stack.md` capturing SwiftUI + iOS 26 rationale
11. Update BRD to note React Native → SwiftUI migration
