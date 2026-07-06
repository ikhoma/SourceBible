---
name: process-bugs
description: Process bugs and UX feedback from the SourceBible TestFlight pipeline. Use when the user says "process bugs", "work on bugs", "fix bugs", "check new bugs", "triage feedback", "pull from the mailbox", or asks to handle items in docs/bugs/new/ or docs/ux/new/. Pulls raw tester feedback from the Drive mailbox, normalizes it, DEDUPES against every folder, routes defects vs UX, presents a summary for review, then implements only what the user approves.
---

# Bug & UX Processing Pipeline

Two parallel pipelines live in the SourceBible project. Both are plain markdown
under git — the source of truth. Tester feedback arrives raw in a **Google Drive
mailbox** and this skill turns it into structured cards.

```
docs/bugs/                       docs/ux/
├── new/         incoming         ├── new/        incoming
├── in-progress/ being fixed      ├── reviewed/   triaged backlog
├── blocked/     needs decision   ├── done/       shipped / closed
├── done/        fixed            ├── img/        screenshots
├── img/         screenshots      └── TEMPLATE.md
└── TEMPLATE.md
```

**Defect vs UX — the routing rule.**
- Something is **broken / wrong / crashes** → `docs/bugs/` (defect).
- It **works but is confusing, awkward, or a wish** → `docs/ux/` (improvement).
- It **works as intended but confuses users** (usually surfaced during triage) → mark
  **by-design**: record/confirm a PDR so it's not re-investigated, and add a row to
  `docs/ux/known-design-friction.md` with a discoverability decision (accept /
  affordance / tutorial). It is NOT a defect — don't change the behaviour; the fix, if
  any, is discoverability (hint / onboarding tutorial).
- It's a **net-new feature the user wants** (app works, just missing a capability) →
  `docs/ux/feature-requests.md` with a target milestone (e.g. v1.5); board status
  **planned**. (Small polish/tweaks stay as ordinary `docs/ux/` items.)
- When unsure, treat it as a defect and note the uncertainty.

**Screenshots live in the `img/` subfolder** of each pipeline and are referenced
from a card as `../img/<id>-K.png` (e.g. `../img/bug-007-2.png`). They are NOT in
the pipeline root. When you read a card, resolve its screenshot link to
`docs/bugs/img/...` or `docs/ux/img/...`.

Card schema is in `docs/bugs/TEMPLATE.md` and `docs/ux/TEMPLATE.md`. Read the
relevant template before creating or normalizing a card.

---

## Phase 0 — Intake from the Drive mailbox (per-sprint batches)

The mailbox is the **"Source Bible Beta Testers"** Drive folder
(id `1NyEVbS7g5dwzO0dzYdQpe4JNtBcDSD7X`). Its layout:

```
Source Bible Beta Testers/
├── 🐞 / 💡 template docs        ← leave alone
├── img/                         ← screenshot files (shared)
├── Sprint N (MM/YY)             ← current sprint, still collecting — DON'T touch
└── Sprint N (MM/YY) Closed      ← CLOSED batch — this is what we process
```

**We process sprint folders whose name ends in `Closed`** — that's the user's signal
"this batch is ready." At sprint close the user drops everything collected into that
folder and renames it `… Closed`. Never process the still-open `Sprint N` folder or
loose root items unless the user explicitly says so.

