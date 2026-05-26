# SourceBible — docs index

One line per document. Read this file at the start of every session.
Load the full document only when the task is relevant to it.

---

## Architecture Decisions (`architecture/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `ADR-003-file-modularity.md` | File Modularity | Proposed | Split large Swift files into focused modules; FlowLayout/CapsuleNavGroupStyle extracted |
| `ADR-009-repository-layer.md` | Repository Layer | — | Data access abstraction layer architecture |
| `ADR-010-bottomsheet-file-split.md` | BottomSheet File Split | — | Modular split of bottom sheet components |
| `ADR-011-notes-bookmarks-persistence.md` | Notes & Bookmarks Persistence | — | Persistence strategy for user annotations |
| `ADR-012-unified-user-data-layer.md` | Unified User Data Layer | — | Unified architecture for user data storage |
| `ADR-013-ios-minimum-target.md` | iOS Minimum Target | Proposed | Minimum iOS version decision for SourceBible |
| `ADR-005-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes Architecture | Accepted (with amendments) | Cross-tab navigation via AppNavigationRouter; GRDB store; UserDataStoreProtocol |
| `ADR-006-localization-translation-provider.md` | Localization: TranslationProvider & Language Switch | Accepted | MorphologyDecoder emits MorphKey constants; BundleTranslationProvider for MVP; Bundle.main swizzled via object_setClass for instant switch; upgrade path → DB → Remote |
| `ADR-007-localization-completion.md` | Localization Completion: Book Names, Model Data, xcstrings Gaps | Proposed | BibleBookNames dual-lang static dict; DatabaseService injects locale names at load; Theologian static var; 25+ missing EN xcstrings keys identified |
| `ADR-008-search-architecture.md` | Search Architecture MVP | Accepted | FTS5 content table + SQL joins for Strong's/lemma/morph; predictive search via search_terms table; vector search deferred to V1.5 (ONNX + sqlite-vec) |

---

## Feature Specs (`features/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `spec-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes — Update | Draft | P0/P1/P2 requirements for unified annotation system |
| `spec-localization-i18n.md` | UI Localization & i18n | Draft | EN+UK MVP; MorphologyDecoder abstraction; Settings language picker; BDB translation deferred to P2 |
| `plan-localization-i18n.md` | Localization — Implementation Plan | Draft | 8-step implementation order; LocalizedBundle swizzle; MorphKey extraction; full string audit |
| `plan-highlights-bookmarks-notes.md` | Highlights, Bookmarks, Notes — Implementation Plan | Draft | Step-by-step implementation plan for annotation system |

---

## Product Decisions (`product decisions/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `PDR-Auth-Strategy.md` | Trust-First Authentication | Accepted | No login wall; local-first data; sync opt-in |
| `PDR-Highlights-Bookmarks-Notes.md` | Notes/Highlights/Bookmarks Differentiation | — | Distinct UX roles for three annotation types |

---

## Reference (`/`)

| File | Summary |
|---|---|
| `db_build.md` | Full SQLite build process, known errors, verse_map details |
| `unified_word_lookup_system_design.md` | System design for word lookup across Hebrew/Greek |
| `xlit_subentry_system_design.md` | Transliteration sub-entry handling (H871a, H1886d, etc.) |
| `verse_offset_system_design.md` | Verse offset/numbering system design |
| `verse_versification_system_design.md` | Cross-tradition versification mapping system design |

## Product Docs (`product/`)

| File | Summary |
|---|---|
| `01-context.md` | Project context and background |
| `02-metrics.md` | Success metrics and KPIs |
| `03-brd.md` | Business Requirements Document |
| `04-user-flows.md` | User flows (Markdown) |
| `05-architecture-diagram.md` | High-level architecture diagram |
| `07-potential-team.md` | Team structure and roles |
