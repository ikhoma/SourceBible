# SourceBible — docs index

One line per document. Read this file at the start of every session.
Load the full document only when the task is relevant to it.

---

## Architecture Decisions (`architecture/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `ADR-001-platform-stack.md` | Platform Stack | Accepted (amended 2026-05-26) | SwiftUI native; iOS 18 minimum target (iOS 26 features behind #available); Swift 6 strict concurrency; compatibility sprint deferred |
| `ADR-003-file-modularity.md` | File Modularity | Accepted | Split large Swift files into focused modules; FlowLayout/CapsuleNavGroupStyle extracted |
| `ADR-005-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes Architecture | Accepted (with amendments) | Cross-tab navigation via AppNavigationRouter; GRDB store; UserDataStoreProtocol |
| `ADR-006-localization-translation-provider.md` | Localization: TranslationProvider & Language Switch | Accepted | MorphologyDecoder emits MorphKey constants; BundleTranslationProvider for MVP; Bundle.main swizzled via object_setClass for instant switch; upgrade path → DB → Remote |
| `ADR-007-localization-completion.md` | Localization Completion: Book Names, Model Data, xcstrings Gaps | Implemented (QA pending) | BibleBookNames dual-lang done; Theologian static var fixed 2026-05-26; QA pass still open |
| `ADR-008-search-architecture.md` | Search Architecture MVP | Accepted | FTS5 content table + SQL joins for Strong's/lemma/morph; predictive search via search_terms table; vector search deferred to V1.5 (ONNX + sqlite-vec) |
| `ADR-009-repository-layer.md` | Repository Layer | Superseded | BibleRepository never built; HighlightRepository superseded by ADR-012; DatabaseService used directly |
| `ADR-010-bottomsheet-file-split.md` | BottomSheet File Split | Accepted | Modular split of bottom sheet components — implemented |
| `ADR-011-notes-bookmarks-persistence.md` | Notes & Bookmarks Persistence | Superseded by ADR-012 | UserDefaults approach rejected; kept as historical record |
| `ADR-012-unified-user-data-layer.md` | Unified User Data Layer | Accepted (amended ×4) | GRDB writable DB; sync-ready schema; block-based notes; PreAuthIdentity pattern |
| `ADR-013-word-usage-book-groups.md` | Word Usage Tab — Per-Book Concordance Data Model | Accepted | Replace flat concordance list with BookUsageGroup per-book breakdown; N per-book queries on MainActor; chapter*1000+verse encoding; forward-compat with v1.5 rhetorical_weight |
| `ADR-014-verse-text-view-cache-invalidation.md` | VerseTextView Cache Invalidation via `.id()` | Accepted | Use SwiftUI `.id()` keyed on `verseId+translationId+highlightColor` to force UITextView recreation on content changes; preserves coordinator cache for selection fast path |
| `ADR-015-trailing-chars.md` | Trailing Characters from Macula `after` Attribute | Proposed | Store `after_char TEXT` in word table from XML; `BibleWord.displayText` for rendering; migration script for existing DBs; fixes maqaf ־ missing from Original tab |
| `ADR-016-original-pill-nasb-bridge.md` | Original Pill — NASB-Gated Clickability, Unified Word Page, Verse Highlight | Proposed |
| `ADR-017-book-covers.md` | Book Covers — Architecture | Accepted | BookCoverView + BookCoverData; hideBookCovers toggle; static asset strategy; all 66 books | Morph-based particle detection (R/C/T); `baseStrongsNumber` helper fixes sub-entry ID mismatch; unified tapWord flows; chevron nav over meaningful words only |

---

## Feature Specs (`features/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `spec-book-covers.md` | Book Covers — System Design | Draft | BookCoverView + BookCoverData; all 66 books; toggle in Settings; Doré image asset strategy |
| `spec-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes — Update | Draft | P0/P1/P2 requirements for unified annotation system |
| `spec-localization-i18n.md` | UI Localization & i18n | Draft | EN+UK MVP; MorphologyDecoder abstraction; Settings language picker; BDB translation deferred to P2 |
| `plan-localization-i18n.md` | Localization — Implementation Plan | Draft | 8-step implementation order; LocalizedBundle swizzle; MorphKey extraction; full string audit |
| `plan-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes — Implementation Plan | Draft | Step-by-step implementation plan for annotation system |
| `verse_versification_system_design.md` | VersificationService — Design & Spec | Draft | Extract versification logic from ViewModel into VersificationService; consumers: loadWordsForSelectedVerse (done), concordance display (bug), cross-refs |
| `unified_word_lookup_system_design.md` | Unified Word Lookup — Design & Spec | Draft | Unify Оригінал tap + translation long-press into single flow; BibleWord bridge in tapWord (TODO); isParticleSegment non-clickable particles (TODO) |
| `spec-original-nasb-bridge.md` | Original Pill ↔ NASB Bridge | Draft | Supersedes unified_word_lookup; morph-based particle detection; unified word page; chevron nav over non-particle words; verse text highlight from both entry points |
| `spec-word-usage-redesign.md` | Word Usage Tab — Redesign | Draft | Show total count + per-book breakdown (book name · count · one example verse); replaces capped 30-item flat list |
| `spec-trailing-chars.md` | Trailing Characters (maqaf etc.) | Draft | Add `after_char` DB column from Macula XML `after` attr; surface in WordRow; migration script + full rebuild path |
| `spec-verse-sharing.md` | Verse Sharing | Draft | iOS native ShareLink; VerseShareFormatter static func; plain text format with reference + translation id; P0 bottom sheet, P1 context menu |
| `commentary-system-design.md` | Commentary System — Bug Diagnoses & Architecture | Draft | Henry verse→section mapping bug (Genesis 2:7); Owen Hebrews 1 blank screen; range header display; validation checklist |
| `plan-word-usage-redesign.md` | Word Usage Tab — Implementation Plan | Draft | 7-step order: model → DB method → ViewModel → MorphKey → strings → View; N per-book queries, chapter*1000+verse encoding, stays on MainActor |
| `proposal_smarter_examples_v1.5.md` | Smarter Example Selection — v1.5 Proposal | Proposal | Pre-compute `rhetorical_weight` in DB (cross_reference votes); Swift picks highest-weight verse per book instead of first occurrence; fallback chain: rhetorical → syntactic centrality → first |

