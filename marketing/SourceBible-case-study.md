# SourceBible — Case Study

> **Bridge the gap between modern readers and the world of the biblical text.**

*A mobile Bible-study app that turns reading into understanding — built solo, design-led, with AI-assisted engineering.*

---

## Snapshot

| | |
|---|---|
| **Role** | Product Designer & Product Owner — vision, UX, system design, and AI-assisted build |
| **Platform** | Native iOS (SwiftUI) |
| **Domain** | Bible study / original-language study tools |
| **Scope** | Concept → product structure → high-fidelity design → shipped iOS app |
| **Status** | Built and in testing (pre-public-launch) |
| **What's notable** | A deep, data-heavy study tool shipped by one person, by pairing product design with AI-assisted development |

---

## One-line pitch

Most Bible apps are built for *reading*. SourceBible is built for *understanding* — it puts the original Hebrew and Greek, the lexicon, cross-references, and centuries of commentary one tap away from any verse, without ever making you leave the page you're on.

---

## The problem

Scripture was written in Hebrew and Greek. Almost everyone reads it in translation — and the moment a reader gets curious ("what's the actual word here?", "why do translations disagree?", "where else does this appear?"), the tools fall apart.

The people who study most seriously — pastors, small-group leaders, teachers, motivated readers — hit the same wall:

- **No bridge between the translation and the original.** The text you read and the text it came from live in separate worlds.
- **Fragmented tools.** Lexicon, concordance, morphology, and commentary are scattered across different apps and websites.
- **High friction.** Every deeper question means leaving your verse, switching context, and finding your place again afterward.
- **Information overload.** The tools that *do* go deep tend to bury beginners in raw lexical data.

The net effect: real Bible study requires multiple tools, real effort, and prior training. Most readers never cross that gap — not for lack of curiosity, but for lack of an on-ramp.

> **The design thesis:** curiosity is fragile. If answering "what does this word really mean?" costs three apps and a lost place in the text, people stop asking. Collapse that cost to a single tap and depth becomes a habit.

---

## Who it's for

**Primary:** Christians who study seriously — small-group leaders, pastors, teachers, and people preparing sermons or lessons.

**Secondary:** motivated readers who want to go deeper than their current Bible app allows, and who are *not* trained in Hebrew or Greek.

The unifying trait: high motivation, mobile-first, and no assumption of original-language training. The product had to make depth feel approachable, not academic.

---

## The core idea: from a reader's question to the right tool

The product's organizing insight is that deep study isn't a feature list — it's a sequence of natural questions a reader already has. The entire interface is designed to map each question to the one tool that answers it.

| A reader's question | The tool that answers it |
|---|---|
| What else does the Bible say about this? | **Cross-references** (*Кроспосилання*) |
| Why do translations differ here? | **Translation comparison** (*Порівняння перекладів*) |
| What word is in the original? | **Lexicon** (*Лексикон*) |
| What does this word mean? | **Word meaning** (*Значення слова*) |
| Why does it take this particular form? | **Morphology** (*Морфологія*) |
| How is it connected to the other words in the sentence? | **Syntax** (*Синтаксис*) |
| How is this word used elsewhere in Scripture? | **Usage / concordance** (*Вживання*) |

This table *is* the product. Every feature exists because a reader asked a real question — and design's job was to make the answer feel like a natural next step, not a detour into a separate app.

---

## The approach

### 1. Frame the product as two study modes, not a pile of features

Rather than ship a toolbar of disconnected utilities, I split study into two complementary modes that mirror how people actually think:

- **Verse mode** — contextual understanding: cross-references, parallel passages, translation comparison, and commentary from theologians across the centuries.
- **Word mode** — original-language exploration: the Hebrew/Greek word, its meaning and semantic range, morphology, and every other place it appears in Scripture.

Modes are switched with explicit tabs, so the reader always knows which lens they're looking through. Clarity over cleverness.

### 2. Make the original language the linking system, not a feature

Under the hood, **Strong's numbers** act as the connective tissue of the entire app. Every meaningful word in the text is tagged, so tapping a word can pull its definition, its grammar, and a concordance of every other occurrence — all from the same identifier. The "bridge" in the slogan is literal: it's the data model.

### 3. Design for continuity — never lose your place

The whole study experience happens in a **bottom sheet** that expands over the page you're reading. You can move verse-to-verse, jump into a word, follow a cross-reference, explore a concordance — and when you dismiss the sheet, you're back exactly where you started. No full-screen takeovers, no losing context. The reading position is sacred.

### 4. Progressive disclosure — approachable first, deep on demand

Word mode opens with the essentials: the word, a short definition, its grammar. "Detailed" reveals the full semantic range. The concordance stays collapsed until you want it. A beginner sees something they can understand; an expert is one tap from everything. The same screen serves both.

---

## The solution, in the reader's hands

A typical study flow that the design makes effortless:

1. Open to your last passage.
2. Tap a verse → the study sheet opens in **Verse mode**, showing cross-references, other translations, the original, and commentary.
3. Curious about one word → tap it → the sheet switches to **Word mode**, highlighting that word in the verse above.
4. Read its meaning, see its grammar, then open **Usage** to see everywhere else it appears.
5. Tap one of those occurrences → jump to that verse with the same word highlighted.
6. Dismiss → back to your original verse, exactly where you left it.

