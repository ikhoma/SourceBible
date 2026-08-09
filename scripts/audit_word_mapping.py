#!/usr/bin/env python3
# audit_word_mapping.py
#
# READ-ONLY diagnostic. Replicates the app's per-translation word↔Macula mapping
# (ReaderViewModel.verseWordSegmentPairs) for EVERY verse in EVERY translation and
# flags the cases behind the "tap a content word → opens אֵת H853 (object marker)"
# bug: a visible translated word that maps to an untranslatable particle.
#
# ⛔ Run ONLY on Mac (~/Projects/SourceBible). The bundled sourcebible.db is an APFS
#    sparse file and reads as corrupt inside the Linux sandbox.
#
# Usage:
#   cd ~/Projects/SourceBible
#   python3 scripts/audit_word_mapping.py sourcebible.db            # all books
#   python3 scripts/audit_word_mapping.py sourcebible.db GEN        # one book
#
# Writes scripts/word_mapping_issues.tsv (full flagged list). Python 3.10+ (CLAUDE.md).

import os
import re
import sqlite3
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

# --- Strong's that are never standalone translated words ---------------------
# lexical_class 'om' = object marker (אֵת), 'art' = article (הַ). These should not
# be the result of tapping a visible content word.
PARTICLE_CLASSES = {"om", "art"}
ET_BASES = {"853"}                      # אֵת object marker — the exact screenshot symptom

S_TAG_RE = re.compile(r"<S>(.*?)</S>", re.IGNORECASE | re.DOTALL)
NUM_RE = re.compile(r"\d+")
OVERRIDE_RE = re.compile(r'"(\d+)"\s*:\s*"(\d+)"')
HAS_LETTER_RE = re.compile(r"[^\W\d_]", re.UNICODE)   # any alphabetic char (Latin/Cyrillic/Hebrew)


def base_of(s: str) -> str:
    m = NUM_RE.search(s or "")
    return m.group(0) if m else ""


def load_nasb_override(repo_dir: str) -> Dict[str, str]:
    path = os.path.join(repo_dir, "SourceBible", "Services", "NASBExtendedOverride.swift")
    out = {}  # type: Dict[str, str]
    try:
        with open(path, "r", encoding="utf-8") as f:
            for ext, base in OVERRIDE_RE.findall(f.read()):
                out[ext] = base
    except OSError:
        pass
    return out


def parse_segments(text: str) -> List[Tuple[str, List[str]]]:
    """Mirror VerseParser: ordered (segment_text, [base numbers]); <S> attaches to the
    previous non-whitespace text segment. Footnote (<n>) / anchor (<f>) text is ignored."""
    segs = []  # type: List[Tuple[str, List[str]]]
    i = 0
    buf = ""
    inside_s = inside_n = inside_f = False
    s_buf = ""
    n = len(text or "")
    t = text or ""

    def flush_text():
        nonlocal buf
        if buf != "":
            segs.append([buf, []])
            buf = ""

    while i < n:
        c = t[i]
        if c == "<":
            j = t.find(">", i)
            if j == -1:
                break
            raw = t[i + 1:j].strip()
            i = j + 1
            low = raw.lower().strip("/ ")
            if raw.startswith("/"):
                if low == "s":
                    inside_s = False
                    ids = []
                    for part in s_buf.split(","):
                        b = base_of(part)
                        if b:
                            ids.append(b)
                    if ids:
                        # attach to last non-whitespace text segment
                        for k in range(len(segs) - 1, -1, -1):
                            if segs[k][0].strip() != "":
                                segs[k][1].extend(ids)
                                break
                    s_buf = ""
                elif low == "n":
                    inside_n = False
                elif low == "f":
                    inside_f = False
            elif low == "s":
                flush_text(); inside_s = True; s_buf = ""
            elif low == "n":
                flush_text(); inside_n = True
            elif low == "f":
                flush_text(); inside_f = True
            # other tags (t,j,i,e,br,pb) — ignored
        else:
            if inside_s:
                s_buf += c
            elif inside_n or inside_f:
                pass
            else:
                buf += c
            i += 1
    flush_text()
    return [(s[0], s[1]) for s in segs]


