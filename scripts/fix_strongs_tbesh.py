#!/usr/bin/env python3
"""
fix_strongs_tbesh.py — Patch existing sourcebible.db with TBESH/TBESG data.

Fixes stub strongs rows (created when openscriptures JSON was unavailable)
by populating original, xlit_simple, transliteration, short_def, and long_def
from the local TBESH / TBESG files in data/.

Usage:
    python3 scripts/fix_strongs_tbesh.py sourcebible.db

Run from the project root (~/Projects/SourceBible/).
No full rebuild required — takes ~5 seconds.
After running: copy to bundle and do Xcode ⇧⌘K → Run.
"""

import csv
import io
import re
import sqlite3
import sys
import zipfile
from pathlib import Path
from typing import Optional, List, Dict

DATA_DIR = Path(__file__).parent.parent / "data"

# ---------------------------------------------------------------------------
# Helpers (duplicated from build_db.py to keep this script self-contained)
# ---------------------------------------------------------------------------

def _find_stepbible_file(prefix):
    # type: (str) -> Optional[Path]
    matches = sorted(DATA_DIR.glob("%s*.txt" % prefix))
    return matches[0] if matches else None


def _find_col(row, *candidates):
    # type: (dict, *str) -> str
    for c in candidates:
        if c in row:
            v = row[c].strip()
            if v:
                return v
    return ""


def _clean_stepbible_html(text):
    # type: (str) -> str
    """Strip HTML markup from STEPBible definition fields."""
    s = text
    # Remove <a href=...>...</a> entirely (citation links)
    s = re.sub(r'<a [^>]*>.*?</a>', '', s, flags=re.IGNORECASE | re.DOTALL)
    # <ref='...'>visible</ref> → visible
    s = re.sub(r"<ref='[^']*'>([^<]*)</ref>", r'\1', s, flags=re.IGNORECASE)
    # <BR /> / <br> → newline
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.IGNORECASE)
    # Strip remaining tags
    s = re.sub(r'<[^>]+>', '', s)
    # Decode common HTML entities
    s = s.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&nbsp;', ' ')
    # Collapse whitespace around newlines
    lines = [ln.strip() for ln in s.splitlines()]
    s = '\n'.join(ln for ln in lines if ln)
    return s.strip()


def _parse_stepbible_file(text):
    # type: (str) -> List[Dict[str, str]]
    """Parse TBESH / TBESG tab-separated file. Returns list of row dicts."""
    lines = text.splitlines()
    header = None
    rows = []
    data_re = re.compile(r'^[HG]\d{4,5}[a-z]?\t')

    for line in lines:
        if header is None:
            if "\t" in line:
                parts = line.split("\t")
                if (parts[0].strip().lower().startswith("estrong") and
                        len(parts) >= 7 and
                        parts[1].strip().lower().startswith("dstrong")):
                    header = [c.strip().lower() for c in parts]
            continue

        stripped = line.strip()
        if not stripped or stripped.startswith("=") or stripped.startswith("$") or stripped.startswith("-"):
            continue
        if not data_re.match(line):
            continue

        parts = line.split("\t")
        row = {}
        for i, col in enumerate(header):
            row[col] = parts[i].strip() if i < len(parts) else ""
        rows.append(row)

    return rows


def normalize_strongs(raw, prefix):
    # type: (str, str) -> Optional[str]
    """Normalize a raw Strong's ID to canonical form (e.g. H0001 → H1, G0023 → G23)."""
    if not raw:
        return None
    s = raw.strip()
    # Strip trailing disambiguation suffixes for our purposes? No — keep as-is.
    # We want exact IDs so the UPDATE targets the right row.
    # But TBESH uses zero-padded 4-digit: H0001. DB uses H1. Normalize.
    m = re.match(r'^([HG])0*(\d+)([a-zA-Z]*)$', s)
    if not m:
        return None
    lang, num, suffix = m.group(1), m.group(2), m.group(3)
    return "%s%s%s" % (lang, num, suffix.lower())


# ---------------------------------------------------------------------------
# Main patch
# ---------------------------------------------------------------------------

STEPBIBLE_FILES = {
    "H": "TBESH",
    "G": "TBESG",
}

