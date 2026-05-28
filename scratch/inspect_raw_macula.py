import zipfile
import io
import csv
import xml.etree.ElementTree as ET

zip_path = "/Users/imac/Projects/SourceBible/data/macula-hebrew-main.zip"

with zipfile.ZipFile(zip_path, 'r') as zf:
    # Let's see the list of files in the zip
    namelist = zf.namelist()
    print("Some files in zip:")
    for name in namelist[:20]:
        print(" ", name)
        
    # Let's inspect the TSV headers and all rows for PSA 1:1
    tsv_path = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"
    if tsv_path in namelist:
        print("\nParsing TSV file...")
        with zf.open(tsv_path) as f:
            raw = io.TextIOWrapper(f, encoding="utf-8")
            reader = csv.DictReader(raw, delimiter="\t")
            print("TSV Columns:")
            print(", ".join(reader.fieldnames))
            
            print("\nRows for PSA 1:1 in TSV:")
            psa_rows = []
            for row in reader:
                ref = row.get("ref", "")
                if ref.startswith("PSA 1:1"):
                    psa_rows.append(row)
            
            print(f"Found {len(psa_rows)} rows in TSV for PSA 1:1.")
            if psa_rows:
                # Print all fields for the first row as an example
                print("\nFields for first word in TSV:")
                for k, v in psa_rows[0].items():
                    print(f"  {k}: {v}")
                    
    # Let's inspect the XML file for Psalm 1
    xml_path = "macula-hebrew-main/WLC/lowfat/19-Psa-001-lowfat.xml"
    if xml_path in namelist:
        print("\nParsing XML file...")
        xml_bytes = zf.read(xml_path)
        root = ET.fromstring(xml_bytes)
        
        # Find all words in verse 1
        words_v1 = []
        for w in root.iter('w'):
            ref = w.get('ref', '')
            if 'PSA 1:1' in ref or ':1!' in ref:
                words_v1.append(w)
                
        print(f"Found {len(words_v1)} words in XML for verse 1.")
        if words_v1:
            print("\nAttributes for first word in XML:")
            for k, v in words_v1[0].attrib.items():
                print(f"  {k}: {v}")
                
            print("\nFull element for first word in XML:")
            print(ET.tostring(words_v1[0], encoding='utf-8').decode('utf-8'))
