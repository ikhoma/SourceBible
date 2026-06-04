"""
Patch the word table: strip trailing 'e' from xlits that end in 'khe'.
These arise from Hebrew words ending in ךְ (final kaf + silent sheva)
where an accent mark follows the sheva, causing it to be transliterated
as 'e' instead of being dropped.

Pattern: xlit ends in 'khe'  →  strip trailing 'e'
Examples: halakhe→halakh, derekhe→derekh, lekhe→lekh, varukhe→varukh
"""
import sqlite3, os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"
if not os.path.exists(db_path):
    print(f"Error: DB not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Preview affected rows
cur.execute("SELECT id, surface, xlit FROM word WHERE xlit LIKE '%khe'")
rows = cur.fetchall()
print(f"Found {len(rows)} words ending in 'khe'")
print("\nSample (first 15):")
for r in rows[:15]:
    wid, surface, xlit = r
    fixed = xlit[:-1]  # strip trailing 'e'
    print(f"  {wid}: {surface} | {xlit} → {fixed}")

print(f"\nApplying fix to all {len(rows)} rows...")
cur.execute("""
    UPDATE word
    SET xlit = SUBSTR(xlit, 1, LENGTH(xlit) - 1)
    WHERE xlit LIKE '%khe'
""")
print(f"Updated {cur.rowcount} rows.")

conn.commit()
conn.close()
print("Done.")
