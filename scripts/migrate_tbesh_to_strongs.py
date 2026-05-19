#!/usr/bin/env python3
"""
migrate_tbesh_to_strongs.py
Updates the `strongs` table with transliteration and long_def from TBESH.

Updates:
  transliteration  TEXT  — lemma transliteration from TBESH (e.g. ha.lakh)
  long_def         TEXT  — full lexicon definition with HTML formatting

Source file:
  data/TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt

Matching strategy:
  TBESH uses zero-padded IDs (H0001, H0835a).
  DB strongs uses unpadded IDs (H1, H835a).
  Normalize: strip leading zeros after 'H'.
  Fallback: strip trailing letter (H835a → try H835) for ~6% of unmatched entries.

  Only the first TBESH row per eStrong# is used (primary/most general entry).

Usage:
  python3 migrate_tbesh_to_strongs.py [--db path/to/sourcebible.db] [--dry-run]
"""

import argparse
import re
import sqlite3
from pathlib import Path

DB_DEFAULT   = Path(__file__).parent.parent / "sourcebible.db"
TBESH_PATH   = Path(__file__).parent.parent / "data" / \
    "TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt"

# TBESH column indices (0-based, tab-separated)
COL_ESTRONG = 0
COL_XLIT    = 4
COL_GLOSS   = 6
COL_MEANING = 7


def normalize_tbesh_id(raw):
    """'H0001' → 'H1',  'H0835a' → 'H835a',  'H1886' → 'H1886'"""
    m = re.match(r'^H(\d+)([a-zA-Z]?)$', raw.strip())
    if not m:
        return raw.strip()
    num    = str(int(m.group(1)))          # strip leading zeros
    suffix = m.group(2).lower()
    return 'H' + num + suffix


def parse_tbesh(path):
    """
    Returns {normalized_id: {xlit, gloss, meaning}}
    Only the first row per eStrong# is kept (primary entry).
    """
    data = {}

    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.startswith('H'):
                continue
            parts = line.split('\t')
            if len(parts) < 7:
                continue

            raw_id = parts[COL_ESTRONG].strip()
            nid    = normalize_tbesh_id(raw_id)

            if nid in data:
                continue  # keep first occurrence only

            xlit    = parts[COL_XLIT].strip()    if len(parts) > COL_XLIT    else ''
            gloss   = parts[COL_GLOSS].strip()   if len(parts) > COL_GLOSS   else ''
            meaning = parts[COL_MEANING].strip() if len(parts) > COL_MEANING else ''

            data[nid] = {
                'xlit':    xlit,
                'gloss':   gloss,
                'meaning': meaning,
            }

    return data


def lookup(tbesh, sid):
    """
    Lookup with two fallbacks:
      1. 'H835a' → try 'H835'    (DB has letter, TBESH only has base)
      2. 'H1254' → try 'H1254a'  (DB has base, TBESH only has lettered sub-entries)
    """
    if sid in tbesh:
        return tbesh[sid]
    # fallback 1: strip trailing letter
    m = re.match(r'^(H\d+)[a-z]$', sid)
    if m and m.group(1) in tbesh:
        return tbesh[m.group(1)]
    # fallback 2: append 'a' to try first sub-entry
    candidate = sid + 'a'
    if candidate in tbesh:
        return tbesh[candidate]
    return None


def migrate(db_path: Path, dry_run: bool) -> None:
    print("=== Parsing TBESH ===")
    tbesh = parse_tbesh(TBESH_PATH)
    print(f"  Loaded {len(tbesh):,} TBESH entries")

    db  = sqlite3.connect(db_path)
    cur = db.cursor()

    cur.execute("SELECT id FROM strongs WHERE language='H'")
    hebrew_ids = [row[0] for row in cur.fetchall()]
    print(f"\n=== Matching {len(hebrew_ids):,} Hebrew strongs entries ===")

    updates      = []
    no_match_ids = []

    for sid in hebrew_ids:
        entry = lookup(tbesh, sid)
        if entry is None:
            no_match_ids.append(sid)
            continue

        # long_def: combine gloss + meaning, or just meaning if gloss already in meaning
        long_def = entry['meaning']

        updates.append((
            entry['xlit'] or None,
            long_def      or None,
            sid,
        ))

    print(f"  Matched   : {len(updates):,}  ({100*len(updates)/len(hebrew_ids):.1f}%)")
    print(f"  No match  : {len(no_match_ids):,}")
    if no_match_ids[:10]:
        print(f"  Sample unmatched: {no_match_ids[:10]}")

    if updates and not dry_run:
        cur.executemany("""
            UPDATE strongs
            SET transliteration = ?,
                long_def        = ?
            WHERE id = ?
        """, updates)
        db.commit()
        print("\n  Changes committed.")
    elif dry_run:
        print("\n  DRY RUN — no changes written.")

    print("\n=== Done ===")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--db',      default=str(DB_DEFAULT))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    migrate(Path(args.db), args.dry_run)