def is_visible_word(text: str) -> bool:
    return HAS_LETTER_RE.search(text or "") is not None


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "sourcebible.db"
    book_filter = sys.argv[2].upper() if len(sys.argv) > 2 else None
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    override = load_nasb_override(repo_dir)

    # verse_map: (translation, book, chapter, trans_verse) -> macula_verse
    vmap = {}  # type: Dict[Tuple, int]
    for tr, bk, ch, tv, mv in conn.execute(
        "SELECT translation, book_id, chapter, trans_verse, macula_verse FROM verse_map"
    ):
        vmap[(tr, bk, ch, tv)] = mv

    # Macula words per (book, chapter, macula_verse), ordered by position
    macula = defaultdict(list)  # type: Dict[Tuple, List[dict]]
    wq = "SELECT book_id, chapter, verse, position, surface, strongs_id, morph, lexical_class FROM word"
    if book_filter:
        wq += " WHERE book_id = ?"
        wcur = conn.execute(wq, (book_filter,))
    else:
        wcur = conn.execute(wq)
    for bk, ch, vs, pos, surf, sid, morph, lclass in wcur:
        macula[(bk, ch, vs)].append({
            "id": "%s|%d|%d|%d" % (bk, ch, vs, pos),
            "pos": pos, "surface": surf, "strongs": sid or "",
            "base": base_of(sid or ""), "morph": morph or "", "class": (lclass or ""),
        })
    for key in macula:
        macula[key].sort(key=lambda w: w["pos"])

    translations = [r[0] for r in conn.execute("SELECT id FROM translation ORDER BY id")]

    counts = defaultdict(lambda: defaultdict(int))  # tid -> flag -> n
    flagged = []          # rows for TSV
    per_verse_flags = defaultdict(int)  # (bk,ch,tv) -> total flags across translations

    for tid in translations:
        vq = "SELECT book_id, chapter, verse, text FROM verse WHERE translation = ?"
        params = [tid]  # type: List
        if book_filter:
            vq += " AND book_id = ?"
            params.append(book_filter)
        for bk, ch, tv, text in conn.execute(vq, params):
            mv = vmap.get((tid, bk, ch, tv), tv)            # identity fallback
            words = macula.get((bk, ch, mv), [])
            if not words:
                continue
            segs = parse_segments(text)

            # Resolve bases (apply NASB override for NASB), then consume-in-order pairing.
            def resolve(b: str) -> str:
                if tid == "NASB":
                    return override.get(b, b)
                return b

            pool = defaultdict(list)  # base -> [word]
            for w in words:
                if w["base"]:
                    pool[w["base"]].append(w)
            cursor = defaultdict(int)
            seen = set()
            # per segment: list of paired words (in tag order); tapWord returns the FIRST.
            for seg_idx, (seg_text, bases) in enumerate(segs):
                if not bases:
                    continue
                paired = []  # [(base, word)]
                for b in bases:
                    rb = resolve(b)
                    idx = cursor[rb]
                    bucket = pool.get(rb, [])
                    if idx < len(bucket):
                        w = bucket[idx]
                        cursor[rb] += 1
                        if w["id"] not in seen:
                            seen.add(w["id"])
                            paired.append((rb, w))
                    # orphan base (no macula word) — tracked below
                if not is_visible_word(seg_text):
                    continue

                resolved_bases = [resolve(b) for b in bases]
                if not paired:
                    if resolved_bases and all(rb not in pool for rb in resolved_bases):
                        counts[tid]["ORPHAN_TAG"] += 1
                        flagged.append((tid, bk, ch, tv, seg_text.strip(),
                                        "ORPHAN_TAG", ",".join(resolved_bases), "", "", ""))
                        per_verse_flags[(bk, ch, tv)] += 1
                    continue

                # tapWord returns paired[0]
                tap_base, tap_w = paired[0]
                tap_is_particle = (tap_w["class"] in PARTICLE_CLASSES) or (tap_base in ET_BASES)
                has_content_alt = any(
                    (w["class"] not in PARTICLE_CLASSES and b not in ET_BASES)
                    for (b, w) in paired
                )
                if tap_is_particle:
                    flag = "COMPOUND_PARTICLE_FIRST" if (len(paired) > 1 and has_content_alt) else "PARTICLE_TARGET"
                    counts[tid][flag] += 1
                    counts[tid]["by_class:" + (tap_w["class"] or "?")] += 1
                    flagged.append((tid, bk, ch, tv, seg_text.strip(), flag,
                                    ",".join(bases), tap_w["surface"], tap_w["strongs"], tap_w["class"]))
                    per_verse_flags[(bk, ch, tv)] += 1

    # --- Report ---------------------------------------------------------------
    print("NASB override entries loaded: %d" % len(override))
    print("Flag legend:")
    print("  PARTICLE_TARGET         — visible word maps to a particle (om/art or H853); module mis-tag")
    print("  COMPOUND_PARTICLE_FIRST — compound tag where the particle wins over a content word (pairing-fixable)")
    print("  ORPHAN_TAG              — tagged base has no Macula word in the verse")
    print()
    print("=== Flags per translation ===")
    keys = ["PARTICLE_TARGET", "COMPOUND_PARTICLE_FIRST", "ORPHAN_TAG"]
    print("%-8s %16s %24s %12s" % ("module", keys[0], keys[1], keys[2]))
    for tid in translations:
        print("%-8s %16d %24d %12d" % (
            tid, counts[tid][keys[0]], counts[tid][keys[1]], counts[tid][keys[2]]))
    print()

    # Top problematic verses (good manual test targets)
    print("=== Top 15 verses by total flags across translations (test these) ===")
    top = sorted(per_verse_flags.items(), key=lambda kv: kv[1], reverse=True)[:15]
    for (bk, ch, tv), n in top:
        print("  %-4s %d:%-3d  flags=%d" % (bk, ch, tv, n))
    print()

    out_path = os.path.join(repo_dir, "scripts", "word_mapping_issues.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("translation\tbook\tchapter\tverse\tsegment_text\tflag\tseg_bases\tpaired_surface\tpaired_strongs\tpaired_class\n")
        for row in flagged:
            f.write("\t".join(str(x) for x in row) + "\n")
    print("Wrote %d flagged rows -> %s" % (len(flagged), out_path))

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
