# Feature requests — asked by users

Net-new capabilities testers/users have asked for. These are **not bugs** and **not
by-design friction** — the app works, they just want something more. Each gets a
**target milestone** (or `unscheduled` until you decide). On the board these carry the
`planned` status and a milestone chip (e.g. `v1.5`).

Distinct from:
- `docs/ux/` small tweaks/polish (still just UX improvements) — stay in the UX track.
- `docs/ux/known-design-friction.md` — "works as designed but confuses" (discoverability).

## Backlog

| id | Request | Reporters | Impact / Effort | Target | Source |
|---|---|---|---|---|---|
| ux-017 | Browse & sort commentaries by theme/tags (heart, relationships, temptation…) as an independent feature, like the Plans-tab tags | Viacheslav | low / high | **v1.5** | [UX review 16](https://docs.google.com/document/d/1mS_fVVAlaM3BsKHlW5q84kFV3n8R5JJLOktVQgGbACo) |
| ux-021 | Red letters (Jesus' words) in ASV — the module ships **0 `<J>` tags of 31 085 verses**, so the toggle silently does nothing there. Three paths: **A** synthesise `<J>` from KJV via Strong's overlap (2 038 of 2 042 verses align; 1 404 whole-verse, 647 partial → need span alignment + low-confidence report), **B** gate/hide the toggle for translations with no markup (safety net, do regardless — otherwise any future unmarked translation reproduces this), **C** source a licence-compatible ASV module that ships `<J>`. Measurements live in `docs/bugs/done/bug-017.md` | oleksiukviacheslav | medium / medium | **v1.1** | [BUG REPORT (Drive)](https://docs.google.com/document/d/1R8dNe8zTJgVcPPvscq2cjoICaRyPopYGL4PZxoBe4do) |

## Unscheduled candidates (from Sprint 1, decide milestone later)

These read as feature requests too — move them into the table above with a target when
you're ready to schedule:

- **ux-005** — FAQ / first-user guide (impact: big)
- **ux-016** — starting / splash screen (impact: medium)
- **ux-011** — empty state for invalid book search (impact: low)

## Completed

| id | Request | Reporters | Resolved | Source |
|---|---|---|---|---|
| ux-003 | Smooth chapter transition (native paged slide via TabView) — see ADR-026 | Viacheslav | v1.0 (ADR-026) | [UX review 18](https://docs.google.com/document/d/1TFg2e9HS4CuqjDyVu906orSJWRa9wmye2wBf4w4DOSw) |
