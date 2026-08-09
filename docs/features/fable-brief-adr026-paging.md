# Fable Run-Brief — ADR-026 Reader Chapter Paging (Phase 2)

**Status:** Done (ADR-026 IMPLEMENTED 2026-07-10 — прогін завершено)

**Spec:** ADR-026 (Accepted scope) · PDR-Page-Turn-Gesture-Zone (full-surface, 2026-07-10)
**Mode:** Autonomous. Isolated branch/worktree only. Review by final diff.

## Goal
Page the **real** classic chapter view in `TabView(.page)` — container change only.
Chevron tap and full-surface swipe both animate a native chapter slide.

## Scope — ALLOW
- Reader chapter **container** in `ReaderView.swift` (ScrollView+ForEach → `TabView(.page)`).
- `currentChapter` ↔ selection binding; chevron actions drive selection.
- Adjacent-chapter prefetch (current ± 1 lazy mounting).
- Retire `EdgeSwipeNavigator` for the full-surface swipe (per amended PDR).

## Scope — DENY (stop & ask if needed)
- Per-verse content view / word-verse interactions (ADR-016).
- Study-Mode business logic + pinning/sizing (ADR-021). In-sheet ‹ › stay prev/next verse/word.
- DB, `sourcebible.db`, cross-ref back-stack (ADR-024), analytics.
- **Reimplementing** the chapter view or stripping tuned UI (cover bleed, offsets, `ignoresSafeArea`).

## Hard rules
- Page the REAL view — do NOT rewrite `ChapterPage` (spike drifted: cover under toolbar).
- No `loadChapter()` / `@Published` re-map during transition (janks first slide) — data per-page, sync VM off animation frame.
- iOS 26 value-based selection behind `#available(iOS 26)` + iOS 18 fallback (= current path).
- Swift 6 strict-concurrency clean; `#Preview` with sample data under `#if DEBUG`.

## Acceptance
1. Chevron + full-surface swipe animate chapter change; new chapter at sane scroll (top / restored anchor).
2. Study Mode unaffected (ADR-021 pinning/sizing/clamp hold).
3. No regression: covers (ADR-017), headings, word tap/long-press, selection, `.id()` cache (ADR-014), cross-ref stack, resume-position.
4. **Device gesture-check** — full-surface swipe vs word tap / long-press / selection. Real clash → **rollback to edge-only** per PDR clause.
5. Builds **and Archives** (Release) on Mac; Clean Build before verifying.

## Exit
Final diff + change report for review. Merge = user. New architectural calls mid-run → ADR/amendment + flag in report.
