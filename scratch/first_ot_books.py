import sqlite3
import os
import re

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

books = ["GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG"]
book_names_ua = {
    "GEN": "Буття", "EXO": "Вихід", "LEV": "Левит", "NUM": "Числа", "DEU": "Повторення Закону",
    "JOS": "Ісус Навин", "JDG": "Судді"
}

for b_id in books:
    cur.execute("SELECT COUNT(*) FROM word WHERE book_id = ? AND strongs_id = 'H3068'", (b_id,))
    count = cur.fetchone()[0]
    
    cur.execute("""
        SELECT chapter, verse 
        FROM word 
        WHERE book_id = ? AND strongs_id = 'H3068'
        ORDER BY chapter, verse, position
        LIMIT 1
    """, (b_id,))
    first_occ = cur.fetchone()
    
    example_verse = ""
    example_ref = ""
    if first_occ:
        ch, vs = first_occ
        example_ref = f"{b_id} {ch}:{vs}"
        cur.execute("""
            SELECT text 
            FROM verse 
            WHERE book_id = ? AND chapter = ? AND verse = ? AND translation = 'KJV'
        """, (b_id, ch, vs))
        text_row = cur.fetchone()
        if text_row:
            example_verse = text_row[0]
            
    b_name_ua = book_names_ua[b_id]
    clean_text = re.sub(r'<[^>]+>', '', example_verse) if example_verse else ""
    # Remove Strong numbers (e.g. word1234)
    clean_text = re.sub(r'\d+', '', clean_text)
    print(f"| {b_name_ua} (`{b_id}`) | {count} | {example_ref}: *\"{clean_text.strip()}\"* |")

conn.close()
