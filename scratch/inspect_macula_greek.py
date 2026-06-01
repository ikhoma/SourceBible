import zipfile
import io
import csv

zip_path = "/Users/imac/Projects/SourceBible/data/macula-greek-main.zip"
tsv_path = "macula-greek-main/Nestle1904/tsv/macula-greek-Nestle1904.tsv"

with zipfile.ZipFile(zip_path, 'r') as zf:
    namelist = zf.namelist()
    print("Files in Greek zip (first 20):")
    for name in namelist[:20]:
        print(" ", name)
        
    if tsv_path in namelist:
        with zf.open(tsv_path) as f:
            raw = io.TextIOWrapper(f, encoding="utf-8")
            reader = csv.DictReader(raw, delimiter="\t")
            print("\nGreek TSV Columns:")
            print(", ".join(reader.fieldnames))
            
            print("\nRows for JHN 3:16 in Greek TSV:")
            jhn_rows = []
            for row in reader:
                ref = row.get("ref", "")
                if ref.startswith("JHN 3:16"):
                    jhn_rows.append(row)
            
            print(f"Found {len(jhn_rows)} rows for JHN 3:16 in Greek TSV.")
            if jhn_rows:
                print("\nFields for first word in Greek TSV:")
                for k, v in jhn_rows[0].items():
                    print(f"  {k}: {v}")
conn.close()
