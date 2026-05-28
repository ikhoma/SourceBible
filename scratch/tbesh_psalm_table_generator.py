import os
import re

tbesh_path = "/Users/imac/Projects/SourceBible/data/TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt"
output_md = "/Users/imac/Projects/SourceBible/scratch/tbesh_psalm_table.md"

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

with open(output_md, "w", encoding="utf-8") as out:
    out.write("| Pos | Word (ID) | TBESH eStrong | TBESH dStrong | TBESH Hebrew | TBESH Gloss | TBESH Meaning |\n")
    out.write("|---|---|---|---|---|---|---|\n")

    for pos, word, sid in strongs_list:
        base_padded, suffix = format_id_for_search(sid)
        
        matches = []
        for row in tbesh_data:
            estr = row.get("estrong#", "")
            if estr == base_padded:
                matches.append(row)
                
        if not matches:
            out.write(f"| {pos} | **{word}** (`{sid}`) | - | - | - | - | *No matching entry in TBESH* |\n")
        else:
            for idx, m in enumerate(matches):
                pos_str = f"{pos}" if idx == 0 else ""
                word_str = f"**{word}** (`{sid}`)" if idx == 0 else ""
                
                estr_val = m.get('estrong#', '')
                dstr_val = m.get('dstrong', '')
                hebrew_val = m.get('hebrew', '')
                gloss_val = m.get('gloss', '')
                meaning_val = m.get('meaning', '').replace("\n", "<br>").replace("|", "\\|")
                
                out.write(f"| {pos_str} | {word_str} | `{estr_val}` | `{dstr_val}` | {hebrew_val} | {gloss_val} | {meaning_val} |\n")

print("Successfully wrote full table to", output_md)
