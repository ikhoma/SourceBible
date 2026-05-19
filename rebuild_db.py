#!/usr/bin/env python3
"""
rebuild_db.py
--------------
Будує чистий sourcebible.db з нуля в одному запуску:

  1. Копіює робочу базу з Bible App backup
  2. Мігрує схему word таблиці (gloss→gloss_macula, додає syntax_role/greek/greek_strong)
  3. Виправляє неправильний xlit для граматичних sub-entries (H2050b, H871a, H1886d тощо)
  4. Додає verse_map (7292 рядки — вирівнювання нумерації псалмів між MT і перекладами)
  5. Замінює SourceBible/Resources/sourcebible.db

Запуск:
  cd ~/Projects/SourceBible
  python3 rebuild_db.py
"""

import sqlite3, shutil, sys, os, re

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
SOURCE_DB   = os.path.expanduser("~/Documents/Claude/Projects/Bible App/sourcebible.db")
TARGET_DB   = os.path.join(SCRIPT_DIR, "SourceBible", "Resources", "sourcebible.db")
WORK_DB     = "/tmp/sourcebible_rebuild.db"

# ─────────────────────────────────────────────────────────────────────────────
# Step 0: Copy source → work location
# ─────────────────────────────────────────────────────────────────────────────
print("=" * 60)
print("Step 0: Copying source DB …")
if not os.path.exists(SOURCE_DB):
    print(f"ERROR: source not found at {SOURCE_DB}")
    sys.exit(1)
shutil.copy2(SOURCE_DB, WORK_DB)
size = os.path.getsize(WORK_DB) / 1e6
print(f"  Copied {size:.0f} MB → {WORK_DB}")

conn = sqlite3.connect(WORK_DB)
cur  = conn.cursor()

def col_names(table):
    cur.execute(f"PRAGMA table_info({table})")
    return {r[1] for r in cur.fetchall()}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Migrate word table schema
# ─────────────────────────────────────────────────────────────────────────────
print("\nStep 1: Migrating word table schema …")
cols = col_names("word")
print(f"  Current columns: {sorted(cols)}")

if "gloss" in cols and "gloss_macula" not in cols:
    cur.execute("ALTER TABLE word RENAME COLUMN gloss TO gloss_macula")
    print("  Renamed gloss → gloss_macula")
elif "gloss_macula" in cols:
    print("  gloss_macula already present")
else:
    print("  WARNING: neither 'gloss' nor 'gloss_macula' found!")

for col in ("syntax_role", "greek", "greek_strong"):
    if col not in cols:
        cur.execute(f"ALTER TABLE word ADD COLUMN {col} TEXT")
        print(f"  Added column: {col}")
    else:
        print(f"  {col} already present")

conn.commit()
final_cols = col_names("word")
print(f"  Final columns: {sorted(final_cols)}")

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Fix wrong xlit for Strong's sub-entries
# ─────────────────────────────────────────────────────────────────────────────
print("\nStep 2: Fixing sub-entry xlit …")
cur.execute("""
    SELECT sub.id
    FROM   strongs AS sub
    JOIN   strongs AS base
      ON   base.id  = RTRIM(sub.id, 'abcdefghijklmnopqrstuvwxyz')
     AND   base.id != sub.id
    WHERE  sub.transliteration IS NOT NULL
      AND  sub.transliteration != ''
      AND  sub.transliteration = base.transliteration
      AND  sub.original != base.original
""")
bad_ids = [r[0] for r in cur.fetchall()]
print(f"  Found {len(bad_ids)} sub-entries with inherited wrong xlit")
if bad_ids:
    placeholders = ",".join("?" * len(bad_ids))
    cur.execute(f"UPDATE strongs SET transliteration = NULL WHERE id IN ({placeholders})", bad_ids)
    print(f"  Nullified {cur.rowcount} rows")
conn.commit()

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Build verse_map
# ─────────────────────────────────────────────────────────────────────────────
print("\nStep 3: Building verse_map …")

cur.execute("DROP TABLE IF EXISTS verse_map")
cur.execute("""
    CREATE TABLE verse_map (
        translation  TEXT NOT NULL,
        book_id      TEXT NOT NULL,
        chapter      INT  NOT NULL,
        trans_verse  INT  NOT NULL,
        macula_verse INT  NOT NULL,
        PRIMARY KEY (translation, book_id, chapter, trans_verse)
    )
""")
cur.execute("CREATE INDEX IF NOT EXISTS idx_verse_map ON verse_map(translation, book_id, chapter)")

