import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Query words for Psalm 1:1
cur.execute("""
    SELECT 
        w.position, 
        w.surface, 
        w.lemma, 
        w.strongs_id, 
        w.gloss, 
        w.xlit, 
        s.original, 
        s.transliteration, 
        s.xlit_simple, 
        s.short_def, 
        s.long_def
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.book_id = 'PSA' AND w.chapter = 1 AND w.verse = 1
    ORDER BY w.position
""")
rows = cur.fetchall()

print(f"| Position | Hebrew Word | Lemma | Strong's ID | Gloss | Translit (Academic/Simple) | Short Definition | BDB Long Definition |")
print(f"|---|---|---|---|---|---|---|---|")

for row in rows:
    pos, surface, lemma, strongs_id, gloss, xlit, orig, trans, xlit_sim, short_def, long_def = row
    
    # Format the long definition to be single-line for markdown tables (replace newlines with <br>)
    long_def_clean = ""
    if long_def:
        long_def_clean = long_def.replace("\n", "<br>").replace("\r", "").replace("|", "\\|")
    
    short_def_clean = short_def.replace("|", "\\|") if short_def else ""
    surface_clean = surface.replace("|", "\\|")
    lemma_clean = lemma.replace("|", "\\|") if lemma else ""
    orig_clean = orig.replace("|", "\\|") if orig else ""
    gloss_clean = gloss.replace("|", "\\|") if gloss else ""
    
    trans_display = f"{trans or ''} / {xlit_sim or ''}"
    if xlit:
        trans_display = f"{xlit} ({trans_display})"
        
    print(f"| {pos} | **{surface_clean}** ({orig_clean}) | {lemma_clean} | `{strongs_id or ''}` | {gloss_clean} | {trans_display} | {short_def_clean} | {long_def_clean} |")

conn.close()
