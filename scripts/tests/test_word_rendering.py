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
    Normalizer, merge_forms, pair_words, pair_words_merged, parse_segments, pick_examples,
    highlight_spec)

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

    def test_space_between_tags_before_comma_dropped_bug056(self):
        segs = parse_segments("to God-ward<S>4136</S> <S>430</S>, that")
        self.assertEqual("".join(s.text for s in segs), "to God-ward, that")
        segs = parse_segments("said<S>559</S> <S>1</S> God")   # перед словом — лишається
        self.assertEqual("".join(s.text for s in segs), "said God")

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

    def test_phrasal_particle_is_kept(self):
        # ADR-041 Amendment 3: «passed over» ≠ «over»; «passed by» ≠ «passed»
        n = Normalizer("en")
        self.assertEqual(n("and passed by"), "passed by")
        self.assertEqual(n("will pass through"), "pass through")
        self.assertEqual(n("shall be cut off"), "cut off")
        self.assertEqual(n("round about"), "round about")      # сама частка — теж передача
        self.assertEqual(n("put their trust in"), "trust")      # чистий прийменник не частка


class TestMergeForms(unittest.TestCase):
    def test_plural_merges_only_with_sibling(self):
        m = merge_forms({"H2617": Counter({"mercy": 5, "mercies": 2, "lovingkindnesses": 1})}, "en")
        self.assertEqual(m[("H2617", "mercies")], "mercy")
        self.assertEqual(m[("H2617", "lovingkindnesses")], "lovingkindnesses")   # сусіда нема

    def test_suffix_collapse_to_fixed_point(self):
        m = merge_forms({"H559": Counter({"saith": 3, "thus saith": 2, "therefore thus saith": 1})}, "en")
        self.assertEqual(m[("H559", "therefore thus saith")], "saith")

    def test_phrasal_verb_merges_on_the_verb(self):
        m = merge_forms({"H5674": Counter({"pass over": 3, "passed over": 2, "over": 1, "pass": 4})}, "en")
        self.assertEqual(m[("H5674", "passed over")], "pass over")
        self.assertEqual(m[("H5674", "pass over")], "pass over")   # не згортається до «over»

    def test_homonym_keeps_its_phrase(self):
        m = merge_forms({"H2617a": Counter({"wicked thing": 1, "reproach": 1})}, "en")
        self.assertEqual(m[("H2617a", "wicked thing")], "wicked thing")



class TestCase_(unittest.TestCase):
    def test_proper_noun_keeps_capital_sentence_start_does_not(self):
        from build_word_rendering import apply_case
        rows = [("H430", [("God", "god")], 1, 0)] * 3 + [("H430", [("gods", "gods")], 2, 0)] \
            + [("H2617", [("Mercy", "mercy")], 3, 0)] + [("H2617", [("mercy", "mercy")], 4, 0)] * 2
        out = [r for _, r, _, _ in apply_case(rows, "en")]
        self.assertEqual(out[:4], ["God", "God", "God", "gods"])
        self.assertEqual(out[4], "mercy")        # велика лише на початку речення

    def test_all_caps_lord_survives(self):
        from build_word_rendering import apply_case
        rows = [("H3068", [("LORD", "lord")], 1, 0)] * 2
        self.assertEqual(apply_case(rows, "en")[0][1], "LORD")

    def test_sentence_start_singleton_not_capitalised(self):
        from build_word_rendering import apply_case
        # RST Пс 110:4 «Памятными соделал…» — єдине входження, на початку вірша
        rows = [("H2143", [("Памятными", "памятный", True)], 1, 0)]
        rows = [("H2143", [("Памятными", "памятный", True)], 1, 0),
                ("H2142", [("памятное", "памятный", False)], 2, 0)]   # з малої під іншим номером
        self.assertEqual(apply_case(rows, "ru")[0][1], "памятный")

    def test_rare_name_only_at_sentence_start_keeps_capital(self):
        from build_word_rendering import apply_case
        rows = [("H5917", [("Achar", "achar", True)], 1, 0)]       # KJV 1Пар 2:7
        self.assertEqual(apply_case(rows, "en")[0][1], "Achar")

    def test_sentence_start_does_not_outvote_mid_sentence(self):
        from build_word_rendering import apply_case
        rows = [("H430", [("God", "god", True)], 1, 0)] * 5 + [("H430", [("God", "god", False)], 2, 0)]
        self.assertEqual(apply_case(rows, "en")[0][1], "God")
        rows = [("H3068", [("LORD", "lord", True)], 1, 0)]
        self.assertEqual(apply_case(rows, "en")[0][1], "LORD")   # усі великі — завжди доказ

    def test_sentence_start_detection(self):
        n = Normalizer("en")
        self.assertTrue(n.tokens("Mercy", "")[0][2])
        self.assertTrue(n.tokens(" Mercy", "and it was so. ")[0][2])
        self.assertFalse(n.tokens(" Mercy", "and the ")[0][2])

    def test_hyphen_stays_inside_word(self):
        self.assertEqual(Normalizer("en")("to God-ward"), "god-ward")

    def test_possessive_capital_s_stripped(self):
        self.assertEqual(Normalizer("en").tokens("the LORD'S"), [("LORD", "lord")])


