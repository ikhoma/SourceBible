"""Тести check_bundle_db.py — гейт складу/розміру sourcebible.db перед бандлом.

Головний регресійний випадок — реальні CREATE-и старих `comments`/`comment_verses`
(взяті з бандленої бази 2026-11-05), які rebuild.sh роками дописував у
sourcebible.db після переїзду коментарів у commentaries-en.db (ADR-027).
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
import check_bundle_db as M  # noqa: E402

FTS_SHADOW = {"verse_fts_config", "verse_fts_data", "verse_fts_docsize", "verse_fts_idx"}

# Дослівно з sqlite_schema бандленої бази (до виправлення).
LEGACY_COMMENTS = """
CREATE TABLE comments (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            source        TEXT    NOT NULL,
            book_id       TEXT    NOT NULL,
            start_chapter INTEGER NOT NULL,
            start_verse   INTEGER NOT NULL,
            end_chapter   INTEGER NOT NULL,
            end_verse     INTEGER NOT NULL,
            text          TEXT    NOT NULL
        );
CREATE TABLE comment_verses (book_id TEXT, chapter INTEGER, verse INTEGER,
            comment_id INTEGER, PRIMARY KEY (book_id, chapter, verse, comment_id));
"""


def make_clean_db(path: Path, skip: frozenset = frozenset()) -> None:
    con = sqlite3.connect(path)
    for name in sorted(M.PROFILES["core"]["allowed"] - FTS_SHADOW - {"verse_fts", "verse"} - skip):
        con.execute(f'CREATE TABLE "{name}" (id INTEGER PRIMARY KEY)')
    if "verse" not in skip:
        con.execute("CREATE TABLE verse (id INTEGER PRIMARY KEY, text_clean TEXT)")
    # Дослівно з бандленої бази: external-content FTS5 над verse — дає 4 тіньові
    # таблиці БЕЗ verse_fts_content (звичайна fts5 мала б і її).
    con.execute("""CREATE VIRTUAL TABLE verse_fts USING fts5(
            text_clean,
            content='verse',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        )""")
    con.commit()
    con.close()


class CheckBundleDb(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "sourcebible.db"

    def tearDown(self):
        self.tmp.cleanup()

    def test_fts5_really_creates_the_listed_shadow_tables(self):
        # Еталон для самої фікстури: якщо SQLite колись назве тіньові таблиці
        # інакше, allow-list мусить це помітити, а не тест — замаскувати.
        make_clean_db(self.db)
        con = sqlite3.connect(self.db)
        names = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_schema WHERE type='table'")}
        con.close()
        self.assertTrue(FTS_SHADOW <= names, names)

    def test_clean_db_passes(self):
        make_clean_db(self.db)
        self.assertEqual(M.check(str(self.db), max_mb=350), [])
        self.assertEqual(M.main([str(self.db)]), 0)

    def test_legacy_comments_tables_fail(self):
        # Регресія 2026-11-05: до виправлення ця база йшла в бандл.
        make_clean_db(self.db)
        con = sqlite3.connect(self.db)
        con.executescript(LEGACY_COMMENTS)
        con.execute("INSERT INTO comments(source,book_id,start_chapter,start_verse,"
                    "end_chapter,end_verse,text) VALUES('Calvin','GEN',1,1,1,1,'x')")
        con.commit()
        con.close()
        problems = M.check(str(self.db), max_mb=350)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("comment_verses", problems[0])
        self.assertIn("comments", problems[0])
        self.assertEqual(M.main([str(self.db)]), 1)

    def test_sqlite_sequence_from_autoincrement_is_optional(self):
        # Контроль: службова таблиця не має валити гейт.
        make_clean_db(self.db)
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE IF NOT EXISTS t_auto (id INTEGER PRIMARY KEY AUTOINCREMENT)")
        con.execute("INSERT INTO t_auto DEFAULT VALUES")
        con.execute("DROP TABLE t_auto")   # sqlite_sequence лишається
        con.execute("ANALYZE")             # sqlite_stat1
        con.commit()
        con.close()
        self.assertEqual(M.check(str(self.db), max_mb=350), [])

    def test_missing_table_fails(self):
        make_clean_db(self.db, skip=frozenset({"verse_org"}))
        problems = M.check(str(self.db), max_mb=350)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("verse_org", problems[0])

    def test_oversize_fails(self):
        make_clean_db(self.db)
        problems = M.check(str(self.db), max_mb=0.001)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("розмір", problems[0])

    def test_gate_leaves_no_sidecar_files_next_to_wal_db(self):
        # Регресія 2026-11-05: mode=ro на WAL-базі лишив sourcebible.db-shm у Resources/.
        make_clean_db(self.db)
        con = sqlite3.connect(self.db)
        con.execute("PRAGMA journal_mode=WAL")
        con.close()
        before = sorted(p.name for p in self.db.parent.iterdir())
        M.check(str(self.db), max_mb=350)
        self.assertEqual(sorted(p.name for p in self.db.parent.iterdir()), before)

    def _word_with(self, cols_sql: str, rows: str = ""):
        make_clean_db(self.db, skip=frozenset({"word"}))
        con = sqlite3.connect(self.db)
        con.execute(f"CREATE TABLE word (id TEXT PRIMARY KEY, book_id TEXT, chapter INT, "
                    f"verse INT, slot INT{cols_sql})")
        if rows:
            con.execute(rows)
        con.commit()
        con.close()

    def test_finalized_word_passes(self):
        self._word_with(", gloss TEXT, gloss_macula TEXT, gloss_display TEXT",
                        "INSERT INTO word VALUES('GEN|1|1|1','GEN',1,1,1,NULL,NULL,'in')")
        self.assertEqual(M.check(str(self.db), max_mb=350), [])

    def test_unfinalized_word_fails_on_each_leftover(self):
        # Форма бази ДО finalize_bundle_db.py — так виглядала база в бандлі 2026-11-05.
        self._word_with(", lemma TEXT, language TEXT, gloss TEXT, gloss_macula TEXT",
                        "INSERT INTO word VALUES('GEN|1|1|1','GEN',1,1,1,'x','hbo','in','in')")
        con = sqlite3.connect(self.db)
        con.execute("CREATE INDEX idx_word_verse ON word(book_id, chapter, verse)")
        con.commit()
        con.close()
        text = " | ".join(M.check(str(self.db), max_mb=350))
        for needle in ("lemma", "language", "word.gloss:", "word.gloss_macula:",
                       "idx_word_verse"):
            self.assertIn(needle, text)

    def test_commentary_profile_rejects_fts(self):
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE comments (key TEXT PRIMARY KEY, text TEXT)")
        con.execute("CREATE TABLE comment_verses (key TEXT, book_id TEXT)")
        con.execute("CREATE TABLE module_info (name TEXT PRIMARY KEY, value TEXT)")
        con.commit()
        self.assertEqual(M.check(str(self.db), kind="commentary"), [])
        # Дослівно як будує build_commentary_db.py (до 2026-11-05 — завжди).
        con.execute("""CREATE VIRTUAL TABLE comments_fts USING fts5(
            text, content='comments', content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2')""")
        con.commit()
        con.close()
        problems = M.check(str(self.db), kind="commentary")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("comments_fts", problems[0])

    def test_stray_files_found_and_controls_ignored(self):
        app = Path(self.tmp.name) / "App"
        (app / "Resources").mkdir(parents=True)
        for f in ("Resources/sourcebible.db-shm", "Resources/sourcebible.db-wal",
                  "Resources/.fuse_hidden0000001700000001", "Localizable.xcstrings.bak",
                  # контролі — легітимні файли бандла
                  "Resources/sourcebible.db", "Localizable.xcstrings", "Resources/x.ttf"):
            (app / f).write_bytes(b"")
        names = [Path(p).name for p in M.stray_files(str(app))]
        self.assertEqual(sorted(names), sorted([
            "sourcebible.db-shm", "sourcebible.db-wal",
            ".fuse_hidden0000001700000001", "Localizable.xcstrings.bak"]))
        make_clean_db(self.db)
        self.assertEqual(M.main([str(self.db), "--app-dir", str(app)]), 1)

    def test_missing_file_fails(self):
        self.assertEqual(M.main([str(self.db)]), 1)


if __name__ == "__main__":
    unittest.main()
