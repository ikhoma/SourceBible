---
name: process-bugs
description: Process bugs from the SourceBible bug pipeline. Use when the user says "process bugs", "work on bugs", "fix bugs", "check new bugs", or asks to triage/handle items in docs/bugs/new/. Analyzes ALL bugs in new/ first (reads files, screenshots, finds root cause, proposes fix), presents a full summary for user review, then implements only the ones the user approves.
---

# Bug Processing Pipeline

The bug pipeline lives at `docs/bugs/` inside the SourceBible project:

```
docs/bugs/
├── new/           ← incoming, unprocessed
├── in progress/   ← currently being worked on
├── blocked/       ← stuck, needs decision
├── done/          ← fixed and closed
├── bug-NNN-1.png  ← screenshots (live here, not in subfolders)
```

Each bug is a markdown file with frontmatter (`id`, `priority`, optionally `component`) and a `# Description` section.

---

## Phase 1 — Analyze all bugs

Work through every `.md` file in `new/` before proposing any fixes. For each bug:

### 1. Read the bug

Read the bug markdown file. Note `id`, `priority`, `component` (if present), and the full description.

### 2. View screenshots

Screenshots are referenced as `../bug-NNN-K.png` but physically live at `docs/bugs/bug-NNN-K.png`. Read each one — PNG images can be viewed directly with the Read tool.

### 3. Search the codebase

Use Grep and Glob to find relevant Swift files:
- If `component` is set in frontmatter → grep for that filename
- Otherwise, search for keywords from the description (UI element names, view names, function names)
- Common locations: `SourceBible/Views/`, `SourceBible/ViewModels/`, `SourceBible/Services/`

Read the relevant sections of found files — enough to understand the current behavior.

### 4. Identify root cause

Note what file(s) are involved, what the current code does, and why it produces the bug.

---

## Phase 2 — Present full summary

After analyzing ALL bugs, present a structured summary in one response:

```
## Bug Analysis Summary

### bug-001 — [short title] (priority: medium)
**Root cause:** [one clear sentence]
**Affected file:** `FileName.swift` line NNN
**Proposed fix:** [description of what to change and why]
**Confidence:** high / medium / low
**Questions:** [anything unclear, or "none"]

---

### bug-002 — [short title] (priority: medium)
...
```

End with: "Let me know which bugs to implement (e.g. 'all', 'bug-001 and bug-002', 'skip bug-003'). Feel free to ask questions about any of them first."

Then **stop and wait**. Do not implement anything until the user responds.

---

## Phase 3 — Implement approved fixes

For each approved bug, in order:

### 1. Move to "in progress"

```bash
mv "docs/bugs/new/bug-NNN.md" "docs/bugs/in progress/bug-NNN.md"
```

### 2. Apply the fix

Use the Edit tool. Keep changes minimal and focused — fix the bug, don't refactor nearby code.

If the fix touches iOS 26-specific APIs, follow the `CLAUDE.md` rule: wrap in `#available(iOS 26, *)` with an iOS 18 fallback.

### 3. Update the bug file and move to done

Append a fix summary to the bug file:

```markdown
## Fix

**Root cause:** [one sentence]
**Changed:** `FileName.swift` — [what changed]
**Status:** done
```

Then move to `done/`:

```bash
mv "docs/bugs/in progress/bug-NNN.md" "docs/bugs/done/bug-NNN.md"
```

### 4. Blocked bugs

If a bug can't be resolved (ambiguous requirement, can't find root cause, needs a design decision), move to `blocked/` and append:

```markdown
## Blocked

**Reason:** [what's unclear or missing]
```

After all implementations, remind the user to Clean Build in Xcode (⇧⌘K → Run).

---

## Key project context

- Swift 6 strict concurrency — follow rules in `CLAUDE.md` (nonisolated, @MainActor, etc.)
- iOS deployment target: iOS 18 minimum. Don't use iOS 26-only API without `#available` guard.
- Do NOT read `sourcebible.db` via Python in the bash sandbox — APFS sparse file issue.
- After DB changes: always remind user to run `build_verse_map.py` and do Clean Build.
- Read `docs/INDEX.md` if a bug seems related to a known architectural decision.
