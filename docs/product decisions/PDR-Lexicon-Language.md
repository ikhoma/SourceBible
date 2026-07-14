# PDR — Lexicon language: English glosses and definitions for MVP

- **Status:** accepted
- **Date:** 2026-07-14
- **Refs:** ADR-006 (localization / TranslationProvider), bug-006, bug-027, bug-005
- **Supersedes:** nothing

## Decision

Original-language **data** — Macula glosses, Strong's `short_def` / `long_def`, lexical
definitions — is **English-only** for MVP, regardless of the interface language or the
active Bible translation. The **interface** (labels, section titles, morphology names,
buttons) IS localized.

Reader-visible consequence: with a Ukrainian UI and RST active, `Оригінал` and
`Лексичне значення` show Ukrainian *labels* wrapped around *English* gloss text.
This is intentional, not a defect.

## Why

- The dataset is English at source: Macula gloss fields, TBESH/TBESG `short_def` /
  `long_def`, BDB and Thayer's are human-authored English lexicography. There is no
  RST/UA gloss column in `sourcebible.db` — nothing to fall back to.
- Machine-translating lexical definitions is explicitly rejected: definitional precision
  is the product's core value, and LLM-generated lexical content is not trustworthy
  enough to stand as the authority a word study rests on (see memory note
  "LLM-generated content trust hypothesis").
- A translated lexicon is a **later stage**, not an MVP cut: it needs sourcing or
  commissioning human-authored Ukrainian/Russian lexical data, which is a project of its
  own (see "Dataset language strategy").

## Boundary — what is NOT covered by this decision

Anything that is a **label** rather than **lexical data** must localize. When a tester
reports "English in the word tab", split the report:

| Surface | Verdict |
|---|---|
| Gloss text, Strong's definitions, phrase glosses | **By design** — this PDR |
| Section titles ("Лексичне значення"), morphology names, tab names, buttons | **Real bug** — must localize |

That split is exactly what bug-005 and bug-027 turned out to be: the label half was a
genuine defect (`String(localized:)` bypassing the `LocalizedBundle` swizzle — fixed
2026-07-13), the data half is this PDR.

Transliteration and morphology *proper nouns* (Qal, Niphal, Piel) are also by design:
they are Latin scholarly terms, not English words, and stay Latin in every language.

## Discoverability

Repeat reports are expected — "why is this English?" is a reasonable question from a
Ukrainian reader. Recorded in `docs/ux/known-design-friction.md` with an **Accept**
decision for now. If reporter count climbs, revisit with an in-UI affordance (e.g. a
small "English lexicon" note on the Original/Meaning panels) rather than reopening the
ticket.

## Revisit when

- A licensed or commissioned Ukrainian/Russian lexicon dataset exists, or
- Reporter count on this friction crosses ~3 distinct testers, or
- The app moves to a paid tier (English-only lexicon is weaker as a paid proposition).
