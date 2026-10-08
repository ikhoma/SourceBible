"""Тести конвертера ASV (ADR-042) на РЕАЛЬНИХ фрагментах OpenBible USX.

Фікстури — дослівні вирізки з закріпленого коміту (див. fixtures/obi_asv/README.md).
Без мережі й без бази: python3 -m unittest discover scripts/tests
"""
import os
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import build_asv_module as M  # noqa: E402

FIX = HERE / "fixtures" / "obi_asv"


class Rendered(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verses, cls.notes, cls.align, cls.stats, cls.problems = M.build(FIX)

    def v(self, b, c, n):
        return self.verses[(b, c, n)]

    def test_no_structural_problems(self):
        self.assertEqual(M.check(self.verses, self.notes, self.stats, self.problems, full=False), [])

    # ── теги на головний токен ──
    def test_gen_22_8_transposition_fixed(self):
        t = self.v("GEN", 22, 8)
        self.assertIn("my son<S>1121</S>", t)            # ASV+: «my son<S>3212</S>»
        self.assertIn("they went<S>1980</S>", t)
        self.assertNotIn("will<S>", t)                   # ASV+: «will<S>1121</S>»

    def test_gen_1_1_prefixes_untagged(self):
        self.assertEqual(self.v("GEN", 1, 1),
                         "In the beginning<S>7225</S> God<S>430</S> created<S>1254</S> "
                         "the heavens<S>8064</S> and the earth<S>776</S>.")

    def test_gen_1_12_missing_space_in_source(self):
        # Оригінальний USX склеїв «פְּרִיאֲשֶׁר» без пробілу; без морфологічного поділу «fruit»
        # лишився б без тега, бо головою «слова» став би אֲשֶׁר.
        self.assertIn("fruit<S>6529</S>", self.v("GEN", 1, 12))

    def test_maqaf_is_a_word_boundary(self):
        org = M.parse_original(FIX / "usx-original-aligned" / "01-GEN.usx")
        self.assertTrue(org["WLC.GEN.22.8.005"]["is_head"])     # יִרְאֶה־ (дієслово)
        self.assertTrue(org["WLC.GEN.22.8.006"]["is_head"])     # לּוֹ: прийменник — голова свого слова
        self.assertFalse(org["WLC.GEN.22.8.007"]["is_head"])    # суфікс וֹ
        self.assertFalse(org["WLC.GEN.22.8.013"]["is_head"])    # בְּנִי: суфікс י

    def test_noncompositional_two_tags(self):
        self.assertIn("a year old<S>1121</S><S>8141</S>", self.v("EXO", 12, 5))

    def test_aramaic_emphatic_article_is_enclitic(self):
        t = self.v("EZR", 4, 8)
        self.assertIn("<S>5613</S>", t)                  # סָפְרָא — тег на іменник
        self.assertNotIn("<S>1</S>", t)                  # H1b (артикль) — не голова

    def test_name_table_fills_missing_strongs(self):
        self.assertIn("Beth-el<S>1008</S><S>1008</S>", self.v("GEN", 12, 8))

    def test_greek_form_numbers_canonicalized(self):
        self.assertIn("this<S>3778</S> is<S>1510</S> my<S>1473</S> body<S>4983</S>", self.v("MAT", 26, 26))

    def test_no_greek_article_tags(self):
        for k, t in self.verses.items():
            if k[0] in M.NT_BOOKS:
                self.assertNotIn("<S>3588</S>", t, k)

    def test_split_unit_fragment_tag_only_when_unique(self):
        self.assertIn("put<S>2289</S> him<S>846</S> to death<S>2289</S>", self.v("MRK", 14, 55))

    def test_the_only_unit_untagged(self):
        # בְּנֵי־מִצְרַיִם → «the Egyptians»: OpenBible вирівняв בְּנֵי на «the». Тег на артиклі
        # відкривав би «син» і давав чип «the» — одиниця лишається без тега.
        t = self.v("EZK", 16, 26)
        self.assertIn("with<S>413</S> the Egyptians<S>4714</S>", t)
        self.assertNotIn("<S>1121</S>", t)

    def test_one_of_fragment_untagged(self):
        # «one of … his sons» ← בְּנוֹ: уламок «one of» без тега, інакше чип «one his sons».
        self.assertIn("and one of his sons<S>1121</S>", self.v("1KI", 13, 11))

    def test_copula_tag_before_supplied_copula(self):
        # Іменне речення: ASV додає «are», OpenBible клеїть його до одиниці. Тег — перед зв'язкою.
        self.assertIn("Blessed<S>835</S> are", self.v("PSA", 119, 1))
        self.assertIn("Many<S>7227</S> are", self.v("PSA", 3, 1))
        self.assertNotRegex(self.v("PSA", 119, 1), r"are<S>835</S>")

    # ── виноски ──
    def test_footnote_anchor_after_unit_of_next_word(self):
        self.assertIn("provide<S>7200</S><f>[1]</f>", self.v("GEN", 22, 8))
        self.assertEqual(self.notes[("GEN", 22, 8)], ["Hebrew <i>see for himself</i>."])

    def test_footnote_at_verse_end_has_no_space(self):
        t = self.v("MAT", 6, 13)
        self.assertTrue(t.endswith(".<f>[2]</f>"), t[-40:])

    def test_nbsp_kept_in_footnote(self):
        n = self.notes[("GEN", 41, 13)][0]
        self.assertIn("\xa0.\xa0.\xa0.", n)              # \s+ з'їв би NBSP

    # ── надписи, акровірш, типографіка ──
    def test_psalm_title_is_n_without_tags(self):
        t = self.v("PSA", 3, 1)
        self.assertTrue(t.startswith("<n>A Psalm of David, when he fled from Absalom his son.</n> Jehovah<S>3068</S>"), t)

    def test_acrostic_letters(self):
        self.assertTrue(self.v("PSA", 119, 1).startswith("ALEPH. Blessed"))
        self.assertTrue(self.v("PSA", 119, 9).startswith("BETH. Wherewith"))

    def test_no_curly_apostrophe(self):
        for k, t in self.verses.items():
            self.assertNotIn("’", t, k)
        for k, ns in self.notes.items():
            for x in ns:
                self.assertNotIn("’", x, k)


class HeadRule(unittest.TestCase):
    """Правило головного токена на РЕАЛЬНІЙ формі токенів (dict з x-morph/sep_after)."""

    def toks(self, ref):
        org = M.parse_original(FIX / "usx-original-aligned" / "01-GEN.usx")
        return [t for k, t in sorted(org.items()) if k.startswith(f"WLC.{ref}.")]

    def test_gen_1_5_head_is_noun_not_preposition(self):
        words = M.hebrew_words(self.toks("GEN.1.5"))
        heads = [M.head_of(w)["strong"] for w in words]
        self.assertIn("H216", heads)                     # לָאוֹר → «світло», не H3807a
        self.assertNotIn("H3807a", heads)


class Manifest(unittest.TestCase):
    def test_tampered_manifest_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            m = Path(d) / "m.txt"
            m.write_text("0" * 64 + "  usx-english-aligned/01-GEN.usx\n")
            fails = M.verify_manifest(FIX, m)
            self.assertTrue(any("маніфест" in f for f in fails))
            self.assertTrue(any("відрізняється" in f for f in fails))


if __name__ == "__main__":
    unittest.main()
