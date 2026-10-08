#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Вибір варіанта й рядка TBESH за глосами Macula (scripts/tbesh_select.py, bug-057).

Фікстура fixtures/tbesh_select_real.json — СПРАВЖНІ рядки TBESH (gloss/meaning
обрізано до 300 символів) і топ-10 глос Macula з бази 2026-10-05. Рішення на
обрізаній фікстурі збігаються з рішеннями на повних даних (перевірено при знятті).

Позитивні випадки: AGREE виправляє H3581/H1004/H5892/H5483.
Контрольні (ловлять протилежну помилку — правило, що «впевнено» перемикає все):
H2896 «good» і H6635 «hosts», де сам сигнал G помиляється; H2617 hesed, де
сигнал слабкий; H7014 Kain/Cain, де помиляється GF.

Запуск без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""
import json
import sys
import unittest
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tbesh_select as TS  # noqa: E402

FIX = json.loads((Path(__file__).parent / "fixtures" / "tbesh_select_real.json").read_text(encoding="utf-8"))


def decide(sid):
    d = FIX[sid]
    return TS.decide_variant(Counter(d["glosses"]), d["variants"], d["order"])


class TestAgree(unittest.TestCase):
    def test_fixes_bug_057_examples(self):
        for sid, want in (("H3581", "H3581b"), ("H1004", "H1004b"), ("H5892", "H5892b"), ("H5483", "H5483b")):
            dec, pick, _ = decide(sid)
            self.assertEqual((dec, pick), ("AUTO", want), f"{sid}: очікували AUTO {want}, отримали {dec} {pick}")

    def test_g_alone_would_be_wrong_so_agree_abstains(self):
        # G обирає b («good» іменник / «Hosts» ім'я ЯХВЕ), правильний — a. AGREE не вирішує.
        for sid in ("H2896", "H6635"):
            dec, pick, info = decide(sid)
            self.assertEqual(info["G"][0:2], ("AUTO", sid + "b"), f"{sid}: фікстура мала відтворити помилку G")
            self.assertNotEqual(dec, "AUTO", f"{sid}: AGREE не мав приймати рішення")

    def test_gf_alone_would_be_wrong_so_agree_abstains(self):
        dec, pick, info = decide("H7014")
        self.assertEqual(info["GF"][1], "H7014a", "фікстура мала відтворити помилку GF (Kain)")
        self.assertNotEqual(dec, "AUTO")

    def test_weak_signal_keeps_hands_off_hesed(self):
        dec, _, _ = decide("H2617")
        self.assertNotEqual(dec, "AUTO", "hesed: покриття ~0.2 — не вгадувати")


class TestRow(unittest.TestCase):
    def test_name_row_skipped_for_common_word(self):
        rows = FIX["H5483"]["variants"]["H5483b"]
        self.assertTrue(TS.is_name_row(rows[0]), "перший рядок H5483b — «Horse (Gate)»")
        self.assertEqual(TS.pick_row(rows, Counter({"Nc": 137}))["gloss"], "horse")

    def test_name_row_kept_for_name(self):
        rows = FIX["H5483"]["variants"]["H5483b"]
        self.assertEqual(TS.pick_row(rows, Counter({"Np": 3}))["gloss"], "Horse (Gate)")

    def test_lowercase_name_row_detected_by_relation(self):
        # H5553G: глоса «rock» з малої, але це «a Name of» → «The Rock / Sela». Має бути «crag».
        rows = FIX["H5553"]["variants"]["H5553"]
        self.assertTrue(TS.is_name_row(rows[0]))
        self.assertEqual(TS.pick_row(rows, Counter({"Nc": 58}))["gloss"], "crag")

    def test_king_row_not_kings_valley(self):
        rows = FIX["H4428"]["variants"]["H4428"]
        self.assertEqual(TS.pick_row(rows, Counter({"Nc": 2523}))["gloss"], "king")
        self.assertTrue(TS.is_name_row(rows[-1]), "останній рядок H4428 — «King's (Valley)»")

    def test_spelling_row_is_not_a_name(self):
        # H7704a: «Sirion» — ім'я; «field» — «a Spelling of», тобто НЕ ім'я.
        rows = FIX["H7704a"]["variants"]["H7704a"]
        self.assertEqual(TS.pick_row(rows, Counter({"Nc": 13}))["gloss"], "field")

    def test_plain_first_row_untouched(self):
        rows = FIX["H1004"]["variants"]["H1004b"]
        self.assertEqual(TS.pick_row(rows, Counter({"Nc": 2042}))["gloss"], rows[0]["gloss"])


class TestText(unittest.TestCase):
    def test_stem_merges_plural_forms(self):
        for a, b in (("houses", "house"), ("cities", "city"), ("ears", "ear"), ("horsemen", "horseman"),
                     ("kindly", "kindness")):
            self.assertEqual(TS.stem(a), TS.stem(b), f"{a} ≠ {b}")

    def test_function_words_survive_with_keep_stop(self):
        self.assertEqual(TS.vocab("from", keep_stop=True), {"from"})
        self.assertEqual(TS.vocab("from"), set())

    def test_macula_class(self):
        self.assertEqual([TS.macula_class(m) for m in ("Ncmsa", "Np", "Vqp3ms", "R", None)],
                         ["Nc", "Np", "V", "R", "?"])


if __name__ == "__main__":
    unittest.main()
