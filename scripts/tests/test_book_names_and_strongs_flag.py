"""Тести build_db: регістр назв книг Громова і translation.has_strongs.

Назви — РЕАЛЬНІ long_name з books модуля GRM (Gromov.zip), усі 66, у порядку модуля.
Без мережі й без бази:  python3 -m unittest discover scripts/tests
"""
import contextlib
import io
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
with contextlib.redirect_stdout(io.StringIO()):     # build_db друкує WARNING при імпорті
    import build_db as B  # noqa: E402

GRM_NAMES = [
    ("БУТТЯ", "Буття"), ("ВИХІД", "Вихід"), ("ЛЕВИТ", "Левит"), ("ЧИСЛА", "Числа"),
    ("ПОВТОРЕННЯ ЗАКОНУ", "Повторення Закону"),
    ("КНИГА ІСУСА НАВИНА", "Книга Ісуса Навина"), ("КНИГА СУДДІВ", "Книга суддів"),
    ("КНИГА РУФ", "Книга Руф"),
    ("1 ЦАРСТВ", "1 Царств"), ("2 ЦАРСТВ", "2 Царств"), ("3 ЦАРСТВ", "3 Царств"),
    ("4 ЦАРСТВ", "4 Царств"), ("1 ХРОНІК", "1 Хронік"), ("2 ХРОНІК", "2 Хронік"),
    ("ЄЗДРИ", "Єздри"), ("НЕЕМІЯ", "Неемія"), ("ЕСФІР", "Есфір"), ("ІОВ", "Іов"),
    ("КНИГА ПСАЛМІВ", "Книга псалмів"), ("ПРИТЧІ", "Притчі"),
    ("ЕККЛЕЗІАСТ", "Екклезіаст"), ("ПІСНЯ ПІСЕНЬ", "Пісня пісень"),
    ("ІСАЯ", "Ісая"), ("ЄРЕМІЯ", "Єремія"), ("ПЛАЧ ЄРЕМІЇ", "Плач Єремії"),
    ("ЄЗЕКІЇЛЯ", "Єзекіїля"), ("ДАНИЇЛА", "Даниїла"), ("ОСІЇ", "Осії"),
    ("ІОЇЛЯ", "Іоїля"), ("АМОСА", "Амоса"), ("АВДІЯ", "Авдія"), ("ІОНИ", "Іони"),
    ("МИХЕЯ", "Михея"), ("НАУМА", "Наума"), ("АВВАКУМА", "Аввакума"),
    ("СОФОНІЇ", "Софонії"), ("АГГЕЯ", "Аггея"), ("ЗАХАРІЇ", "Захарії"),
    ("МАЛАХІЇ", "Малахії"),
    ("ЄВАНГЕЛІЄ ВІД МАТВІЯ", "Євангеліє від Матвія"),
    ("ЄВАНГЕЛІЄ ВІД МАРКА", "Євангеліє від Марка"),
    ("ЄВАНГЕЛІЄ ВІД ЛУКИ", "Євангеліє від Луки"),
    ("ЄВАНГЕЛІЄ ВІД ІОАННА", "Євангеліє від Іоанна"),
    ("ДІЯННЯ АПОСТОЛІВ", "Діяння апостолів"),
    ("ПОСЛАННЯ ЯКОВА", "Послання Якова"),
    ("ПЕРШЕ ПОСЛАННЯ ПЕТРА", "Перше послання Петра"),
    ("ДРУГЕ ПОСЛАННЯ ПЕТРА", "Друге послання Петра"),
    ("ПЕРШЕ ПОСЛАННЯ ІОАННА", "Перше послання Іоанна"),
    ("ДРУГЕ ПОСЛАННЯ ІОАННА", "Друге послання Іоанна"),
    ("ТРЕТЄ ПОСЛАННЯ ІОАННА", "Третє послання Іоанна"),
    ("ПОСЛАННЯ ІУДИ", "Послання Іуди"),
    ("ПОСЛАННЯ ДО РИМЛЯН", "Послання до римлян"),
    ("ПЕРШЕ ПОСЛАННЯ ДО КОРИНФЯН", "Перше послання до коринфян"),
    ("ДРУГЕ ПОСЛАННЯ ДО КОРИНФЯН", "Друге послання до коринфян"),
    ("ПОСЛАННЯ ДО ГАЛАТІВ", "Послання до галатів"),
    ("ПОСЛАННЯ ДО ЕФЕСЯН", "Послання до ефесян"),
    ("ПОСЛАННЯ ДО ФИЛИП’ЯН", "Послання до филип’ян"),
    ("ПОСЛАННЯ ДО КОЛОСЯН", "Послання до колосян"),
    ("ПЕРШЕ ПОСЛАННЯ ДО СОЛУНЯН", "Перше послання до солунян"),
    ("ДРУГЕ ПОСЛАННЯ ДО СОЛУНЯН", "Друге послання до солунян"),
    ("ПЕРШЕ ПОСЛАННЯ ДО ТИМОФІЯ", "Перше послання до Тимофія"),
    ("ДРУГЕ ПОСЛАННЯ ДО ТИМОФІЯ", "Друге послання до Тимофія"),
    ("ПОСЛАННЯ ДО ТИТА", "Послання до Тита"),
    ("ПОСЛАННЯ ДО ФИЛИМОНА", "Послання до Филимона"),
    ("ПОСЛАННЯ ДО ЄВРЕЇВ", "Послання до євреїв"),
    ("ОДКРОВЕННЯ", "Одкровення"),
]


