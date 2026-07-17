---
name: calvin-ru-uk
description: Build a per-book translation kit for John Calvin's Bible commentary, Russian→Ukrainian (English as QA anchor only). Use when the user says "«переклади Кальвіна на книгу»", "«зроби кит для книги»", "translate Calvin commentary", grow the trilingual glossary, run EN↔RU verification, or lint UK for Russianisms. Targets a local Gemma model.
---

# Calvin commentary RU→UK translation kit

Codifies the SourceBible workflow for translating Calvin's NT commentary into Ukrainian.
**Russian is the source** (good published translation; close-language transposition beats EN→UK).
**English is anchor + QA only — never fed to the model.** Glossary is a living term base that
grows book-by-book and must stay consistent across the whole NT.

## Sources (MyBible SQLite, in `data/New/`)
- RU: `Кальвин-к.commentaries.SQLite3` — human Russian Calvin (pivot/source).
- EN: `Calvin-c.commentaries.SQLite3` — English Calvin (QA anchor). Patched EN Genesis exists as
  `Calvin-c.commentaries.PATCHED.SQLite3`. SWORD `CalvinCommentaries.zip` = fallback for EN gaps.
- Read `reference/sources.md` for book-number map (NON-standard — identify by content), coverage,
  and known gaps.

## Hard facts to respect
- Book numbers in these modules are NOT standard MyBible; verify a book by its text, not its number
  (see reference/sources.md). John=500, Acts=510, Romans=520, 1Cor=530 …
- RU covers 21 NT books (John, Acts, 13 Pauline, Hebrews, James, 1–2 Peter, 1 John, Jude) — all complete.
  **Synoptics (Matthew/Mark/Luke) are NOT in RU** — they exist only as Calvin's Harmony, EN-only.
- EN module has chapter gaps (e.g. John 6, parts of Genesis). If EN QA for a chapter is missing,
  note it; RU stays the source. Patch from SWORD if EN is truly needed.
- Psalm numbering: RU/Synodal Ps50 = Hebrew/KJV Ps51 (Miserere).

## Workflow (per book)
1. **Extract** RU (source) + EN (QA) per verse → `scripts/extract_book.py <book_number>`
   writes `source_texts/<Book>_RU.txt` and `<Book>_EN.txt` (`[ch:v]` per line, all chapters).
2. **Grow the glossary** (`calvin_nt_glossary.json`, living master):
   - Mine signature terms from the book's RU text (proper names + theological/technical terms).
   - For every term fill **all three** columns EN | RU | UK (no selective EN — always anchor).
     EN comes from the verse-aligned EN module; RU verbatim from RU text; UK = target.
   - Fields per term: `ru,uk,source("ru"|"en"),chapters,category,type,note,added`.
   - UK = anti-interference: no Russianisms/calques; apply `false_friends`; proper names in Ukrainian
     forms (Іван Хреститель, Ізмаїл, Єрусалим, Сіон, Утішитель…). Divine name → «Ягве».
3. **Verify uniformly (EN↔RU):** for every term check the RU rendering against the aligned EN;
   flag drift for the reviewer (don't decide per-term whether to check — check all).
4. **Lint UK** for Russianisms (suffix -ость/-ение, false friends, рос. proper forms). Must be 0 flags.
5. **Assemble kit** → zip:
   - `prompt_<Book>_RU-UK.md` — Gemma prompt (RU→UK), chat template, temp 0.2, per-verse.
     - MUST-HAVE rule in the prompt: keep Greek/Hebrew/Latin words VERBATIM (same script), no transliteration, no LaTeX/`$...$`/`\cmd` — translate only surrounding explanation. (Gemma turned Greek into LaTeX otherwise.)
   - `glossary_inject_RU-UK.txt` — RU→UK lines (+false_friends, book names, divine name). Goes IN the model.
   - `calvin_nt_glossary.json` — trilingual master (reviewer/QA, NOT in model).
   - `source_texts/<Book>_RU.txt` (source) + `<Book>_EN.txt` (QA).
   - `READ_ME_FIRST.txt`.
6. Ask output format `[ch:v] <UK>` so results collate against the source for reviewers.

## Model
Local **Gemma (гемма4 31B)**. No system role — put everything in one user turn. RU→UK only.

## TUNABLE KNOBS (edit these as we learn)
- **Glossary** `calvin_nt_glossary.json` — the living asset; add/fix terms every book.
- **`false_friends`** list — extend when the model produces new calques.
- **Prompt wording** in `prompt_*` — tighten rules the model violates.
- **Model params** (temperature, penalties) — adjust if output drifts or repeats.
- **Term-mining candidate lists** in step 2 — expand per book's distinctive vocabulary.
- **Divine-name / numbering / proper-name conventions** — one place, applied everywhere.

## Deliver
Zip the kit; also keep the updated `calvin_nt_glossary.json` in `data/`. Present the zip.