class TestPickExamples(unittest.TestCase):
    def test_heaviest_verse_wins_and_ties_go_to_earliest(self):
        rows = [("H2617", "mercy", 1019019, 0),   # Бут 19:19, вага 5
                ("H2617", "mercy", 33006008, 2),  # Мих 6:8, вага 2072
                ("H2617", "kindness", 1020013, 0),
                ("H2617", "kindness", 1021023, 1)]  # обидва без ваги → найраніший
        ex = pick_examples(rows, {1019019: 5, 33006008: 2072})
        self.assertEqual(ex[("H2617", "mercy")], (33006008, 2))
        self.assertEqual(ex[("H2617", "kindness")], (1020013, 0))


if __name__ == "__main__":
    unittest.main()


class TestSplitTags(unittest.TestCase):
    """Одне слово оригіналу, розмічене в перекладі кількома тегами."""
    MT_26_59 = "to<S>3704</S> put<S>2289</S> him<S>846</S> to death<S>2289</S>;"

    def test_surplus_tag_is_merged_not_dropped(self):
        words = [(1, "G3704"), (2, "G2289"), (3, "G846")]
        out = pair_words_merged(words, parse_segments(self.MT_26_59))
        w = [x for x in out if x[0] == 2][0]
        self.assertEqual(w[2], 1)                        # seg_ord першого шматка
        self.assertEqual(w[4], [(3, "to death")])        # доклеєний шматок
        # стара функція (порт Swift) — без змін
        self.assertEqual([x[2] for x in pair_words(words, parse_segments(self.MT_26_59))], [0, 1, 2])

    def test_highlight_spec(self):
        toks = [("put", "put", False, 0, 3, 1), ("to", "to", False, 0, 2, 3), ("death", "death", False, 3, 8, 3)]
        self.assertEqual(highlight_spec(toks, 1, {1: "put", 3: "to death"}), "1:0:3;3:0:8")
        self.assertIsNone(highlight_spec([("mercy", "mercy", False, 0, 5, 0)], 0, {0: "mercy"}))
        self.assertEqual(highlight_spec([("mercy", "mercy", False, 8, 13, 0)], 0, {0: "for his mercy"}), "0:8:5")

    def test_kept_phrase_not_collapsed_below(self):
        m = merge_forms({"G2289": Counter({"put to death": 3, "cause to be put to death": 2, "death": 2})},
                        "en", {"G2289": {"put to death", "cause to be put to death"}})
        self.assertEqual(m[("G2289", "cause to be put to death")], "put to death")
        self.assertEqual(m[("G2289", "put to death")], "put to death")

    def test_gap_filled_from_kept_phrase(self):
        # ASV Мк 14:55: «to» розмічене як εἰς → склейка «put death»
        m = merge_forms({"G2289": Counter({"put to death": 10, "put death": 1})},
                        "en", {"G2289": {"put to death", "put death"}})   # обидва — склейки
        self.assertEqual(m[("G2289", "put death")], "put to death")
        self.assertEqual(m[("G2289", "put to death")], "put to death")


class TestRuHead(unittest.TestCase):
    def setUp(self):
        try:
            self.n = Normalizer("ru")
        except SystemExit:
            self.skipTest("pymorphy3 не встановлено")

    def head(self, *words):
        toks = [(w, self.n.lemma(w.lower()), False, 0, 0, 0) for w in words]
        return " ".join(t[1] for t in self.n.ru_head(toks))

    def test_aux_verb_dropped(self):
        self.assertEqual(self.head("будут", "преследовать"), "преследовать")
        self.assertEqual(self.head("было", "помочь"), "помочь")

    def test_adjective_agrees_and_order_is_unified(self):
        self.assertEqual(self.head("хлебного", "приношения"), "хлебное приношение")
        self.assertEqual(self.head("приношение", "хлебное"), "хлебное приношение")

    def test_noun_with_prepositional_phrase(self):
        self.assertEqual(self.head("жертву", "за", "грех"), "жертва за грех")


