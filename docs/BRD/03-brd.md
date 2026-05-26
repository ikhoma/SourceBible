# BRD — Source Bible App (v1 MVP)

## Document info

- Status: draft
- Last updated: 2026-04-12
- Scope: MVP (iOS, React Native)
- Author: Ivan Khoma

---

## Overview

Source is a mobile Bible study app built around two complementary modes — Verse and Word — unified through a single interaction model. The core experience allows users to move seamlessly from reading a verse to exploring its original language meaning without switching apps or losing context.

---

## Interaction model

The app is structured around a bottom sheet exploration layer that expands on top of the main reading view.

Flow:
1. User opens app → Reader shows last viewed passage
2. User taps a verse → bottom sheet opens in **Verse mode**
3. User navigates between verses using `< >` arrows in the bottom sheet header
4. User taps a word → bottom sheet switches to **Word mode**
5. User navigates between words using `< >` arrows in Word mode
6. User can navigate deeper (concordance, cross-refs) without leaving the sheet
7. User dismisses sheet → returns to exact reading position

Modes are switched via explicit tabs (Вірш / Слово) inside the bottom sheet.

---

## Navigation structure

Bottom navigation (persistent):
- **Bible** — Reader (default tab)
- **Entries** — Notes + Bookmarks (two tabs within)
- **Menu** — Settings and other options

Header (contextual, in Reader):
- Book / Chapter dropdown → opens Book/Chapter picker
- Translation dropdown → opens Translation picker
- 🔍 Search icon → opens Search modal

---

## Feature specs

---

### F-01 — Bible Reader

**Description:**
Main reading view. Displays chapters and verses in a clean, readable format.

**Acceptance criteria:**
- [ ] App opens to last viewed passage by default
- [ ] User can read any book/chapter of the Bible
- [ ] Tapping a verse highlights it and opens the bottom sheet
- [ ] Tapping a word inside the verse opens bottom sheet in Word mode
- [ ] Navigation between chapters via swipe or button
- [ ] Font size adjustable
- [ ] Default translation configurable
- [ ] Verse numbers displayed inline
- [ ] Highlighted verses shown in green in the reader

**Out of scope:**
- Multiple translation columns side by side
- Audio playback
- Offline mode (v1)

---

### F-02 — Verse Mode (bottom sheet)

**Description:**
Contextual study layer for a selected verse. Organised into four pill-based sections.

**Acceptance criteria:**
- [ ] Opens automatically when a verse is tapped
- [ ] Header shows active verse reference (e.g. "Псалом 1:1")
- [ ] Header has `< >` arrows to navigate to previous/next verse without closing sheet
- [ ] Four pill-based sections:
  - **Паралельні** — cross-references to related verses across Scripture
  - **Переклади** — same verse in multiple translations (Огієнко, Турконяк, KJV, ASV, etc.)
  - **Оригінал** — Hebrew/Greek words with Strong's numbers, grammar, and definitions
  - **Коментарі** — list of theologians with commentary
- [ ] Each cross-reference is tappable (loads that verse in the sheet)
- [ ] Tab labeled "Вірш", active by default

**Data sources:**
- Cross-references: Open Bible cross-reference dataset or similar
- Translations: Grom, Огієнко, Турконяк, KJV, ASV (API or local)
- Commentary: Жан Кальвін (XVI), Меттью Генрі (XVIII), Чарльз Сперджен (XIX) — public domain

**Empty states:**
- No cross-references: "Перехресні посилання не знайдені"
- No commentary: "Коментар недоступний для цього вірша"

**Error state:** "Не вдалось завантажити дані вірша. Спробуйте ще раз."

---

### F-03 — Commentary Detail

**Description:**
Full commentary text for a selected theologian. Opens from the Коментарі pill in Verse mode.

**Acceptance criteria:**
- [ ] List shows theologians with portrait, era, and style:
  - Жан Кальвін — XVI ст. · Текст і богослов'я
  - Меттью Генрі — XVIII ст. · Серце і застосування
  - Чарльз Сперджен — XIX ст. · Проповідь і образи
- [ ] Tapping a theologian → opens full commentary text
- [ ] Back navigation returns to Verse mode

**Empty state:** "Коментар для цього вірша недоступний"

---

### F-04 — Word Mode (bottom sheet)

**Description:**
Original language exploration for any word in a verse. Core differentiator of the product.

**Acceptance criteria:**
- [ ] Activates when user taps a word in the verse, or switches to "Слово" tab
- [ ] First word of verse highlighted by default when tab is opened without a word tap
- [ ] `< >` arrows to navigate between words in the verse
- [ ] Tapped/active word highlighted in the verse text above the sheet
- [ ] **Sub-tab "Значення":**
  - Strong's number and original word (e.g. אֶשֶׁר 835)
  - Semantic range (3–5 key nuances)
  - Lexical data: part of speech, transliteration, pronunciation
  - "Детальніше" button → full lexical entry
