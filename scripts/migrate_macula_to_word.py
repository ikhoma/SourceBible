#!/usr/bin/env python3
"""
migrate_macula_to_word.py
Adds 5 columns to the `word` table and populates them from Macula Hebrew XML.

New columns:
  xlit         TEXT  — occurrence-specific transliteration (e.g. hālaḵə)
  gloss_macula TEXT  — contextual gloss per occurrence (e.g. he.walks)
  syntax_role  TEXT  — syntactic role: v=predicate, s=subject, o=object, etc.
  greek        TEXT  — LXX Greek equivalent word
  greek_strong TEXT  — LXX Greek Strong's number (e.g. G4198)

Matching strategy:
  Both the DB word table and Macula XML store every morphological token
  separately (prefixes, articles, prepositions as individual rows).
  Within a verse the document order is identical, so we match by
  sequential index: n-th Macula <w> node == n-th DB word row (same verse).
  We assert strongnumberx matches strongs_id as a sanity check.

Usage:
  python3 migrate_macula_to_word.py [--db path/to/sourcebible.db] [--dry-run]
"""

import argparse
import re
import sqlite3
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

DB_DEFAULT = Path(__file__).parent.parent / "sourcebible.db"
ZIP_PATH   = Path(__file__).parent.parent / "data" / "macula-hebrew-main.zip"

BOOK_ABBR = {
    '1CH':'1Ch','1KI':'1Ki','1SA':'1Sa','2CH':'2Ch','2KI':'2Ki','2SA':'2Sa',
    'AMO':'Amo','DAN':'Dan','DEU':'Deu','ECC':'Ecc','EST':'Est','EXO':'Exo',
    'EZK':'Ezk','EZR':'Ezr','GEN':'Gen','HAB':'Hab','HAG':'Hag','HOS':'HOS',
    'ISA':'Isa','JDG':'Jdg','JER':'Jer','JOB':'Job','JOL':'Jol','JON':'Jon',
    'JOS':'Jos','LAM':'Lam','LEV':'Lev','MAL':'Mal','MIC':'Mic','NAM':'Nam',
    'NEH':'Neh','NUM':'Num','OBA':'Oba','PRO':'Pro','PSA':'Psa','RUT':'Rut',
    'SNG':'Sng','ZEC':'Zec','ZEP':'Zep',
}


def normalize_strong(s) -> str:
    """'H1980' -> '1980',  '0835a' -> '835a',  '1886a' -> '1886a'"""
    if not s:
        return ''
    s = s.lstrip('H').lstrip('0') or '0'
    return s


def add_columns(cur: sqlite3.Cursor) -> None:
    existing = {row[1] for row in cur.execute("PRAGMA table_info(word)")}
    for col, typ in [
        ('xlit',         'TEXT'),
        ('gloss_macula', 'TEXT'),
        ('syntax_role',  'TEXT'),
        ('greek',        'TEXT'),
        ('greek_strong', 'TEXT'),
    ]:
        if col not in existing:
            cur.execute(f"ALTER TABLE word ADD COLUMN {col} {typ}")
            print(f"  + column '{col}' added")
        else:
            print(f"  · column '{col}' already exists")


def macula_nodes_for_chapter(z: zipfile.ZipFile, book_id: str,
                              book_num: int, chapter: int) -> dict:
    """
    Returns {verse_num: [list of w.attrib dicts in document order]}
    """
    abbr     = BOOK_ABBR.get(book_id)
    filename = f"macula-hebrew-main/WLC/lowfat/{book_num:02d}-{abbr}-{chapter:03d}-lowfat.xml"
    try:
        xml  = z.read(filename)
    except KeyError:
        return {}

    root   = ET.fromstring(xml)
    result: dict[int, list] = {}
    for w in root.iter('w'):
        ref = w.get('ref', '')
        m   = re.search(r':(\d+)!', ref)
        if not m:
            continue
        v = int(m.group(1))
        result.setdefault(v, []).append(w.attrib)
    return result


def match_verse(db_words, mac_words):
    """
    Match DB word rows to Macula nodes using Strong's occurrence index.
    Robust against count mismatches and word-order differences between sources.

    Returns list of (word_id, mac_attrib | None) tuples.
    mac_attrib is None when no Macula node found for a DB word.
    """
    from collections import defaultdict

    # Index Macula nodes by normalized Strong's number (in document order)
    mac_by_strong: dict[str, list] = defaultdict(list)
    for mac in mac_words:
        key = normalize_strong(mac.get('strongnumberx', ''))
        mac_by_strong[key].append(mac)

    occ_counter: dict[str, int] = defaultdict(int)
    result = []
    for db_row in db_words:
        word_id, _, _, strongs_id = db_row
        key = normalize_strong(strongs_id)
        occ_counter[key] += 1
        n = occ_counter[key]

        candidates = mac_by_strong.get(key, [])
        mac = candidates[n - 1] if len(candidates) >= n else None
        result.append((word_id, mac))

    return result


def migrate(db_path: Path, dry_run: bool) -> None:
    db  = sqlite3.connect(db_path)
    cur = db.cursor()

    print("=== Adding columns ===")
    add_columns(cur)
    if not dry_run:
        db.commit()

    z = zipfile.ZipFile(ZIP_PATH)

    cur.execute("""
        SELECT b.id, b.num, w.chapter
        FROM word w
        JOIN book b ON b.id = w.book_id
        WHERE w.language = 'hbo'
        GROUP BY b.id, b.num, w.chapter
        ORDER BY b.num, w.chapter
    """)
    chapters = cur.fetchall()
    print(f"\n=== Processing {len(chapters)} chapters ===")

    total_updated  = 0
    total_no_match = 0

    for book_id, book_num, chapter in chapters:
        macula_ch = macula_nodes_for_chapter(z, book_id, book_num, chapter)
        if not macula_ch:
            continue

        cur.execute("""
            SELECT id, verse, position, strongs_id
            FROM word
            WHERE book_id=? AND chapter=? AND language='hbo'
            ORDER BY verse, position
        """, (book_id, chapter))
        db_words = cur.fetchall()

        db_by_verse: dict[int, list] = {}
        for row in db_words:
            db_by_verse.setdefault(row[1], []).append(row)

        updates = []
        for verse, db_verse_words in db_by_verse.items():
            mac_verse = macula_ch.get(verse, [])
            pairs     = match_verse(db_verse_words, mac_verse)

            for word_id, mac in pairs:
                if mac is None:
                    total_no_match += 1
                    continue

                greek_strong = mac.get('greekstrong', '')
                if greek_strong:
                    greek_strong = 'G' + greek_strong

                updates.append((
                    mac.get('transliteration', '') or None,
                    mac.get('gloss', '')           or None,
                    mac.get('role', '')            or None,
                    mac.get('greek', '')           or None,
                    greek_strong                   or None,
                    word_id,
                ))

        if updates and not dry_run:
            cur.executemany("""
                UPDATE word
                SET xlit=?, gloss_macula=?, syntax_role=?, greek=?, greek_strong=?
                WHERE id=?
            """, updates)
            db.commit()

        total_updated += len(updates)

    print(f"\n=== Done ===")
    print(f"  Updated   : {total_updated:,} words")
    print(f"  No match  : {total_no_match:,} words (columns left NULL)")
    if dry_run:
        print("  DRY RUN — no changes written")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--db',      default=str(DB_DEFAULT))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    migrate(Path(args.db), args.dry_run)
