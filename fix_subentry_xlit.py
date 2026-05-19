#!/usr/bin/env python3
"""
fix_subentry_xlit.py
---------------------
Two-phase fix:

Phase 1 — Reconstruct the DB.
  The source file is an APFS sparse SQLite file. Pages that were never written
  read back as zeros, which SQLite treats as corrupt (btreeInitPage error 11).
  sqlite3's .recover mode reads every readable page and writes a clean copy.

Phase 2 — NULL bad xlits for Strong's grammatical sub-entries.
  Sub-entries like H2050b/c/d, H871a/b, H1886d inherited the transliteration
  from their unrelated base number during migration. We NULL any sub-entry
  whose transliteration is identical to its base number's transliteration.

Usage:
  python3 fix_subentry_xlit.py
  python3 fix_subentry_xlit.py /path/to/sourcebible.db
"""

import subprocess, sys, os, shutil, tempfile

DB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "SourceBible", "Resources", "sourcebible.db"
)
SQLITE = "/usr/bin/sqlite3"
print(f"DB:     {DB}")
print(f"SQLite: {SQLITE}\n")


def run(db_path: str, sql: str, label: str = "") -> str:
    r = subprocess.run([SQLITE, db_path], input=sql,
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        print(f"ERROR ({label}):\n{r.stderr.strip()}")
        sys.exit(1)
    return r.stdout.strip()


# ─────────────────────────────────────────────────────────────
# Phase 1: Reconstruct via .recover
# ─────────────────────────────────────────────────────────────
print("Phase 1: Recovering DB from corrupt sparse file …")

tmp_dir = tempfile.mkdtemp()
recovered_sql  = os.path.join(tmp_dir, "recovered.sql")
recovered_db   = os.path.join(tmp_dir, "recovered.db")

# .recover dumps every readable page as INSERT statements
recover_proc = subprocess.run(
    [SQLITE, DB, ".recover"],
    capture_output=True, text=True, encoding="utf-8",
)
print(f"  .recover exit code: {recover_proc.returncode}")
if recover_proc.stderr.strip():
    print(f"  .recover warnings:\n    " +
          recover_proc.stderr.strip().replace("\n", "\n    "))

dump = recover_proc.stdout
with open(recovered_sql, "w", encoding="utf-8") as f:
    f.write(dump)

lines = dump.count("\n")
print(f"  Recovered {lines:,} SQL lines → {recovered_sql}")

# Feed dump into a fresh DB
print(f"  Building {recovered_db} …")
r = subprocess.run([SQLITE, recovered_db],
                   input=dump, capture_output=True, text=True, encoding="utf-8")
if r.returncode != 0:
    print(f"ERROR building recovered DB:\n{r.stderr}")
    sys.exit(1)

# Verify key tables
tables = run(recovered_db, ".tables")
print(f"  Tables in recovered DB: {tables}")
if "strongs" not in tables:
    print("ERROR: 'strongs' missing from recovered DB. The data may be unrecoverable.")
    sys.exit(1)

count = run(recovered_db, "SELECT COUNT(*) FROM strongs;")
print(f"  strongs rows: {count}")

# ─────────────────────────────────────────────────────────────
# Phase 2: NULL bad xlits
# ─────────────────────────────────────────────────────────────
print("\nPhase 2: Fixing sub-entry xlits …")

find_sql = """
SELECT sub.id, sub.transliteration, base.transliteration
FROM   strongs AS sub
JOIN   strongs AS base
  ON   base.id  = RTRIM(sub.id, 'abcdefghijklmnopqrstuvwxyz')
 AND   base.id != sub.id
WHERE  sub.transliteration IS NOT NULL
  AND  sub.transliteration = base.transliteration;
"""
raw = run(recovered_db, find_sql, "find")

if not raw:
    print("  No sub-entries with inherited transliteration. Nothing to patch.")
else:
    rows = [line.split("|") for line in raw.splitlines()]
    print(f"  Found {len(rows)} sub-entries with wrong transliteration:")
    for r in rows:
        print(f"    {r[0]:10}  xlit='{r[1]}'  (from base '{r[2]}')")

    ids_sql = ", ".join(f"'{r[0]}'" for r in rows)
    patch = f"UPDATE strongs SET transliteration = NULL WHERE id IN ({ids_sql});"
    run(recovered_db, patch, "patch")
    print(f"  Patched {len(rows)} row(s).")

# ─────────────────────────────────────────────────────────────
# Replace original DB with the clean recovered copy
# ─────────────────────────────────────────────────────────────
print(f"\nPhase 3: Replacing original DB …")
backup = DB + ".bak"
shutil.copy2(DB, backup)
print(f"  Backup: {backup}")
shutil.copy2(recovered_db, DB)
print(f"  Replaced: {DB}")

# Final sanity check on the replaced file
tables_final = run(DB, ".tables")
rows_final   = run(DB, "SELECT COUNT(*) FROM strongs;")
print(f"\n✓ Done.  Tables: {tables_final}")
print(f"         strongs rows: {rows_final}")
print(f"\nRebuild SourceBible in Xcode to pick up the updated DB.")
