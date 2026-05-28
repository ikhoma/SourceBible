import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Get words for Psalm 1:1
# schema: CREATE TABLE IF NOT EXISTS word (
#     id           TEXT PRIMARY KEY,  -- 'GEN|1|1|1'
#     book_id      TEXT NOT NULL,
#     chapter      INTEGER NOT NULL,
#     verse        INTEGER NOT NULL,
#     position     INTEGER NOT NULL,
#     surface      TEXT NOT NULL,
#     lemma        TEXT,
#     strongs_id   TEXT,
#     morph        TEXT,
#     gloss        TEXT,
#     language     TEXT NOT NULL,
#     ...
# )
print("Words in Psalm 1:1:")
cur.execute("""
    SELECT w.position, w.surface, w.lemma, w.strongs_id, w.gloss, w.xlit, s.original, s.transliteration, s.xlit_simple, s.short_def, s.long_def
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.book_id = 'PSA' AND w.chapter = 1 AND w.verse = 1
    ORDER BY w.position
""")
rows = cur.fetchall()

print(f"Found {len(rows)} words in PSA 1:1")
for row in rows:
    pos, surface, lemma, strongs_id, gloss, xlit, orig, trans, xlit_sim, short_def, long_def = row
    print("=" * 80)
    print(f"Position: {pos} | Surface: {surface} | Lemma: {lemma} | Strongs: {strongs_id} | Gloss: {gloss}")
    print(f"Context Xlit: {xlit} | Orig: {orig} | Translit: {trans} | Xlit Simple: {xlit_sim}")
    print(f"Short Def: {short_def}")
    print(f"Long Def (first 300 chars): {long_def[:300] if long_def else None}...")
    # Print the rest or full if needed, let's print full long_def
    print(f"Long Def (Full):\n{long_def}")

conn.close()
