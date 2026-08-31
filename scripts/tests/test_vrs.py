#!/usr/bin/env python3
"""Тести парсера .vrs (bug-050).

Фікстури відтворюють РЕАЛЬНУ форму рядків із org/eng/rso — не вигадану.
Правило проєкту: тест, який годують вигаданими даними, перевіряє припущення
автора, а не код.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from vrs import parse_vrs  # noqa: E402


def _tmp(text: str) -> str:
    fh = tempfile.NamedTemporaryFile("w", suffix=".vrs.txt", delete=False, encoding="utf-8")
    fh.write(text)
    fh.close()
    return fh.name


class TestMergedVerses(unittest.TestCase):
    """Головне, заради чого парсер існує: повторений ключ = ДВА таргети."""

    def test_repeated_key_keeps_both_targets(self):
        s = parse_vrs(_tmp("# 2CO 11:32 = 2CO 11:32-33\n"
                           "2CO 11:32 = 2CO 11:32\n"
                           "2CO 11:32 = 2CO 11:33\n"))
        self.assertEqual(s.mappings[("2CO", 11, 32)], [(11, 32), (11, 33)])

    def test_merge_across_chapter_boundary(self):
        # REV 13:1 зливає кінець 12-ї глави з початком 13-ї.
        s = parse_vrs(_tmp("REV 13:1 = REV 12:18\nREV 13:1 = REV 13:1\n"))
        self.assertEqual(s.mappings[("REV", 13, 1)], [(12, 18), (13, 1)])

    def test_source_order_preserved(self):
        # Порядок таргетів — це порядок тексту оригіналу. Конкатенація в
        # loadOriginalWords покладається на нього.
        s = parse_vrs(_tmp("LEV 14:55 = LEV 14:55\nLEV 14:55 = LEV 14:56\n"))
        self.assertEqual(s.mappings[("LEV", 14, 55)], [(14, 55), (14, 56)])

    def test_merged_sources_lists_only_multi_target_keys(self):
        s = parse_vrs(_tmp("LEV 14:55 = LEV 14:55\n"
                           "LEV 14:55 = LEV 14:56\n"
                           "GEN 32:1 = GEN 32:2\n"))
        self.assertEqual(s.merged_sources, [("LEV", 14, 55)])

    def test_three_target_merge(self):
        # План §11: KJV PSA 60:1 накриває ТРИ оригінальні вірші (60:1+60:2
        # надписання, 60:3 зміст) — модель мапінгу мусить бути списком
        # довільної довжини, не парою. Живого потрійного повтору зараз немає
        # в жодному з трьох `.vrs.txt` (максимум — 2, звірено 2026-08-27,
        # саме тому цей випадок і йде через `overrides.tsv`, див. план §14) —
        # рядки нижче в реальному форматі файлу, змодельовані на
        # задокументованому кейсі PSA 60:1.
        s = parse_vrs(_tmp("PSA 60:1 = PSA 60:1\n"
                           "PSA 60:1 = PSA 60:2\n"
                           "PSA 60:1 = PSA 60:3\n"))
        self.assertEqual(s.mappings[("PSA", 60, 1)], [(60, 1), (60, 2), (60, 3)])
        self.assertEqual(s.merged_sources, [("PSA", 60, 1)])


class TestRanges(unittest.TestCase):
    def test_equal_ranges_expand_pairwise(self):
        s = parse_vrs(_tmp("LEV 6:1-7 = LEV 5:20-26\n"))
        self.assertEqual(s.mappings[("LEV", 6, 1)], [(5, 20)])
        self.assertEqual(s.mappings[("LEV", 6, 7)], [(5, 26)])
        self.assertEqual(len(s.mappings), 7)

    def test_unequal_range_is_reported_not_guessed(self):
        # ⛔ Контроль на протилежну помилку: парсер НЕ має вгадувати вирівнювання.
        s = parse_vrs(_tmp("PSA 89:2-6 = PSA 90:1-6\n"))
        self.assertEqual(s.mappings, {})
        self.assertEqual(len(s.unequal_ranges), 1)

    def test_cross_book_is_reported_not_mapped(self):
        s = parse_vrs(_tmp("ESG 1:1 = EST 1:1\n"))
        self.assertEqual(s.mappings, {})
        self.assertEqual(len(s.cross_book), 1)


class TestVerseZeroStripped(unittest.TestCase):
    """Вірш 0 = слот надписання псалма (див. коментар у vrs.py) — рядки
    нижче взяті дослівно з rso.vrs.txt (202-204), включно з фантомним
    злиттям, якому цей фільтр і запобігає."""

    def test_target_verse_zero_is_stripped(self):
        # PSA 9:22 = PSA 10:0 (dst v=0, викидається) +
        # PSA 9:22-39 = PSA 10:1-18 (пара 9:22->10:1 лишається) —
        # без фільтра (9,22) отримав би ДВА таргети: (10,0) і (10,1),
        # фантомне злиття, якого в оригіналі нема.
        s = parse_vrs(_tmp("PSA 9:22 = PSA 10:0\n"
                           "PSA 9:22-39 = PSA 10:1-18\n"))
        self.assertEqual(s.mappings[("PSA", 9, 22)], [(10, 1)])
        self.assertNotIn(("PSA", 9, 22), s.merged_sources)

    def test_source_verse_zero_is_stripped(self):
        # PSA 10:0-7 = PSA 11:0-7 — джерело теж проходить крізь 0 у діапазоні.
        s = parse_vrs(_tmp("PSA 10:0-7 = PSA 11:0-7\n"))
        self.assertNotIn(("PSA", 10, 0), s.mappings)
        self.assertEqual(s.mappings[("PSA", 10, 1)], [(11, 1)])
        self.assertEqual(len(s.mappings), 7)  # верші 1..7, НЕ 0..7


class TestMaxVerses(unittest.TestCase):
    def test_counts_indexed_by_chapter(self):
        s = parse_vrs(_tmp("GEN 1:31 2:25 3:24\n"))
        self.assertEqual(s.max_verses["GEN"], [31, 25, 24])

    def test_maxverses_line_is_not_read_as_mapping(self):
        s = parse_vrs(_tmp("GEN 1:31 2:25\n"))
        self.assertEqual(s.mappings, {})


class TestComments(unittest.TestCase):
    def test_comment_form_of_a_merge_is_ignored(self):
        # ⛔ Контроль: людський запис злиття в коментарі (`= LEV 14:55-56`) НЕ
        # має ставати мапінгом — інакше отримаємо дублікати з іншим вирівнюванням.
        s = parse_vrs(_tmp("# LEV 14:55 = LEV 14:55-56\n"))
        self.assertEqual(s.mappings, {})

    def test_trailing_comment_stripped(self):
        s = parse_vrs(_tmp("LEV 14:55 = LEV 14:56   # хвостовий коментар\n"))
        self.assertEqual(s.mappings[("LEV", 14, 55)], [(14, 56)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
