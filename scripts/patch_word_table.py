#!/usr/bin/env python3
"""
patch_word_table.py
-------------------
Patches the Hebrew word table in sourcebible.db without a full rebuild.

What it fixes
─────────────
The original import used the Macula ref's word-group position (!N) as a
unique key, silently dropping all tokens beyond the first in each group.
Hebrew word groups commonly include a prefix token AND the root token at the
same !N position.  This dropped ~163 k tokens (≈35% of the Hebrew corpus).

Greek is unaffected (one token per ref in the Greek TSV).

Usage
─────
    python3 scripts/patch_word_table.py

The script:
  1. Deletes all rows in word WHERE language = 'hbo'
  2. Re-imports from data/macula-hebrew-main.zip with sequential positions
  3. Writes the patched DB to sourcebible.db (same path)
  4. Copies it to SourceBible/Resources/sourcebible.db if that path exists
"""

import csv, io, re, sqlite3, zipfile, shutil
from pathlib import Path

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT     = Path(__file__).parent.parent
DB_PATH  = ROOT / "sourcebible.db"
RES_DB   = ROOT / "SourceBible" / "Resources" / "sourcebible.db"
HEB_ZIP  = ROOT / "data" / "macula-hebrew-main.zip"
HEB_TSV  = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"

BOOKS = [
    ( 1,"GEN"), ( 2,"EXO"), ( 3,"LEV"), ( 4,"NUM"), ( 5,"DEU"),
    ( 6,"JOS"), ( 7,"JDG"), ( 8,"RUT"), ( 9,"1SA"), (10,"2SA"),
    (11,"1KI"), (12,"2KI"), (13,"1CH"), (14,"2CH"), (15,"EZR"),
    (16,"NEH"), (17,"EST"), (18,"JOB"), (19,"PSA"), (20,"PRO"),
    (21,"ECC"), (22,"SNG"), (23,"ISA"), (24,"JER"), (25,"LAM"),
    (26,"EZK"), (27,"DAN"), (28,"HOS"), (29,"JOL"), (30,"AMO"),
    (31,"OBA"), (32,"JON"), (33,"MIC"), (34,"NAM"), (35,"HAB"),
    (36,"ZEP"), (37,"HAG"), (38,"ZEC"), (39,"MAL"),
]
VALID_OSIS = {b[1] for b in BOOKS}


def normalize_strongs(raw, lang_prefix=""):
    if not raw:
        return None
    first = raw.strip().split()[0]
    if not first:
        return None
    if first[0].isdigit() and lang_prefix:
        first = lang_prefix + first
    m = re.match(r'^([HG])0*(\d+)([a-z]?)$', first, re.IGNORECASE)
    if m:
        return f"{m.group(1).upper()}{m.group(2)}{m.group(3)}"
    return None


def parse_ref(ref):
    """'PSA 1:2!3' → ('PSA', 1, 2, 3) or None."""
    m = re.match(r'^(\S+)\s+(\d+):(\d+)(?:!(\d+))?', ref)
    if not m:
        return None
    book = m.group(1).upper()
    if book not in VALID_OSIS:
        return None
    return book, int(m.group(2)), int(m.group(3)), int(m.group(4) or 1)


def parse_tsv(zf):
    """Read the Hebrew TSV and return word rows with sequential positions."""
    rows = []
    verse_seq: dict = {}
    with zf.open(HEB_TSV) as f:
        reader = csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t")
        for row in reader:
            ref     = row.get("ref", "").strip()
            parsed  = parse_ref(ref)
            if not parsed:
                continue
            osis, ch, vs, _ = parsed

            surface = row.get("text", "").strip()
            if not surface:
                continue                        # empty morphological marker

            lemma      = row.get("lemma",   "").strip() or None
            morph      = row.get("morph",   "").strip() or None
            gloss      = row.get("english", "").strip() or None
            strongs_id = normalize_strongs(row.get("strongnumberx", ""), "H")

            key = (osis, ch, vs)
            pos = verse_seq.get(key, 0) + 1
            verse_seq[key] = pos

            word_id = f"{osis}|{ch}|{vs}|{pos}"
            rows.append((word_id, osis, ch, vs, pos, surface, lemma,
                         strongs_id, morph, gloss, "hbo"))
    return rows


def main():
    print("=" * 55)
    print("  Macula Hebrew word-table patch")
    print("=" * 55)

    if not HEB_ZIP.exists():
        raise SystemExit(f"ERROR: {HEB_ZIP} not found. Put macula-hebrew-main.zip in data/")
    if not DB_PATH.exists():
        raise SystemExit(f"ERROR: {DB_PATH} not found. Run build_db.py first.")

    print(f"\nDB:        {DB_PATH}")
    print(f"Source:    {HEB_ZIP}")

    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()

    # Before
    cur.execute("SELECT COUNT(*) FROM word WHERE language='hbo'")
    before = cur.fetchone()[0]
    print(f"\nHebrew words before patch: {before:,}")

    # Wipe Hebrew words
    print("Deleting old Hebrew words …")
    cur.execute("DELETE FROM word WHERE language='hbo'")
    con.commit()

    # Re-import
    print("Parsing Macula Hebrew TSV …")
    with zipfile.ZipFile(HEB_ZIP) as zf:
        rows = parse_tsv(zf)
    print(f"Parsed {len(rows):,} tokens (was {before:,} → +{len(rows)-before:,})")

    print("Inserting …")
    cur.executemany(
        "INSERT OR IGNORE INTO word "
        "(id,book_id,chapter,verse,position,surface,lemma,strongs_id,morph,gloss,language) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()

    # Verify
    cur.execute("SELECT COUNT(*) FROM word WHERE language='hbo'")
    after = cur.fetchone()[0]
    print(f"Hebrew words after  patch: {after:,}")

    # Spot-check PSA 1:2
    cur.execute(
        "SELECT position, surface, strongs_id, lemma "
        "FROM word WHERE book_id='PSA' AND chapter=1 AND verse=2 ORDER BY position"
    )
    psa12 = cur.fetchall()
    print(f"\nPSA 1:2 spot-check: {len(psa12)} words (expected 15)")
    for r in psa12:
        print(f"  pos={r[0]:2}  {r[1]!r:22} strongs={r[2]}  lemma={r[3]}")

    # Finalize
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    cur.execute("PRAGMA journal_mode=DELETE")
    cur.execute("ANALYZE")
    con.commit()
    con.close()

    mb = DB_PATH.stat().st_size / 1_048_576
    print(f"\nDB size: {mb:.1f} MB")

    # Copy to Resources if it exists
    if RES_DB.exists():
        shutil.copy2(DB_PATH, RES_DB)
        print(f"Copied → {RES_DB}")
    else:
        print(f"Note: {RES_DB} not found — copy sourcebible.db to Xcode manually.")

    print("\n✓ Patch complete.")


if __name__ == "__main__":
    main()
