#!/usr/bin/env python3
"""
migrate_add_book_names.py
─────────────────────────
Adds the `book_name` table to an existing sourcebible.db and populates it
from the MyBible source ZIPs — without a full rebuild.

Run from the project root:
    python3 scripts/migrate_add_book_names.py

Or point at a specific DB:
    python3 scripts/migrate_add_book_names.py path/to/sourcebible.db
"""

import os
import sys
import sqlite3
import tempfile
import zipfile
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────

ROOT     = Path(__file__).parent.parent
DATA_DIR = ROOT / "data"
OUTPUT_DB = ROOT / "sourcebible.db"

if len(sys.argv) > 1:
    OUTPUT_DB = Path(sys.argv[1])

# ── Translation source files (must match build_db.py TRANSLATIONS) ─────────

TRANSLATIONS = [
    ("KJV",  "King James Version",          "en", DATA_DIR / "KJV+.zip"),
    ("ASV",  "American Standard Version",   "en", DATA_DIR / "ASV+.zip"),
    ("NASB", "New American Standard Bible", "en", DATA_DIR / "NASB+.zip"),
    ("RST",  "Синодальний переклад",        "ru", DATA_DIR / "RST+.zip"),
]

# ── Canonical book list (must match build_db.py BOOKS) ─────────────────────

BOOKS = [
    ( 1,"GEN","OT","Genesis",        50),
    ( 2,"EXO","OT","Exodus",         40),
    ( 3,"LEV","OT","Leviticus",      27),
    ( 4,"NUM","OT","Numbers",        36),
    ( 5,"DEU","OT","Deuteronomy",    34),
    ( 6,"JOS","OT","Joshua",         24),
    ( 7,"JDG","OT","Judges",         21),
    ( 8,"RUT","OT","Ruth",            4),
    ( 9,"1SA","OT","1 Samuel",       31),
    (10,"2SA","OT","2 Samuel",       24),
    (11,"1KI","OT","1 Kings",        22),
    (12,"2KI","OT","2 Kings",        25),
    (13,"1CH","OT","1 Chronicles",   29),
    (14,"2CH","OT","2 Chronicles",   36),
    (15,"EZR","OT","Ezra",           10),
    (16,"NEH","OT","Nehemiah",       13),
    (17,"EST","OT","Esther",         10),
    (18,"JOB","OT","Job",            42),
    (19,"PSA","OT","Psalms",        150),
    (20,"PRO","OT","Proverbs",       31),
    (21,"ECC","OT","Ecclesiastes",   12),
    (22,"SNG","OT","Song of Solomon", 8),
    (23,"ISA","OT","Isaiah",         66),
    (24,"JER","OT","Jeremiah",       52),
    (25,"LAM","OT","Lamentations",    5),
    (26,"EZK","OT","Ezekiel",        48),
    (27,"DAN","OT","Daniel",         12),
    (28,"HOS","OT","Hosea",          14),
    (29,"JOL","OT","Joel",            3),
    (30,"AMO","OT","Amos",            9),
    (31,"OBA","OT","Obadiah",         1),
    (32,"JON","OT","Jonah",           4),
    (33,"MIC","OT","Micah",           7),
    (34,"NAM","OT","Nahum",           3),
    (35,"HAB","OT","Habakkuk",        3),
    (36,"ZEP","OT","Zephaniah",       3),
    (37,"HAG","OT","Haggai",          2),
    (38,"ZEC","OT","Zechariah",      14),
    (39,"MAL","OT","Malachi",         4),
    (40,"MAT","NT","Matthew",        28),
    (41,"MRK","NT","Mark",           16),
    (42,"LUK","NT","Luke",           24),
    (43,"JHN","NT","John",           21),
    (44,"ACT","NT","Acts",           28),
    (45,"ROM","NT","Romans",         16),
    (46,"1CO","NT","1 Corinthians",  16),
    (47,"2CO","NT","2 Corinthians",  13),
    (48,"GAL","NT","Galatians",       6),
    (49,"EPH","NT","Ephesians",       6),
    (50,"PHP","NT","Philippians",     4),
    (51,"COL","NT","Colossians",      4),
    (52,"1TH","NT","1 Thessalonians", 5),
    (53,"2TH","NT","2 Thessalonians", 3),
    (54,"1TI","NT","1 Timothy",       6),
    (55,"2TI","NT","2 Timothy",       4),
    (56,"TIT","NT","Titus",           3),
    (57,"PHM","NT","Philemon",        1),
    (58,"HEB","NT","Hebrews",        13),
    (59,"JAS","NT","James",           5),
    (60,"1PE","NT","1 Peter",         5),
    (61,"2PE","NT","2 Peter",         3),
    (62,"1JN","NT","1 John",          5),
    (63,"2JN","NT","2 John",          1),
    (64,"3JN","NT","3 John",          1),
    (65,"JUD","NT","Jude",            1),
    (66,"REV","NT","Revelation",     22),
]

# ── Helpers (mirrors build_db.py) ───────────────────────────────────────────

