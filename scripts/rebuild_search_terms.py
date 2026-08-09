#!/usr/bin/env python3
"""
Rebuild ONLY `search_terms` — the per-language autocomplete dictionaries.

Why this script exists: the per-language split (ADR-008, amendment 2026-08-07) changes one
table that is derived entirely from `verse.text_clean`. Nothing about `verse`, `word`,
`strongs`, `verse_org` or the FTS index changes, so paying ~10 minutes of `./rebuild.sh`
(plus versification, commentaries and glosses) to regenerate a 1.5 MB table would be waste.
Measured cost of the real work: ~2.5 s.

⛔ Runs on the Mac only. This WRITES to sourcebible.db, and writing to the DB from the Linux
sandbox is forbidden (see CLAUDE.md — the file may be an APFS sparse clone there).

Usage:
    python3 scripts/rebuild_search_terms.py [path/to/sourcebible.db]

Default path is ./sourcebible.db at the repo root (the build artefact, NOT the copy inside
SourceBible/Resources/). Copy it into Resources afterwards exactly as ./rebuild.sh does, then
Clean Build Folder in Xcode (⇧⌘K) — Xcode caches the old DB and the app would keep querying
a table without a `lang` column.

Exits non-zero if the rebuilt table fails verification, and does so BEFORE committing, so a
failed run leaves the previous dictionary in place instead of a half-broken one.
"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Reuse the builder and the checks from the canonical pipeline. Importing rather than
# copying is deliberate: a second implementation of the same word extraction would drift
# from build_db.py, and then a full rebuild and this script would produce different
# dictionaries — the kind of divergence that is invisible until a user reports it.
from build_db import build_search_terms, verify_search_terms  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DB = ROOT / "sourcebible.db"


def main() -> int:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.exists():
        print(f"✗ Not found: {db_path}")
        return 1

    print(f"Rebuilding search_terms in {db_path}")
    con = sqlite3.connect(db_path)
    cur = con.cursor()

    # A DB without translations/verses is not something to "fix" by writing an empty
    # dictionary over the old one.
    (n_verse,) = cur.execute("SELECT COUNT(*) FROM verse").fetchone()
    (n_tr,) = cur.execute("SELECT COUNT(*) FROM translation").fetchone()
    if not n_verse or not n_tr:
        print(f"✗ Refusing to run: verse={n_verse:,}, translation={n_tr} — "
              f"is this a complete build?")
        return 1
    print(f"  source: {n_verse:,} verses across {n_tr} translations")

    before = cur.execute("SELECT COUNT(*) FROM search_terms").fetchone()[0]

    build_search_terms(cur, con)

    print("\nVerifying search_terms...")
    failures = verify_search_terms(cur)
    if failures:
        con.rollback()
        print("\n✗ search_terms verification FAILED — nothing written:")
        for f in failures:
            print(f"    • {f}")
        return 1

    con.commit()
    after = cur.execute("SELECT COUNT(*) FROM search_terms").fetchone()[0]
    cur.execute("ANALYZE")
    con.commit()
    con.close()

    print(f"\n✓ search_terms: {before:,} → {after:,} rows")
    print("  Next: cp sourcebible.db SourceBible/Resources/sourcebible.db")
    print("        Xcode: ⇧⌘K (Clean Build Folder) → Run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
