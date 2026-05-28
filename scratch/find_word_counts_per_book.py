import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# The 8 words from Old Testament:
# 1. H3068 - YHWH
# 2. H559 - amar (say)
# 3. H1121 - ben (son)
# 4. H430 - Elohim (God)
# 5. H4428 - melek (king)
# 6. H776 - erets (land/earth)
# 7. H3117 - yom (day)
# 8. H376 - ish (man)

target_strongs = {
    "H3068": ("יהוה", "YHWH / Господь"),
    "H559": ("אָמַר", "сказати / говорити"),
    "H1121": ("בֵּן", "син"),
    "H430": ("אֱלֹהִים", "Бог"),
    "H4428": ("מֶלֶךְ", "цар"),
    "H776": ("אֶרֶץ", "земля / країна"),
    "H3117": ("יוֹם", "день"),
    "H376": ("אִישׁ", "чоловік / людина")
}

# We also need a mapping from book_id (like GEN, PSA) to its English/Ukrainian name
cur.execute("SELECT id, name_en FROM book")
book_names = {row[0]: row[1] for row in cur.fetchall()}

# Add Ukrainian translations for book names for display:
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

print("| Слово | Strong's | Книга з макс. частотою | Макс. к-ть в одній книзі | Загальна к-ть в Біблії |")
print("|---|---|---|---|---|")

for sid, (hebrew, translation) in target_strongs.items():
    # Find overall frequency
    cur.execute("SELECT COUNT(*) FROM word WHERE strongs_id = ?", (sid,))
    total_count = cur.fetchone()[0]
    
    # Find counts per book
    cur.execute("""
        SELECT book_id, COUNT(*) as freq 
        FROM word 
        WHERE strongs_id = ? 
        GROUP BY book_id 
        ORDER BY freq DESC
        LIMIT 1
    """, (sid,))
    top_book = cur.fetchone()
    
    if top_book:
        b_id, b_freq = top_book
        book_display = book_names_ua.get(b_id, book_names.get(b_id, b_id))
        print(f"| **{hebrew}** ({translation}) | `{sid}` | {book_display} (`{b_id}`) | **{b_freq}** | {total_count} |")
    else:
        print(f"| **{hebrew}** ({translation}) | `{sid}` | - | - | {total_count} |")

conn.close()
