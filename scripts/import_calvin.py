#!/usr/bin/env python3
"""
import_calvin.py — Import Calvin's Collected Commentaries into sourcebible.db

Source: data/CalvinCommentaries.zip  (SWORD zCom, BlockType=BOOK, OSIS, Public Domain)

Usage (on Mac only — APFS sparse file):
    python3 scripts/import_calvin.py [path/to/sourcebible.db]

Default DB path: SourceBible/Resources/sourcebible.db
"""

import sys
import os
import struct
import zlib
import zipfile
import re
import sqlite3

# ---------------------------------------------------------------------------
# OSIS book ID  →  SourceBible DB book_id
# ---------------------------------------------------------------------------
OSIS_TO_DB = {
    "Gen": "GEN", "Exod": "EXO", "Lev": "LEV", "Num": "NUM", "Deut": "DEU",
    "Josh": "JOS", "Judg": "JDG", "Ruth": "RUT", "1Sam": "1SA", "2Sam": "2SA",
    "1Kgs": "1KI", "2Kgs": "2KI", "1Chr": "1CH", "2Chr": "2CH",
    "Ezra": "EZR", "Neh": "NEH", "Esth": "EST", "Job": "JOB",
    "Ps": "PSA", "Prov": "PRO", "Eccl": "ECC", "Song": "SNG",
    "Isa": "ISA", "Jer": "JER", "Lam": "LAM", "Ezek": "EZK",
    "Dan": "DAN", "Hos": "HOS", "Joel": "JOL", "Amos": "AMO",
    "Obad": "OBA", "Jonah": "JON", "Mic": "MIC", "Nah": "NAM",
    "Hab": "HAB", "Zeph": "ZEP", "Hag": "HAG", "Zech": "ZEC", "Mal": "MAL",
    # NT
    "Matt": "MAT", "Mark": "MRK", "Luke": "LUK", "John": "JHN",
    "Acts": "ACT", "Rom": "ROM", "1Cor": "1CO", "2Cor": "2CO",
    "Gal": "GAL", "Eph": "EPH", "Phil": "PHP", "Col": "COL",
    "1Thess": "1TH", "2Thess": "2TH", "1Tim": "1TI", "2Tim": "2TI",
    "Titus": "TIT", "Phlm": "PHM", "Heb": "HEB", "Jas": "JAS",
    "1Pet": "1PE", "2Pet": "2PE", "1John": "1JN", "2John": "2JN",
    "3John": "3JN", "Jude": "JUD", "Rev": "REV",
}

# ---------------------------------------------------------------------------
# SWORD zCom decoder
# ---------------------------------------------------------------------------

