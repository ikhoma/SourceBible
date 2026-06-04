# PDR: Book Cover Design — Doré Engravings with Canonical Metadata

**Status:** Accepted  
**Date:** 2026-06-02

## Decision

Book covers feature Gustave Doré engravings on a blue background with two metadata elements shown as small text:

1. **Canonical section** (Protestant groupings) — displayed as a tag
2. **Chapter count** — e.g. "9 CHAPTERS"

Format: `SECTION · N CHAPTERS` as a single centered line.

## Protestant Canonical Sections

| Section | Books |
|---|---|
| THE LAW | Genesis, Exodus, Leviticus, Numbers, Deuteronomy |
| HISTORICAL BOOKS | Joshua, Judges, Ruth, 1–2 Samuel, 1–2 Kings, 1–2 Chronicles, Ezra, Nehemiah, Esther |
| POETRY & WISDOM | Job, Psalms, Proverbs, Ecclesiastes, Song of Solomon |
| MAJOR PROPHETS | Isaiah, Jeremiah, Lamentations, Ezekiel, Daniel |
| MINOR PROPHETS | Hosea, Joel, Amos, Obadiah, Jonah, Micah, Nahum, Habakkuk, Zephaniah, Haggai, Zechariah, Malachi |
| THE GOSPELS | Matthew, Mark, Luke, John |
| ACTS | Acts |
| PAUL'S LETTERS | Romans, 1–2 Corinthians, Galatians, Ephesians, Philippians, Colossians, 1–2 Thessalonians, 1–2 Timothy, Titus, Philemon |
| GENERAL LETTERS | Hebrews, James, 1–2 Peter, 1–2–3 John, Jude |
| PROPHECY | Revelation |

## Rationale

- Section labels double as wayfinding: the browse flow (All → OT/NT → canonical section filter) uses the same vocabulary, so the cover tag reads as a breadcrumb
- Chapter count is universally meaningful, gives every book non-empty metadata (including short books like Amos — 9 chapters), and follows a classical table-of-contents convention
- Protestant groupings chosen over Hebrew canon (Torah/Nevi'im/Ketuvim) for lower friction in the browse flow; target users are more familiar with this system

## Supersedes / Related

- Visual design: Doré engravings on blue background (established in design exploration, 2026-06-02)
- Psalms covers may additionally show subdivision info (Book 1 / Psalms 1–41) as a secondary element alongside the standard format
