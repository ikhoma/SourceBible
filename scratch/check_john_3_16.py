import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Query word table fields (Macula data sources) for John 3:16
cur.execute("""
    SELECT 
        position,
        surface,
        lemma,
        strongs_id,
        morph,
        gloss,
        xlit,
        gloss_macula,
        syntax_role,
        greek,
        greek_strong
    FROM word
    WHERE book_id = 'JHN' AND chapter = 3 AND verse = 16
    ORDER BY position
""")
rows = cur.fetchall()

print("| Pos | Surface | Lemma | Strong's ID | Morph | Gloss (TSV) | Xlit | Gloss (XML) | Syntax Role | Greek | Greek Strong's |")
print("|---|---|---|---|---|---|---|---|---|---|---|")

for row in rows:
    pos, surface, lemma, strongs_id, morph, gloss, xlit, gloss_mac, role, gk, gk_str = row
    
    # Clean None values to empty strings
    lemma = lemma or ""
    strongs_id = strongs_id or ""
    morph = morph or ""
    gloss = gloss or ""
    xlit = xlit or ""
    gloss_mac = gloss_mac or ""
    role = role or ""
    gk = gk or ""
    gk_str = gk_str or ""
    
    print(f"| {pos} | **{surface}** | {lemma} | `{strongs_id}` | `{morph}` | {gloss} | *{xlit}* | {gloss_mac} | `{role}` | {gk} | `{gk_str}` |")

conn.close()