class BookNameCase(unittest.TestCase):
    def test_all_66_gromov_names(self):
        self.assertEqual(len(GRM_NAMES), 66)
        for src, want in GRM_NAMES:
            self.assertEqual(B._uk_book_sentence_case(src), want, src)

    def test_normal_case_untouched(self):
        # Контроль протилежної помилки: Огієнко вже в нормальному регістрі — не чіпати.
        for name in ("До римлян", "Повторення Закону", "1-е Петра", "Дiї"):
            self.assertEqual(B._uk_book_sentence_case(name), name)

    def test_only_gromov_is_normalized(self):
        self.assertEqual(set(B.BOOK_NAME_CASE), {"GRM"})


def make_db(verses):
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE translation (id TEXT PRIMARY KEY, name TEXT, language TEXT, "
                "has_strongs INTEGER NOT NULL DEFAULT 0)")
    con.execute("CREATE TABLE verse (id TEXT, translation TEXT, text TEXT)")
    for tid, texts in verses.items():
        con.execute("INSERT INTO translation (id) VALUES (?)", (tid,))
        con.executemany("INSERT INTO verse VALUES (?,?,?)",
                        [(f"{tid}|{i}", tid, t) for i, t in enumerate(texts)])
    return con


TAGGED = "In the beginning<S>7225</S> God<S>430</S> created<S>1254</S>"
PLAIN = "На початку Бог створив небо та землю."


class HasStrongs(unittest.TestCase):
    def run_mark(self, con):
        with contextlib.redirect_stdout(io.StringIO()):
            B.mark_strongs_translations(con.cursor())
        return dict(con.execute("SELECT id, has_strongs FROM translation"))

    def test_full_and_none(self):
        con = make_db({"KJV": [TAGGED] * 200, "UBIO": [PLAIN] * 200, "XYZ": [PLAIN] * 5})
        self.assertEqual(self.run_mark(con), {"KJV": 1, "UBIO": 0, "XYZ": 0})

    def test_tolerates_a_few_untagged_verses(self):
        # ASV: 31 083 з 31 086 — кілька віршів без жодного тегу (заміряно 2026-10-27).
        con = make_db({"ASV": [TAGGED] * 999 + [PLAIN]})
        self.assertEqual(self.run_mark(con), {"ASV": 1})

    def test_partial_markup_fails(self):
        # Громов ДО зняття приміток «слово»: 1 348 з 31 167 віршів мали <S> — 4.3%.
        con = make_db({"XYZ": [TAGGED] * 43 + [PLAIN] * 957})
        with self.assertRaises(SystemExit):
            self.run_mark(con)

    def test_expected_flag_mismatch_fails(self):
        con = make_db({"UBIO": [TAGGED] * 100})       # Огієнко раптом «розмічений»
        with self.assertRaises(SystemExit):
            self.run_mark(con)


if __name__ == "__main__":
    unittest.main()