def parse_bzs(bzs: bytes) -> list:
    """Parse BZS index. Each 12-byte entry: (bzz_offset, comp_size, uncomp_size)."""
    return [struct.unpack_from("<III", bzs, i * 12) for i in range(len(bzs) // 12)]


def read_bzv_entry(bzv: bytes, i: int) -> tuple:
    """BZV format: 10 bytes per verse — (block_num: u32, start: u32, size: u16)."""
    return struct.unpack_from("<IIH", bzv, i * 10)


def decompress_block(bzz: bytes, entry: tuple) -> bytes:
    off, comp, _ = entry
    if comp == 0:
        return b""
    return zlib.decompress(bzz[off : off + comp])


def strip_osis(raw: str) -> str:
    """
    Convert OSIS XML to clean plain text suitable for display.
    Steps:
      1. Remove <note>…</note> footnotes (noisy, often Latin references).
      2. Convert paragraph divs / <lb/> to newlines.
      3. Strip remaining XML tags.
      4. Normalise whitespace while preserving paragraph breaks.
    """
    # 1. Remove footnotes
    text = re.sub(r"<note\b[^>]*>.*?</note>", " ", raw, flags=re.DOTALL)

    # 2. Paragraph breaks — end-of-p div and <lb/> → newline sentinel
    text = re.sub(r'<div\s+eID="[^"]*"\s+type="x-p"\s*/>', "\n\n", text)
    text = re.sub(r"<lb\s*/>", "\n", text)

    # 3. Strip all remaining XML tags
    text = re.sub(r"<[^>]+>", "", text)

    # 4. Decode XML entities
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    text = text.replace("&apos;", "'").replace("&quot;", '"')

    # 5. Normalise: collapse runs of spaces/tabs, keep paragraph breaks
    lines = []
    for para in text.split("\n"):
        para = re.sub(r"[ \t]+", " ", para).strip()
        lines.append(para)
    text = "\n".join(lines)

    # Collapse 3+ newlines → 2
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text


def extract_verse_ref(raw: str) -> tuple | None:
    """
    Pull (osis_book, chapter, verse) from annotateRef="Bible:Book.ch.v".
    Returns None if not found or not parseable.
    """
    m = re.search(r'annotateRef="Bible:([^"]+)"', raw)
    if not m:
        return None
    parts = m.group(1).split(".")
    if len(parts) != 3:
        return None
    try:
        return parts[0], int(parts[1]), int(parts[2])
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Main importer
# ---------------------------------------------------------------------------

def import_testament(bzs_data, bzv_data, bzz_data, db_cursor, source="Calvin"):
    blocks = parse_bzs(bzs_data)
    n_entries = len(bzv_data) // 10

    # Cache decompressed blocks — one per book (~50–3.5 MB each)
    block_cache: dict[int, bytes] = {}

    def get_block(bn: int) -> bytes:
        if bn not in block_cache:
            if bn >= len(blocks):
                block_cache[bn] = b""
            else:
                block_cache[bn] = decompress_block(bzz_data, blocks[bn])
        return block_cache[bn]

    rows = []
    skipped = 0

    for i in range(n_entries):
        bn, start, size = read_bzv_entry(bzv_data, i)
        if size == 0:
            continue
        if bn >= len(blocks):
            continue

        block_data = get_block(bn)
        if not block_data or start + size > len(block_data):
            continue

        raw = block_data[start : start + size].decode("utf-8", errors="replace")
        ref = extract_verse_ref(raw)
        if ref is None:
            skipped += 1
            continue

        osis_book, chapter, verse = ref
        book_id = OSIS_TO_DB.get(osis_book)
        if book_id is None:
            skipped += 1
            continue

        text = strip_osis(raw)
        if not text:
            skipped += 1
            continue

        rows.append((source, book_id, chapter, verse, text))

    db_cursor.executemany(
        "INSERT OR REPLACE INTO commentary (source, book_id, chapter, verse, text) VALUES (?,?,?,?,?)",
        rows,
    )
    return len(rows), skipped


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else "SourceBible/Resources/sourcebible.db"
    zip_path = "data/CalvinCommentaries.zip"

    if not os.path.exists(db_path):
        print(f"❌  DB not found: {db_path}")
        sys.exit(1)
    if not os.path.exists(zip_path):
        print(f"❌  Zip not found: {zip_path}")
        sys.exit(1)

    print(f"→ Opening {db_path}")
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # Create table (idempotent)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS commentary (
            source   TEXT NOT NULL,
            book_id  TEXT NOT NULL,
            chapter  INTEGER NOT NULL,
            verse    INTEGER NOT NULL,
            text     TEXT NOT NULL,
            PRIMARY KEY (source, book_id, chapter, verse)
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_commentary_verse ON commentary(book_id, chapter, verse)")

    # Clear existing Calvin rows so re-runs are clean
    cur.execute("DELETE FROM commentary WHERE source = 'Calvin'")

    print("→ Reading zip...")
    with zipfile.ZipFile(zip_path) as z:
        bzs_ot = z.read("modules/comments/zcom/calvincommentaries/ot.bzs")
        bzv_ot = z.read("modules/comments/zcom/calvincommentaries/ot.bzv")
        bzz_ot = z.read("modules/comments/zcom/calvincommentaries/ot.bzz")
        bzs_nt = z.read("modules/comments/zcom/calvincommentaries/nt.bzs")
        bzv_nt = z.read("modules/comments/zcom/calvincommentaries/nt.bzv")
        bzz_nt = z.read("modules/comments/zcom/calvincommentaries/nt.bzz")

    print("→ Importing OT...")
    ot_rows, ot_skip = import_testament(bzs_ot, bzv_ot, bzz_ot, cur)
    print(f"   OT: {ot_rows} verses imported, {ot_skip} skipped")

    print("→ Importing NT...")
    nt_rows, nt_skip = import_testament(bzs_nt, bzv_nt, bzz_nt, cur)
    print(f"   NT: {nt_rows} verses imported, {nt_skip} skipped")

    conn.commit()
    conn.close()

    total = ot_rows + nt_rows
    print(f"✓ Done: {total} Calvin commentary entries in {db_path}")


if __name__ == "__main__":
    main()
