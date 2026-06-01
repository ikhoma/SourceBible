#!/usr/bin/env python3
"""
add_after_char.py — Fast migration: add after_char column to existing sourcebible.db
---------------------------------------------------------------------------------------
Reads the Macula Hebrew XML lowfat files (same files used by build_db.py) and populates
the new `after_char` column without a full DB rebuild (~1 min vs ~10 min).

Usage:
    cd ~/Projects/SourceBible
    python3 scripts/add_after_char.py [path/to/sourcebible.db]

    # Default DB path if omitted:
    python3 scripts/add_after_char.py
    # → uses sourcebible.db in the project root

After running:
    cp sourcebible.db SourceBible/Resources/sourcebible.db
    # Xcode: ⇧⌘K → Run
"""

import sqlite3, zipfile, re, sys, xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# ─────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────

ROOT           = Path(__file__).parent.parent
DATA_DIR       = ROOT / "data"
MACULA_HEB_ZIP = DATA_DIR / "macula-hebrew-main.zip"

DEFAULT_DB     = ROOT / "sourcebible.db"

# Maps OSIS book IDs → Macula Hebrew 3-letter abbreviations used in filenames
# (mirrors _MACULA_HEB_ABBR in build_db.py — kept in sync manually)
_MACULA_HEB_ABBR = {
    '1CH':'1Ch','1KI':'1Ki','1SA':'1Sa','2CH':'2Ch','2KI':'2Ki','2SA':'2Sa',
    'AMO':'Amo','DAN':'Dan','DEU':'Deu','ECC':'Ecc','EST':'Est','EXO':'Exo',
    'EZK':'Ezk','EZR':'Ezr','GEN':'Gen','HAB':'Hab','HAG':'Hag','HOS':'Hos',
    'ISA':'Isa','JDG':'Jdg','JER':'Jer','JOB':'Job','JOL':'Jol','JON':'Jon',
    'JOS':'Jos','LAM':'Lam','LEV':'Lev','MAL':'Mal','MIC':'Mic','NAM':'Nam',
    'NEH':'Neh','NUM':'Num','OBA':'Oba','PRO':'Pro','PSA':'Psa','RUT':'Rut',
    'SNG':'Sng','ZEC':'Zec','ZEP':'Zep',
}

# ─────────────────────────────────────────────
# Helpers (mirror build_db.py logic exactly)
# ─────────────────────────────────────────────

def _xml_nodes_for_chapter(zf, book_id, book_num, chapter):
    """
    Read a Macula Hebrew lowfat XML chapter file from the zip.
    Returns {verse_num: [list of w.attrib dicts in document order]}.
    """
    abbr = _MACULA_HEB_ABBR.get(book_id)
    if not abbr:
        return {}
    filename = f"macula-hebrew-main/WLC/lowfat/{book_num:02d}-{abbr}-{chapter:03d}-lowfat.xml"
    try:
        xml_bytes = zf.read(filename)
    except KeyError:
        return {}
    root = ET.fromstring(xml_bytes)
    result = {}
    for w in root.iter('w'):
        ref = w.get('ref', '')
        m = re.search(r':(\d+)!', ref)
        if not m:
            continue
        v = int(m.group(1))
        result.setdefault(v, []).append(w.attrib)
    return result


def _xml_match_verse(db_words, mac_words):
    """
    Match DB word rows to Macula XML nodes using Strong's occurrence index.
    db_words: list of (word_id, verse, position, strongs_id)
    Returns: list of (word_id, mac_attrib | None)
    """
    def _norm(s):
        if not s:
            return ''
        return s.lstrip('H').lstrip('G').lstrip('0') or '0'

    mac_by_strong = defaultdict(list)
    for mac in mac_words:
        key = _norm(mac.get('strongnumberx', ''))
        mac_by_strong[key].append(mac)

    occ_counter = defaultdict(int)
    result = []
    for db_row in db_words:
        word_id, _, _, strongs_id = db_row
        key = _norm(strongs_id)
        occ_counter[key] += 1
        n = occ_counter[key]
        candidates = mac_by_strong.get(key, [])
        mac = candidates[n - 1] if len(candidates) >= n else None
        result.append((word_id, mac))
    return result


