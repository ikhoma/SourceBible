#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Invariants for the full-text search index built in scripts/build_db.py (bug-035).

What broke
----------
`build_verse_fts()` indexed the RAW `verse.text`, which deliberately keeps inline
markup for the app parser (`<S>1234</S>`, `<J>`, `<i>`). FTS5's `unicode61`
tokenizer knows nothing about XML, so `<S>6757</S>` entered the index as three
tokens — `S | 6757 | S` — sitting BETWEEN two real words. Since
`DatabaseService.makeFTSQuery()` sends every query as a quoted phrase
(`"смертной тени"*`), and a phrase requires adjacent tokens, every multi-word
search returned nothing. A one-word query is a one-token phrase and needs no
neighbour, which is exactly why the bug read as "multi-word search is broken"
instead of "search is broken".

`test_phrase_across_strongs_markup` and `test_phrase_across_semantic_tag` are the
pair that matters: both fail on the pre-fix code (index over `text`) and pass on
the fixed one (index over `text_clean`). `test_control_phrase_wrong_order_misses`
guards the opposite error — a "fix" that drops adjacency (e.g. rewriting the query
builder to `NEAR(...)`) would make search match word salad, and would pass every
other test here.

Data
----
Inline, not a fixture file: one clause of Ps 22:4 in the Russian Synodal text
(public domain, 1876) carrying its real `<S>` markup, plus synthetic strings for
the tag shapes. Two-word phrases throughout — a single-word anchor passes on the
BROKEN index and proves nothing.

No network, no database. `sourcebible.db` is never opened.
"""

import importlib.util
import sqlite3
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("build_db", SCRIPTS / "build_db.py")
build_db = importlib.util.module_from_spec(_spec)
sys.modules["build_db"] = build_db
_spec.loader.exec_module(build_db)

_search_text = build_db._search_text

# Ps 22:4 (RST numbering) as the module stores it — Strong's tags between words.
RAW_RST = ("Если я пойду<S>3212</S> и долиною<S>1516</S> смертной<S>6757</S> "
           "тени,<S>6757</S> не убоюсь<S>3372</S> зла,<S>7451</S> потому что Ты со мной")


def fts_over(column, rows):
    """In-memory replica of build_verse_fts(): same tokenizer, same external content.

    `column` selects which column the index is built over — 'text' reproduces the
    broken build, 'text_clean' the fixed one, so a single test can assert both.
    """
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE verse(rowid INTEGER PRIMARY KEY, text TEXT, text_clean TEXT)")
    con.executemany("INSERT INTO verse VALUES (?,?,?)",
                    [(i + 1, r, _search_text(r)) for i, r in enumerate(rows)])
    con.execute(f"CREATE VIRTUAL TABLE fts USING fts5({column}, content='verse', "
                "content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')")
    con.execute("INSERT INTO fts(fts) VALUES('rebuild')")
    return con


def hits(con, phrase):
    """Count matches the way the app asks for them — makeFTSQuery()'s quoted phrase + star."""
    expr = '"%s"*' % phrase.replace('"', '""')
    (n,) = con.execute("SELECT COUNT(*) FROM fts WHERE fts MATCH ?", (expr,)).fetchone()
    return n


