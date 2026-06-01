import zipfile
import io
import csv

zip_path = "/Users/imac/Projects/SourceBible/data/macula-greek-main.zip"
tsv_path = "macula-greek-main/Nestle1904/tsv/macula-greek-Nestle1904.tsv"
output_md = "/Users/imac/Projects/SourceBible/scratch/macula_john_3_16.md"

jhn_rows = []
with zipfile.ZipFile(zip_path, 'r') as zf:
    with zf.open(tsv_path) as f:
        raw = io.TextIOWrapper(f, encoding="utf-8")
        reader = csv.DictReader(raw, delimiter="\t")
        for row in reader:
            ref = row.get("ref", "")
            if ref.startswith("JHN 3:16"):
                jhn_rows.append(row)

# Let's generate a comprehensive markdown document
with open(output_md, "w", encoding="utf-8") as out:
    out.write("# Raw Macula Dataset for John 3:16\n\n")
    out.write("This document contains the raw data from the Macula Greek New Testament dataset (`macula-greek-Nestle1904.tsv`) for John 3:16.\n\n")
    
    # ────────────────────────────────────────────────────────
    # Category 1: Text, Lemma, and References
    # ────────────────────────────────────────────────────────
    out.write("## 1. Text, Lemma, and Identifiers\n")
    out.write("| Pos | Surface Word | Trailing Char | Lemma | Strong's ID | XML ID | Role | Class |\n")
    out.write("|---|---|---|---|---|---|---|---|\n")
    for row in jhn_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        after = row.get("after", "")
        lemma = row.get("lemma", "")
        strong = "G" + row.get("strong", "")
        xml_id = row.get("xml:id", "")
        role = row.get("role", "")
        w_class = row.get("class", "")
        out.write(f"| {pos} | **{text}** | `{after}` | {lemma} | `{strong}` | `{xml_id}` | `{role}` | `{w_class}` |\n")
    
    out.write("\n---\n\n")
    
    # ────────────────────────────────────────────────────────
    # Category 2: Translations and Lexicons
    # ────────────────────────────────────────────────────────
    out.write("## 2. Contextual Translations & Semantic Domains\n")
    out.write("| Pos | Surface Word | Gloss (Contextual) | Domain | Louw-Nida (LN) | Referent |\n")
    out.write("|---|---|---|---|---|---|\n")
    for row in jhn_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        gloss = row.get("gloss", "")
        domain = row.get("domain", "")
        ln = row.get("ln", "")
        referent = row.get("referent", "")
        out.write(f"| {pos} | **{text}** | {gloss} | `{domain}` | `{ln}` | {referent} |\n")

    out.write("\n---\n\n")

    # ────────────────────────────────────────────────────────
    # Category 3: Detailed Grammar & Morphology
    # ────────────────────────────────────────────────────────
    out.write("## 3. Grammar & Morphology (Fully Decoded)\n")
    out.write("| Pos | Surface | Morph Code | Tense | Voice | Mood | Person | Number | Gender | Case | Degree |\n")
    out.write("|---|---|---|---|---|---|---|---|---|---|---|\n")
    for row in jhn_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        morph = row.get("morph", "")
        tense = row.get("tense", "")
        voice = row.get("voice", "")
        mood = row.get("mood", "")
        person = row.get("person", "")
        number = row.get("number", "")
        gender = row.get("gender", "")
        w_case = row.get("case", "")
        degree = row.get("degree", "")
        out.write(f"| {pos} | **{text}** | `{morph}` | {tense} | {voice} | {mood} | {person} | {number} | {gender} | {w_case} | {degree} |\n")

print("Generated complete raw Macula Greek table document successfully.")
