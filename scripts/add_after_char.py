#!/usr/bin/env python3
"""
add_after_char.py — Fast migration: add after_char column to existing sourcebible.db
---------------------------------------------------------------------------------------
Reads Macula Hebrew + Greek XML lowfat files and populates the `after_char` column
without a full DB rebuild (~2 min vs ~10 min).

Usage:
    cd ~/Projects/SourceBible
    python3 scripts/add_after_char.py [path/to/sourcebible.db]

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
MACULA_GRK_ZIP = DATA_DIR / "macula-greek-main.zip"
DEFAULT_DB     = ROOT / "sourcebible.db"

# ─────────────────────────────────────────────
# Book mappings
# ─────────────────────────────────────────────

_MACULA_HEB_ABBR = {
    '1CH':'1Ch','1KI':'1Ki','1SA':'1Sa','2CH':'2Ch','2KI':'2Ki','2SA':'2Sa',
    'AMO':'Amo','DAN':'Dan','DEU':'Deu','ECC':'Ecc','EST':'Est','EXO':'Exo',
    'EZK':'Ezk','EZR':'Ezr','GEN':'Gen','HAB':'Hab','HAG':'Hag','HOS':'Hos',
    'ISA':'Isa','JDG':'Jdg','JER':'Jer','JOB':'Job','JOL':'Jol','JON':'Jon',
    'JOS':'Jos','LAM':'Lam','LEV':'Lev','MAL':'Mal','MIC':'Mic','NAM':'Nam',
    'NEH':'Neh','NUM':'Num','OBA':'Oba','PRO':'Pro','PSA':'Psa','RUT':'Rut',
    'SNG':'Sng','ZEC':'Zec','ZEP':'Zep',
}

_MACULA_GRK_FILES = {
    'MAT': '01-matthew',    'MRK': '02-mark',        'LUK': '03-luke',
    'JHN': '04-john',       'ACT': '05-acts',         'ROM': '06-romans',
    '1CO': '07-1corinthians','2CO': '08-2corinthians', 'GAL': '09-galatians',
    'EPH': '10-ephesians',  'PHP': '11-philippians',  'COL': '12-colossians',
    '1TH': '13-1thessalonians','2TH': '14-2thessalonians',
    '1TI': '15-1timothy',   '2TI': '16-2timothy',    'TIT': '17-titus',
    'PHM': '18-philemon',   'HEB': '19-hebrews',     'JAS': '20-james',
    '1PE': '21-1peter',     '2PE': '22-2peter',      '1JN': '23-1john',
    '2JN': '24-2john',      '3JN': '25-3john',       'JUD': '26-jude',
    'REV': '27-revelation',
}

# ─────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────

def _norm_strong(s):
    """'H1980' → '1980', 'G1063' → '1063', '0835a' → '835a'"""
    if not s:
        return ''
    return s.lstrip('H').lstrip('G').lstrip('0') or '0'


def _xml_match_verse(db_words, mac_words, strong_attr='strongnumberx'):
    """
    Match DB word rows to Macula XML nodes by Strong's occurrence index.
    db_words:    list of (word_id, verse, position, strongs_id)
    strong_attr: 'strongnumberx' for Hebrew, 'strong' for Greek
    Returns: list of (word_id, mac_attrib | None)
    """
    mac_by_strong = defaultdict(list)
    for mac in mac_words:
        key = _norm_strong(mac.get(strong_attr, ''))
        mac_by_strong[key].append(mac)

    occ_counter = defaultdict(int)
    result = []
    for db_row in db_words:
        word_id, _, _, strongs_id = db_row
        key = _norm_strong(strongs_id)
        occ_counter[key] += 1
        n = occ_counter[key]
        candidates = mac_by_strong.get(key, [])
        mac = candidates[n - 1] if len(candidates) >= n else None
        result.append((word_id, mac))
    return result


def _extract_after(mac):
    raw = mac.get('after', '').strip()
    return raw if raw else None

# ─────────────────────────────────────────────
# Hebrew helpers
# ─────────────────────────────────────────────

def _xml_nodes_for_chapter(zf, book_id, book_num, chapter):
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
        m = re.search(r':(\d+)!', w.get('ref', ''))
        if m:
            result.setdefault(int(m.group(1)), []).append(w.attrib)
    return result

# ─────────────────────────────────────────────
# Greek helpers
# ─────────────────────────────────────────────

def _xml_nodes_for_book(zf, book_id):
    fname = _MACULA_GRK_FILES.get(book_id)
    if not fname:
        return {}
    path = f'macula-greek-main/Nestle1904/lowfat/{fname}.xml'
    try:
        xml_bytes = zf.read(path)
    except KeyError:
        return {}
    root = ET.fromstring(xml_bytes)
    result = {}
    for w in root.iter('w'):
        m = re.match(r'\w+ (\d+):(\d+)!', w.get('ref', ''))
        if m:
            cv = (int(m.group(1)), int(m.group(2)))
            result.setdefault(cv, []).append(w.attrib)
    return result

# ─────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────

def add_after_char(db_path: Path):
    if not db_path.exists():
        print(f"ERROR: DB not found at {db_path}")
        sys.exit(1)

    con = sqlite3.connect(str(db_path))
    cur = con.cursor()

    # ── Step 1: Add column (no-op if already exists) ──────────────────────────
    try:
        cur.execute("ALTER TABLE word ADD COLUMN after_char TEXT")
        con.commit()
        print("[1/4] Column after_char added.")
    except sqlite3.OperationalError as e:
        if "duplicate column" in str(e).lower():
            print("[1/4] Column after_char already exists — resetting for re-population.")
            cur.execute("UPDATE word SET after_char=NULL")
            con.commit()
        else:
            raise

    # ── Step 2: Hebrew ────────────────────────────────────────────────────────
    if not MACULA_HEB_ZIP.exists():
        print(f"[2/4] SKIP Hebrew: {MACULA_HEB_ZIP} not found.")
    else:
        print("[2/4] Populating after_char from Macula Hebrew XML...")
        cur.execute("""
            SELECT b.id, b.num, w.chapter
            FROM word w JOIN book b ON b.id = w.book_id
            WHERE w.language = 'hbo'
            GROUP BY b.id, b.num, w.chapter ORDER BY b.num, w.chapter
        """)
        chapters = cur.fetchall()
        print(f"  Processing {len(chapters)} Hebrew chapters...")
        heb_updated = heb_no_match = 0

        with zipfile.ZipFile(MACULA_HEB_ZIP) as zf:
            for book_id, book_num, chapter in chapters:
                macula_ch = _xml_nodes_for_chapter(zf, book_id, book_num, chapter)
                if not macula_ch:
                    continue
                cur.execute("""
                    SELECT id, verse, position, strongs_id FROM word
                    WHERE book_id=? AND chapter=? AND language='hbo'
                    ORDER BY verse, position
                """, (book_id, chapter))
                db_by_verse = {}
                for row in cur.fetchall():
                    db_by_verse.setdefault(row[1], []).append(row)

                updates = []
                for verse, db_words in db_by_verse.items():
                    for word_id, mac in _xml_match_verse(db_words, macula_ch.get(verse, [])):
                        if mac is None:
                            heb_no_match += 1; continue
                        ac = _extract_after(mac)
                        if ac: updates.append((ac, word_id))

                if updates:
                    cur.executemany("UPDATE word SET after_char=? WHERE id=?", updates)
                    heb_updated += len(updates)

        con.commit()
        print(f"  Updated: {heb_updated:,}  |  No match: {heb_no_match:,}")

    # ── Step 3: Greek ─────────────────────────────────────────────────────────
    if not MACULA_GRK_ZIP.exists():
        print(f"[3/4] SKIP Greek: {MACULA_GRK_ZIP} not found.")
    else:
        print("[3/4] Populating after_char from Macula Greek XML...")
        cur.execute("SELECT DISTINCT book_id FROM word WHERE language='grc' ORDER BY book_id")
        book_ids = [r[0] for r in cur.fetchall()]
        print(f"  Processing {len(book_ids)} Greek books...")
        grk_updated = grk_no_match = 0

        with zipfile.ZipFile(MACULA_GRK_ZIP) as zf:
            for book_id in book_ids:
                nodes = _xml_nodes_for_book(zf, book_id)
                if not nodes:
                    continue
                cur.execute("""
                    SELECT id, verse, position, strongs_id FROM word
                    WHERE book_id=? AND language='grc'
                    ORDER BY chapter, verse, position
                """, (book_id,))
                db_by_cv = {}
                for row in cur.fetchall():
                    parts = row[0].split('|')
                    if len(parts) >= 3:
                        cv = (int(parts[1]), int(parts[2]))
                        db_by_cv.setdefault(cv, []).append(row)

                updates = []
                for cv, db_words in db_by_cv.items():
                    for word_id, mac in _xml_match_verse(db_words, nodes.get(cv, []), strong_attr='strong'):
                        if mac is None:
                            grk_no_match += 1; continue
                        ac = _extract_after(mac)
                        if ac: updates.append((ac, word_id))

                if updates:
                    cur.executemany("UPDATE word SET after_char=? WHERE id=?", updates)
                    grk_updated += len(updates)

        con.commit()
        print(f"  Updated: {grk_updated:,}  |  No match: {grk_no_match:,}")

    # ── Step 4: Spot-checks ───────────────────────────────────────────────────
    print("[4/4] Spot-checks...")
    for label, sql in [
        ("Psalm 1:1 (Hebrew)",
         "SELECT surface, after_char FROM word WHERE book_id='PSA' AND chapter=1 AND verse=1 ORDER BY position"),
        ("John 3:16 (Greek, first 6 words)",
         "SELECT surface, after_char FROM word WHERE book_id='JHN' AND chapter=3 AND verse=16 ORDER BY position LIMIT 6"),
    ]:
        print(f"\n  {label}:")
        cur.execute(sql)
        for surface, after in cur.fetchall():
            display = surface + (after or '')
            flag = f" ← '{after}'" if after else ""
            print(f"    {display:25s}{flag}")

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
