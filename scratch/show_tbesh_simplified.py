import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Query word and strongs simple xlit for Psalm 1:1
cur.execute("""
    SELECT 
        w.position, 
        w.surface, 
        w.strongs_id, 
        s.xlit_simple,
        w.gloss
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.book_id = 'PSA' AND w.chapter = 1 AND w.verse = 1
    ORDER BY w.position
""")
rows = cur.fetchall()

print("| Pos | Hebrew Word | Strong's ID | Gloss | TBESH Simplified Translit |")
print("|---|---|---|---|---|")

for row in rows:
    pos, surface, strongs_id, xlit_sim, gloss = row
    strongs_id = strongs_id or ""
    xlit_sim = xlit_sim or ""
    gloss = gloss or ""
    print(f"| {pos} | **{surface}** | `{strongs_id}` | {gloss} | **{xlit_sim}** |")

conn.close()
