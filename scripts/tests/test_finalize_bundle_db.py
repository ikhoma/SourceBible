"""Тести finalize_bundle_db.py — схудла копія бази для бандла.

Форма word відтворює РЕАЛЬНУ: Swift читає COALESCE(gloss_display, gloss_macula, gloss),
тому колонки gloss/gloss_macula мусять лишитись (лише обнулені), а обнулення
дозволене тільки коли запасні гілки COALESCE ніде не спрацьовують.
Без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import check_bundle_db as G  # noqa: E402
import finalize_bundle_db as M  # noqa: E402

# Реальні значення (Бут 1:1 בָּרָא: Cherith `created`, SIL `he.created`, показ `he.created`).
WORDS = [
    # id, book, ch, v, pos, slot, lemma, language, gloss, gloss_macula, gloss_display
    ("GEN|1|1|1", "GEN", 1, 1, 1, 1, "רֵאשִׁית", "hbo", "beginning", "in.beginning", "in the beginning"),
    ("GEN|1|1|2", "GEN", 1, 1, 2, 2, "בָּרָא", "hbo", "created", "he.created", "he.created"),
    # порожня показана глоса з порожніми запасними — легальний випадок (3 100 таких у базі)
    ("GEN|1|1|3", "GEN", 1, 1, 3, 3, "אֵת", "hbo", None, None, None),
]


def make_core(path: Path, words=WORDS) -> None:
    con = sqlite3.connect(path)
    con.execute("""CREATE TABLE word (id TEXT PRIMARY KEY, book_id TEXT NOT NULL,
        chapter INTEGER NOT NULL, verse INTEGER NOT NULL, position INTEGER NOT NULL,
        slot INTEGER, lemma TEXT, language TEXT NOT NULL, gloss TEXT,
        gloss_macula TEXT, gloss_display TEXT)""")
    con.execute("CREATE INDEX idx_word_verse ON word(book_id, chapter, verse)")
    con.execute("CREATE INDEX idx_word_slot ON word(book_id, chapter, verse, slot)")
    con.executemany("INSERT INTO word VALUES (?,?,?,?,?,?,?,?,?,?,?)", words)
    con.execute("PRAGMA journal_mode=WAL")     # бандлена база — WAL
    con.commit()
    con.close()


def display(path: Path) -> list:
    con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    rows = [r[0] for r in con.execute(M.DISPLAY_GLOSS_SQL)]
    con.close()
    return rows


class FinalizeCore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.src, self.dst = self.d / "src.db", self.d / "dst.db"

    def tearDown(self):
        self.tmp.cleanup()

    def test_slims_copy_and_keeps_display_gloss(self):
        make_core(self.src)
        before = display(self.src)
        self.assertEqual(M.main(["--kind", "core", str(self.src), str(self.dst)]), 0)
        self.assertEqual(display(self.dst), before)
        con = sqlite3.connect(f"file:{self.dst}?mode=ro&immutable=1", uri=True)
        cols = {r[1] for r in con.execute("PRAGMA table_info(word)")}
        self.assertTrue({"gloss", "gloss_macula", "gloss_display"} <= cols)  # Swift читає
        self.assertFalse({"lemma", "language"} & cols)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM word WHERE gloss IS NOT NULL "
                                     "OR gloss_macula IS NOT NULL").fetchone()[0], 0)
        ix = {r[0] for r in con.execute("SELECT name FROM sqlite_schema WHERE type='index'")}
        self.assertNotIn("idx_word_verse", ix)
        self.assertIn("idx_word_slot", ix)                                      # контроль
        con.close()

    def test_source_is_untouched(self):
        make_core(self.src)
        raw = self.src.read_bytes()
        M.run("core", self.src, self.dst)
        self.assertEqual(self.src.read_bytes(), raw)

    def test_output_passes_bundle_gate_rules(self):
        make_core(self.src)
        M.run("core", self.src, self.dst)
        text = " | ".join(G.check(str(self.dst), max_mb=350))
        for needle in ("lemma", "language", "gloss", "idx_word_verse"):
            self.assertNotIn(needle, text)

    def test_refuses_when_fallback_gloss_would_be_shown(self):
        # gloss_display порожня, але gloss_macula ні → COALESCE показує запасну;
        # обнулення змінило б показ. Мусить впасти і НЕ лишити dst.
        bad = WORDS + [("GEN|1|1|4", "GEN", 1, 1, 4, 4, "שָׁמַיִם", "hbo",
                        "heavens", "the.heavens", None)]
        make_core(self.src, bad)
        self.assertEqual(M.main(["--kind", "core", str(self.src), str(self.dst)]), 1)
        self.assertFalse(self.dst.exists())
        self.assertEqual([p.name for p in self.d.iterdir() if "finalize-tmp" in p.name], [])

    def test_refuses_same_file(self):
        make_core(self.src)
        with self.assertRaises(M.FinalizeError):
            M.run("core", self.src, self.src)

    def test_leaves_nothing_but_src_and_dst(self):
        # Регресія 2026-11-05: після першого rebuild у корені лишився
        # sourcebible.bundle.db.finalize-tmp-shm (WAL-індекс тимчасової копії).
        make_core(self.src)
        before = {p.name for p in self.d.iterdir()}       # src.db (+ можливо його -wal/-shm)
        M.run("core", self.src, self.dst)
        self.assertEqual({p.name for p in self.d.iterdir()} - before, {"dst.db"})


class FinalizeCommentary(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.src, self.dst = self.d / "c.db", self.d / "out.db"
        con = sqlite3.connect(self.src)
        con.execute("CREATE TABLE comments (key TEXT PRIMARY KEY, source TEXT, text TEXT)")
        con.execute("CREATE TABLE comment_verses (key TEXT, book_id TEXT, chapter INT, verse INT)")
        con.execute("CREATE TABLE module_info (name TEXT PRIMARY KEY, value TEXT)")
        con.executemany("INSERT INTO comments VALUES (?,?,?)",
                        [("k1", "Calvin", "In the beginning."), ("k2", "Henry", "The shepherd")])
        con.executemany("INSERT INTO comment_verses VALUES (?,?,?,?)",
                        [("k1", "GEN", 1, 1), ("k2", "PSA", 23, 1)])
        con.execute("INSERT INTO module_info VALUES ('language','en')")
        con.execute("""CREATE VIRTUAL TABLE comments_fts USING fts5(text, content='comments',
            content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')""")
        con.execute("INSERT INTO comments_fts(comments_fts) VALUES('rebuild')")
        con.commit()
        con.close()

    def tearDown(self):
        self.tmp.cleanup()

    def test_drops_fts_keeps_rows(self):
        self.assertEqual(M.main(["--kind", "commentary", str(self.src), str(self.dst)]), 0)
        self.assertEqual(G.check(str(self.dst), kind="commentary", max_mb=10), [])
        con = sqlite3.connect(f"file:{self.dst}?mode=ro&immutable=1", uri=True)
        self.assertEqual(con.execute("SELECT text FROM comments ORDER BY key").fetchall(),
                         [("In the beginning.",), ("The shepherd",)])
        con.close()

    def test_idempotent_on_already_finalized(self):
        M.run("commentary", self.src, self.dst)
        out2 = self.d / "out2.db"
        M.run("commentary", self.dst, out2)
        self.assertEqual(G.check(str(out2), kind="commentary", max_mb=10), [])


if __name__ == "__main__":
    unittest.main()
