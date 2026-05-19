#!/usr/bin/env python3
"""
migrate_word_schema.py
-----------------------
Brings the word table schema in line with what DatabaseService.swift expects.

The Bible-App backup copy has an older schema:
  gloss          →  rename to gloss_macula
  (missing)      →  add syntax_role  TEXT
  (missing)      →  add greek        TEXT
  (missing)      →  add greek_strong TEXT

Run once after replacing sourcebible.db with the Bible-App backup copy.

Usage:
  python3 migrate_word_schema.py [path/to/sourcebible.db]
"""

import sqlite3, sys, os

DB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "SourceBible", "Resources", "sourcebible.db"
)
print(f"DB: {DB}\n")

conn = sqlite3.connect(DB)
cur  = conn.cursor()

# Current columns
cur.execute("PRAGMA table_info(word)")
cols = {r[1] for r in cur.fetchall()}
print("Current columns:", sorted(cols))

# ── 1. Rename gloss → gloss_macula ───────────────────────────────────────────
if "gloss" in cols and "gloss_macula" not in cols:
    print("\nRenaming gloss → gloss_macula …")
    cur.execute("ALTER TABLE word RENAME COLUMN gloss TO gloss_macula")
    print("  Done.")
elif "gloss_macula" in cols:
    print("\ngloss_macula already present — skipping rename.")
else:
    print("\nWARNING: neither 'gloss' nor 'gloss_macula' found in word table!")

# ── 2. Add missing columns ────────────────────────────────────────────────────
for col in ("syntax_role", "greek", "greek_strong"):
    if col not in cols:
        print(f"Adding column '{col}' …")
        cur.execute(f"ALTER TABLE word ADD COLUMN {col} TEXT")
        print(f"  Done.")
    else:
        print(f"'{col}' already present — skipping.")

conn.commit()

# ── 3. Verify ─────────────────────────────────────────────────────────────────
cur.execute("PRAGMA table_info(word)")
final_cols = [r[1] for r in cur.fetchall()]
print("\nFinal columns:", final_cols)

required = {"gloss_macula", "syntax_role", "greek", "greek_strong"}
missing  = required - set(final_cols)
if missing:
    print(f"\nERROR: still missing: {missing}")
    sys.exit(1)

print("\n✓ Schema migration complete. Rebuild SourceBible in Xcode.")
conn.close()
