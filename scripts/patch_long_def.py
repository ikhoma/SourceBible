#!/usr/bin/env python3
"""
patch_long_def.py
-----------------
One-shot migration: overwrites strongs.long_def with BDB (Hebrew) / Abbott-Smith (Greek)
definitions from STEPBible TBESH/TBESG lexicon files.

Why this is needed:
  import_strongs() fills long_def with kjv_def (a short keyword list like "blessed, happy").
  import_stepbible_lexicons() used a CASE WHEN long_def = '' condition — so it never
  replaced the non-empty kjv_def with the proper BDB definition.
  LexiconParser expects BDB numbered-sense format, not keyword lists → nothing rendered.

Fix applied here: always overwrite long_def when TBESH/TBESG has a non-empty definition.
The same fix is now in build_db.py for future full rebuilds.

Usage:
  python3 scripts/patch_long_def.py                     # uses default DB path
  python3 scripts/patch_long_def.py --db path/to/db
  python3 scripts/patch_long_def.py --dry-run           # print counts, no changes
"""

import argparse
import re
import sqlite3
import sys
from pathlib import Path

DB_DEFAULT = Path(__file__).parent.parent / "sourcebible.db"
DATA_DIR   = Path(__file__).parent.parent / "data"


# ── parsing logic (mirrors build_db.py exactly) ───────────────────────────────

def _parse_stepbible_file(text: str) -> list[dict]:
    """
    Parse a STEPBible TSV lexicon file (TBESH / TBESG format).
    Only rows with bare Strong's IDs (H/G + digits, no letter suffix) are returned.
    Returns list of dicts keyed by lowercased column names.
    """
    lines = text.splitlines()
    header = None
    rows = []
    data_re = re.compile(r'^[HG]\d{4,5}\t')

    for line in lines:
        if header is None:
            if "\t" in line:
                parts = line.split("\t")
                if (parts[0].strip().lower().startswith("estrong") and
                        len(parts) >= 7 and
                        parts[1].strip().lower().startswith("dstrong")):
                    header = [c.strip().lower() for c in parts]
            continue

        stripped = line.strip()
        if not stripped or stripped.startswith("=") or stripped.startswith("$") or stripped.startswith("-"):
            continue

        if not data_re.match(line):
            continue

        parts = line.split("\t")
        row = {}
        for i, col in enumerate(header):
            row[col] = parts[i].strip() if i < len(parts) else ""
        rows.append(row)

    return rows


def _find_col(row: dict, *candidates) -> str:
    for c in candidates:
        if c in row:
            v = row[c].strip()
            if v:
                return v
    return ""


def _clean_stepbible_html(text: str) -> str:
    """Strip HTML / markup from STEPBible definition fields, converting <br> → \\n."""
    s = text
    s = re.sub(r'<a\b[^>]*>.*?</a>', '', s, flags=re.IGNORECASE | re.DOTALL)
    s = re.sub(r"<ref='[^']*'>([^<]*)</ref>", r'\1', s, flags=re.IGNORECASE)
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.IGNORECASE)
    s = re.sub(r'<Level[23]\s*/?>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'</Level[23]>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'<b\s*/?>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'</b>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'<i\s*/?>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'</i>', '', s, flags=re.IGNORECASE)
    s = re.sub(r'&amp;',  '&', s)
    s = re.sub(r'&lt;',   '<', s)
    s = re.sub(r'&gt;',   '>', s)
    s = re.sub(r'&quot;', '"', s)
    s = re.sub(r'&#39;',  "'", s)
    s = re.sub(r'[ \t]+', ' ', s)
    s = re.sub(r'\n{3,}', '\n\n', s)
    return s.strip()


def normalize_strongs(raw_id: str, lang_prefix: str) -> str:
    """'H0001' → 'H1', 'G00123' → 'G123'"""
    m = re.match(r'^[HG]?(\d+[a-z]?)$', raw_id.strip(), re.IGNORECASE)
    if not m:
        return ""
    num = m.group(1).lstrip('0') or '0'
    return f"{lang_prefix}{num}"


def _find_stepbible_file(prefix: str):
    """Find a TBESH or TBESG .txt file in data/."""
    if DATA_DIR.exists():
        for f in DATA_DIR.iterdir():
            if f.suffix.lower() == ".txt" and f.stem.upper().startswith(prefix.upper()):
                return f
    return None


# ── main ──────────────────────────────────────────────────────────────────────

def patch(db_path: Path, dry_run: bool) -> None:
    print(f"DB: {db_path}")
    if not db_path.exists():
        print(f"ERROR: DB not found at {db_path}")
        sys.exit(1)

    updates: list[tuple[str, str]] = []  # (long_def, strongs_id)

    for prefix, lang in [("TBESH", "H"), ("TBESG", "G")]:
        f = _find_stepbible_file(prefix)
        if not f:
            print(f"  WARNING: {prefix} file not found in {DATA_DIR} — skipping")
            continue

        print(f"Reading {f.name} …")
        text = f.read_text(encoding="utf-8", errors="replace")
        rows = _parse_stepbible_file(text)

        if not rows:
            print(f"  WARNING: no data rows found — check file format")
            continue

        last_col = list(rows[0].keys())[-1] if rows else None
        print(f"  Columns: {list(rows[0].keys())}")
        print(f"  Data rows: {len(rows):,}")

        found = 0
        seen_ids: set[str] = set()  # keep only FIRST occurrence per eStrong ID (main lexeme)
        for row in rows:
            raw_id = _find_col(row, "estrong#", "estrong", "strongs", "id")
            if not raw_id:
                continue
            sid = normalize_strongs(raw_id, lang)
            if not sid or sid in seen_ids:
                continue
            seen_ids.add(sid)

            long_def = _find_col(row, "meaning", "longdefinition", "definition",
                                  "fulldefinition", "longdef", "bdb", "abbottsmith")
            if not long_def and last_col:
                long_def = row.get(last_col, "")

            long_def = _clean_stepbible_html(long_def)
            if not long_def:
                continue

            long_def = long_def[:5000]
            updates.append((long_def, sid))
            found += 1

        print(f"  {found:,} entries with definitions")

    if not updates:
        print("\nNo definitions found — nothing to patch.")
        return

    print(f"\nTotal to patch: {len(updates):,} entries")

    if dry_run:
        print("DRY RUN — no changes written. Sample:")
        for long_def, sid in updates[:5]:
            preview = long_def[:80].replace("\n", "\\n")
            print(f"  {sid}: {preview}")
        return

    con = sqlite3.connect(db_path)
    cur = con.cursor()

    patched = 0
    for long_def, sid in updates:
        cur.execute("UPDATE strongs SET long_def = ? WHERE id = ?", (long_def, sid))
        if cur.rowcount:
            patched += 1

    con.commit()
    con.close()

    skipped = len(updates) - patched
    print(f"✓ Patched {patched:,} entries (skipped {skipped} — IDs not in DB)")
    print(f"\nNext steps:")
    print(f"  cp {db_path} {db_path.parent}/SourceBible/Resources/sourcebible.db")
    print(f"  Then in Xcode: Product → Clean Build Folder (Shift+Cmd+K), then Run")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Patch strongs.long_def from TBESH/TBESG")
    parser.add_argument("--db",      default=str(DB_DEFAULT))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    patch(Path(args.db), args.dry_run)
