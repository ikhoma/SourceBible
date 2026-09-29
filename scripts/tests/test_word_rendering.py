#!/usr/bin/env python3
"""Тести build_word_rendering.py (ADR-041, частина 1).

Фікстури — РЕАЛЬНІ рядки `verse.text` / `word` із sourcebible.db (2026-09-28),
не вигадані: тест, який годують вигаданими даними, перевіряє припущення автора.
"""
import os
import sys
import unittest
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from build_word_rendering import (  # noqa: E402
    Normalizer, merge_forms, pair_words, parse_segments)

KJV_EXO_34_6 = ('And the LORD<S>3068</S> passed by<S>5674</S> before him<S>6440</S>, and proclaimed<S>7121</S>, '
                'The LORD<S>3068</S>, The LORD<S>3068</S> God<S>410</S>, merciful<S>7349</S> and gracious<S>2587</S>, '
                'longsuffering<S>750</S> <S>639</S>, and abundant<S>7227</S> in goodness<S>2617</S> and truth<S>571</S>,')
KJV_PSA_136_1 = ('O give thanks<S>3034</S> unto the LORD<S>3068</S>; for he is good<S>2896</S>: '
                 'for his mercy<S>2617</S> endureth for ever<S>5769</S>.')
KJV_LEV_20_17_PART = ('and she see<S>7200</S> his nakedness<S>6172</S>; it is a wicked thing<S>2617</S>; '
                      'and they shall be cut off<S>3772</S>')
KJV_1KI_3_6_TAIL = ('this great<S>1419</S> kindness<S>2617</S>, that thou hast given<S>5414</S> him a son<S>1121</S>. '
                    '<n>mercy: or, bounty</n>')
RST_EXO_34_6_PART = ('Бог<S>410</S> человеколюбивый<S>7349</S> и милосердый,<S>2587</S> '
                     'долготерпеливый<S>750</S><S>639</S> и многомилостивый<S>7227</S><S>2617</S> и истинный,<S>571</S>')
RST_JHN_3_16 = ('<pb/><J>Ибо<S>1063</S> так<S>3779</S> возлюбил<S>25</S><S>3588</S> Бог<S>2316</S><S>3588</S> '
                'мир,<S>2889</S> что<S>5620</S><S>3588</S> отдал<S>1325</S> Сына<S>5207</S></J>')
JHN_3_16_WORDS = [('JHN|3|16|1', 'G3779'), ('JHN|3|16|2', 'G1063'), ('JHN|3|16|3', 'G25'),
                  ('JHN|3|16|4', 'G3588'), ('JHN|3|16|5', 'G2316'), ('JHN|3|16|6', 'G3588'),
                  ('JHN|3|16|7', 'G2889'), ('JHN|3|16|8', 'G5620'), ('JHN|3|16|9', 'G3588'),
                  ('JHN|3|16|10', 'G5207'), ('JHN|3|16|11', 'G3588'), ('JHN|3|16|12', 'G3439'),
                  ('JHN|3|16|13', 'G1325')]
PSA_136_1_WORDS = [('PSA|136|1|1', 'H3034'), ('PSA|136|1|2', 'H3807a'), ('PSA|136|1|3', 'H3068'),
                   ('PSA|136|1|4', 'H3588'), ('PSA|136|1|5', 'H2896'), ('PSA|136|1|6', 'H3588'),
                   ('PSA|136|1|7', 'H3807a'), ('PSA|136|1|8', 'H5769'), ('PSA|136|1|9', 'H2617'),
                   ('PSA|136|1|10', 'H2050c')]


def tagged(segs):
    return [(s.text, s.strongs) for s in segs if s.strongs]


class TestVerseParserPort(unittest.TestCase):
    """Має поводитись як VerseParser.swift — навіть там, де Swift дивний."""

    def test_leading_separators_split_off(self):
        t = tagged(parse_segments(KJV_EXO_34_6))
        self.assertIn(("in goodness", ["S2617"]), t)
        self.assertIn(("before him", ["S6440"]), t)       # «, » відрізано, не підсвічується

    def test_consecutive_tags_accumulate_bug055(self):
        # bug-055: другий тег на тому ж слові ДОДАЄТЬСЯ (раніше Swift перезаписував).
        t = tagged(parse_segments(KJV_EXO_34_6))
        self.assertIn(("longsuffering", ["S750", "S639"]), t)
        r = tagged(parse_segments(RST_EXO_34_6_PART))
        self.assertIn(("и многомилостивый", ["S7227", "S2617"]), r)

    def test_rst_article_no_longer_steals_the_word_bug055(self):
        segs = parse_segments(RST_JHN_3_16)
        pairs = pair_words(JHN_3_16_WORDS, segs)
        by_text = {}
        for _, sid, _, text in pairs:
            by_text.setdefault(text, sid)          # перша пара сегмента = що відкриє tapWord
        self.assertEqual(by_text["возлюбил"], "G25")
        self.assertEqual(by_text["Бог"], "G2316")
        self.assertIn("G25", {sid for _, sid, _, _ in pairs})

    def test_footnote_text_is_not_a_segment(self):
        segs = parse_segments(KJV_1KI_3_6_TAIL)
        self.assertNotIn("bounty", "".join(s.text for s in segs))
        self.assertIn(("kindness", ["S2617"]), tagged(segs))


class TestPairing(unittest.TestCase):
    def test_hebrew_order_differs_from_english(self):
        pairs = pair_words(PSA_136_1_WORDS, parse_segments(KJV_PSA_136_1))
        by_id = {sid: text for _, sid, _, text in pairs}
        self.assertEqual(by_id["H2617"], "for his mercy")
        self.assertEqual(by_id["H5769"], "endureth for ever")
        self.assertNotIn("H3807a", by_id)                 # прийменник KJV окремо не тегує

    def test_seg_ord_counts_only_tagged_segments(self):
        pairs = pair_words(PSA_136_1_WORDS, parse_segments(KJV_PSA_136_1))
        self.assertEqual({sid: o for _, sid, o, _ in pairs}["H2617"], 3)


class TestNormalizer(unittest.TestCase):
    def test_tail_after_last_stopword(self):
        n = Normalizer("en")
        self.assertEqual(n("for his mercy"), "mercy")
        self.assertEqual(n("it is a wicked thing"), "wicked thing")
        self.assertEqual(n("unto her"), "")                # лише службові слова → порожньо
        self.assertEqual(n("love's"), "love")


class TestMergeForms(unittest.TestCase):
    def test_plural_merges_only_with_sibling(self):
        m = merge_forms({"H2617": Counter({"mercy": 5, "mercies": 2, "lovingkindnesses": 1})}, "en")
        self.assertEqual(m[("H2617", "mercies")], "mercy")
        self.assertEqual(m[("H2617", "lovingkindnesses")], "lovingkindnesses")   # сусіда нема

    def test_suffix_collapse_to_fixed_point(self):
        m = merge_forms({"H559": Counter({"saith": 3, "thus saith": 2, "therefore thus saith": 1})}, "en")
        self.assertEqual(m[("H559", "therefore thus saith")], "saith")

    def test_homonym_keeps_its_phrase(self):
        m = merge_forms({"H2617a": Counter({"wicked thing": 1, "reproach": 1})}, "en")
        self.assertEqual(m[("H2617a", "wicked thing")], "wicked thing")


if __name__ == "__main__":
    unittest.main()
