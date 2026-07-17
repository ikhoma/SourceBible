# Sources & facts (SourceBible Calvin pipeline)

## MyBible modules (data/New/)
- `Кальвин-к.commentaries.SQLite3` — RU Calvin (source). Table `commentaries(book_number,
  chapter_number_from, verse_number_from, chapter_number_to, verse_number_to, text)`. Text is HTML.
- `Calvin-c.commentaries.SQLite3` — EN Calvin (QA). Same schema.
- `Calvin-c.commentaries.PATCHED.SQLite3` — EN with Genesis rebuilt 1–50 from SWORD.
- `../CalvinCommentaries.zip` — SWORD zCom EN (full 22-vol). Read without pysword:
  parse `ot/nt.bzs` (12B `<III` block index), `.bzv` (10B `<IIH` verse index), zlib blocks in `.bzz`;
  Genesis verse slot = chap_head[c]+v+1.

## Book numbers = identify by CONTENT (non-standard numbering)
OT: 10 Genesis, 230 Psalms, 300 Jeremiah.
NT (this module's order): 500 John, 510 Acts, 520 Romans, 530 1 Cor, 540 2 Cor, 550 Galatians,
560 Ephesians, 570 Philippians, 580 Colossians, 590 1 Thess, 600 2 Thess, 610 1 Tim, 620 2 Tim,
630 Titus, 640 Philemon, 650 Hebrews, 660 James, 670 1 Peter, 680 2 Peter, 690 1 John, 720 Jude.

## RU coverage
21 NT books (all complete) + partial OT (Gen 15/17, Ps 19/50, Jer). Missing: Synoptics (Harmony),
2–3 John, Revelation (last two Calvin never wrote). Synoptic Harmony exists EN-only (Matt/Mark/Luke
in Calvin-c, cross-referenced) — a separate, weaker EN→UK effort.

## EN gaps observed
Genesis 10–30 were missing/truncated (now patched). John 6 missing in Calvin-c. Check per book.

## Conventions
- Divine name: EN Jehovah/LORD → RU Господь/Иегова → UK «Ягве».
- Psalm 50 (RU/Synodal) = Psalm 51 (Heb/KJV/EN).
- EN never goes to the model; RU→UK only. EN is anchor + uniform QA.
