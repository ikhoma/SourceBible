import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Get total count
cur.execute("SELECT COUNT(*) FROM word WHERE strongs_id = 'H3068'")
total_count = cur.fetchone()[0]

# All OT books in canonical order:
cur.execute("SELECT id, name_en, num FROM book WHERE testament = 'OT' ORDER BY num")
ot_books = cur.fetchall()

book_names_ua = {
    "GEN": "Буття", "EXO": "Вихід", "LEV": "Левит", "NUM": "Числа", "DEU": "Повторення Закону",
    "JOS": "Ісус Навин", "JDG": "Судді", "RUT": "Рут", "1SA": "1 Самуїла", "2SA": "2 Самуїла",
    "1KI": "1 Царів", "2KI": "2 Царів", "1CH": "1 Хронік", "2CH": "2 Хронік", "EZR": "Езри",
    "NEH": "Неемії", "EST": "Естер", "JOB": "Йова", "PSA": "Псалми", "PRO": "Приповісті",
    "ECC": "Екклезіяст", "SNG": "Пісня Пісень", "ISA": "Ісаї", "JER": "Єремії", "LAM": "Плач Єремії",
    "EZK": "Єзекіїля", "DAN": "Даниїла", "HOS": "Осії", "JOL": "Йоіля", "AMO": "Амоса",
    "OBA": "Овдія", "JON": "Йони", "MIC": "Михея", "NAM": "Наума", "HAB": "Авакума",
    "ZEP": "Софонії", "HAG": "Аггея", "ZEC": "Захарії", "MAL": "Малахії"
}

results = []
for b_id, b_name_en, b_num in ot_books:
    # 1. Count occurrences in this book
    cur.execute("SELECT COUNT(*) FROM word WHERE book_id = ? AND strongs_id = 'H3068'", (b_id,))
    count = cur.fetchone()[0]
    
    example_verse = ""
    example_ref = ""
    
    if count > 0:
        # 2. Get first occurrence (first chapter, first verse)
        cur.execute("""
            SELECT chapter, verse 
            FROM word 
            WHERE book_id = ? AND strongs_id = 'H3068'
            ORDER BY chapter, verse, position
            LIMIT 1
        """, (b_id,))
        first_occ = cur.fetchone()
        
        if first_occ:
            ch, vs = first_occ
            example_ref = f"{b_id} {ch}:{vs}"
            
            # 3. Get verse text (KJV preferred)
            cur.execute("""
                SELECT text 
                FROM verse 
                WHERE book_id = ? AND chapter = ? AND verse = ? AND translation = 'KJV'
            """, (b_id, ch, vs))
            text_row = cur.fetchone()
            if text_row:
                example_verse = text_row[0]
                
    results.append((b_id, count, example_ref, example_verse))

print(f"Total YHWH occurrences in Old Testament: {total_count}")
print("\n| Книга | Кількість | Перша згадка (Приклад KJV) |")
print("|---|---|---|")
for b_id, count, ref, text in results:
    b_name_ua = book_names_ua.get(b_id, b_id)
    # Strip strong tags from KJV text if any (e.g. <S>H3068</S>)
    import re
    clean_text = re.sub(r'<[^>]+>', '', text) if text else ""
    print(f"| {b_name_ua} (`{b_id}`) | {count} | {ref}: *\"{clean_text}\"* |" if count > 0 else f"| {b_name_ua} (`{b_id}`) | 0 | *Слово не зустрічається* |")

conn.close()
