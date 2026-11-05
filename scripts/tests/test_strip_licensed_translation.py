"""Тести strip_licensed_translation.py — App Store-база без NASB.

Фікстура — РЕАЛЬНА схема й реальні рядки Бут. 1:1–10 у п'яти перекладах
(fixtures/strip_translation/README.md). Без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""
import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import strip_licensed_translation as M  # noqa: E402

FIX = HERE / "fixtures" / "strip_translation"


def make_db(path: Path) -> None:
    con = sqlite3.connect(path)
    con.executescript((FIX / "schema.sql").read_text())
    data = json.loads((FIX / "gen1.json").read_text())
    for table, d in data.items():
        cols = ",".join(f'"{c}"' for c in d["cols"])
        marks = ",".join("?" * len(d["cols"]))
        con.executemany(f'INSERT INTO "{table}" ({cols}) VALUES ({marks})', d["rows"])
    con.execute("INSERT INTO verse_fts(verse_fts) VALUES('rebuild')")
    con.execute("PRAGMA journal_mode=WAL")        # shipped DB is WAL — reproduce it
    con.commit()
    cur = con.cursor()
    M.build_search_terms(cur, con)
    con.commit()
    con.close()


def nasb_only_word(con) -> str:
    """A word that occurs ≥2× in NASB Gen 1:1–10 (search_terms drops hapaxes) and in no
    other English translation there."""
    import re
    from collections import Counter
    word = re.compile(r"[A-Za-z']+")
    def words(tid):
        return Counter(w.lower() for (t,) in con.execute(
            "SELECT text_clean FROM verse WHERE translation=?", (tid,)) for w in word.findall(t))
    nasb, other = words("NASB"), set(words("KJV")) | set(words("ASV"))
    only = sorted(w for w, n in nasb.items() if n >= 2 and len(w) >= 2 and w not in other)
    assert only, "fixture has no NASB-only word with freq >= 2"
    return only[0]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Strip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.src, self.dst = d / "src.db", d / "dst.db"
        make_db(self.src)
        # The real dictionary gate checks words that 10 verses of Genesis cannot contain
        # ('shepherd', 'щоб', …). It is exercised by the full-DB run; here it is stubbed.
        self._verify = M.verify_search_terms
        M.verify_search_terms = lambda cur: []

    def tearDown(self):
        M.verify_search_terms = self._verify
        self.tmp.cleanup()

    def ro(self, p):
        return sqlite3.connect(f"file:{p}?mode=ro", uri=True)

    def test_removes_every_nasb_row_and_keeps_the_rest(self):
        s = self.ro(self.src)
        before = {t: dict(s.execute(f'SELECT "{c}", COUNT(*) FROM "{t}" GROUP BY 1'))
                  for t, c in M.DELETES}
        M.strip(self.src, self.dst, "NASB")
        d = self.ro(self.dst)
        for t, c in M.DELETES:
            after = dict(d.execute(f'SELECT "{c}", COUNT(*) FROM "{t}" GROUP BY 1'))
            self.assertNotIn("NASB", after, t)
            for tid, n in before[t].items():
                if tid != "NASB":
                    self.assertEqual(after.get(tid), n, f"{t}[{tid}] changed")
        self.assertEqual(d.execute("SELECT COUNT(*) FROM footnote").fetchone(),
                         s.execute("SELECT COUNT(*) FROM footnote").fetchone())

    def test_source_is_never_modified(self):
        h = sha(self.src)
        M.strip(self.src, self.dst, "NASB")
        self.assertEqual(sha(self.src), h)

    def test_fts_forgets_nasb_but_finds_the_rest(self):
        word = nasb_only_word(self.ro(self.src))
        s = self.ro(self.src)
        self.assertGreater(s.execute("SELECT COUNT(*) FROM verse_fts WHERE verse_fts MATCH ?",
                                     (f'"{word}"',)).fetchone()[0], 0)
        M.strip(self.src, self.dst, "NASB")
        d = self.ro(self.dst)
        self.assertEqual(d.execute("SELECT COUNT(*) FROM verse_fts WHERE verse_fts MATCH ?",
                                   (f'"{word}"',)).fetchone()[0], 0)
        q = ("SELECT COUNT(*) FROM verse_fts f JOIN verse v ON v.rowid=f.rowid "
             "WHERE verse_fts MATCH '\"beginning\"' AND v.translation IN ('KJV','ASV')")
        self.assertEqual(d.execute(q).fetchone(), s.execute(q).fetchone())

    def test_search_terms_rebuilt_without_nasb_vocabulary(self):
        word = nasb_only_word(self.ro(self.src))
        s = self.ro(self.src)
        self.assertEqual(s.execute("SELECT COUNT(*) FROM search_terms WHERE term=? AND lang='en'",
                                   (word,)).fetchone()[0], 1, "fixture: term must exist before")
        M.strip(self.src, self.dst, "NASB")
        d = self.ro(self.dst)
        self.assertEqual(d.execute("SELECT COUNT(*) FROM search_terms WHERE term=?",
                                   (word,)).fetchone()[0], 0)
        self.assertEqual(d.execute("SELECT COUNT(*) FROM search_terms WHERE term='god' "
                                   "AND lang='en'").fetchone()[0], 1)

    def test_no_nasb_bytes_and_no_wal_in_output(self):
        M.strip(self.src, self.dst, "NASB")
        self.assertNotIn(b"NASB", self.dst.read_bytes())
        self.assertEqual(self.ro(self.dst).execute("PRAGMA journal_mode").fetchone()[0], "delete")
        self.assertFalse(Path(str(self.dst) + "-wal").exists())

    def test_unlisted_table_referencing_nasb_fails_and_writes_nothing(self):
        con = sqlite3.connect(self.src)
        con.execute("CREATE TABLE future_feature (translation TEXT, x INTEGER)")
        con.execute("INSERT INTO future_feature VALUES ('NASB', 1)")
        con.commit(); con.close()
        with self.assertRaises(SystemExit) as e:
            M.strip(self.src, self.dst, "NASB")
        self.assertIn("future_feature.translation", str(e.exception))
        self.assertFalse(self.dst.exists())
        self.assertEqual(list(self.dst.parent.glob("*.strip-tmp*")), [])

    def test_missing_translation_fails(self):
        with self.assertRaises(SystemExit):
            M.strip(self.src, self.dst, "XYZ")
        self.assertFalse(self.dst.exists())

    def test_existing_dst_replaced_atomically(self):
        self.dst.write_bytes(b"old")
        M.strip(self.src, self.dst, "NASB")
        self.assertEqual(self.ro(self.dst).execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_cli_refuses_same_src_and_dst(self):
        argv = sys.argv
        sys.argv = ["x", str(self.src), str(self.src)]
        try:
            with self.assertRaises(SystemExit):
                M.main()
        finally:
            sys.argv = argv


    # ── кілька перекладів за один прохід (NASB + GRM в App Store-збірці, 2026-10-26) ──
    # UBIO тут — дублер GRM (український, синодальна нумерація). У фікстурі виноски має
    # лише ASV, тож додаємо одну у формі, яку пише build_db для GRM (маркер `[1]`), —
    # щоб покрити рядок `footnote` у DELETES. (ASV як дублер не годиться: у Бут 1 він
    # майже дослівно = KJV, зразків для байтової перевірки не набереться.)
    def add_ubio_footnote(self):
        con = sqlite3.connect(self.src)
        con.execute("INSERT INTO footnote (translation, book_id, chapter_from, verse_from, "
                    "chapter_to, verse_to, marker, text) VALUES "
                    "('UBIO','GEN',1,1,1,1,'[1]','Примітка перекладача до Бут 1:1')")
        con.commit()
        con.close()

    def test_strips_several_translations_in_one_pass(self):
        self.add_ubio_footnote()
        s = self.ro(self.src)
        gone = ("NASB", "UBIO")
        before = {t: dict(s.execute(f'SELECT "{c}", COUNT(*) FROM "{t}" GROUP BY 1'))
                  for t, c in M.DELETES}
        self.assertGreater(before["footnote"].get("UBIO", 0), 0)
        M.strip(self.src, self.dst, list(gone))
        d = self.ro(self.dst)
        for t, c in M.DELETES:
            after = dict(d.execute(f'SELECT "{c}", COUNT(*) FROM "{t}" GROUP BY 1'))
            for tid in gone:
                self.assertNotIn(tid, after, f"{t} still has {tid}")
            for tid, n in before[t].items():
                if tid not in gone:
                    self.assertEqual(after.get(tid), n, f"{t}[{tid}] changed")
        blob = self.dst.read_bytes()
        for tid in gone:
            self.assertNotIn(f"{tid}|".encode(), blob)

    def test_duplicate_or_empty_translation_list_fails(self):
        for bad in (["NASB", "NASB"], []):
            with self.assertRaises(SystemExit):
                M.strip(self.src, self.dst, bad)
            self.assertFalse(self.dst.exists())

    def test_cli_translation_is_repeatable(self):
        argv = sys.argv
        sys.argv = ["x", str(self.src), str(self.dst), "--translation", "NASB", "--translation", "UBIO"]
        try:
            self.assertEqual(M.main(), 0)
        finally:
            sys.argv = argv
        ids = {r[0] for r in self.ro(self.dst).execute("SELECT id FROM translation")}
        self.assertEqual(ids & {"NASB", "UBIO"}, set())


class AppStorePhase(unittest.TestCase):
    """Build-фаза AppStore мусить вирізати КОЖЕН переклад, який не можна шипити.
    Скрипт уже вмів кілька id, а фаза передавала лише NASB — Громов поїхав би в App Store
    (зловлено ревʼю 2026-10-26). Тест читає сам project.pbxproj."""
    MUST_STRIP = {"NASB", "GRM"}

    def test_phase_passes_every_unlicensed_translation(self):
        import re
        pbx = (HERE.parent.parent / "SourceBible.xcodeproj" / "project.pbxproj").read_text()
        calls = [line for line in pbx.split("\\n") if "strip_licensed_translation.py" in line
                 and not line.lstrip().startswith("#") and "$PY" in line]
        self.assertEqual(len(calls), 1, f"expected one strip call in the phase, got {calls}")
        got = set(re.findall(r"--translation\s+([A-Z]+)", calls[0]))
        self.assertEqual(got, self.MUST_STRIP)

if __name__ == "__main__":
    unittest.main()
