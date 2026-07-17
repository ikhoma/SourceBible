#!/usr/bin/env python3
"""Extract RU (source) + EN (QA) commentary per verse for one book_number.
Usage: python3 extract_book.py <book_number> <BookLabel> [out_dir]
RU from Кальвин-к, EN from Calvin-c (PATCHED if present). Identify book_number by content first
(see reference/sources.md) — numbering is non-standard."""
import sqlite3, re, sys, os, glob
DATA = os.environ.get("SB_DATA", os.path.expanduser("~/Projects/SourceBible/data/New"))
def find(pat):
    m = glob.glob(os.path.join(DATA, pat))
    return m[0] if m else None
def clean(t):
    t = re.sub(r"<[^>]+>", " ", t or "").replace("&nbsp;", " ")
    return re.sub(r"[ \t]+", " ", t).strip()
def dump(db, bk):
    cur = sqlite3.connect(db).cursor()
    chs = sorted({r[0] for r in cur.execute(
        "SELECT DISTINCT chapter_number_from FROM commentaries WHERE book_number=?", (bk,)) if r[0] not in (None, 0)})
    out = []
    for ch in chs:
        out.append(f"\n===== {ch} =====")
        for v, t in cur.execute(
            "SELECT verse_number_from,text FROM commentaries WHERE book_number=? AND chapter_number_from=? ORDER BY verse_number_from", (bk, ch)):
            c = clean(t)
            if c: out.append(f"[{ch}:{v}] {c}")
    return "\n\n".join(out), chs
def main():
    bk = int(sys.argv[1]); label = sys.argv[2]
    out_dir = sys.argv[3] if len(sys.argv) > 3 else "source_texts"
    os.makedirs(out_dir, exist_ok=True)
    ru = find("*альвин-к*.SQLite3") or find("*Кальвин*")
    en = find("*Calvin-c*PATCHED*.SQLite3") or find("*Calvin-c*.SQLite3")
    rt, rc = dump(ru, bk); open(f"{out_dir}/{label}_RU.txt", "w").write(rt)
    et, ec = (dump(en, bk) if en else ("", []))
    if en: open(f"{out_dir}/{label}_EN.txt", "w").write(et)
    print(f"{label}: RU chapters {rc}"); print(f"{label}: EN chapters {ec}")
    miss = [c for c in rc if c not in ec]
    if miss: print(f"WARNING: EN QA missing chapters {miss} (RU is source, OK).")
if __name__ == "__main__":
    main()
