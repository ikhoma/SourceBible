import zipfile
import io
import csv

zip_path = "/Users/imac/Projects/SourceBible/data/macula-hebrew-main.zip"
tsv_path = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"
output_md = "/Users/imac/Projects/SourceBible/scratch/full_macula_psalm.md"

# Read rows from TSV
psa_rows = []
with zipfile.ZipFile(zip_path, 'r') as zf:
    with zf.open(tsv_path) as f:
        raw = io.TextIOWrapper(f, encoding="utf-8")
        reader = csv.DictReader(raw, delimiter="\t")
        for row in reader:
            ref = row.get("ref", "")
            if ref.startswith("PSA 1:1"):
                psa_rows.append(row)

# Let's generate a comprehensive markdown document
with open(output_md, "w", encoding="utf-8") as out:
    out.write("# Full Macula Dataset for Psalm 1:1\n\n")
    out.write("This document contains **every single data point and column** stored in the raw Macula Hebrew dataset (`macula-hebrew.tsv`) for Psalm 1:1, broken down into logical categories to prevent a 32-column table from wrapping into unreadability.\n\n")
    
    # ────────────────────────────────────────────────────────
    # Category 1: Text, Lemma, and References
    # ────────────────────────────────────────────────────────
    out.write("## 1. Text, Lemma, and Identifiers\n")
    out.write("| Pos | Surface Word | Trailing Char | Lemma | Strong's ID | XML ID | Ref |\n")
    out.write("|---|---|---|---|---|---|---|\n")
    for row in psa_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        after = row.get("after", "")
        lemma = row.get("lemma", "")
        strong = row.get("strongnumberx", "")
        xml_id = row.get("xml:id", "")
        ref = row.get("ref", "")
        out.write(f"| {pos} | **{text}** | `{after}` | {lemma} | `{strong}` | `{xml_id}` | `{ref}` |\n")
    
    out.write("\n---\n\n")
    
    # ────────────────────────────────────────────────────────
    # Category 2: Translations and Lexicons
    # ────────────────────────────────────────────────────────
    out.write("## 2. Contextual Translations & Septuagint (LXX) Alignment\n")
    out.write("| Pos | Surface Word | English | Gloss (Detailed) | Mandarin | LXX Greek | LXX Strong's |\n")
    out.write("|---|---|---|---|---|---|---|\n")
    for row in psa_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        english = row.get("english", "")
        gloss = row.get("gloss", "")
        mandarin = row.get("mandarin", "")
        greek = row.get("greek", "")
        gk_str = row.get("greekstrong", "")
        out.write(f"| {pos} | **{text}** | {english} | {gloss} | {mandarin} | *{greek}* | `{gk_str}` |\n")

    out.write("\n---\n\n")

    # ────────────────────────────────────────────────────────
    # Category 3: Detailed Grammar & Morphology
    # ────────────────────────────────────────────────────────
    out.write("## 3. Grammar & Morphology (Fully Decoded)\n")
    out.write("| Pos | Surface | Morph Code | Part of Speech | Stem | Person | Gender | Number | State | Type |\n")
    out.write("|---|---|---|---|---|---|---|---|---|---|\n")
    for row in psa_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        morph = row.get("morph", "")
        word_pos = row.get("pos", "")
        stem = row.get("stem", "")
        person = row.get("person", "")
        gender = row.get("gender", "")
        number = row.get("number", "")
        state = row.get("state", "")
        w_type = row.get("type", "")
        out.write(f"| {pos} | **{text}** | `{morph}` | {word_pos} | {stem} | {person} | {gender} | {number} | {state} | {w_type} |\n")

    out.write("\n---\n\n")

    # ────────────────────────────────────────────────────────
    # Category 4: Semantic Domains & Syntax Frames
    # ────────────────────────────────────────────────────────
    out.write("## 4. Semantic Domains & Structural Syntax Attributes\n")
    out.write("| Pos | Surface | Transliteration | SDBH ID | Lexical Domain | Core Domain | Verb Frame | Subj Ref | Participant Ref |\n")
    out.write("|---|---|---|---|---|---|---|---|---|\n")
    for row in psa_rows:
        ref_parts = row.get("ref", "").split("!")
        pos = ref_parts[1] if len(ref_parts) > 1 else ""
        text = row.get("text", "")
        translit = row.get("transliteration", "")
        sdbh = row.get("sdbh", "")
        lexdomain = row.get("lexdomain", "")
        coredomain = row.get("coredomain", "")
        frame = row.get("frame", "")
        subjref = row.get("subjref", "")
        partref = row.get("participantref", "")
        out.write(f"| {pos} | **{text}** | *{translit}* | `{sdbh}` | {lexdomain} | {coredomain} | {frame} | {subjref} | {partref} |\n")

print("Generated complete raw Macula table document successfully.")
