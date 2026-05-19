#!/usr/bin/env python3
"""
build_verse_map.py
------------------
Знаходить всі (translation, book, chapter) де кількість віршів відрізняється
від Macula і будує verse_map через Strong's-overlap greedy alignment.

Зберігає тільки рядки де trans_verse != macula_verse (non-identity mappings)
щоб мінімізувати розмір таблиці.

Usage:
    python3 build_verse_map.py [path/to/sourcebible.db]
"""

import sqlite3
import re
import sys
from collections import defaultdict

DB = sys.argv[1] if len(sys.argv) > 1 else "SourceBible/Resources/sourcebible.db"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def extract_kjv_strongs(raw_text: str) -> frozenset:
    """Extract and normalise Strong's IDs from raw KJV verse markup."""
    nums = re.findall(r'<S>(\d+[a-z]?)</S>', raw_text, re.IGNORECASE)
    # Strip trailing sub-entry letter for comparison (H2050b → H2050)
    return frozenset("H" + re.sub(r'[a-z]+$', '', n) for n in nums)

def macula_strongs_for_verse(cur, book_id, chapter, verse) -> frozenset:
    cur.execute(
        "SELECT strongs_id FROM word "
        "WHERE book_id=? AND chapter=? AND verse=? AND strongs_id IS NOT NULL",
        (book_id, chapter, verse)
    )
    return frozenset(re.sub(r'[a-z]+$', '', r[0]) for r in cur.fetchall())

# ---------------------------------------------------------------------------
# Core alignment
# ---------------------------------------------------------------------------

def align_chapter(cur, translation, book_id, chapter, trans_verses, macula_verses):
    """
    Greedy bipartite matching: for each translation verse (in order) pick
    the Macula verse with the highest Strong's overlap that's not yet assigned.
    Returns list of (trans_verse, macula_verse) for non-identity pairs only.
    """
    # Pre-compute strongs for all macula verses in this chapter
    m_strongs = {}
    for mv in macula_verses:
        m_strongs[mv] = macula_strongs_for_verse(cur, book_id, chapter, mv)

    assigned = set()
    mapping = []

    for tv in trans_verses:
        # Get strongs from translation verse text
        cur.execute(
            "SELECT text FROM verse WHERE translation=? AND book_id=? AND chapter=? AND verse=?",
            (translation, book_id, chapter, tv)
        )
        row = cur.fetchone()
        if not row:
            continue
        t_strongs = extract_kjv_strongs(row[0])

        # Find best unassigned Macula verse
        best_mv, best_overlap = tv, -1   # default to identity
        for mv in macula_verses:
            if mv in assigned:
                continue
            overlap = len(t_strongs & m_strongs[mv])
            if overlap > best_overlap:
                best_overlap = overlap
                best_mv = mv

        assigned.add(best_mv)
        if best_mv != tv:   # store only non-identity
            mapping.append((tv, best_mv))

    return mapping

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build(db_path):
    con = sqlite3.connect(db_path)
    cur = con.cursor()

    # Create verse_map table
    cur.executescript("""
        DROP TABLE IF EXISTS verse_map;
        CREATE TABLE verse_map (
            translation  TEXT    NOT NULL,
            book_id      TEXT    NOT NULL,
            chapter      INTEGER NOT NULL,
            trans_verse  INTEGER NOT NULL,
            macula_verse INTEGER NOT NULL,
            PRIMARY KEY (translation, book_id, chapter, trans_verse)
        );
        CREATE INDEX IF NOT EXISTS idx_verse_map
            ON verse_map(translation, book_id, chapter);
    """)

    # Find all (translation, book, chapter) combos with verse-count mismatch
    cur.execute("SELECT DISTINCT id FROM translation")
    translations = [r[0] for r in cur.fetchall()]

    # Get Macula max verse per chapter (cached)
    cur.execute("""
        SELECT book_id, chapter, MAX(verse)
        FROM word GROUP BY book_id, chapter
    """)
    macula_max = {(r[0], r[1]): r[2] for r in cur.fetchall()}

    total_rows = 0
    chapters_processed = 0

    for translation in translations:
        cur.execute("""
            SELECT book_id, chapter, MAX(verse)
            FROM verse WHERE translation=?
            GROUP BY book_id, chapter
        """, (translation,))
        trans_maxes = cur.fetchall()

        for book_id, chapter, t_max in trans_maxes:
            m_max = macula_max.get((book_id, chapter))
            if m_max is None or t_max == m_max:
                continue

            # Verse lists
            cur.execute(
                "SELECT DISTINCT verse FROM verse "
                "WHERE translation=? AND book_id=? AND chapter=? ORDER BY verse",
                (translation, book_id, chapter)
            )
            trans_verses = [r[0] for r in cur.fetchall()]

            cur.execute(
                "SELECT DISTINCT verse FROM word "
                "WHERE book_id=? AND chapter=? ORDER BY verse",
                (book_id, chapter)
            )
            macula_verses = [r[0] for r in cur.fetchall()]

            mapping = align_chapter(
                cur, translation, book_id, chapter, trans_verses, macula_verses
            )

            if mapping:
                cur.executemany(
                    "INSERT OR REPLACE INTO verse_map VALUES (?,?,?,?,?)",
                    [(translation, book_id, chapter, tv, mv) for tv, mv in mapping]
                )
                total_rows += len(mapping)
                chapters_processed += 1
                print(f"  {translation} {book_id} {chapter}: {len(mapping)} non-identity mappings")

    con.commit()
    con.close()
    print(f"\n✓ Done: {total_rows} rows across {chapters_processed} chapters")

if __name__ == "__main__":
    build(DB)
