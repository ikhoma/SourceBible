"""Тести strip_commentary_source.py — App Store-модуль коментарів без Spurgeon-VE.

Фікстура — РЕАЛЬНА схема й реальні рядки commentaries-en.db
(fixtures/strip_commentary/README.md). Без мережі й без бази:
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
import strip_commentary_source as M  # noqa: E402

FIX = HERE / "fixtures" / "strip_commentary"
VE, TOD = "Spurgeon-VE", "Spurgeon-TOD"


def make_db(path: Path) -> None:
    con = sqlite3.connect(path)
    con.executescript((FIX / "schema.sql").read_text())
    data = json.loads((FIX / "rows.json").read_text())
    for table, d in data.items():
        cols = ",".join(f'"{c}"' for c in d["cols"])
        con.executemany(f'INSERT INTO "{table}" ({cols}) VALUES ({",".join("?" * len(d["cols"]))})',
                        d["rows"])
    con.execute("INSERT INTO comments_fts(comments_fts) VALUES('rebuild')")
    con.commit()
    con.close()


def ro(p):
    return sqlite3.connect(f"file:{p}?mode=ro", uri=True)


class Strip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.src, self.dst = d / "src.db", d / "dst.db"
        make_db(self.src)

    def tearDown(self):
        self.tmp.cleanup()

    def test_removes_source_rows_and_keeps_every_other_source(self):
        before_c, before_v = M.counts(ro(self.src).cursor())
        self.assertIn(VE, before_c)
        M.strip(self.src, self.dst, VE)
        after_c, after_v = M.counts(ro(self.dst).cursor())
        self.assertNotIn(VE, after_c)
        self.assertNotIn(VE, after_v)
        for s in before_c:
            if s != VE:
                self.assertEqual(after_c[s], before_c[s], s)
                self.assertEqual(after_v[s], before_v[s], s)
        self.assertIn(TOD, after_c, "Treasury of David must stay")

    def test_no_orphan_verse_rows(self):
        M.strip(self.src, self.dst, VE)
        n = ro(self.dst).execute("SELECT COUNT(*) FROM comment_verses v LEFT JOIN comments c "
                                 "ON c.key = v.key WHERE c.key IS NULL").fetchone()[0]
        self.assertEqual(n, 0)

    def test_fts_forgets_the_source(self):
        s = ro(self.src)
        frag = M.unique_text_samples(s.cursor(), VE)[0]
        word = max(frag.split(), key=len).strip(".,;:!?«»\"'()")
        q = ("SELECT c.source FROM comments_fts f JOIN comments c ON c.rowid = f.rowid "
             "WHERE comments_fts MATCH ?")
        self.assertIn(VE, {r[0] for r in s.execute(q, (f'"{word}"',))})
        M.strip(self.src, self.dst, VE)
        d = ro(self.dst)
        self.assertNotIn(VE, {r[0] for r in d.execute(q, (f'"{word}"',))})
        self.assertEqual(d.execute("SELECT COUNT(*) FROM comments_fts_docsize").fetchone(),
                         d.execute("SELECT COUNT(*) FROM comments").fetchone())

    def test_module_info_no_longer_lists_source(self):
        M.strip(self.src, self.dst, VE)
        d = ro(self.dst)
        sources = json.loads(d.execute("SELECT value FROM module_info WHERE name='sources'").fetchone()[0])
        bv = json.loads(d.execute("SELECT value FROM module_info WHERE name='book_versions'").fetchone()[0])
        self.assertNotIn(VE, {s["source"] for s in sources})
        self.assertNotIn(VE, bv)
        self.assertIn(TOD, bv)

    def test_no_source_bytes_and_no_wal(self):
        samples = M.unique_text_samples(ro(self.src).cursor(), VE)
        M.strip(self.src, self.dst, VE)
        blob = self.dst.read_bytes()
        self.assertNotIn(VE.encode(), blob)
        for s in samples:
            self.assertNotIn(s.encode(), blob)
        self.assertEqual(ro(self.dst).execute("PRAGMA journal_mode").fetchone()[0], "delete")

    def test_source_never_modified(self):
        h = hashlib.sha256(self.src.read_bytes()).hexdigest()
        M.strip(self.src, self.dst, VE)
        self.assertEqual(hashlib.sha256(self.src.read_bytes()).hexdigest(), h)

    def test_unknown_source_fails_and_writes_nothing(self):
        with self.assertRaises(SystemExit):
            M.strip(self.src, self.dst, "Nobody")
        self.assertFalse(self.dst.exists())
        self.assertEqual(list(self.dst.parent.glob("*.strip-tmp*")), [])

    def test_cli_refuses_same_src_and_dst(self):
        argv = sys.argv
        sys.argv = ["x", str(self.src), str(self.src)]
        try:
            with self.assertRaises(SystemExit):
                M.main()
        finally:
            sys.argv = argv


if __name__ == "__main__":
    unittest.main()