# ─────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────

def add_after_char(db_path: Path):
    if not db_path.exists():
        print(f"ERROR: DB not found at {db_path}")
        sys.exit(1)
    if not MACULA_HEB_ZIP.exists():
        print(f"ERROR: {MACULA_HEB_ZIP} not found.")
        print("  → Download macula-hebrew-main.zip from GitHub and put it in data/")
        sys.exit(1)

    con = sqlite3.connect(str(db_path))
    cur = con.cursor()

    # ── Step 1: Add column (no-op if already exists) ──────────────────────────
    try:
        cur.execute("ALTER TABLE word ADD COLUMN after_char TEXT")
        con.commit()
        print("[1/3] Column after_char added.")
    except sqlite3.OperationalError as e:
        if "duplicate column" in str(e).lower():
            print("[1/3] Column after_char already exists — skipping ALTER.")
        else:
            raise

    # ── Step 2: Populate from Macula Hebrew XML ────────────────────────────────
    print("[2/3] Populating after_char from Macula Hebrew XML...")

    cur.execute("""
        SELECT b.id, b.num, w.chapter
        FROM word w
        JOIN book b ON b.id = w.book_id
        WHERE w.language = 'hbo'
        GROUP BY b.id, b.num, w.chapter
        ORDER BY b.num, w.chapter
    """)
    chapters = cur.fetchall()
    print(f"  Processing {len(chapters)} Hebrew chapters...")

    total_updated  = 0
    total_no_match = 0

    with zipfile.ZipFile(MACULA_HEB_ZIP) as zf:
        for book_id, book_num, chapter in chapters:
            macula_ch = _xml_nodes_for_chapter(zf, book_id, book_num, chapter)
            if not macula_ch:
                continue

            cur.execute("""
                SELECT id, verse, position, strongs_id
                FROM word
                WHERE book_id=? AND chapter=? AND language='hbo'
                ORDER BY verse, position
            """, (book_id, chapter))
            db_words = cur.fetchall()

            db_by_verse = {}
            for row in db_words:
                db_by_verse.setdefault(row[1], []).append(row)

            updates = []
            for verse, db_verse_words in db_by_verse.items():
                mac_verse = macula_ch.get(verse, [])
                pairs = _xml_match_verse(db_verse_words, mac_verse)
                for word_id, mac in pairs:
                    if mac is None:
                        total_no_match += 1
                        continue
                    # .strip() removes surrounding whitespace; empty result → NULL (space-only = no char)
                    raw_after = mac.get('after', '').strip()
                    after_char = raw_after if raw_after else None
                    if after_char is not None:
                        updates.append((after_char, word_id))

            if updates:
                cur.executemany(
                    "UPDATE word SET after_char=? WHERE id=?",
                    updates
                )
                total_updated += len(updates)

    con.commit()
    print(f"  Words updated : {total_updated:,}")
    print(f"  No XML match  : {total_no_match:,} (after_char left NULL)")

    # ── Step 3: Spot-check ────────────────────────────────────────────────────
    print("[3/3] Spot-check Psalm 1:1...")
    cur.execute("""
        SELECT surface, after_char
        FROM word
        WHERE book_id='PSA' AND chapter=1 AND verse=1
        ORDER BY position
    """)
    rows = cur.fetchall()
    for surface, after in rows:
        display = surface + (after or '')
        flag = " ← has trailing char" if after else ""
        print(f"  {display!r:30s}{flag}")

    con.close()
    print("\nDone. Next steps:")
    print("  cp sourcebible.db SourceBible/Resources/sourcebible.db")
    print("  Xcode: ⇧⌘K → Run")


# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────

if __name__ == "__main__":
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    add_after_char(db_path)