**Knowing what's already done — without being told.** Two layers, no Drive tidying
needed (don't move/delete anything, and there is no "Processed" subfolder anymore):

- **Sprint ledger** `docs/bugs/processed-sprints.md` — one line per processed sprint
  (name · Drive id · date · item count). On intake, list the `Closed` folders, skip
  any already in the ledger, and process the rest oldest-first. So you auto-pick the
  next un-done sprint; the user never has to point you at it.
- **Per-item `source` key** (backstop) — every card stores the Drive doc id it came
  from. Even if a sprint is re-scanned, or a tester drops a late doc into an
  already-processed sprint, anything already carded is skipped and only the genuinely
  new doc is picked up.

Run this when the user says "process bugs", "process the sprint", "pull feedback", etc.

1. **Pick the batch.** List the mailbox, take the oldest `Closed` sprint folder NOT in
   `docs/bugs/processed-sprints.md`. (If none are un-done, say so and stop.) List its
   contents.

2. **Read each item — skip already-carded.** Items are Google Docs (bug reports & UX
   reviews); testers self-number them ("BUG REPORT 22", "UX review 18"). Skip any doc
   whose Drive id already appears as a card `source`. For each new doc, read it and
   locate its screenshot(s) — reports reference bare filenames (`33.jpg`,
   `37.jpg / 37.1.jpg`); find them in `img/` (or the sprint folder) and fetch into the
   repo `img/` as `<id>-K.<ext>`.
   - **Non-image attachments** (e.g. `39.mp4`) can't be auto-viewed — link them in the
     card and flag "needs manual review", don't block on them.

3. **Normalize each into a card.** For every distinct report:
   - Decide **defect vs UX** (routing rule above).
   - Assign the next sequential `id` (`bug-NNN` / `ux-NNN`). Keep the tester's own
     number (e.g. "BUG REPORT 22") in `Notes` for cross-reference.
   - Fill template fields; infer `area`, `severity`/`impact`, `context` (translation,
     screen, device) from the report. Leave a field blank rather than guess wildly.
   - Record the tester in `reporters`, and the Drive doc id + link in `source`.
   - Write the card to `docs/bugs/new/` or `docs/ux/new/`.

4. **Log the sprint.** Append a line to `docs/bugs/processed-sprints.md`
   (name · Drive id · date · item count), then report the tally and routing
   (e.g. "Sprint 1 Closed: 9 items → 7 defects, 2 UX; 1 video for manual review").
   Continue to Phase 1 (dedup).

> Never delete or move anything on Drive. On intake, only read `Closed` sprint folders
> not yet in the ledger; ignore `img/`, the template docs, and the open sprint.

---

## Phase 1 — Dedup (do this before analyzing fixes)

With many testers, the same issue arrives multiple times. Duplicates are a **priority
signal, not noise** — never silently drop them.

1. **Build an index of EVERY existing card**, across all folders:
   `docs/bugs/{new,in-progress,blocked,done}/` and, for UX items,
   `docs/ux/{new,reviewed,done}/`. For each card capture: `id`, `area`, title/symptom,
   `reporters`, screenshot, status.

2. **Check against known design decisions BEFORE opening anything.** Read
   `docs/INDEX.md` (especially the Product Decisions / PDR table). If a report
   matches a documented "by design / not a bug" decision (e.g.
   `PDR-Page-Turn-Gesture-Zone` — edge-only swipe paging is intentional), do NOT
   open a defect: note the match, link the report to that PDR plus any related UX
   item, and add the reporter to the existing item instead. This is how a settled
   question stops getting re-investigated every time it resurfaces. Only a
   genuinely new failure mode (not the known misunderstanding) becomes a fresh
   defect — and if it contradicts a PDR, surface the conflict, don't silently act.

3. **For each remaining NEW card, find likely duplicates.** A pair is a likely duplicate when
   they share the same `area` AND describe the same symptom (overlapping keywords, same
   UI element, same screenshot subject). Defects only dedup against defects; UX only
   against UX — **never across the two**.

4. **Flag, don't merge yet.** In the Phase 2 summary, list each suspected duplicate
   group with a proposed action. Default proposal:
   - Keep the earliest open card as canonical.
   - Append the new reporter(s) to its `reporters` list.
   - Bump priority/impact if the report count crosses a threshold (e.g. ≥3 reporters).
   - Set `duplicate_of: <canonical-id>` on the redundant new card and plan to move it
     to `done/` (defects) or `done/` (ux) marked as merged — **after** approval.
   - If a new report matches something already in `done/`, it may be a **regression** —
     flag it as such, don't auto-close.

5. **Wait for the user's OK before merging.** This is your explicit instruction:
   detect and propose, but do not mutate `reporters`/`priority` or move duplicate files
   until the user approves the merge in Phase 2.

---

## Phase 2 — Analyze and present

Analyze every non-duplicate card in `new/` (defects) before proposing fixes. For each:

### 1. Read the card and screenshots
Resolve screenshot links to `../img/` and view each PNG with the Read tool.

### 2. Search the codebase
Use Grep/Glob. If `component` is set → grep that file. Otherwise search keywords from
the description and `area`. Common locations: `SourceBible/Views/`,
`SourceBible/ViewModels/`, `SourceBible/Services/`. Read enough to understand current
behavior. If the card touches a known decision, check `docs/INDEX.md` first.

### 3. Identify root cause
Note the file(s), what the current code does, and why it produces the bug.

### Present one summary, then STOP

```
## Triage Summary

### Suspected duplicates
- bug-008 ↔ bug-003 (area reader/lexicon, both "H-number not highlighted")
  → merge into bug-003, add reporter tester-C, bump to P1 (now 3 reporters). Approve?

### Defects to fix
#### bug-007 — H341 not clickable under NASB (severity: high · P1)
**Root cause:** [one sentence]
**Affected file:** `ReaderViewModel.swift` ~line NNN
**Proposed fix:** [what changes and why]
**Confidence:** high / medium / low
**Questions:** [or "none"]

### UX items (routed to docs/ux, not fixed here)
- ux-002 — word-tab labels unclear (impact medium). Logged for your review.

### Needs your call
- [anything ambiguous]
```

End with: "Tell me which to implement (e.g. 'all', 'bug-007 only', 'merge the dupes',
'skip bug-009'), or ask questions first." Then **stop and wait.** Implement nothing yet.