class SearchTextStripping(unittest.TestCase):

    def test_strongs_number_removed_with_its_tag(self):
        # Stripping only the tags would leave "1516" as a searchable word — that is
        # how 25.3% of RST's autocomplete terms became pure numbers.
        out = _search_text("долиною<S>1516</S> смертной<S>6757</S> тени")
        self.assertEqual(out, "долиною смертной тени")
        self.assertNotIn("1516", out)

    def test_lettered_strongs_suffix_removed(self):
        # H871a-style sub-entry IDs appear in the modules too.
        self.assertEqual(_search_text("word<S>871a</S> next"), "word next")

    def test_semantic_tag_stripped_content_kept(self):
        self.assertEqual(_search_text("и сказал <J>Я есмь</J> путь"), "и сказал Я есмь путь")

    def test_line_break_becomes_space_not_nothing(self):
        # <br/> must not fuse the words on either side into one token.
        self.assertEqual(_search_text("первое<br/>второе"), "первое второе")

    def test_translator_note_content_survives(self):
        self.assertEqual(_search_text("он <n>то есть Давид</n> сказал"),
                         "он (то есть Давид) сказал")

    def test_no_digits_left_for_the_word_list(self):
        # Guards build_search_terms(), which tokenizes this output.
        self.assertFalse(any(c.isdigit() for c in _search_text(RAW_RST)))

    def test_multi_number_strongs_tag_removed(self):
        # Would FAIL before 2026-08-07: the pattern was `<S>\d+[a-z]?</S>`, so a tag
        # holding two numbers never matched, fell through to the generic tag strip, and
        # left the digits as TEXT welded to the previous word:
        #     "save1487, 3361 Crispus"
        # Real shape, from ASV 1Co 1:14 — 1 115 such tags across ASV/NASB.
        out = _search_text("save<S>1487, 3361</S> Crispus and Gaius")
        self.assertEqual(out, "save Crispus and Gaius")
        self.assertFalse(any(c.isdigit() for c in out))

    def test_mixed_content_strongs_tag_removed(self):
        # Same corner, uglier data: the S element is not always digits at all.
        # Real shape from ASV: <S>3739, Leviticus2</S>.
        self.assertEqual(_search_text("which<S>3739, Leviticus2</S> is"), "which is")

    def test_multi_number_tag_does_not_break_phrase_adjacency(self):
        # The user-visible half of the same defect: with the digits left inline, the two
        # real words are no longer neighbours and the phrase query returns nothing.
        con = fts_over("text_clean", ["save<S>1487, 3361</S> Crispus and Gaius"])
        self.assertEqual(hits(con, "save Crispus"), 1)

    def test_footnote_anchor_removed_with_its_marker(self):
        # Would FAIL before 2026-08-07: `<f>` had no rule, so the generic tag strip left
        # "[2]" as literal text. Real shape from UBIO Gen 1:2.
        out = _search_text("над безоднею,<f>[2]</f> і Дух Божий")
        self.assertEqual(out, "над безоднею, і Дух Божий")
        self.assertNotIn("[2]", out)

    def test_footnote_anchor_does_not_break_phrase_adjacency(self):
        # The user-visible half: the marker stood between two words, so the phrase failed
        # on the second verse of the Bible in Ukrainian.
        con = fts_over("text_clean", ["над безоднею,<f>[2]</f> і Дух Божий"])
        self.assertEqual(hits(con, "безоднею і Дух"), 1)

    def test_inline_translator_note_still_survives(self):
        # Control for the rule above: <f> is an ANCHOR (content lives in the footnote
        # table), <n> is inline verse text. Deleting both would lose real words.
        self.assertEqual(_search_text("він <n>цебто Давид</n> сказав<f>[7]</f>"),
                         "він (цебто Давид) сказав")

    def test_space_stranded_by_removed_tag_before_punctuation_goes(self):
        # Real shape, KJV Gen 7:2 — two Strong's for one word with a literal space between
        # the tags. 972 of 982 affected verses look exactly like this.
        self.assertEqual(_search_text("by sevens<S>7651</S> <S>7651</S>, the male"),
                         "by sevens, the male")

    def test_space_between_words_is_never_removed(self):
        # The control that keeps the rule above honest. The "сказалБог" defect was a space
        # BETWEEN WORDS being dropped; this rule must be unable to reach that case.
        self.assertEqual(_search_text("сказал<S>3004</S> <i>Бог</i>"), "сказал Бог")
        self.assertEqual(_search_text("word<S>1</S> <S>2</S> next"), "word next")

    def test_space_before_dash_survives(self):
        # In Ukrainian a space before an em dash is correct punctuation, not debris.
        self.assertEqual(_search_text("і те́мрява — над безоднею"),
                         "і те́мрява — над безоднею")

    def test_source_numbers_without_markup_are_kept(self):
        # The control for the opposite error: do NOT start deleting bare numbers to make
        # the ceiling look good. ASV genuinely ships verses where a word was replaced by a
        # number (Job 21:5 has "480" where "Mark" belongs). That is a dataset defect and
        # must stay visible in the data, not be laundered by the stripper.
        self.assertEqual(_search_text("480<S>6437</S> me, and be astonished"),
                         "480 me, and be astonished")


class PhraseSearch(unittest.TestCase):

    def test_phrase_across_strongs_markup(self):
        # THE regression. Fails on an index built over `text`.
        con = fts_over("text_clean", [RAW_RST])
        self.assertEqual(hits(con, "смертной тени"), 1)
        self.assertEqual(hits(con, "долиною смертной тени"), 1)

    def test_phrase_across_semantic_tag(self):
        # Not only <S>: any tag opening mid-verse used to cut the phrase.
        con = fts_over("text_clean", ["и сказал <J>Я есмь</J> путь"])
        self.assertEqual(hits(con, "сказал Я"), 1)
        self.assertEqual(hits(con, "есмь путь"), 1)

    def test_single_word_still_matches(self):
        # Held even while broken — asserted so a future "fix" cannot trade it away.
        con = fts_over("text_clean", [RAW_RST])
        self.assertEqual(hits(con, "долиною"), 1)

    def test_prefix_star_still_applies_to_last_word(self):
        con = fts_over("text_clean", [RAW_RST])
        self.assertEqual(hits(con, "смертной тен"), 1)   # "тени" via the trailing *

    def test_control_phrase_wrong_order_misses(self):
        # Both words present, wrong order → must miss. A NEAR()-based query builder
        # would match this; that is the trade-off being refused.
        con = fts_over("text_clean", [RAW_RST])
        self.assertEqual(hits(con, "тени долиною"), 0)

    def test_control_phrase_absent_words_miss(self):
        con = fts_over("text_clean", [RAW_RST])
        self.assertEqual(hits(con, "долиною тракторной"), 0)

    def test_raw_index_reproduces_the_bug(self):
        # Pins the diagnosis itself: if this ever passes, the cause was not markup
        # in the index, and the fix above is resting on a wrong explanation.
        con = fts_over("text", [RAW_RST])
        self.assertEqual(hits(con, "долиною"), 1, "single word matched even when broken")
        self.assertEqual(hits(con, "смертной тени"), 0, "raw index must still break phrases")


if __name__ == "__main__":
    unittest.main(verbosity=2)