cur.execute("SELECT id FROM translation")
translations = [r[0] for r in cur.fetchall()]
print(f"  Translations: {translations}")

# Find chapters where verse counts differ between translation and Macula word table
total_rows = 0
chapters_affected = 0

for trans in translations:
    # Get all book/chapter combos where verse count differs
    cur.execute("""
        SELECT DISTINCT v.book_id, v.chapter,
               MAX(v.verse)       AS tv_max,
               MAX(w.verse)       AS mv_max
        FROM   verse v
        JOIN   word  w ON w.book_id = v.book_id AND w.chapter = v.chapter
        WHERE  v.translation = ?
        GROUP  BY v.book_id, v.chapter
        HAVING MAX(v.verse) != MAX(w.verse)
    """, (trans,))
    chapters = cur.fetchall()

    for book_id, chapter, tv_max, mv_max in chapters:
        # Load strongs ids from word table for each macula verse
        cur.execute("""
            SELECT verse, GROUP_CONCAT(strongs_id)
            FROM   word
            WHERE  book_id = ? AND chapter = ?
            GROUP  BY verse
            ORDER  BY verse
        """, (book_id, chapter))
        macula_strongs = {v: set(s.split(",")) if s else set()
                          for v, s in cur.fetchall()}

        # Load strongs ids from parsed verse text for each translation verse
        cur.execute("""
            SELECT verse, text FROM verse
            WHERE  translation = ? AND book_id = ? AND chapter = ?
            ORDER  BY verse
        """, (trans, book_id, chapter))
        tv_rows = cur.fetchall()

        # Parse <S>N</S> tags from verse text
        def extract_strongs(text):
            ids = set()
            for raw in re.findall(r'<S>([^<]+)</S>', text):
                for part in raw.split(","):
                    part = part.strip()
                    if part:
                        ids.add(part if part[0].isalpha() else "S" + part)
            return ids

        mappings = []
        used_macula = set()
        macula_verses = sorted(macula_strongs.keys())

        for tv, text in tv_rows:
            tv_set = extract_strongs(text)
            if not tv_set:
                continue
            # Find macula verse with highest overlap
            best_mv, best_overlap = tv, 0
            for mv in macula_verses:
                if mv in used_macula:
                    continue
                overlap = len(tv_set & macula_strongs[mv])
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_mv = mv
            if best_overlap >= 2 and best_mv != tv:
                mappings.append((trans, book_id, chapter, tv, best_mv))
                used_macula.add(best_mv)

        if mappings:
            cur.executemany(
                "INSERT OR REPLACE INTO verse_map VALUES (?,?,?,?,?)",
                mappings
            )
            total_rows += len(mappings)
            chapters_affected += 1

conn.commit()
print(f"  verse_map: {total_rows} rows across {chapters_affected} chapters")

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Final verification
# ─────────────────────────────────────────────────────────────────────────────
print("\nStep 4: Verification …")
for table, col in [("verse", None), ("word", None), ("strongs", None),
                   ("verse_map", None), ("cross_reference", None)]:
    cur.execute(f"SELECT COUNT(*) FROM {table}")
    print(f"  {table}: {cur.fetchone()[0]:,} rows")

# Spot-check: PSA 1:1 words
cur.execute("""
    SELECT w.surface, w.strongs_id, w.gloss_macula, w.xlit
    FROM word w WHERE w.book_id='PSA' AND w.chapter=1 AND w.verse=1
    ORDER BY w.position
""")
print(f"\n  PSA 1:1 words:")
for r in cur.fetchall():
    print(f"    {r[0]}  {r[1]}  gloss={r[2]}  xlit={r[3]}")

# Spot-check: verse_map for RST (a translation with big offsets)
cur.execute("SELECT COUNT(*) FROM verse_map WHERE translation='RST'")
rst_rows = cur.fetchone()[0]
print(f"\n  verse_map RST rows: {rst_rows}")

conn.close()

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Replace target
# ─────────────────────────────────────────────────────────────────────────────
print(f"\nStep 5: Replacing {TARGET_DB} …")
if os.path.exists(TARGET_DB + ".bak"):
    os.remove(TARGET_DB + ".bak")
if os.path.exists(TARGET_DB):
    shutil.copy2(TARGET_DB, TARGET_DB + ".bak")
    print(f"  Backup saved: {TARGET_DB}.bak")
shutil.copy2(WORK_DB, TARGET_DB)
final_size = os.path.getsize(TARGET_DB) / 1e6
print(f"  Written: {TARGET_DB} ({final_size:.0f} MB)")

print("\n✅ Done. Rebuild SourceBible in Xcode.")