Six moves, one continuous thread, zero app-switching. That continuity is the entire point.

---

## Building it: a designer shipping a deep product with AI

This is the part I'm proudest of. SourceBible is a genuinely data-heavy product — it's not a CRUD app with a nice skin. It runs on a bundled SQLite database that fuses several scholarly datasets: original-language text with morphology, the Strong's lexicon, multiple translations, cross-references, public-domain commentary, and a verse-numbering map that reconciles the differences between the original text and modern translations (the Psalms alone shift numbering across hundreds of chapters).

As a product designer and owner — not a career engineer — I shipped this by treating **AI-assisted development as a real part of the team**, and by being disciplined about how I worked:

- **Design and product decisions stayed mine.** The interaction model, the question→tool mapping, the progressive-disclosure choices — those came from product thinking, not the tooling.
- **AI handled implementation depth I couldn't have reached alone** — SwiftUI under strict concurrency, the database build pipeline, and the gnarly edge cases (verse-numbering offsets, transliteration rules, morphology decoding).
- **I kept rigorous documentation as the source of truth.** Every significant decision is captured as an Architecture Decision Record (ADR), a spec, or a product-decision record, with a single index read at the start of every working session. That documentation discipline is what let a solo build stay coherent across dozens of interlocking decisions — and what let an AI collaborator stay on-rails instead of drifting.

The takeaway: a strong product designer with the right process and AI leverage can ship something that used to require a full team — *if* the thinking, the structure, and the guardrails are theirs.

---

## What I'd highlight as a designer

- **A clear product thesis** (reading → understanding) that drove every screen, instead of a feature checklist.
- **An interaction model designed around real user questions**, made tangible in the question→tool mapping.
- **Continuity as a first-class constraint** — the bottom-sheet study flow that never loses your place.
- **Progressive disclosure** that lets one interface serve both a curious beginner and a trained teacher.
- **Operating as product owner end-to-end** — from problem framing and metrics definition to shipping a technically deep iOS app via AI-assisted development.

---

## Honest reflection

The product is built and in testing, not yet publicly launched, so this case study is deliberately light on adoption numbers — I'd rather show the thinking than invent metrics. The success criteria I set are behavioral: do people actually move from reading into *connected* study (verse → word → meaning → usage), and does original-language study become a habit rather than a novelty? Those are the questions the next phase answers.

If I were starting again, the biggest lesson is how much of "shipping deep, solo" comes down to documentation discipline. The product design was the fun part; the structure around it — specs, decision records, a single index — is what actually made the build survivable.

---

# Appendix — Landing-page-ready blocks

*Lift these straight onto the marketing site. Each block is written to stand alone.*

## Hero

**Headline:** Bridge the gap between modern readers and the world of the biblical text.

**Subheadline:** SourceBible puts the original Hebrew and Greek, the lexicon, cross-references, and centuries of commentary one tap away from any verse — without ever making you leave the page you're reading.

**Primary CTA:** Start studying free
**Secondary CTA:** See how it works

---

## The problem (short)

Most Bible apps are built for reading. The moment you get curious — *what's the real word here? why do translations disagree? where else does this appear?* — you're stuck juggling apps, losing your place, and decoding raw data. Real study shouldn't cost that much friction.

---

## Value propositions (3–4 blocks)

**Reading, meet understanding.**
Tap any verse to open the original language, the meaning behind the word, and how it's used across all of Scripture — in one continuous flow.

**One tap, never lost.**
Every tool lives in a study sheet that opens over your page. Explore as deep as you want; dismiss it and you're back exactly where you started.

**The original language, made approachable.**
Strong's-linked Hebrew and Greek with clear definitions, grammar, and usage — designed for curious readers, not just scholars.

**Depth on your terms.**
A simple overview first, the full semantic range and concordance when you want them. Approachable for beginners, complete for teachers.

---

## Feature grid (question → tool)

Built around the questions you already ask while you read:

- **What else does the Bible say about this?** → Cross-references
- **Why do translations differ here?** → Translation comparison
- **What word is in the original?** → Lexicon
- **What does this word mean?** → Word meaning
- **Why does it take this form?** → Morphology
- **How does it connect in the sentence?** → Syntax
- **Where else is this word used?** → Usage across Scripture

---

## How it works (3 steps)

1. **Read.** Open to your passage like any Bible app.
2. **Tap.** Tap a verse for context, or a word for its original-language meaning.
3. **Go deeper.** Follow cross-references and usage as far as your curiosity takes you — then return to your verse, right where you left it.

---

## Closing CTA

**Stop reading past the depth.** Start understanding Scripture in its original words — free.
**[ Start studying free ]**

---

## Boilerplate (for press / footer / about)

SourceBible is a mobile Bible-study app that bridges the gap between modern readers and the original biblical text. By linking every verse to its Hebrew and Greek source, a clear lexicon, cross-references, and historic commentary — all in one uninterrupted flow — SourceBible turns passive reading into genuine understanding.
