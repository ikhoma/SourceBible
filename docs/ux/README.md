# UX & Improvements Track

A parallel pipeline to `docs/bugs/`, but for things that **work yet could be better** —
confusing flows, awkward wording, polish, and "it would be nice if…" requests from testers.

Defects (broken / wrong / crash) belong in `docs/bugs/`, not here.

```
docs/ux/
├── new/        ← incoming UX notes & improvement ideas (raw → normalized by the skill)
├── reviewed/   ← triaged: impact + effort assigned, kept for the backlog
├── done/       ← shipped or closed
├── img/        ← screenshots (referenced as ../img/ux-NNN-K.png)
└── TEMPLATE.md ← the schema for one item
```

## Lifecycle

1. **new/** — a tester observation lands here (via the Drive mailbox, normalized by the
   `process-bugs` skill, or added by hand from `TEMPLATE.md`).
2. **reviewed/** — you assess `impact` and `effort`, dedup against existing items, and
   decide keep / drop. Survivors wait here as a prioritized backlog.
3. **done/** — implemented or consciously closed.

## Prioritizing

Use **impact × effort**. High-impact + low-effort items are quick wins — do them first.
Repeated requests from multiple testers raise impact: the skill appends `reporters` on
merge so the count is visible.

## Relationship to the bug skill

The `process-bugs` skill routes intake: anything describing something **broken** goes to
`docs/bugs/new/`; anything describing **friction or a wish** comes here. UX items are
never deduplicated against defects.