class TestRuLemma(unittest.TestCase):
    def setUp(self):
        try:
            self.n = Normalizer("ru")
        except SystemExit:
            self.skipTest("pymorphy3 не встановлено")

    def test_unknown_names_use_text_vocabulary(self):
        self.n.vocab = frozenset({"иоав", "иоава", "авессалом", "израилев", "едом", "ед"})
        self.assertEqual(self.n.lemma("иоава"), "иоав")
        self.assertEqual(self.n.lemma("авессалом"), "авессалом")   # не «авессало»
        self.assertEqual(self.n.lemma("израилевой"), "израилев")
        self.assertEqual(self.n.lemma("едом"), "едом")             # не «ед»
        self.assertEqual(self.n.lemma("соделал"), "соделать")      # дієслово не чіпаємо

    def test_overrides(self):
        self.assertEqual(self.n.lemma("род"), "род")
        self.assertEqual(self.n.lemma("сиклей"), "сикль")

    def test_gore_by_context(self):
        self.assertEqual([t[1] for t in self.n.tokens("Горе")], ["горе"])
        self.assertEqual([t[1] for t in self.n.tokens("на горе")], ["гора"])


class TestPickGroups(unittest.TestCase):
    """Групи звіту docs/features/report-adr041-rendering-cases.md."""
    def setUp(self):
        self.n = Normalizer("en")

    def w(self, seg, cls, gloss=""):
        r = self.n.pick(seg, "", cls, gloss)
        return None if r is None else " ".join(t[0] for t in r)

    def test_pronoun_original_has_no_row(self):
        self.assertIsNone(self.w("them", "pron"))

    def test_useful_pronouns_shown_clean(self):
        self.assertEqual(self.w("unto him", "pron_show"), "him")      # ἐκεῖνος
        self.assertEqual(self.w("of that", "pron_show"), "that")
        self.assertEqual(self.w("the same", "pron_show"), "same")
        self.assertEqual(self.w("a certain man", "pron_show"), "certain")   # τις, «man» — курсив KJV
        self.assertEqual(self.w("one another", "pron_show"), "one another")

    def test_function_word_original_kept(self):
        self.assertEqual(self.w("against", "prep"), "against")
        self.assertEqual(self.w("unto him for", "prep"), "for")
        self.assertEqual(self.w("thereof round about", "adv"), "round about")
        self.assertEqual(self.w("according to", "prep"), "according to")

    def test_gloss_span(self):
        self.assertEqual(self.w("the master of the house", "noun", "master of the house"),
                         "master of the house")
        self.assertEqual(self.w("the goodman of the house", "noun", "master of the house"),
                         "goodman of the house")
        self.assertEqual(self.w("the brother of Goliath", "noun", "Goliath"), "Goliath")

    def test_stopword_collision_and_fallback(self):
        self.assertEqual(self.w("until the even", "noun", "evening"), "even")
        self.assertEqual(self.w("ye shall do", "verb", "do"), "do")

    def test_possessive_blanked(self):
        from build_word_rendering import blank_possessive
        self.assertEqual(self.w(blank_possessive("'s brother"), "noun", "brother"), "brother")


class TestPossessiveSplit(unittest.TestCase):
    def test_possessive_split_off_tagged_segment(self):
        # ASV Мк 12:19 — «'s» окремим сегментом без Strong's, як у VerseParser.swift
        segs = parse_segments("If a man<S>5100</S>'s brother<S>80</S> die<S>599</S>")
        tagged = [(sg.text, sg.strongs) for sg in segs if sg.strongs]
        self.assertEqual(tagged[1][0], "brother")
        self.assertIn("'s ", [sg.text for sg in segs if not sg.strongs])

    def test_son_of_mans_sake(self):
        # ASV Лк 6:22 «Son<S>5207</S> of man<S>444</S>'s sake<S>5207</S>»
        segs = parse_segments("for the Son<S>5207</S> of man<S>444</S>'s sake<S>5207</S>.")
        self.assertEqual([sg.text for sg in segs if sg.strongs][-1], "sake")


class TestAsvTagDrift(unittest.TestCase):
    def test_rom_4_7(self):
        from fix_asv_tag_drift import fix_verse
        text = ("saying<S>3107</S>, Blessed are they whose<S>3739</S> iniquities<S>458</S> "
                "are forgiven<S>863</S>.")
        words = [(1, "G3107"), (2, "G3739"), (3, "G863"), (4, "G458")]
        info = {1: ("adj", "Blessed"), 2: ("pron", "of whom"), 3: ("verb", "are forgiven"),
                4: ("noun", "lawless deeds")}
        new, n = fix_verse(text, words, info)
        self.assertEqual(n, 1)
        self.assertTrue(new.startswith("saying, Blessed<S>3107</S> are they whose<S>3739</S>"))
        self.assertEqual(fix_verse(new, words, info)[1], 0)      # повторно — нічого

    def test_correct_tag_untouched(self):
        from fix_asv_tag_drift import fix_verse
        text = "and the name<S>8034</S> of his city<S>5892</S>."
        info = {1: ("noun", "name"), 2: ("noun", "city")}
        self.assertEqual(fix_verse(text, [(1, "H8034"), (2, "H5892")], info)[1], 0)
