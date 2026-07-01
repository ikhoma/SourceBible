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
| `ADR-008-search-architecture.md` | Search Architecture MVP | Accepted (amended 2026-06-11) | FTS5 content table + SQL joins for Strong's/lemma/morph; predictive search via search_terms table; vector search deferred to V1.5 (ONNX + sqlite-vec). Amend 2026-06-11: suggestions rendered inline (Apple Music pattern), `.searchSuggestions` dropped |
| `ADR-009-repository-layer.md` | Repository Layer | Superseded | BibleRepository never built; HighlightRepository superseded by ADR-012; DatabaseService used directly |
| `ADR-010-bottomsheet-file-split.md` | BottomSheet File Split | Accepted | Modular split of bottom sheet components — implemented |
| `ADR-011-notes-bookmarks-persistence.md` | Notes & Bookmarks Persistence | Superseded by ADR-012 | UserDefaults approach rejected; kept as historical record |
| `ADR-012-unified-user-data-layer.md` | Unified User Data Layer | Accepted (amended ×4) | GRDB writable DB; sync-ready schema; block-based notes; PreAuthIdentity pattern |
| `ADR-013-word-usage-book-groups.md` | Word Usage Tab — Per-Book Concordance Data Model | Accepted | Replace flat concordance list with BookUsageGroup per-book breakdown; N per-book queries on MainActor; chapter*1000+verse encoding; forward-compat with v1.5 rhetorical_weight |
| `ADR-014-verse-text-view-cache-invalidation.md` | VerseTextView Cache Invalidation via `.id()` | Accepted | Use SwiftUI `.id()` keyed on `verseId+translationId+highlightColor` to force UITextView recreation on content changes; preserves coordinator cache for selection fast path |
| `ADR-015-trailing-chars.md` | Trailing Characters from Macula `after` Attribute | Proposed | Store `after_char TEXT` in word table from XML; `BibleWord.displayText` for rendering; migration script for existing DBs; fixes maqaf ־ missing from Original tab |
| `ADR-016-original-pill-nasb-bridge.md` | Original Pill — NASB-Gated Clickability, Unified Word Page, Verse Highlight | Accepted (amended 2026-06-22) | Amend 2026-06-22: clickability gate switched NASB→per-displayed-translation via one canonical word↔segment mapping (translation order, occurrence-indexed); fixes nav-order + repeated-word jump; NASB-set/morph gate retired (measurement: no coverage advantage); Phase 2 = unify tagging across all modules (verse_markup) |
| `ADR-017-book-covers.md` | Book Covers — Architecture | Accepted | `BookCoverView` + `BookCoverData`; Doré engraving on all 66 books; blue gradient bg; `hideBookCovers` Settings toggle; minimal changes to ReaderView |
| `ADR-018-translation-native-book-names.md` | Translation-Native Book Names and Order | Accepted | `book_name` table (book_id, translation_id, long_name, short_name, sort_order); extracted from MyBible `books` table in build_db.py; BibleBookNames becomes UI-only fallback; enables per-translation ordering | BookCoverView + BookCoverData; hideBookCovers toggle; static asset strategy; all 66 books | Morph-based particle detection (R/C/T); `baseStrongsNumber` helper fixes sub-entry ID mismatch; unified tapWord flows; chevron nav over meaningful words only |
| `ADR-019-strongs-original-lemma-source.md` | Source of `strongs.original` — TBESH vs Macula `word.lemma` | Accepted | Keep TBESH as primary headword source; improve Macula fallback in `_enrich_strongs_stubs` to use frequency-ranked `GROUP BY lemma ORDER BY COUNT(*) DESC` instead of `LIMIT 1`; 11% of sub-entries have multiple lemma values in Macula (H871a: 3 variants, H3807a: 6 variants) |
| `ADR-020-hebrew-translit-build-validation.md` | Hebrew Transliteration Build-Time Validation | Proposed | Two-level validation in `_apply_bh_hebrew_translit()`: per-verse count parity + per-slot Strong's alignment; writes `data/hebrew_translit_mismatches.tsv`; fixes 3 gaps in rebuild plan (unverified HTML regex, narrow translit char class, missing `:count` sentinel) |
| `ADR-021-study-mode-scroll-positioning.md` | Study Mode — Verse Pinning & Sheet Sizing | Accepted (covers-off + covers-on done) | Decision trail for Study-Mode scroll: atomic `StudyPinView` (verse's own background reads frame+offset together — no cross-layer skew) replaces scrollTo; NO top inset (content above gives headroom) — kills the entry jerk AND covers-on rubber band; `toolbarGap`(0) decoupled from `sheetGap`(8, kept <12 so next verse hides behind sheet); `detentTopOffset`(16) empirical (SE-validation pending); `StudyScrollClamper` fixes last-verse exit gap; default interactive dismiss restored; dual sheet-sizing (SwiftUI detent + UIKit applier) confirmed complementary, kept. Lists hard "don't regress" rules |
| `ADR-022-analytics-event-collection-strategy.md` | Analytics Event-Collection Strategy | Accepted | Adoption = `feature_adopted_<feature>` once per session, **6 granular features 1:1 with UI surfaces** (original/lexicon/concordance/commentary/cross_reference/parallel_translation — original≠lexicon≠concordance, see glossary); first three form word-study funnel; depth = counters in `study_session_summary` (`<feature>_views_count`, `word_nav_count`, etc.) — NOT a discrete event per tap, to stay under free-tier (1M/mo); search/annotations/translation_switched kept discrete; `SessionTracker.recordFeatureUse(_:)` owns adoption + counters; loses per-view timestamps (acceptable). Supersedes the per-tap Slice 3 draft |
| `ADR-024-cross-reference-back-stack.md` | Cross-Reference Back-Stack Navigation | Proposed | Cross-ref переходи у Study Mode тепер мають back-стек (`crossRefBackStack` у ReaderViewModel); leading toolbar морфиться між 3 станами — пікер/«Закрити»(стек порожній)/«‹ Назад»(крок по cross-ref історії); `‹ ›` чеврони (intra-chapter) стек НЕ чіпають; cross-ref тап обходить router (in-Reader пряма навігація); push у success-гілці `navigateToVerse(source:)`; свайп-вниз закриває + чистить стек. Амендить spec-study-mode-redesign R4/R7. Без БД/схеми |
| `ADR-023-status-bar-style-control.md` | Status Bar Style Control in SwiftUI App Lifecycle | Reverted (backed out 2026-06-21) | Білий статус-бар на обкладинках. SwiftUI App lifecycle не має API для статус-бара. Поточно: підміна `window.rootViewController` контейнером — **зламало `.preferredColorScheme`** (dark mode), бо HC перестав бути коренем; довелось перебрати appearance на `overrideUserInterfaceStyle`. Research: підклас/підміна HC ламає lifecycle; стандарт — **swizzle `childForStatusBarStyle`** (HC лишається коренем). Рекомендація: **Option B (swizzle)** — нативний dark mode, safe на iPad multi-window; Option A прийнятний тимчасово з hardening. Двовходова модель статус-бара ортогональна. (NB: visionOS не таргет — прибрати `7` з device family) |

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
| `plan-hebrew-translit-rebuild.md` | Hebrew Transliteration — Full DB Rebuild Plan | Approved | New `slot`, `after_char`, `xlit_slot` columns; `fetch_biblehub_translit_hebrew.py` positional scraper; full `build_db.py` rebuild; supersedes `add_after_char.py` migration |
| `spec-study-mode-redesign.md` | Study Mode Redesign | Draft | Verse pins 16pt below toolbar, reader scroll locked; single dynamic-height sheet anchored under verse; toolbar `<>` repurposed to verse/word nav; book/translation picker morphs to Back button (iOS 26); sheet chevrons + bottom action bar → context menu; highlight palette Purple/Pink/Orange/Mint/Blue+None. Includes Fable autonomous run brief |
| `proposal_smarter_examples_v1.5.md` | Smarter Example Selection — v1.5 Proposal | Proposal | Pre-compute `rhetorical_weight` in DB (cross_reference votes); Swift picks highest-weight verse per book instead of first occurrence; fallback chain: rhetorical → syntactic centrality → first |
| `plan-status-bar-cover-white.md` | White Status Bar over Book Cover — algorithm + history | Deferred (working code preserved) | Full code (4 files + ReaderView/ContentView hooks) for the swizzle solution that worked, the variants tried (window-root/class-swizzle/per-instance/scrim) and results, and the ONE open problem: immediate tab-switch (shared HC class + async race; Apple Music sidesteps it via per-screen UIKit VCs). Fix candidates incl. synchronous driver, correct per-instance target, or design-level scrim. Implements ADR-023. Code is here ONLY (reverted from git) |
| `plan-semantic-search-rag.md` | Semantic Search + On-Device RAG | Proposal (V1.5) | Apple-native on-device stack: `NLContextualEmbedding` (embed) + `sqlite-vec` (store) + Foundation Models (RAG generation, iOS 26 за `#available`, fallback до semantic search на iOS 18). **Амендить ADR-008** V1.5 upgrade path (свіч embedder ONNX→Apple, +додає generation шар). On-device indexing (НЕ в build_db.py). Open: corpus scope, search-only vs full RAG. ⛔ LLM не генерує лексичні визначення (trust-rule). Spike на якість ембедингів перед коммітом |
| `spec-windowed-verse-rendering.md` | Windowed Verse Rendering (Doom-style) for Fast Verse Open | Draft / Proposed (fallback) | Render a window `[focus−2 … focus+12]` around the navigated verse + chapter title instead of the whole chapter; present immediately, assemble the rest on sheet dismiss (scroll is locked in Study Mode). Targets ONLY "open verse fast from another chapter/book" (Ps 119 = 176 UITextViews eagerly built → slow → sheet sizes at 45% fallback). Fallback if the `setVerseHeight` `objectWillChange` hotfix (2026-06-22) is insufficient. Hard parts: pin headroom (title mitigates), prepend-without-jump, chevron window growth, StudyPin/clamper geometry re-derivation |
| `spec-analytics-mixpanel.md` | Analytics (Mixpanel) Integration | Draft | Mixpanel in beta AND prod (D3 ✅), gated on consent toggle (`analyticsEnabled`, default ON) — NOT `#if BETA`; PreAuthIdentity distinct_id; event taxonomy (engagement/retention, search, feature adoption); per-session `study_session_summary` → MSS as tunable Mixpanel Custom Event; North Star = weekly users with ≥1 MSS; `PrivacyInfo.xcprivacy`; card/folder/tag events deferred to slice 4; Slice 1+2+3 Work Orders inside; swap MixpanelAnalytics→custom impl when free-tier insufficient (abstraction swap, no remote kill-switch); ⚠️ code still `#if BETA`-gated — needs gating change (Slice 1.5/2) |

---

## Product Decisions (`product decisions/`)

| File | Title | Status | Summary |
|---|---|---|---|
| `PDR-Auth-Strategy.md` | Trust-First Authentication | Accepted | No login wall; local-first data; sync opt-in |
| `PDR-Analytics-Mixpanel.md` | Analytics (Mixpanel) | Proposed | Mixpanel in beta AND prod, anonymous (PreAuthIdentity), no PII; gated on consent toggle (default ON), not build-flag; North Star = Meaningful Study Session; metric defs live in Mixpanel (tunable); D1 no query-text ✅, D2 beta consent (default ON) ✅, D3 prod analytics ✅, D4 prod consent = opt-IN (default OFF; beta stays opt-out) ✅, D5 separate Dev/Beta/Prod projects (runtime token by isTestFlight) ✅; swap to custom (self-hosted OSS/paid, not bespoke) when free-tier insufficient; reconciles with trust-first |
| `PDR-Highlights-Bookmarks-Notes.md` | Notes/Highlights/Bookmarks Differentiation | — | Distinct UX roles for three annotation types |
| `PDR-Book-Covers.md` | Book Cover Design — Doré Engravings | Accepted | Doré engraving + blue bg; Protestant canonical section tag + chapter count per cover; section vocab mirrors browse flow |
| `PDR-Hebrew-Transliteration-Rules.md` | Hebrew Transliteration Rules for `simplify_xlit()` | Accepted | Grammar rules + 4 bugs fixed: monosyllabic shewa, dagesh doubling, spirant peh (combining char), modifier letter ᵃ |
| `PDR-Page-Turn-Gesture-Zone.md` | Page-Turn Swipe Is Edge-Only (Not a Bug) | Accepted | Swipe paging active only in left/right edge bands by design (center swipe collides with tappable words / long-press Word tab / selection). "Swipe doesn't work" = center-swipe misunderstanding, NOT a defect — link repeat reports here. Discoverability tracked as UX in `docs/ux/new/ux-001.md` (reclassified from bug-004) |

---

## Reference (`/`)

| File | Summary |
|---|---|
| `glossary.md` | Term definitions — word-study surfaces (original ≠ lexicon ≠ concordance), analytics taxonomy, session/consent, Mixpanel projects. Read when terms feel ambiguous |
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