- [ ] **Sub-tab "Вживання":**
  - Concordance — all occurrences of this word in Scripture
  - Each occurrence tappable → loads that verse in Reader + highlights same word
- [ ] Tab labeled "Слово"

**Data sources:**
- Strong's Exhaustive Concordance (public domain)
- Hebrew: BDB lexicon (OT)
- Greek: Thayer's / BDAG summary (NT)
- Morphology: OpenScriptures Hebrew Bible, SBLGNT

**Empty states:**
- Word not tagged (articles, conjunctions): "Дані оригінальної мови недоступні для цього слова"
- No concordance results: "Інших входжень не знайдено"

**Error state:** "Не вдалось завантажити дані слова. Спробуйте ще раз."

**Out of scope:**
- Full parsing tables
- Audio pronunciation
- Root word trees / etymology diagrams

---

### F-05 — Strong's-based navigation

**Description:**
Strong's numbers serve as the linking system across the entire app.

**Acceptance criteria:**
- [ ] Every content word in the Bible text is tagged with a Strong's number
- [ ] Strong's number displayed as a label (e.g. G3056)
- [ ] Concordance list generated from the Strong's number
- [ ] Navigating a concordance verse preserves the Strong's context (same word highlighted in that verse)

---

### F-06 — Study flow continuity

**Description:**
Users can move through study layers without losing their place or context.

**Acceptance criteria:**
- [ ] Bottom sheet has back navigation within the study session
- [ ] User can return to origin verse after exploring cross-refs or concordance
- [ ] Switching Вірш ↔ Слово tab preserves the current verse selection
- [ ] Closing the bottom sheet returns user to the exact reading position
- [ ] All study navigation stays within the bottom sheet (no full-screen takeovers)

---

### F-07 — Progressive disclosure

**Description:**
Information is revealed in layers — simple overview first, deeper data on demand.

**Acceptance criteria:**
- [ ] Word mode default: Strong's number + short definition + morphology
- [ ] "Детальніше" reveals full semantic range
- [ ] Concordance collapsed by default, expandable
- [ ] Commentary shows theologian list first, full text on tap
- [ ] No information overload on first open — primary data visible without scrolling

---

### F-08 — Highlight a Verse

**Description:**
User can mark a verse with a green highlight for future reference.

**Acceptance criteria:**
- [ ] "Відмітити" button in bottom action bar of bottom sheet
- [ ] One tap applies green highlight to the verse instantly (toggle)
- [ ] Highlighted state is visible in the Reader
- [ ] Second tap removes the highlight (toggle off)
- [ ] State saved automatically, no confirmation required

---

### F-09 — Entries: Notes

**Description:**
User can create text notes attached to one or more verses, organized in folders.

**Entry points:**
- "Нотатка" button in bottom action bar of bottom sheet
- "Entries" tab in bottom nav → Notes tab → "+" button → "Create note"

**Note card (in list):**
- Verse reference + translation (e.g. "Бут 1:3 (GROM)") + date
- Verse quote (the attached verse text)
- Note text written by user
- ↗ arrow → navigates to that verse in Reader
- ✏️ pencil → opens note editor

**Creating a note:**
- [ ] "+ Add verses" — user selects one or more verses to attach to the note
- [ ] Folder picker — "No folder" default, expandable dropdown
- [ ] "Create folder" available inline within folder picker
- [ ] Text area with placeholder "What do you think about this verse?"
- [ ] "SAVE" button — active once text or verse is added
- [ ] Note saved and appears in the list

**Folder management:**
- [ ] Folders created via "Create folder" → name input + Save
- [ ] "Field cannot be empty" validation on folder name
- [ ] Notes organized under folder sections in the list

**Acceptance criteria:**
- [ ] Notes list accessible via Entries → Notes tab
- [ ] Note can exist without a verse attachment (standalone)
- [ ] Note can have one or more verses attached
- [ ] Tapping ↗ on note card → navigates to the verse in Reader
- [ ] Tapping ✏️ on note card → opens editor
- [ ] "+" in header → opens create menu (Create note / Create folder / Create bookmark / Create category)

**Empty state:** "No notes yet"

---

### F-10 — Entries: Bookmarks

**Description:**
User can bookmark specific verses, organized in categories with color labels.

**Entry points:**
- "Entries" tab in bottom nav → Bookmarks tab → "+" button → "Create bookmark"

**Bookmark card (in list):**
- Verse reference + translation (e.g. "Бут 3:15 (GROM)") + date
- Red bookmark icon
- Full verse text
- ↗ arrow → navigates to that verse in Reader
- ✏️ pencil → opens bookmark editor

**Creating a bookmark:**
- [ ] "+ Add verses" — user selects one or more verses to bookmark
- [ ] Category picker — "No category" default, list of existing categories
- [ ] "Create category" available inline
- [ ] "SAVE" button — active only when at least one verse is selected (greyed out otherwise)

