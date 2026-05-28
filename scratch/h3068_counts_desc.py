import sqlite3
import os
import re

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# 1. Get total count
cur.execute("SELECT COUNT(*) FROM word WHERE strongs_id = 'H3068'")
total_count = cur.fetchone()[0]

# 2. Get counts per book ordered descending by count
cur.execute("""
    SELECT book_id, COUNT(*) as freq 
    FROM word 
    WHERE strongs_id = 'H3068' 
    GROUP BY book_id 
    ORDER BY freq DESC
""")
book_counts = cur.fetchall()

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
for b_id, count in book_counts:
    # Get first occurrence
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
            
    results.append((b_id, count, example_ref, example_verse))

# Also add the books where it is 0
all_ot_books = set(book_names_ua.keys())
present_books = set([r[0] for r in results])
missing_books = all_ot_books - present_books
for b_id in sorted(missing_books):
    results.append((b_id, 0, "", ""))

print(f"Total H3068 (YHWH) occurrences: {total_count}")
print("\n| Книга | Кількість | Перша згадка (Приклад KJV) |")
print("|---|---|---|")
for b_id, count, ref, text in results:
    b_name_ua = book_names_ua.get(b_id, b_id)
    if count > 0:
        clean_text = re.sub(r'<[^>]+>', '', text) if text else ""
        clean_text = re.sub(r'\d+', '', clean_text).strip()
        print(f"| {b_name_ua} (`{b_id}`) | {count} | {ref}: *\"{clean_text}\"* |")
    else:
        print(f"| {b_name_ua} (`{b_id}`) | 0 | *Слово не зустрічається* |")

conn.close()
