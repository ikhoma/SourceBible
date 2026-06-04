import sqlite3
import os

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

if not os.path.exists(db_path):
    print(f"Error: Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# 1. Update H835a variants to 'ashrey' in word table
cur.execute("""
    UPDATE word 
    SET xlit = 'ashrey' 
    WHERE strongs_id = 'H835a' 
      AND (xlit IN ('ashere', 'asherey', 'ashre') OR xlit IS NULL)
""")
word_rows = cur.rowcount
print(f"Updated {word_rows} rows in word table to 'ashrey'")

conn.commit()
conn.close()
print("Database patched successfully.")
