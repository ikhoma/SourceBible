import os
import re

tbesh_path = "/Users/imac/Projects/SourceBible/data/TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt"

strongs_list = [
    (1, "אַ֥שְׁרֵי", "H835a"),
    (2, "הָ", "H1886a"),
    (3, "אִ֗ישׁ", "H376"),
    (4, "אֲשֶׁ֤ר", "H834"),
    (5, "לֹ֥א", "H3808"),
    (6, "הָלַךְ֮", "H1980"),
    (7, "בַּ", "H871a"),
    (8, "עֲצַ֪ת", "H6098"),
    (9, "רְשָׁ֫עִ֥ים", "H7563"),
    (10, "וּ", "H2050b"),
    (11, "בְ", "H871a"),
    (12, "דֶ֣רֶךְ", "H1870"),
    (13, "חַ֭טָּאִים", "H2400"),
    (14, "לֹ֥א", "H3808"),
    (15, "עָמָ֑ד", "H5975"),
    (16, "וּ", "H2050b"),
    (17, "בְ", "H871a"),
    (18, "מוֹשַׁ֥ב", "H4186"),
    (19, "לֵ֝צִ֗ים", "H3887a"),
    (20, "לֹ֣א", "H3808"),
    (21, "יָשָֽׁב", "H3427")
]

def format_id_for_search(sid):
    match = re.match(r'^([HG])(\d+)([a-z]?)$', sid)
    if match:
        prefix, num, suffix = match.groups()
        num_padded = f"{int(num):04d}"
        return prefix + num_padded, suffix
    return sid, ""

# Read TBESH rows
tbesh_data = []
with open(tbesh_path, "r", encoding="utf-8", errors="replace") as f:
    header = None
    for line in f:
        if not line.strip() or line.strip().startswith("==") or line.strip().startswith("$") or line.strip().startswith("-"):
            continue
        if "\t" in line:
            parts = [p.strip() for p in line.split("\t")]
            if parts[0].lower().startswith("estrong"):
                header = [p.lower() for p in parts]
                continue
            if header and len(parts) >= len(header):
                row = dict(zip(header, parts))
                tbesh_data.append(row)

print("| Pos | Word (ID) | TBESH eStrong | TBESH dStrong | TBESH Hebrew | TBESH Gloss | TBESH Meaning |")
print("|---|---|---|---|---|---|---|")

for pos, word, sid in strongs_list:
    base_padded, suffix = format_id_for_search(sid)
    
    # Let's find matches in TBESH
    # We will look for:
    # 1. Exact match on dStrong or eStrong# matching base_padded + suffix
    # 2. Match on base_padded (e.g. H0835, H3887, etc.)
    matches = []
    
    # Try exact match with suffix (like H3887a, H1886a) first in dstrong or estrong#
    # Wait, in TBESH the first column is eStrong#, which is padded, like H0835 or H3887.
    # dStrong can contain suffixes or notes, e.g. H3887 =, H1870J = a Meaning of, etc.
    # Let's search for rows where eStrong# is base_padded
    for row in tbesh_data:
        estr = row.get("estrong#", "")
        if estr == base_padded:
            matches.append(row)
            
    if not matches:
        print(f"| {pos} | **{word}** (`{sid}`) | - | - | - | - | *No matching entry in TBESH* |")
    else:
        # Since a base Strong can have multiple disambiguated (dStrong) meanings in TBESH,
        # let's list them or merge them cleanly.
        # To avoid making the table excessively long, if there are multiple sub-meanings (like H1870 has 3-4 sub-meanings),
        # we will list them in a single row using <br> or list them as separate rows.
        # Let's do it as separate rows but grouped under the position.
        for idx, m in enumerate(matches):
            pos_str = f"{pos}" if idx == 0 else ""
            word_str = f"**{word}** (`{sid}`)" if idx == 0 else ""
            
            estr_val = m.get('estrong#', '')
            dstr_val = m.get('dstrong', '')
            hebrew_val = m.get('hebrew', '')
            gloss_val = m.get('gloss', '')
            meaning_val = m.get('meaning', '').replace("\n", "<br>").replace("|", "\\|")
            
            # Highlight if the dStrong matches the specific suffix or concept if possible, or just print them all
            print(f"| {pos_str} | {word_str} | `{estr_val}` | `{dstr_val}` | {hebrew_val} | {gloss_val} | {meaning_val} |")
