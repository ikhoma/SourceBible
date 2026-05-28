import os
import re

tbesh_path = "/Users/imac/Projects/SourceBible/data/TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt"

if not os.path.exists(tbesh_path):
    print(f"Error: TBESH file not found at {tbesh_path}")
    exit(1)

# Strong's IDs in Psalm 1:1 (from word table)
strongs_list = [
    "H835a", "H1886a", "H376", "H834", "H3808", "H1980", "H871a", "H6098", 
    "H7563", "H2050b", "H871a", "H1870", "H2400", "H3808", "H5975", "H2050b", 
    "H871a", "H4186", "H3887a", "H3808", "H3427"
]

def format_id_for_search(sid):
    # Strip suffix like 'a' for searching base form if needed, e.g., H835a -> H0835
    match = re.match(r'^([HG])(\d+)([a-z]?)$', sid)
    if match:
        prefix, num, suffix = match.groups()
        num_padded = f"{int(num):04d}"
        return prefix + num_padded, suffix
    return sid, ""

print("Parsed forms to search in TBESH:")
search_pairs = [format_id_for_search(sid) for sid in strongs_list]
for sid, (base_padded, suffix) in zip(strongs_list, search_pairs):
    print(f"{sid} -> base: {base_padded}, suffix: {suffix}")

# Read the TBESH file and parse rows
# Header: eStrong#	dStrong	uStrong	Hebrew	Transliteration	Morph	Gloss	Meaning
tbesh_data = []
with open(tbesh_path, "r", encoding="utf-8", errors="replace") as f:
    header = None
    for line in f:
        if not line.strip():
            continue
        if line.strip().startswith("==") or line.strip().startswith("$") or line.strip().startswith("-"):
            continue
        if "\t" in line:
            parts = [p.strip() for p in line.split("\t")]
            if parts[0].lower().startswith("estrong"):
                header = [p.lower() for p in parts]
                continue
            if header and len(parts) >= len(header):
                row = dict(zip(header, parts))
                tbesh_data.append(row)

print(f"\nParsed {len(tbesh_data)} rows from TBESH.")

# Find matches for each word in Psalm 1:1
print("\nMatches in TBESH:")
print("| Pos | Word Strong's | Padded Search | Matches found in TBESH (eStrong# | dStrong | Gloss | Meaning) |")
print("|---|---|---|---|")

for idx, sid in enumerate(strongs_list, 1):
    base_padded, suffix = format_id_for_search(sid)
    
    # We will search for rows where estrong# equals base_padded or contains it
    matches = []
    for row in tbesh_data:
        estr = row.get("estrong#", "")
        dstr = row.get("dstrong", "")
        # Also check dStrong or uStrong if there are matches
        if estr == base_padded:
            matches.append(row)
            
    print(f"Position {idx} ({sid}):")
    if not matches:
        print("  NO MATCH FOUND")
    for m in matches:
        print(f"  eStrong: {m.get('estrong#')}, dStrong: {m.get('dstrong')}, uStrong: {m.get('ustrong')}, Hebrew: {m.get('hebrew')}, Translit: {m.get('transliteration')}, Gloss: {m.get('gloss')}, Meaning: {m.get('meaning')}")