def run(db_path):
    # type: (str) -> None
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    cur = conn.cursor()

    total_updated = 0

    for lang_prefix, file_prefix in STEPBIBLE_FILES.items():
        local_path = _find_stepbible_file(file_prefix)
        if not local_path:
            print("  WARNING: %s*.txt not found in data/ — skipping %s" % (file_prefix, lang_prefix))
            continue

        print("  [local] %s" % local_path.name)
        raw = local_path.read_text(encoding="utf-8", errors="replace")
        rows = _parse_stepbible_file(raw)
        if not rows:
            print("  WARNING: no rows parsed from %s" % local_path.name)
            continue

        print("  Columns detected: %s" % list(rows[0].keys())[:10])
        last_col = list(rows[0].keys())[-1] if rows else None

        updated = 0
        skipped = 0

        for row in rows:
            raw_id = _find_col(row, "estrong#", "estrong",
                               "strongs", "strongsextended", "strongsnumber", "id")
            sid = normalize_strongs(raw_id, lang_prefix)
            if not sid:
                skipped += 1
                continue

            xlit_simple = _find_col(row, "transliteration", "xlit", "translit", "pronunciation")
            # Column 6 in both TBESH and TBESG is the short gloss
            short_def   = _find_col(row, "gloss")
            # NOTE: original (Hebrew/Greek script) is NOT sourced from TBESH here —
            # it comes from word.lemma (Macula) in the SQL backfill step below.
            long_def    = _find_col(row, "longdefinition", "definition", "fulldefinition",
                                         "longdef", "bdb", "abbottsmith", "meaning")
            if not long_def and last_col:
                long_def = row.get(last_col, "")

            long_def = _clean_stepbible_html(long_def)

            xlit_simple = xlit_simple[:100]
            short_def   = short_def[:200]
            long_def    = long_def[:5000]

            cur.execute("""
                UPDATE strongs
                SET
                    xlit_simple     = CASE WHEN ? != ''                                                      THEN ? ELSE xlit_simple     END,
                    transliteration = CASE WHEN (transliteration IS NULL OR transliteration = '') AND ? != '' THEN ? ELSE transliteration END,
                    short_def       = CASE WHEN (short_def IS NULL OR short_def = '') AND ? != ''            THEN ? ELSE short_def       END,
                    long_def        = CASE WHEN ? != ''                                                      THEN ? ELSE long_def        END
                WHERE id = ?
            """, (
                xlit_simple, xlit_simple,
                xlit_simple, xlit_simple,
                short_def,   short_def,
                long_def,    long_def,
                sid,
            ))
            if cur.rowcount:
                updated += 1

            # Propagate suffixed entry data to base ID (H1471a → H1471).
            # Macula uses bare IDs; without this, base rows stay NULL even when
            # TBESH only has the suffixed variant.
            # NULL-guard: won't overwrite a base entry that already has its own data.
            m_base = re.match(r'^([HG]\d+)[a-z]$', sid)
            if m_base:
                base_sid = m_base.group(1)
                cur.execute("""
                    UPDATE strongs SET
                        xlit_simple = CASE WHEN (xlit_simple IS NULL OR xlit_simple = '') AND ? != '' THEN ? ELSE xlit_simple END,
                        short_def   = CASE WHEN (short_def   IS NULL OR short_def   = '') AND ? != '' THEN ? ELSE short_def   END,
                        long_def    = CASE WHEN (long_def    IS NULL OR long_def    = '') AND ? != '' THEN ? ELSE long_def    END
                    WHERE id = ?
                """, (xlit_simple, xlit_simple, short_def, short_def, long_def, long_def, base_sid))
                if cur.rowcount:
                    updated += 1

        conn.commit()
        print("  %s: %d rows updated, %d skipped" % (lang_prefix, updated, skipped))
        total_updated += updated

    # Backfill strongs.original from word.lemma (Macula) — avoids any dependency
    # on openscriptures JSON files which may not be present.
    print("\n  Backfilling strongs.original from word.lemma...")
    cur = conn.cursor()
    cur.execute("""
        UPDATE strongs
        SET original = (
            SELECT lemma FROM word
            WHERE word.strongs_id = strongs.id
              AND lemma IS NOT NULL AND lemma != ''
            LIMIT 1
        )
        WHERE (original IS NULL OR original = '')
          AND EXISTS (
                SELECT 1 FROM word
                WHERE word.strongs_id = strongs.id
                  AND lemma IS NOT NULL AND lemma != ''
              )
    """)
    conn.commit()
    print("  Backfilled: %d Strong's entries got original from Macula" % cur.rowcount)

    conn.close()
    print("\nDone. %d total rows updated." % total_updated)
    print("Next: cp sourcebible.db SourceBible/Resources/sourcebible.db")
    print("      Xcode: ⇧⌘K → Run")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/fix_strongs_tbesh.py <path/to/sourcebible.db>")
        sys.exit(1)
    print("fix_strongs_tbesh.py — patching %s" % sys.argv[1])
    run(sys.argv[1])
