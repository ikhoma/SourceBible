import sqlite3
import os
import re

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Let's find the top 5 verses in the Book of Psalms (PSA) containing YHWH (strongs_id = 'H3068')
# ordered by the total cross-reference votes (inbound or outbound)
# This represents a proxy for "rhetorical/theological weight".
cur.execute("""
    SELECT 
        v.chapter, 
        v.verse, 
        v.text,
        SUM(xr.votes) as total_votes
    FROM word w
    JOIN verse v ON w.book_id = v.book_id AND w.chapter = v.chapter AND w.verse = v.verse
    LEFT JOIN cross_reference xr ON 
        (xr.from_book = v.book_id AND xr.from_chapter = v.chapter AND xr.from_verse = v.verse) OR
        (xr.to_book = v.book_id AND xr.to_chapter = v.chapter AND xr.to_verse = v.verse)
    WHERE w.book_id = 'PSA' AND w.strongs_id = 'H3068' AND v.translation = 'KJV'
    GROUP BY v.chapter, v.verse
    ORDER BY total_votes DESC
    LIMIT 5
""")
weighted_verses = cur.fetchall()

print("Top 5 'Rhetorically Weighted' Verses for YHWH in Psalms (by Cross-Ref Votes):")
print("| Verse | Total Votes | Verse Text |")
print("|---|---|---|")
for ch, vs, text, votes in weighted_verses:
    clean_text = re.sub(r'<[^>]+>', '', text)
    clean_text = re.sub(r'\d+', '', clean_text).strip()
    print(f"| Psalm {ch}:{vs} | {votes} | *\"{clean_text}\"* |")

conn.close()
