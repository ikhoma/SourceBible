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
| ux-001 | Swipe over the center of the page doesn't turn pages; feels broken | Paging is edge-only to avoid clashing with tappable words / long-press Word tab / text selection | 1 | **Tutorial** + consider **Affordance** (edge indicator/chevrons) | PDR-Page-Turn-Gesture-Zone; `docs/ux/…/ux-001.md` |
| bug-006 *(candidate)* | Original-tab gloss shows in English under RST | Lexical glosses are English-only for MVP (ADR-006; translated lexicon is a later stage) | 1 | Pending — confirm reporter meant the gloss (by-design) vs labels (real bug) | ADR-006; memory "Dataset language strategy" |

## Tutorial backlog

Items flagged **Tutorial** above, gathered for the onboarding walkthrough / FAQ.
This ties into ux-005 (FAQ / first-user guide) and ux-016 (starting screen).

- **Swipe from the edges to turn pages** (ux-001) — show the edge zones on first run.

_When 2–3 items accumulate here, that's the trigger to actually build the tutorial
(one coherent onboarding pass beats scattered one-off hints)._
