"""
Two fixes:
1. Strip trailing mater-lectionis yod: xlit ending in 'iy' → strip to 'i'
   e.g. kiy→ki, niy→ni, biy→bi  (Macula convention, not spoken form)
   Does NOT touch 'ay' or 'ey' diphthongs.

2. H2656 (חֵפֶץ) construct forms have xlit=NULL in Macula.
   Derive a spoken xlit from the Hebrew surface + known vowel rules:
   - חֶ = che  (het + segol)
   - פְ = p   (pe + silent sheva → drop)
   - צ = ts   (tsade)
   - Suffix vowels: וֹ=ow, ִי=i, ָ=a, etc.
   We update them to 'cheptsow', 'cheptsi', etc. based on suffix.
"""
import sqlite3, os, unicodedata

db_path = "/Users/imac/Projects/SourceBible/SourceBible/Resources/sourcebible.db"
if not os.path.exists(db_path):
    print(f"Error: DB not found"); exit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

# ── FIX 1: kiy → ki (mater lectionis yod after i-vowel) ──────────────────────
cur.execute("SELECT COUNT(*) FROM word WHERE xlit LIKE '%iy'")
total = cur.fetchone()[0]
print(f"Fix 1: words ending in 'iy': {total}")

cur.execute("""
    UPDATE word
    SET xlit = SUBSTR(xlit, 1, LENGTH(xlit) - 1)
    WHERE xlit LIKE '%iy'
""")
print(f"  Updated {cur.rowcount} rows (stripped trailing 'y' from 'iy' ending)")

# Verify H3588
cur.execute("SELECT DISTINCT xlit FROM word WHERE strongs_id='H3588' LIMIT 10")
print(f"  H3588 distinct xlits now: {[r[0] for r in cur.fetchall()]}")

# ── FIX 2: H2656 construct forms — derive xlit from surface Hebrew ────────────
# These words have no Macula transliteration. We derive from the surface form.
# The pattern: חֶפְצ + suffix-vowel
# Known suffix tokens (H2050c = pronominal suffix):
#   וֹ  = 'ow'  (3ms: his)
#   ִי  = 'i'   (1cs: my)
#   ְךָ = 'ekha' (2ms: your)
#   etc.
# Strategy: for H2656 words with xlit=NULL, look at the next token (H2050c) to 
# get the suffix, then build: 'chepts' + suffix_xlit

# First update the H2656 construct forms themselves
# The construct stem is always חֶפְצ = 'chepts' (het+segol, pe+silent-sheva, tsade)
cur.execute("""
    SELECT id, surface FROM word 
    WHERE strongs_id='H2656' AND xlit IS NULL
""")
h2656_rows = cur.fetchall()
print(f"\nFix 2: H2656 words with no xlit: {len(h2656_rows)}")

# For each, look at the following token to get the suffix
updated_h2656 = 0
for wid, surface in h2656_rows:
    parts = wid.split('|')
    book, ch, vs, pos = parts
    next_pos = str(int(pos) + 1)
    next_id = f"{book}|{ch}|{vs}|{next_pos}"
    
    cur.execute("SELECT surface, xlit, strongs_id FROM word WHERE id=?", (next_id,))
    next_row = cur.fetchone()
    
    if next_row:
        next_surf, next_xlit, next_strongs = next_row
        # Determine suffix vowel from next token surface
        # וֹ = holam vav → 'ow'
        # ִי = hiriq yod → 'i'  (but after fix 1, xlit would be 'i')
        # ָ  = qamats → 'a'
        # ֶ  = segol → 'e'
        if 'וֹ' in next_surf or '\u05d5\u05b9' in next_surf:
            suffix = 'ow'
        elif next_xlit:
            suffix = next_xlit
        else:
            suffix = ''
        
        stem = 'chepts'
        full_xlit = stem + suffix
        
        cur.execute("UPDATE word SET xlit=? WHERE id=?", (full_xlit, wid))
        updated_h2656 += 1
        print(f"  {wid}: {surface} + {next_surf} ({next_strongs}) → xlit='{full_xlit}'")
    else:
        # Word-final construct with no suffix token
        cur.execute("UPDATE word SET xlit='chepts' WHERE id=?", (wid,))
        updated_h2656 += 1
        print(f"  {wid}: {surface} (no suffix) → xlit='chepts'")

print(f"  Updated {updated_h2656} H2656 rows")

# ── FIX 3: update xlit_simple for H2656 strongs entry too ──────────────────────
cur.execute("SELECT xlit_simple FROM strongs WHERE id='H2656'")
old = cur.fetchone()
print(f"\nFix 3: strongs H2656 xlit_simple was: '{old[0] if old else None}'")
cur.execute("UPDATE strongs SET xlit_simple='chephets' WHERE id='H2656'")
print("  Updated H2656 xlit_simple → 'chephets'")

conn.commit()
conn.close()
print("\nDone.")
