---
id: ux-NNN               # ux-001, ux-002, … (sequential)
type: improvement        # ux  | improvement
                         #   ux          = something works but is confusing / awkward / unclear
                         #   improvement = a feature or polish request ("it would be nice if…")
status: new              # new | reviewed | done
area: reader/lexicon     # same area vocabulary as docs/bugs (the dedup key)
reporters: [tester-A]    # who raised it. Repeated requests = stronger signal
impact: medium           # high | medium | low   (how much it helps users)
effort: medium           # high | medium | low   (rough build cost — fill during review)
app_version: "1.0 (1)"
context:                 # screen / state where it came up
date_reported: 2026-06-23
duplicate_of:            # null normally; set when merged
related: []
source:                  # Drive item id + link this was normalized from (idempotency key)
---

# Observation

What the tester said, or what they struggled with. Their words if possible.

## Why it matters

The underlying need or friction — not the proposed solution, the problem.

## Possible direction

Optional. One or two ideas for addressing it. Leave blank if it's just an observation.

## Screenshots

- ../img/ux-NNN-1.png

<!--
This track is SEPARATE from docs/bugs on purpose:
  - A defect = something is broken (wrong/crash). Goes to docs/bugs.
  - A UX note / improvement = it works but could be better. Goes here.
The skill never dedups a UX note against a defect — different things.

Prioritize with impact × effort: high-impact + low-effort wins go first.
Required minimum: id, type, status, area, reporters, date_reported, Observation.
-->