---

## Phase 3 — Implement approved items

Only after the user approves. For each approved item, in order:

### Approved merges
Append reporter(s) to the canonical card's `reporters`, adjust `priority`/`impact`,
set `duplicate_of` on the redundant card, then move the redundant card to `done/`.

### Approved fixes
1. **Move to in-progress** and update the card's `status: in-progress`:
   ```bash
   mv "docs/bugs/new/bug-NNN.md" "docs/bugs/in-progress/bug-NNN.md"
   ```
2. **Apply the fix** with Edit. Keep it minimal and focused — fix the bug, don't
   refactor nearby code. Honor every `CLAUDE.md` rule (see Key context below).
3. **Append a fix block, set `status: done`, move to done:**
   ```markdown
   ## Fix
   **Root cause:** [one sentence]
   **Changed:** `FileName.swift` — [what changed]
   **Status:** done
   ```
   ```bash
   mv "docs/bugs/in-progress/bug-NNN.md" "docs/bugs/done/bug-NNN.md"
   ```

### Blocked items
If it can't be resolved (ambiguous requirement, no root cause, needs a design call),
set `status: blocked`, append a `## Blocked` block with the reason, and move to
`blocked/`.

After implementing, remind the user to **Clean Build Folder in Xcode (⇧⌘K → Run)**.

---

## Delegating to subagents (pick the optimal model per task)

For a batch, parallelize with the Agent tool and **match the model to the job** —
don't burn the heaviest model on mechanical work, and don't do deep code reasoning
on the lightest. Pass `model:` on the Agent tool.

- **Haiku — cheap & mechanical.** Drive-mailbox intake/normalization, building the
  dedup index across folders, fetching/renaming screenshots, `INDEX.md` lookups,
  routine file moves. High volume, low judgment.
- **Sonnet — default working model.** Root-cause search in the codebase, writing a
  focused fix, drafting cards, most triage analysis.
- **Opus — hardest reasoning.** Gnarly multi-file root causes, Swift 6 concurrency
  / iOS-26-API subtleties, anything touching the DB build, or PDR/ADR-level
  decisions — i.e. where a wrong fix is expensive.
- **Verification subagent.** For any non-trivial fix, spawn a SEPARATE agent
  (Sonnet or Opus) to review the diff / sanity-check before you report done —
  fresh eyes, not the agent that wrote it.

Spawn one agent per independent bug so they run in parallel. Keep the approval
gate (Phase 2) on the main thread: subagents **analyze and draft**, the user still
approves before anything is implemented. Only spawn agents when the batch is large
enough to be worth it — a single small bug is faster done inline.

---

## Key project context (from CLAUDE.md)

- ⛔ **Do not change Swift/scripts/DB without an explicit "fix it" / "implement"** — the
  approval gate in Phase 2/3 IS that explicit permission, per-item.
- Swift 6 strict concurrency rules (`nonisolated`, `@MainActor`, file-level funcs in
  escaping closures, visibility of private types).
- iOS 18 minimum deployment target — no iOS 26-only API without `#available(iOS 26, *)`
  + iOS 18 fallback.
- ⛔ **Never read `sourcebible.db` via Python/sqlite in the Linux sandbox** (APFS sparse
  file → false corruption). DB scripts run on the Mac only.
- Python scripts target **Python 3.9** (no `str | None`, `list[str]`, match/case).
- After DB changes: remind to run `build_verse_map.py` and Clean Build.
- `#Preview` using sample data must be wrapped in `#if DEBUG … #endif`.
- Before writing iOS 26 UI code, research the correct API first (see CLAUDE.md).