def _open_mybible_sqlite(path):
    path = Path(path)
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as z:
            candidates = [n for n in z.namelist()
                          if n.lower().endswith(".sqlite3") and "comment" not in n.lower()]
            if not candidates:
                candidates = [n for n in z.namelist() if n.lower().endswith(".sqlite3")]
            if not candidates:
                raise RuntimeError(f"No .SQLite3 found inside {path.name}")
            data = z.read(candidates[0])
        tmp = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
        tmp.write(data)
        tmp.close()
        return sqlite3.connect(tmp.name), tmp.name
    else:
        return sqlite3.connect(str(path)), None


def _build_book_mapping(src, tname, book_col):
    nums    = sorted(int(r[0]) for r in src.execute(f'SELECT DISTINCT "{book_col}" FROM "{tname}"'))
    ot_nums = [n for n in nums if n < 470]
    nt_nums = [n for n in nums if n >= 470]
    ot_osis = [b[1] for b in BOOKS if b[2] == "OT"]
    nt_osis = [b[1] for b in BOOKS if b[2] == "NT"]
    mapping = {}
    for i, num in enumerate(ot_nums):
        if i < len(ot_osis):
            mapping[num] = ot_osis[i]
    for i, num in enumerate(nt_nums):
        if i < len(nt_osis):
            mapping[num] = nt_osis[i]
    return mapping


def _detect_verse_table(src):
    """Return (table_name, book_col) — enough for book mapping."""
    cur = src.cursor()
    tables = {r[0].lower(): r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for tname_lower in ("verses", "bible", "verse", "t"):
        if tname_lower not in tables:
            continue
        tname = tables[tname_lower]
        cols  = {r[1].lower(): r[1] for r in cur.execute(f"PRAGMA table_info('{tname}')")}
        book_col = next((cols[c] for c in ("book_number","book","b","bnumber","bk") if c in cols), None)
        if book_col:
            return tname, book_col
    raise RuntimeError("Cannot detect verse table for book mapping")


def _extract_book_names(src, book_mapping):
    try:
        rows = src.execute(
            "SELECT book_number, long_name, short_name FROM books ORDER BY book_number"
        ).fetchall()
    except Exception:
        return []

    result = []
    for sort_order, (book_num, long_name, short_name) in enumerate(rows):
        osis = book_mapping.get(int(book_num))
        if osis and long_name:
            result.append((osis, long_name.strip(), (short_name or long_name).strip(), sort_order))
    return result


# ── Migration ───────────────────────────────────────────────────────────────

def migrate(db_path):
    print(f"Target DB: {db_path}")
    if not db_path.exists():
        print(f"  ERROR: {db_path} not found.")
        sys.exit(1)

    con = sqlite3.connect(str(db_path))
    cur = con.cursor()

    # 1. Create table (idempotent)
    cur.executescript("""
        CREATE TABLE IF NOT EXISTS book_name (
            book_id        TEXT NOT NULL,
            translation_id TEXT NOT NULL,
            long_name      TEXT NOT NULL,
            short_name     TEXT NOT NULL,
            sort_order     INTEGER NOT NULL,
            PRIMARY KEY (book_id, translation_id),
            FOREIGN KEY (book_id)        REFERENCES book(id),
            FOREIGN KEY (translation_id) REFERENCES translation(id)
        );
        CREATE INDEX IF NOT EXISTS idx_book_name_tid ON book_name(translation_id);
    """)
    con.commit()
    print("  book_name table ready.")

    # 2. Populate from source ZIPs
    for (tid, name, lang, zip_path) in TRANSLATIONS:
        if not Path(zip_path).exists():
            print(f"  SKIP [{tid}]: {zip_path.name} not found in data/")
            continue

        print(f"  [{tid}] extracting book names...")
        try:
            src, tmp_path = _open_mybible_sqlite(zip_path)
        except Exception as e:
            print(f"    ERROR opening source: {e}")
            continue

        try:
            tname, book_col = _detect_verse_table(src)
            book_mapping    = _build_book_mapping(src, tname, book_col)
            book_name_rows  = _extract_book_names(src, book_mapping)
        except Exception as e:
            print(f"    ERROR: {e}")
            src.close()
            if tmp_path:
                os.unlink(tmp_path)
            continue

        src.close()
        if tmp_path:
            os.unlink(tmp_path)

        if book_name_rows:
            cur.executemany(
                "INSERT OR REPLACE INTO book_name "
                "(book_id, translation_id, long_name, short_name, sort_order) VALUES (?,?,?,?,?)",
                [(osis, tid, long, short, order) for (osis, long, short, order) in book_name_rows]
            )
            print(f"    {len(book_name_rows)} book names inserted.")
        else:
            # Fallback: use canonical English names
            fallback = [(b[1], tid, b[3], b[3], b[0] - 1) for b in BOOKS]
            cur.executemany(
                "INSERT OR IGNORE INTO book_name "
                "(book_id, translation_id, long_name, short_name, sort_order) VALUES (?,?,?,?,?)",
                fallback
            )
            print(f"    No `books` table in source — used name_en fallback ({len(fallback)} rows).")

        con.commit()

    # 3. Summary
    total = cur.execute("SELECT COUNT(*) FROM book_name").fetchone()[0]
    print(f"\nDone. {total} rows in book_name.")
    con.close()


if __name__ == "__main__":
    migrate(OUTPUT_DB)
