import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Query lemma frequencies with part of speech and definitions
# We will filter out grammatical particles, prepositions, conjunctions, pronouns, etc.
# parts of speech to ignore (commonly):
# - particles, prepositions, conjunctions, relative pronouns, definite articles
# In strongs table: part_of_speech might contain things like "prep", "conj", "art", "particle", etc.
# Let's inspect the most frequent strongs entries in the database first.
cur.execute("""
    SELECT 
        w.strongs_id, 
        w.lemma, 
        w.language,
        COUNT(*) as freq,
        s.part_of_speech,
        s.short_def,
        s.long_def
    FROM word w
    LEFT JOIN strongs s ON w.strongs_id = s.id
    WHERE w.strongs_id IS NOT NULL
    GROUP BY w.strongs_id, w.lemma
    ORDER BY freq DESC
    LIMIT 100
""")
rows = cur.fetchall()

print("Top 50 most frequent Strong's IDs in the database:")
print("| Rank | Strong's ID | Lemma | Language | Freq | Part of Speech | Short Def | Meaningful? |")
print("|---|---|---|---|---|---|---|---|")

rank = 1
for row in rows:
    sid, lemma, lang, freq, pos, short_def, long_def = row
    pos = pos or ""
    short_def = short_def or ""
    
    # Simple heuristic to determine if it is a grammatical particle / preposition / conjunction / pronoun / article
    is_grammatical = False
    
    # We can check short_def or pos for common grammatical words
    pos_lower = pos.lower()
    short_lower = short_def.lower()
    
    # Hebrew prepositions, conjunctions, articles, pronouns
    # e.g., H871a (in), H2050b (and), H1886a (the) - wait, let's look at the actual words
    # Common ones:
    # H853 (direct object marker - et/את)
    # H1980 (walk/go)
    # H3068 (YHWH / LORD)
    # H430 (Elohim / God)
    # H1121 (ben / son)
    # H559 (amar / to say)
    # H1870 (way/derekh)
    # H3117 (yom / day)
    
    grammatical_pos = ['prep', 'conj', 'art', 'pron', 'part', 'particle', 'preposition', 'conjunction', 'relative', 'article', 'pronoun']
    if any(gp in pos_lower for gp in grammatical_pos):
        is_grammatical = True
        
    # Check common non-meaningful short definitions
    non_meaningful_keywords = ['direct object', 'relative', 'preposition', 'conjunction', 'article', 'pronoun', 'sign of the definite object']
    if any(kw in short_lower for kw in non_meaningful_keywords):
        is_grammatical = True
        
    # Special overrides for particles that might have empty/weird pos
    if sid in ['H853', 'H834', 'H3808', 'H3588', 'H4100', 'H4310', 'H1992', 'H1992a', 'H2007', 'H1931', 'H2088', 'H2090', 'H2090a', 'H5921', 'H413', 'H4480', 'H5973']:
        is_grammatical = True

    meaningful_status = "No" if is_grammatical else "Yes"
    print(f"| {rank} | `{sid}` | {lemma} | {lang} | {freq} | {pos} | {short_def} | {meaningful_status} |")
    rank += 1

conn.close()
