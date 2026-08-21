# Known design friction — "works as designed, but confuses users"

A register of behaviours that are **intentional** yet trip users up. These are NOT
bugs — closing them silently loses the signal. Each entry pairs the intentional
decision (why) with a **discoverability decision** (what, if anything, we do so users
stop tripping). This doc is the single feed for the **onboarding tutorial / FAQ**.

## How an item lands here

1. A tester reports something as broken; investigation shows it's working as designed.
2. Record the decision as a PDR (so it isn't re-investigated) and set the ticket's
   status to **by-design** on the board.
3. Add a row here with a **discoverability decision**:
   - **Accept** — leave as is (minor, one-off). No further action.
   - **Affordance** — add an in-UI hint (chevron, edge indicator, empty state, tooltip).
   - **Tutorial** — surface it in the onboarding tutorial / FAQ (for non-obvious,
     high-value interactions). Add it to the Tutorial backlog below.
4. Reporter count matters: repeats raise the priority of doing something (Accept →
   Affordance/Tutorial) even for a by-design item.

## Register

| Item | Confusion | Why (by design) | Reporters | Decision | Refs |
|---|---|---|---|---|---|
| ~~ux-001~~ **RESOLVED 2026-07-10** | Swipe over the center of the page doesn't turn pages; feels broken | Was: edge-only paging. Superseded by ADR-026 Phase 2 — full-surface swipe via UIPageViewController; no gesture clash on device | 1 | **Resolved by design change** (tutorial item dropped) | PDR-Page-Turn-Gesture-Zone (amended); `docs/ux/done/ux-001.md` |
| **bug-006** *(+ bug-027 data half)* | Original / Meaning shows English gloss + English Strong's definitions under a Ukrainian UI + RST | Lexical **data** is English-only for MVP — the dataset (Macula, TBESH/TBESG, BDB, Thayer's) is human-authored English and there is no RST/UA gloss column; machine translation of definitions is rejected on trust grounds | 1 | **Accept** — no in-UI affordance for now; revisit at ~3 distinct reporters (then add a small "English lexicon" note on the panels) | PDR-Lexicon-Language; ADR-006; memory "Dataset language strategy", "LLM-generated content trust hypothesis" |
| **bug-012** | Rotating the phone does nothing — landscape "doesn't work" | Portrait is locked **deliberately**. The 2026-07 investigation traced it to a **systemic iOS 26 bug**: reader content shifted to the right on rotation and the offset **accumulated** with every rotation. Locking orientation works around someone else's defect — it is not our layout oversight | 1 | **Accept** — revisit when Apple fixes it (trigger: re-test on a new minor iOS release) | memory "iOS 26 landscape content shift"; ⚠️ `docs/board.html` records this as "Not yet investigated" — that field is WRONG |
| **ux-006** | «Red Letters» toggle label reads as unclear | The term is a **standard English Bible-publishing convention**. Validated 2026-07 by asking a native English speaker who reads the Bible regularly: obvious to anyone past beginner level. The reporter sat outside the target context twice over — Ukrainian, and not a habitual Bible reader. The Ukrainian label was checked separately and is fine | 1 | **Accept** — no rename, in either language | validation: 1 native-EN Bible reader; memory "validate reports against the target persona" |
| **ux-010** | Translation window: lots of empty space, options pinned to the top | `.presentationDetent(.large)`; the empty space is the sheet's flex room for dynamic height (same mechanics as ADR-021 Study Mode sizing). Options sit top-anchored for immediate discoverability — bottom-anchoring would push them below the window height | 1 | **Accept** — a collapsing/floating picker is a v1.5+ refinement, not a fix | ADR-021; related ux-002, ux-013 |

## Tutorial backlog

Items flagged **Tutorial** above, gathered for the onboarding walkthrough / FAQ.
This ties into ux-005 (FAQ / first-user guide) and ux-016 (starting screen).

- ~~**Swipe from the edges to turn pages** (ux-001)~~ — dropped 2026-07-10: swipe is
  now full-surface (ADR-026 Phase 2), nothing to teach.

_When 2–3 items accumulate here, that's the trigger to actually build the tutorial
(one coherent onboarding pass beats scattered one-off hints)._