---

## Product Decisions (`product decisions/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `PDR-Auth-Strategy.md` | Trust-First Authentication | Accepted | No login wall; local-first data; sync opt-in |
| `PDR-Highlights-Bookmarks-Notes.md` | Notes/Highlights/Bookmarks Differentiation | — | Distinct UX roles for three annotation types |
| `PDR-Book-Covers.md` | Book Cover Design — Doré Engravings | Accepted | Doré engraving + blue bg; Protestant canonical section tag + chapter count per cover; section vocab mirrors browse flow |

---

## Reference (`/`)

| File | Summary |
|---|---|
| `db_build.md` | Full SQLite build process, known errors, verse_map details |
| `xlit_subentry_system_design.md` | Transliteration sub-entry handling (H871a, H1886d, etc.) — implemented |
| `verse_offset_system_design.md` | Verse offset/numbering system design — implemented (findBestMaculaVerse, Strong's overlap) |

## Product Docs (`BRD/`)

> ⚠️ **These docs reflect the pre-SwiftUI React Native prototype. Rewrite before release to reflect the current SwiftUI + iOS 26 stack.**

| File | Summary |
|---|---|
| `01-context.md` | Project context and background |
| `02-metrics.md` | Success metrics and KPIs |
| `03-brd.md` | Business Requirements Document (outdated — describes React Native + Expo) |
| `04-user-flows.md` | User flows (Markdown) |
| `05-architecture-diagram.md` | High-level architecture diagram (outdated) |
| `07-potential-team.md` | Team structure and roles |
