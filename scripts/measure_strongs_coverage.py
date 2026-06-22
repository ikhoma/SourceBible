#!/usr/bin/env python3
# measure_strongs_coverage.py
#
# READ-ONLY diagnostic. Measures Strong's tagging coverage per translation
# module and the per-verse gap versus NASB. Helps decide whether switching the
# Original-pill clickability gate from NASB to per-translation causes a coverage
# regression (and on which module / how big).
#
# ⛔ Run ONLY on Mac (~/Projects/SourceBible). The bundled sourcebible.db is an
#    APFS sparse file and reads as corrupt inside the Linux sandbox.
#
# Usage:
#   cd ~/Projects/SourceBible
#   python3 scripts/measure_strongs_coverage.py sourcebible.db
#
# Python 3.9 compatible. Opens the DB read-only. No writes, no schema changes.

import re
import sqlite3
import sys
from collections import defaultdict
from typing import Dict, List, Set, Tuple

S_TAG_RE = re.compile(r"<S>(.*?)</S>", re.IGNORECASE | re.DOTALL)
NUM_RE = re.compile(r"\d+")


def bases_in_text(text: str) -> List[str]:
    """All Strong's base numbers tagged in a verse's raw text, in order.
    '<S>835</S>' -> ['835']; '<S>8384, 5929</S>' -> ['8384','5929']."""
    out = []  # type: List[str]
    for inner in S_TAG_RE.findall(text or ""):
        for n in NUM_RE.findall(inner):
            out.append(n)
    return out


def base_of(strongs_id: str) -> str:
    """word.strongs_id 'H835a' -> '835'; 'G4198' -> '4198'."""
    m = NUM_RE.search(strongs_id or "")
    return m.group(0) if m else ""


def open_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect("file:%s?mode=ro" % path, uri=True)


def list_translations(conn: sqlite3.Connection) -> List[str]:
    rows = conn.execute("SELECT id FROM translation ORDER BY id").fetchall()
    return [r[0] for r in rows]


def load_verse_bases(conn: sqlite3.Connection, tid: str) -> Dict[Tuple, List[str]]:
    """(book_id, chapter, verse) -> list of tagged base numbers for one translation."""
    out = {}  # type: Dict[Tuple, List[str]]
    cur = conn.execute(
        "SELECT book_id, chapter, verse, text FROM verse WHERE translation = ?", (tid,)
    )
    for book_id, chapter, verse, text in cur:
        out[(book_id, chapter, verse)] = bases_in_text(text)
    return out


def load_macula_bases(conn: sqlite3.Connection) -> Dict[Tuple, List[str]]:
    """(book_id, chapter, verse) -> list of Macula word base numbers (identity verse join).
    NOTE: ignores verse_map numbering offsets (~459 chapters, mostly Psalms); the
    word-level estimate is therefore approximate for those chapters."""
    out = defaultdict(list)  # type: Dict[Tuple, List[str]]
    cur = conn.execute(
        "SELECT book_id, chapter, verse, strongs_id FROM word WHERE strongs_id IS NOT NULL"
    )
    for book_id, chapter, verse, sid in cur:
        b = base_of(sid)
        if b:
            out[(book_id, chapter, verse)].append(b)
    return out


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "sourcebible.db"
    conn = open_ro(path)

    translations = list_translations(conn)
    if "NASB" not in translations:
        print("WARNING: no 'NASB' translation id found. Found:", translations)
    print("Translations in DB:", ", ".join(translations))
    print()

    # Load tagged base sets per translation
    per_tid = {}  # type: Dict[str, Dict[Tuple, List[str]]]
    for tid in translations:
        per_tid[tid] = load_verse_bases(conn, tid)

    # --- Module-level summary -------------------------------------------------
    print("=== Module-level Strong's tagging ===")
    print("%-8s %10s %12s %12s %14s" % (
        "module", "verses", "verses w/<S>", "tag occurs", "distinct bases"))
    for tid in translations:
        vb = per_tid[tid]
        verses = len(vb)
        with_tag = sum(1 for b in vb.values() if b)
        occ = sum(len(b) for b in vb.values())
        distinct = set()  # type: Set[str]
        for b in vb.values():
            distinct.update(b)
        print("%-8s %10d %12d %12d %14d" % (tid, verses, with_tag, occ, len(distinct)))
    print()

    # --- Pairwise vs NASB (per-verse base sets) -------------------------------
    if "NASB" in per_tid:
        nasb = per_tid["NASB"]
        print("=== Per-verse coverage vs NASB (tag base-number sets) ===")
        print("On verses present in BOTH modules. 'covered%%' = share of NASB base")
        print("occurrences (per verse) that the module also tags.")
        print()
        print("%-8s %10s %12s %12s %12s %10s" % (
            "module", "common v", "shared", "NASB-only", "module-only", "covered%"))
        for tid in translations:
            if tid == "NASB":
                continue
            mod = per_tid[tid]
            common = 0
            shared = nasb_only = mod_only = 0
            verses_short = 0  # verses where module tags fewer distinct bases than NASB
            for key, nlist in nasb.items():
                if key not in mod:
                    continue
                common += 1
                nset = set(nlist)
                mset = set(mod[key])
                shared += len(nset & mset)
                nasb_only += len(nset - mset)
                mod_only += len(mset - nset)
                if len(mset) < len(nset):
                    verses_short += 1
            denom = shared + nasb_only
            covered = (100.0 * shared / denom) if denom else 0.0
            print("%-8s %10d %12d %12d %12d %9.1f%%" % (
                tid, common, shared, nasb_only, mod_only, covered))
            print("          verses where module tags FEWER distinct bases than NASB: %d"
                  % verses_short)
        print()

    # --- Word-level gate estimate --------------------------------------------
    # For each Macula word (with Strong's), is its base tagged by the module for
    # that verse? Approximates how many Original-pill words each gate makes
    # clickable. Identity verse join (verse_map offsets ignored — see note).
    macula = load_macula_bases(conn)
    total_words = sum(len(v) for v in macula.values())
    print("=== Word-level gate estimate (Macula words made clickable) ===")
    print("Macula words with a Strong's id (identity verse join): %d" % total_words)
    print("%-8s %16s %10s" % ("module", "clickable words", "of total"))
    for tid in translations:
        vb = per_tid[tid]
        clickable = 0
        for key, wbases in macula.items():
            tagset = set(vb.get(key, []))
            if not tagset:
                continue
            for b in wbases:
                if b in tagset:
                    clickable += 1
        pct = (100.0 * clickable / total_words) if total_words else 0.0
        print("%-8s %16d %9.1f%%" % (tid, clickable, pct))
    print()
    print("NOTE: NASB word-level count is slightly understated — NASB extended")
    print("numbers (H9000+) require the override map to resolve to Macula bases,")
    print("which this raw measurement does not apply.")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
