# Project Context — Source Bible App

## What is this?

Source is a mobile-first Bible study application designed to help users deeply understand Scripture through structured exploration of verses and original words.

It combines verse-level and word-level study into a unified experience, allowing users to seamlessly move from reading to interpretation using Strong’s-based data and contextual insights.

---

## Problem we're solving

Most Bible apps are optimized for reading, not for understanding.

Users who want to study Scripture deeply face several problems:
- lack of connection between translation and original language
- fragmented tools (lexicon, concordance, commentaries are disconnected)
- high friction in accessing deeper insights
- overwhelming or poorly structured information

As a result, deep Bible study requires multiple tools, significant effort, and prior knowledge.

Source solves this by:
- unifying study tools into one interaction model
- making original language accessible
- reducing friction between reading and understanding

---

## Target audience

### Primary audience:
- Christians engaged in serious Bible study
- small group leaders, pastors, teachers
- users preparing sermons or teachings

### Secondary audience:
- motivated beginners who want deeper understanding
- users transitioning from basic Bible apps

### Characteristics:
- age: 20–50+
- medium to high motivation for study
- not necessarily trained in Hebrew/Greek
- mobile-first usage (daily reading + study)

---

## Core Concept

The product is built around two complementary study modes:

- Verse mode → contextual understanding (cross-references, commentary, parallels)
- Word mode → original language exploration (Strong’s, meaning, usage)

These modes are explicitly controlled via UI (tabs), ensuring clarity and discoverability.

Strong’s numbers serve as a core linking system, connecting all layers of study into a unified experience.

---

## Key features (v1)

- Verse-level study tools:
  - cross-references
  - parallel passages
  - translations comparison
  - commentaries (basic layer)

- Word-level study:
  - Strong’s numbers
  - lexical meaning
  - semantic range
  - morphology
  - concordance usage

- Unified interaction model:
  - Verse / Word mode switching via tabs
  - bottom sheet for contextual exploration

- Strong’s-based navigation:
  - consistent linking between verse and word data
  - ability to move across meanings and usages

- Progressive disclosure:
  - simple overview → deeper study layers

- Study flow continuity:
  - seamless transition between verse and word exploration
  - ability to drill down into deeper insights without losing context

- Structured information layers:
  - overview → detailed lexical data → usage across Scripture

---

## Out of scope (v1)

- RAG based AI commentary
- social features (sharing, community discussions)
- Cotext tab: Historical context, Cultural context, Geographical context, Author context, Literary context, Actors
- advanced note-taking systems
- desktop-first experience

---

## Platform

- Mobile-first application
  - iOS (priority)
  - Android (planned)

- Tech stack:
  - React Native (cross-platform)
  - backend with API-driven architecture
  - scalable data model for Bible + lexical data

---

## Current status

- High-fidelity UI prototype completed
- User flows defined and reviewed
- Initial backend architecture drafted
- Product structure and interaction model defined

Next step:
→ BRD finalization → MVP development

---

## Team

- Product Designer / Product Owner:
  - responsible for product vision, UX, and system design

- AI-assisted development:
  - used for backend, architecture, and implementation support

Future roles (planned):
- backend engineer
- mobile developer

## Links
- Figma Pitch Deck: https://www.figma.com/deck/GN1fVigfMEUeiF7rFCw3Al
- Figma UX Board: https://www.figma.com/board/30PODxCPCrWUFK4MHoE3pi/Source-Bible-UX
