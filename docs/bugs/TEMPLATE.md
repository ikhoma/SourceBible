---
id: bug-NNN              # bug-001, bug-002, … (assigned at intake; keep sequential)
type: defect             # always "defect" for this folder; UX ideas go to docs/ux/
status: new              # new | in-progress | blocked | done
severity: medium         # crash | high | medium | low   (how bad is the impact)
priority: P2             # P0 | P1 | P2 | P3              (how soon we fix it)
area: reader/lexicon     # the DEDUP KEY — keep these consistent (see Areas below)
component:               # optional: specific Swift file if known, e.g. ReaderViewModel.swift
reporters: [tester-A]    # who reported it. 3 reporters on one bug = strong priority signal
app_version: "1.0 (1)"   # TestFlight build, e.g. "1.0 (42)"
device:                  # e.g. iPhone 15 Pro  (optional but helpful)
ios_version:             # e.g. "26.0"          (optional but helpful)
context:                 # decisive app state, e.g. "NASB+ active", "Psalms", "dark mode"
date_reported: 2026-06-23
duplicate_of:            # null normally; set to another bug id when merged
related: []              # ids of related-but-not-duplicate bugs
source:                  # Drive item id + link this was normalized from (idempotency key)
---

# Description

One or two plain sentences: what's wrong, from the user's point of view.

## Steps to Reproduce

1. Open …
2. Tap …
3. Observe …

## Expected

What should happen.

## Actual

What actually happens.

## Screenshots

- ../img/bug-NNN-1.png

## Notes

Anything else: which translation was active, how often it happens, guesses about cause.
Leave blank if nothing to add.

<!--
=========================  FIELD GUIDE  =========================

severity vs priority — keep them separate:
  severity = how much damage      (crash > high > medium > low)
  priority = how soon we act on it (P0 now, P1 this cycle, P2 soon, P3 someday)
  A cosmetic bug 5 testers hit can be low severity but high priority.

area — the dedup key. Reuse the SAME strings so duplicates cluster.
  Current areas (extend as needed):
    reader/lexicon        reader/navigation     reader/word-tab
    reader/morphology     translations/nasb     translations/kjv
    strongs/mapping       db/verse-map          commentaries
    search                settings              onboarding
    crash/startup         build/tooling

reporters — list every tester who hit it. When the skill merges duplicates
  it APPENDS reporters here and bumps priority, so the count survives the merge.

status — mirrors the folder the file lives in (new/ → in-progress/ → done/,
  or blocked/). The skill keeps the two in sync.

You usually won't fill every field by hand — the process-bugs skill normalizes
raw tester feedback from the Drive mailbox into this shape. Required minimum:
id, type, status, severity, area, reporters, date_reported, Description.
================================================================
-->