**Category management:**
- [ ] Categories created via "Create category" → name input + color picker
- [ ] Color picker: 9 muted color options
- [ ] "Field cannot be empty" validation on category name
- [ ] Bookmarks organized under category sections in the list

**Acceptance criteria:**
- [ ] Bookmarks list accessible via Entries → Bookmarks tab
- [ ] Bookmark must have at least one verse (SAVE disabled without verse)
- [ ] Categories are color-coded and visible in bookmark list
- [ ] Tapping ↗ on bookmark card → navigates to verse in Reader
- [ ] Tapping ✏️ on bookmark card → opens editor

**Empty state:** "No bookmarks yet"

---

### F-11 — Keyword Search

**Description:**
Full-text search across all Bible verses by word or phrase.

**Acceptance criteria:**
- [ ] 🔍 icon in header (accessible from any screen) → opens Search modal
- [ ] Active tab: "За словом"
- [ ] Search triggers automatically after each character input
- [ ] Results: list of verses with the keyword highlighted in yellow
- [ ] Each result shows verse reference (Book + Chapter:Verse)
- [ ] Tapping a result → modal closes, Reader scrolls to verse (highlighted in blue), bottom sheet opens

**Empty state:** "Нічого не знайдено — продовжіть введення"

**Technical note:** Case-sensitive / exact word form match. Stem-based search not supported in v1.

---

### F-12 — Smart Search (AI-powered)

**Description:**
Semantic search using AI — finds verses by topic, idea, or natural-language question.

**Acceptance criteria:**
- [ ] Second tab in Search modal: "Розумний пошук"
- [ ] Text input: natural language query (e.g. "Де говориться про успіх?")
- [ ] Voice input: 🎤 button → dictate query
- [ ] Submit button → triggers AI processing
- [ ] Loading state: skeleton cards while processing
- [ ] Results:
  - **AI ВІДПОВІДЬ** — blue card with AI-generated answer to the question
  - **ЗНАЙДЕНІ ВІРШІ** — semantically relevant verses
- [ ] Tapping a verse → modal closes, Reader navigates to verse, bottom sheet opens

**Empty state:** "Спробуйте поставити питання інакше"
**Error state:** "Не вдалось виконати пошук. Перевірте з'єднання."

---

### F-13 — Navigation (Book / Chapter / Translation)

**Description:**
User can navigate to any book, chapter, or switch translation from the reader.

**Acceptance criteria:**
- [ ] Tapping "Book + Chapter" dropdown in header → opens Book/Chapter picker modal
- [ ] Picker: two-step — select Book (OT / NT grouped) → select Chapter
- [ ] Search field for book name in picker
- [ ] Tapping "Translation" dropdown → opens translation list (Grom, Огієнко, Турконяк, KJV, ASV, etc.)
- [ ] Selecting translation → Reader reloads with new translation
- [ ] Both pickers dismissible by tapping outside

---

### F-14 — Settings

**Description:**
User preferences for reading environment.

**Acceptance criteria:**
- [ ] Font size / style — live preview updates as user adjusts
- [ ] Theme — Light / Dark / System
- [ ] Default translation — applies to new sessions
- [ ] UI language
- [ ] All settings saved automatically, applied immediately app-wide

---

## Data architecture (high level)

```
Bible text (tagged)
  └── verse
        └── word → Strong's ID
                      ├── lexical entry (definition, semantic range)
                      ├── morphology tag
                      └── concordance index (all verses with same ID)

Verse metadata
  ├── cross-references
  ├── parallel passages
  ├── translation variants
  └── commentary (per theologian)

User data
  ├── highlights (verse ID → color)
  ├── bookmarks (chapter reference)
  └── notes (verse ID or standalone → text)
```

**Key requirement:** Strong's ID is the primary foreign key linking text → lexicon → concordance.

---

## Non-functional requirements

- App launch → readable content in < 2 seconds
- Bottom sheet open → < 300ms
- Word tap → Word mode data visible in < 500ms
- Search results → first results in < 1 second (keyword), < 3 seconds (AI)
- Works on iOS 15+
- React Native (Expo or bare workflow — TBD)
- Offline: not required for v1, but data model should support it later

---

## Open questions

- [ ] Bible text API vs local SQLite? (affects offline capability and licensing)
- [ ] Which commentary source for v1? (licensing for Кальвін / Генрі / Сперджен in Ukrainian?)
- [ ] Expo or bare React Native workflow?
- [ ] Authentication in v1? (needed for notes/highlights/bookmarks sync across devices)
- [ ] Analytics SDK?
- [ ] AI search: in-house model or third-party API (e.g. OpenAI embeddings)?

---

## Out of scope (v1)

- RAG-based AI commentary generation (Smart Search is in scope; generated theological commentary is not)
- Social features (sharing, community discussions)
- Context tab (Historical, Cultural, Geographical, Author, Literary context)
- Advanced note-taking (formatting, tags, folders)
- Desktop / web version
- Audio Bible
- Android (planned post-iOS launch)
