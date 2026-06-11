#!/usr/bin/env python3
"""
process_glosses.py — Gloss Synthesizer
Adds/updates word.gloss_display with clean English glosses.

Usage:
    python3 scripts/process_glosses.py sourcebible.db

Run after build_db.py, build_verse_map.py, import_commentaries.py.
Approx. 1 min for ~600k rows.

Pipeline (Hebrew words only; Greek returned as-is):
    Stage 1  — Untranslatable particles (H853 → "—")
    Stage 2  — Strip square brackets: "[is].the" → "the"
    Stage 3  — Strip dot-subject prefix: "he.created" → "created"
    Stage 4  — Fix construct chain order: "heart your" → "your heart"
    Stage 5  — Normalize remaining dots: "and to.peace" → "and to peace"
    Stage 6  — Proper noun safety net: preserve canonical capitalization
"""

import re
import sqlite3
import sys
from typing import Optional, List, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Particles with no English translation — displayed as em dash.
UNTRANSLATABLE = {"H853"}

# Subject pronouns Macula prepends to verb glosses with a dot.
# "he.created" → "created"; "and he.said" → "and said"
SUBJECT_PRONOUNS = {"he", "she", "it", "i", "we", "they", "you"}

# Suffix pronouns (possessives) that appear AFTER the noun in Hebrew.
# "heart your" → "your heart"; "God our" → "our God"
SUFFIX_PRONOUNS = {"my", "your", "his", "her", "our", "their", "its"}

# Canonical display form keyed by strongs_id.
# Safety net: ensures proper nouns survive pipeline transformations intact.
PROPER_NOUNS = {
    "H3068": "Yahweh",
    "H3069": "Yahweh",   # ketiv variant
    "H136":  "Lord",     # Adonai
    "H410":  "God",      # El
    "H430":  "God",      # Elohim
    "H3478": "Israel",
    "H1732": "David",
    "H3389": "Jerusalem",
    "H6726": "Zion",
    "H4714": "Egypt",
    "H894":  "Babylon",
    "H53":   "Absalom",
    "H85":   "Abraham",
    "H3327": "Isaac",
    "H3290": "Jacob",
    "H4872": "Moses",
}

# Compiled regex patterns
_RE_BRACKET_DOT = re.compile(r'\[.*?\]\.')   # "[is]."  → ""
_RE_BRACKET     = re.compile(r'\[.*?\]')      # "[is]"   → ""  (trailing dot already gone)
_RE_SUBJ_PREFIX = re.compile(                 # optional "and/or/but " + pronoun + "."
    r'^((?:and|or|but)\s+)?([a-zA-Z]+)\.(.*)',
    re.IGNORECASE
)

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def synthesize(
    raw,            # type: Optional[str]
    strongs_id,     # type: Optional[str]
    language        # type: str
):
    # type: (...) -> Optional[str]
    """Return cleaned gloss_display for one word row. None = store NULL."""
    if not raw or not raw.strip():
        return None

    # Greek glosses are already clean — no dot notation or construct chains.
    if language == "G":
        return raw.strip()

    text = raw.strip()

    # Stage 1: untranslatable particles.
    if strongs_id and strongs_id in UNTRANSLATABLE:
        return "—"  # em dash "—"

    # Stage 2: strip square-bracket content.
    # "[is].the" → "the"; "[is].my shepherd" → "my shepherd"
    text = _RE_BRACKET_DOT.sub("", text)   # remove "[...]." first (with trailing dot)
    text = _RE_BRACKET.sub("", text)        # then any remaining "[...]"
    text = text.strip()
    if not text:
        return None

    # Stage 3: strip dot-encoded subject pronoun prefix.
    # "he.created" → "created"; "and he.said" → "and said"; "let.it.be" → unchanged
    m = _RE_SUBJ_PREFIX.match(text)
    if m:
        prefix  = (m.group(1) or "").strip()   # "and" / "or" / "but" / ""
        pronoun = m.group(2).lower()
        rest    = m.group(3)
        if pronoun in SUBJECT_PRONOUNS:
            text = ((prefix + " " + rest).strip()) if prefix else rest

    # Stage 4: fix construct chain word order.
    # "heart your" → "your heart"; "God our" → "our God"
    # Only handles simple case: last token is a suffix pronoun.
    words = text.split()
    if len(words) >= 2 and words[-1].lower() in SUFFIX_PRONOUNS:
        pronoun_word = words[-1]
        noun_parts   = words[:-1]
        text = pronoun_word + " " + " ".join(noun_parts)

    # Stage 5: normalize remaining dots to spaces.
    # "and to.peace" → "and to peace"; "let.it.be" → "let it be"
    text = text.replace(".", " ")
    text = " ".join(text.split())   # collapse multiple spaces

    # Stage 6: proper noun safety net — override with canonical form when
    # the processed gloss matches (case-insensitively) the expected form.
    if strongs_id and strongs_id in PROPER_NOUNS:
        canonical = PROPER_NOUNS[strongs_id]
        parts = text.split()
        if len(parts) == 1:
            text = canonical
        elif parts[-1].lower() == canonical.lower():
            # e.g. "of david" → "of David"
            text = " ".join(parts[:-1]) + " " + canonical

    return text if text else None


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def add_column_if_missing(conn):
    # type: (sqlite3.Connection) -> None
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(word)")
    cols = [row[1] for row in cur.fetchall()]
    if "gloss_display" not in cols:
        cur.execute("ALTER TABLE word ADD COLUMN gloss_display TEXT")
        conn.commit()
        print("  Added column word.gloss_display")
    else:
        print("  Column word.gloss_display already exists — overwriting values")


def fetch_rows(conn):
    # type: (sqlite3.Connection) -> List[Tuple]
    cur = conn.cursor()
    cur.execute("""
        SELECT id, gloss_macula, gloss, strongs_id, language
        FROM   word
    """)
    return cur.fetchall()


def flush_batch(conn, batch):
    # type: (sqlite3.Connection, List[Tuple]) -> None
    conn.executemany(
        "UPDATE word SET gloss_display = ? WHERE id = ?",
        batch
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/process_glosses.py <path/to/sourcebible.db>")
        sys.exit(1)

    db_path = sys.argv[1]
    print("Gloss Synthesizer")
    print("  DB: {}".format(db_path))

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")

    add_column_if_missing(conn)

    print("  Fetching word rows...")
    rows = fetch_rows(conn)
    total = len(rows)
    print("  Processing {:,} rows...".format(total))

    BATCH_SIZE = 5000
    batch   = []
    changed = 0

    for idx, (row_id, gloss_macula, gloss_short, strongs_id, language) in enumerate(rows, 1):
        raw    = gloss_macula or gloss_short
        result = synthesize(raw, strongs_id, language or "")

        batch.append((result, row_id))
        if result != raw:
            changed += 1

        if len(batch) >= BATCH_SIZE:
            flush_batch(conn, batch)
            batch = []

        if idx % 100000 == 0:
            pct = idx * 100 // total
            print("  {:,}/{:,} ({}%)".format(idx, total, pct))

    if batch:
        flush_batch(conn, batch)

    conn.close()
    print("  Done. {:,} rows changed.".format(changed))


if __name__ == "__main__":
    main()
