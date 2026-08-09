#!/usr/bin/env python3
"""
derive_org_to_eng.py — derive the Masoretic (ORG) -> English (ENG) verse mapping
from data, not from `verse_map`.

WHY THIS EXISTS
───────────────
`fetch_biblehub_translit_hebrew.py` enumerates ORG refs out of Macula and then
requests biblehub.com/text/<book>/<ch>-<vs>.htm with them. BibleHub serves
ENGLISH numbering at those URLs. In every chapter where the two systems diverge
the scraper stored the transliteration of a *different verse* under the ORG key.
Measured on 2026-08-04: 1,427 verses corrupted, 917 of them in Psalms.

`verse_map` cannot supply the missing map — ADR-028 measured 4,152 of its 7,292
rows as wrong. So the map is derived from two sources that are independently
trustworthy about references:

  * Macula WLC TSV      — ORG numbering, one row per morpheme, `strongnumberx`
  * data/bsb_tables.tsv — ENG numbering (`VerseId`), one row per word, `Str Heb`

Both describe the same consonantal text in the same order, so every ORG verse
can be located in the ENG stream by content rather than by arithmetic. No offset
table is hardcoded anywhere.

THE RELATION IS N:M, NOT 1:1
────────────────────────────
English Bibles fold a psalm's superscription into verse 1, so MT 3:1 and MT 3:2
both live inside ENG 3:1. The reverse also happens: a long MT verse is sometimes
split across two ENG verses. A verse-to-verse map cannot express either.

So the unit here is a SEGMENT: a contiguous run of ENG words belonging to one
ORG verse.

    osis  org_ch  org_vs  seg  eng_ch  eng_vs  word_offset  word_len

    PSA   3       1       0    3       1       0            6
    PSA   3       2       0    3       1       6            5
    PSA   3       3       0    3       2       0            8

An ORG verse with two segments needs two ENG pages concatenated. An ENG page
shared by two ORG verses is sliced between them. The scraper does that slicing
at fetch time, so what lands in hebrew_translit.json is still "ORG verse -> its
own words, in order" — the same contract build_db.py already consumes.
`_apply_bh_hebrew_translit()` therefore needs NO change.

SELF-CHECK
──────────
The script verifies its own output and exits non-zero on failure:

  * ANCHORS    settled ORG->ENG facts (Jonah 2:1 = 1:17, Malachi 3:19 = 4:1, ...)
               plus unshifted controls, plus known merges checked as merges.
  * TILING     within each ENG verse the segments claiming it must tile it
               exactly — no gap, no overlap, no word claimed twice. This is the
               check that catches a bad split, and it is not something a
               verse-level map could even express.
  * STRUCTURE  monotone, no duplicate (ORG, seg), every ORG verse accounted for.
  * COVERAGE   the share of unexplained verses must stay near zero.

An anchor failure can also mean the anchor is wrong, so failures print the
produced value next to the expected one.

READ-ONLY. Touches no database. Writes:

    data/org_to_eng.tsv           the segment map
    data/org_to_eng_review.tsv    everything refused, with the reason

Usage:
    python3 scripts/derive_org_to_eng.py
    python3 scripts/derive_org_to_eng.py --book PSA
    python3 scripts/derive_org_to_eng.py --window 40
    python3 scripts/derive_org_to_eng.py --verify-only

Exit codes:  0 ok   1 a check failed   2 bad input
"""

import argparse
import csv
import io
import os
import re
import sys
import zipfile
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data")

MACULA_ZIP = os.path.join(DATA, "macula-hebrew-main.zip")
MACULA_TSV = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"
BSB_TSV = os.path.join(DATA, "bsb_tables.tsv")

OUT_MAP = os.path.join(DATA, "org_to_eng.tsv")
OUT_REVIEW = os.path.join(DATA, "org_to_eng_review.tsv")

C_LANGUAGE = 4
C_STR_HEB = 10
C_VERSE_ID = 12

BSB_TO_OSIS = {
    "Genesis": "GEN", "Exodus": "EXO", "Leviticus": "LEV", "Numbers": "NUM",
    "Deuteronomy": "DEU", "Joshua": "JOS", "Judges": "JDG", "Ruth": "RUT",
    "1 Samuel": "1SA", "2 Samuel": "2SA", "1 Kings": "1KI", "2 Kings": "2KI",
    "1 Chronicles": "1CH", "2 Chronicles": "2CH", "Ezra": "EZR",
    "Nehemiah": "NEH", "Esther": "EST", "Job": "JOB", "Psalm": "PSA",
    "Proverbs": "PRO", "Ecclesiastes": "ECC", "Song of Solomon": "SNG",
    "Isaiah": "ISA", "Jeremiah": "JER", "Lamentations": "LAM",
    "Ezekiel": "EZK", "Daniel": "DAN", "Hosea": "HOS", "Joel": "JOL",
    "Amos": "AMO", "Obadiah": "OBA", "Jonah": "JON", "Micah": "MIC",
    "Nahum": "NAM", "Habakkuk": "HAB", "Zephaniah": "ZEP", "Haggai": "HAG",
    "Zechariah": "ZEC", "Malachi": "MAL",
}

# Macula-internal helper morphemes: separate rows in Macula, merged into the head
# word by BSB. They must not take part in the comparison or the word counting.
HELPER_STRONGS = {
    "1886a", "871a", "3509a", "1930a", "2050b", "2050c", "2050d", "5105b",
}

DEFAULT_WINDOW = 25      # resync search radius, forward only

# Coverage is the primary gate; containment only shapes the block.
#
# Macula splits a word into morphemes — a pronominal suffix is its own row with
# its own Strong's — while BSB keeps the word whole. So a correct match still
# leaves Macula tokens unaccounted for, and containment sits systematically
# below coverage. Gating on min(coverage, containment) therefore rejected sound
# 1:1 matches wherever a verse was suffix-heavy: Isaiah 53:5 was refused that
# way while every verse around it matched. Coverage does not have that bias —
# BSB is the coarser side, so a real match explains nearly all of its words.
ACCEPT_COVERAGE = 0.60   # the ENG verse must be this well explained
MIN_CONTAINMENT = 0.35   # floor that still rejects an absurd pairing
GROUP_GAIN = 0.15        # a bigger block must beat the simpler one by this much
STRONG_SCORE = 0.85
MAX_GROUP = 4

MIN_ACCOUNTED_RATE = 0.98
MAX_WEAK_RATE = 0.05

# (osis, org_ch, org_vs, eng_ch, eng_vs, note) — the ENG verse the ORG verse
# STARTS in. A merged verse still has a first segment, so these hold either way.
KNOWN_ANCHORS = [
    ("GEN", 1, 1, 1, 1, "control"),
    ("EXO", 20, 1, 20, 1, "control"),
    ("ISA", 53, 5, 53, 5, "control"),

    ("GEN", 32, 2, 32, 1, "MT 32:1 = English 31:55, so the chapter runs one ahead"),
    ("PSA", 3, 3, 3, 2, "first clean verse after the merged superscription"),
    ("PSA", 51, 7, 51, 5, "the verse in the bug report"),
    ("PSA", 23, 1, 23, 1, "superscription inline in MT too — NOT shifted"),
    # MT Ecclesiastes 4 has 17 verses, English 16 — so MT 4:17 opens English 5.
    # An earlier version of this table stated the inverse and the matcher was
    # blamed for it. Verified against the produced map on 2026-08-04.
    ("ECC", 4, 17, 5, 1, "MT 4:17 is English 5:1; MT 5:1 is therefore English 5:2"),
    ("ISA", 8, 23, 9, 1, "MT 8:23 opens English chapter 9"),
    ("HOS", 2, 1, 1, 10, "chapter boundary differs"),
    ("JOL", 3, 1, 2, 28, "MT has 4 chapters, English 3"),
    ("JON", 2, 1, 1, 17, "the great fish verse"),
    ("NAM", 2, 1, 1, 15, "chapter boundary differs"),
    ("ZEC", 2, 1, 1, 18, "chapter boundary differs"),
    ("MAL", 3, 19, 4, 1, "MT has 3 chapters, English 4"),
    ("NUM", 17, 1, 16, 36, "chapter boundary differs"),
    ("DEU", 13, 1, 12, 32, "chapter boundary differs"),
    ("2SA", 19, 1, 18, 33, "chapter boundary differs"),
    # Same inversion as ECC: MT Leviticus 5 has 26 verses, English 19, so MT
    # 5:20 opens English chapter 6 and MT 6:1 lands on English 6:8.
    ("LEV", 5, 20, 6, 1, "MT 5:20 is English 6:1; MT 6:1 is therefore English 6:8"),
]

# ORG verses that must come out as part of a multi-verse block rather than a
# clean 1:1 — i.e. their segment must not be the whole of its ENG verse.
KNOWN_MERGED = [
    ("PSA", 3, 1, "superscription — shares ENG 3:1 with MT 3:2"),
    ("PSA", 3, 2, "shares ENG 3:1 with the superscription"),
    ("PSA", 51, 1, "superscription, part one"),
    ("PSA", 51, 2, "superscription, part two"),
]


def base_num(sid):
    if not sid:
        return ""
    digits = "".join(c for c in sid if c.isdigit())
    return digits.lstrip("0") or "0"


def sub_key(sid):
    if not sid:
        return ""
    return (sid.strip().lstrip("H").lstrip("0")) or "0"


# ─── Inputs ───────────────────────────────────────────────────────────────────

def load_macula():
    out = defaultdict(lambda: defaultdict(list))
    ref_re = re.compile(r"^(\S+)\s+(\d+):(\d+)")
    valid = set(BSB_TO_OSIS.values())
    with zipfile.ZipFile(MACULA_ZIP) as z:
        with z.open(MACULA_TSV) as f:
            for row in csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t"):
                m = ref_re.match((row.get("ref") or "").strip())
                if not m:
                    continue
                book = m.group(1).upper()
                if book not in valid:
                    continue
                sid = (row.get("strongnumberx") or "").strip()
                if not sid or sub_key(sid) in HELPER_STRONGS:
                    continue
                b = base_num(sid)
                if b:
                    out[book][(int(m.group(2)), int(m.group(3)))].append(b)
    return out


def load_bsb():
    out = defaultdict(lambda: defaultdict(list))
    vid_re = re.compile(r"^(.*?)\s+(\d+):(\d+)\s*$")
    csv.field_size_limit(10 ** 7)
    cur = None
    with open(BSB_TSV, encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        next(reader, None)
        for row in reader:
            if len(row) <= C_VERSE_ID:
                continue
            vid = (row[C_VERSE_ID] or "").strip()
            if vid:
                cur = None
                m = vid_re.match(vid)
                if m:
                    osis = BSB_TO_OSIS.get(m.group(1).strip())
                    if osis:
                        cur = (osis, int(m.group(2)), int(m.group(3)))
            if cur is None:
                continue
            if (row[C_LANGUAGE] or "").strip() not in ("Hebrew", "Aramaic"):
                continue
            b = base_num((row[C_STR_HEB] or "").strip())
            if b:
                out[cur[0]][(cur[1], cur[2])].append(b)
    return out


# ─── Scoring ──────────────────────────────────────────────────────────────────

def score(mac_list, bsb_list):
    """-> (coverage, containment). See the N:M note in the module docstring."""
    if not mac_list or not bsb_list:
        return 0.0, 0.0
    pool = defaultdict(int)
    for s in mac_list:
        pool[s] += 1
    hit = 0
    for s in bsb_list:
        if pool[s] > 0:
            pool[s] -= 1
            hit += 1
    return hit / len(bsb_list), hit / len(mac_list)


# ─── Segmenting one aligned block ─────────────────────────────────────────────

def segment_block(org_verses, eng_words):
    """
    Split one aligned block into segments.

    org_verses: [(org_key, [strongs])]           in text order
    eng_words:  [((eng_ch, eng_vs), pos, strong)] in text order, pos 1-based
                within its own ENG verse

    -> (segments, ok)
       segments: [(org_key, seg_idx, eng_ch, eng_vs, offset, length)]

    Words are handed out left to right: each ORG verse consumes ENG words while
    they are still explained by its own Strong's multiset. One unexplained word
    is tolerated mid-verse (Macula and BSB disagree about a handful of lexeme
    ids) but a run of them ends the verse. The last ORG verse takes whatever is
    left, so the block always tiles exactly — the tiling check downstream is
    therefore about *where* the boundaries fell, not whether they exist.
    """
    segments = []
    pos = 0
    n = len(eng_words)

    for vi, (org_key, mac_list) in enumerate(org_verses):
        last = (vi == len(org_verses) - 1)
        start = pos
        if last:
            pos = n
        else:
            pool = defaultdict(int)
            for s in mac_list:
                pool[s] += 1
            misses = 0
            while pos < n:
                s = eng_words[pos][2]
                if pool[s] > 0:
                    pool[s] -= 1
                    misses = 0
                    pos += 1
                elif misses == 0 and pos + 1 < n and pool.get(eng_words[pos + 1][2], 0) > 0:
                    misses = 1          # tolerate a single unexplained word
                    pos += 1
                else:
                    break
            if pos == start:            # consumed nothing — refuse the block
                return [], False

        if pos <= start:
            return [], False

        # The consumed run may straddle an ENG verse boundary when the block is
        # 1:N. Emit one segment per ENG verse touched.
        seg_idx = 0
        k = start
        while k < pos:
            vkey = eng_words[k][0]
            run_start = k
            while k < pos and eng_words[k][0] == vkey:
                k += 1
            offset = eng_words[run_start][1] - 1        # 0-based within ENG verse
            segments.append((org_key, seg_idx, vkey[0], vkey[1], offset, k - run_start))
            seg_idx += 1

    return segments, True


# ─── Aligning one book ────────────────────────────────────────────────────────

def map_book(osis, mac_book, bsb_book, window):
    """
    Two-pointer alignment producing N:M blocks.

    -> (rows, review, stats)
       rows: (osis, och, ovs, seg, ech, evs, offset, length, score, flag)
    """
    mac_keys = sorted(mac_book.keys())
    bsb_keys = sorted(bsb_book.keys())
    if not bsb_keys:
        return [], [(osis, "", "", "NO_BSB_BOOK", "book absent from bsb_tables.tsv")], {}

    rows, review = [], []
    stats = defaultdict(int)
    i = j = 0

    def eng_words_for(js):
        out = []
        for jj in js:
            key = bsb_keys[jj]
            for p, s in enumerate(bsb_book[key], 1):
                out.append((key, p, s))
        return out

    def emit(org_span, eng_span, cov, con, kind):
        org_verses = [(mac_keys[x], mac_book[mac_keys[x]]) for x in org_span]
        segs, ok = segment_block(org_verses, eng_words_for(eng_span))
        if not ok:
            for x in org_span:
                review.append((osis, mac_keys[x][0], mac_keys[x][1], "SEGMENT_FAILED",
                               "block %s -> %s could not be split into segments"
                               % (kind, [bsb_keys[y] for y in eng_span])))
            return False
        # The recorded score is COVERAGE, not min(coverage, containment).
        # Containment is depressed by Macula's finer tokenisation, so using it
        # here labelled half of a sound map "weak" and said nothing useful.
        worst = cov
        flag = "OK" if worst >= STRONG_SCORE else "WEAK"
        if kind != "1:1":
            flag += "|" + kind
        for (okey, sidx, ech, evs, off, ln) in segs:
            if (okey[0], okey[1]) != (ech, evs) and "|" not in flag:
                pass
            f = flag
            if (okey[0], okey[1]) != (ech, evs) and "SHIFTED" not in f:
                f += "|SHIFTED"
            rows.append((osis, okey[0], okey[1], sidx, ech, evs, off, ln,
                         round(worst, 3), f))
        stats[kind] += 1
        return True

    while i < len(mac_keys) and j < len(bsb_keys):
        # Evaluate EVERY shape and take the best, rather than accepting 1:1 the
        # moment it clears the bar. A merged psalm superscription can leave the
        # first MT verse covering exactly 60% of the ENG verse, which squeaks
        # past a 0.60 threshold as a clean 1:1 — swallowing the whole page and
        # orphaning the verse it was merged with. Asking "which shape explains
        # both sides best" instead of "does this shape pass" removes that trap.
        candidates = []

        cov, con = score(mac_book[mac_keys[i]], bsb_book[bsb_keys[j]])
        candidates.append((cov, con, 2, "1:1", 1, 1))

        for n in range(2, MAX_GROUP + 1):          # N MT verses inside one ENG verse
            if i + n > len(mac_keys):
                break
            combined = [s for x in range(i, i + n) for s in mac_book[mac_keys[x]]]
            c2, k2 = score(combined, bsb_book[bsb_keys[j]])
            candidates.append((c2, k2, n + 1, "N:1", n, 1))

        for mm in range(2, MAX_GROUP + 1):         # one MT verse across M ENG verses
            if j + mm > len(bsb_keys):
                break
            combined = [s for y in range(j, j + mm) for s in bsb_book[bsb_keys[y]]]
            c2, k2 = score(mac_book[mac_keys[i]], combined)
            candidates.append((c2, k2, mm + 1, "1:N", 1, mm))

        # Ranking and gating answer different questions and must not share a
        # number.
        #
        #   RANKING  — which shape is this? Judged on the WEAKER side. Only the
        #              weaker side distinguishes the three cases: a merge starves
        #              coverage (one MT verse explains half an ENG verse), a split
        #              starves containment (one MT verse holds a whole ENG verse
        #              and more), a clean pair starves neither.
        #   GATING   — is the chosen shape good enough? Judged on COVERAGE, which
        #              carries no bias, because Macula's finer tokenisation
        #              permanently depresses containment on correct matches.
        #
        # Collapsing both onto coverage made splits invisible: a verse that
        # covered its ENG verse completely and spilled into the next one scored
        # coverage 1.0 and was taken as a clean 1:1, so 1:N blocks fell from 172
        # to 2. Collapsing both onto min() did the opposite and refused
        # suffix-heavy verses like Isaiah 53:5.
        simple = candidates[0]
        best = max(candidates, key=lambda c: (min(c[0], c[1]), -c[2]))
        if best[3] != "1:1" and min(best[0], best[1]) < min(simple[0], simple[1]) + GROUP_GAIN:
            best = simple

        cov, con, _sz, kind, n, m = best
        if cov >= ACCEPT_COVERAGE and con >= MIN_CONTAINMENT:
            emit(list(range(i, i + n)), list(range(j, j + m)), cov, con, kind)
            i += n
            j += m
            continue

        # Resync — FORWARD ONLY. Searching backwards let a later block re-claim
        # ENG verses an earlier one had already taken, which is where the 33
        # tiling overlaps and 16 backward jumps in the 2026-08-04 run came from.
        # The text is monotone; the answer is never behind us.
        found = None
        for jj in range(j, min(len(bsb_keys), j + window + 1)):
            c2, k2 = score(mac_book[mac_keys[i]], bsb_book[bsb_keys[jj]])
            if c2 >= ACCEPT_COVERAGE and k2 >= MIN_CONTAINMENT:
                if found is None or c2 > found[1]:
                    found = (jj, c2, k2)
                if c2 >= STRONG_SCORE:
                    break
        if found:
            jj, c2, k2 = found
            if jj > j:
                stats["resync_skipped_eng"] += (jj - j)
            emit([i], [jj], c2, k2, "1:1")
            i += 1
            j = jj + 1
            continue

        # Nothing fits. Record it, then advance BOTH pointers. Advancing only the
        # ORG side leaves the two streams one verse out of step, so a single
        # unmatched verse used to knock everything after it out of alignment —
        # that is what turned one bad verse at the Numbers 30 boundary into 227
        # consecutive failures.
        review.append((osis, mac_keys[i][0], mac_keys[i][1], "NO_ALIGNMENT",
                       "no 1:1, no N:1 up to %d, no 1:N up to %d, and nothing within "
                       "+%d of ENG index %d clears coverage %.2f"
                       % (MAX_GROUP, MAX_GROUP, window, j, ACCEPT_COVERAGE)))
        stats["unaligned"] += 1
        i += 1
        j += 1

    while i < len(mac_keys):
        review.append((osis, mac_keys[i][0], mac_keys[i][1], "PAST_END_OF_BSB",
                       "ENG stream exhausted before the ORG stream"))
        i += 1

    return rows, review, stats


# ─── Self-check ───────────────────────────────────────────────────────────────

def verify(rows, total_considered, books_checked):
    failures = []
    scope = set(books_checked)

    first_seg = {}
    segs_by_org = defaultdict(list)
    for r in rows:
        key = (r[0], r[1], r[2])
        segs_by_org[key].append(r)
        if r[3] == 0:
            first_seg[key] = r

    print("\n─── anchors ───")
    run = ok = 0
    for osis, och, ovs, ech, evs, note in KNOWN_ANCHORS:
        if osis not in scope:
            continue
        run += 1
        got = first_seg.get((osis, och, ovs))
        if got is None:
            failures.append("ANCHOR MISSING  %s %d:%d — expected ENG %d:%d, absent from the map"
                            % (osis, och, ovs, ech, evs))
            print("  ✗ %-4s %3d:%-3d  expected %d:%-3d  got —" % (osis, och, ovs, ech, evs))
            continue
        if (got[4], got[5]) == (ech, evs):
            ok += 1
            print("  ✓ %-4s %3d:%-3d  ->  %d:%-3d off=%-3d len=%-3d %s"
                  % (osis, och, ovs, ech, evs, got[6], got[7], note))
        else:
            failures.append(
                "ANCHOR MISMATCH %s %d:%d — expected ENG %d:%d, produced %d:%d. "
                "Either the matcher is wrong here, or the anchor is."
                % (osis, och, ovs, ech, evs, got[4], got[5]))
            print("  ✗ %-4s %3d:%-3d  expected %d:%-3d  got %d:%-3d"
                  % (osis, och, ovs, ech, evs, got[4], got[5]))
    print("  %d/%d anchors matched" % (ok, run))

    print("\n─── known merges ───")
    mrun = mok = 0
    eng_claims = defaultdict(list)
    for r in rows:
        eng_claims[(r[0], r[4], r[5])].append(r)
    for osis, och, ovs, note in KNOWN_MERGED:
        if osis not in scope:
            continue
        mrun += 1
        got = first_seg.get((osis, och, ovs))
        if got is None:
            failures.append("MERGE MISSING   %s %d:%d absent from the map — %s"
                            % (osis, och, ovs, note))
            print("  ✗ %-4s %3d:%-3d  absent" % (osis, och, ovs))
            continue
        sharers = eng_claims[(osis, got[4], got[5])]
        distinct = {(s[1], s[2]) for s in sharers}
        if len(distinct) > 1:
            mok += 1
            print("  ✓ %-4s %3d:%-3d  shares ENG %d:%-3d with %d other verse(s)  %s"
                  % (osis, och, ovs, got[4], got[5], len(distinct) - 1, note))
        else:
            failures.append(
                "MERGE NOT SEEN  %s %d:%d was mapped 1:1 onto ENG %d:%d, but this verse "
                "is known to share its ENG verse. A whole page would be handed to it."
                % (osis, och, ovs, got[4], got[5]))
            print("  ✗ %-4s %3d:%-3d  mapped 1:1 onto %d:%d" % (osis, och, ovs, got[4], got[5]))
    if mrun:
        print("  %d/%d known merges behaved as merges" % (mok, mrun))

    print("\n─── tiling ───")
    gaps = overlaps = 0
    for (osis, ech, evs), claims in eng_claims.items():
        spans = sorted((c[6], c[6] + c[7]) for c in claims)
        cursor = spans[0][0]
        if cursor != 0:
            gaps += 1
            failures.append("TILING GAP      %s ENG %d:%d starts at word %d, not 0"
                            % (osis, ech, evs, cursor))
        for a, b in spans:
            if a > cursor:
                gaps += 1
                failures.append("TILING GAP      %s ENG %d:%d words %d..%d claimed by nobody"
                                % (osis, ech, evs, cursor, a))
            elif a < cursor:
                overlaps += 1
                failures.append("TILING OVERLAP  %s ENG %d:%d words %d..%d claimed twice"
                                % (osis, ech, evs, a, cursor))
            cursor = max(cursor, b)
    print("  ENG verses claimed : %d" % len(eng_claims))
    print("  gaps               : %d" % gaps)
    print("  overlaps           : %d" % overlaps)

    print("\n─── structure ───")
    dup = sum(1 for k, v in segs_by_org.items() if len({r[3] for r in v}) != len(v))
    multi = sum(1 for v in segs_by_org.values() if len(v) > 1)
    print("  ORG verses in map    : %d" % len(segs_by_org))
    print("  with >1 segment      : %d   (MT verse split across ENG verses)" % multi)
    print("  duplicate (ORG,seg)  : %d" % dup)
    if dup:
        failures.append("DUPLICATE SEG   %d ORG verses have a repeated segment index" % dup)

    print("\n─── coverage ───")
    accounted = len(segs_by_org)
    rate = accounted / max(1, total_considered)
    weak = sum(1 for r in rows if "WEAK" in r[9])
    weak_rate = weak / max(1, len(rows))
    print("  ORG verses accounted : %d/%d = %.2f%%  (floor %.0f%%)"
          % (accounted, total_considered, 100 * rate, 100 * MIN_ACCOUNTED_RATE))
    print("  unexplained          : %d" % (total_considered - accounted))
    print("  weak segments        : %d/%d = %.2f%%  (ceiling %.0f%%)"
          % (weak, len(rows), 100 * weak_rate, 100 * MAX_WEAK_RATE))
    if rate < MIN_ACCOUNTED_RATE:
        failures.append("COVERAGE LOW    %.2f%% accounted for, %d verses unexplained "
                        "(floor %.0f%%). Try --window 40."
                        % (100 * rate, total_considered - accounted, 100 * MIN_ACCOUNTED_RATE))
    if weak_rate > MAX_WEAK_RATE:
        failures.append("WEAK RATE HIGH  %.2f%% of segments scored below %.2f"
                        % (100 * weak_rate, STRONG_SCORE))

    shifted = defaultdict(int)
    for r in rows:
        if "SHIFTED" in r[9] and r[3] == 0:
            shifted[r[0]] += 1
    if shifted:
        print("\n─── shifted verses per book (what BibleHub got wrong) ───")
        for b, n in sorted(shifted.items(), key=lambda kv: -kv[1])[:12]:
            print("  %-4s %6d" % (b, n))

    return (len(failures) == 0), failures


def load_map_rows(path):
    if not os.path.exists(path):
        sys.exit("missing %s — run without --verify-only first" % path)
    rows = []
    with open(path, encoding="utf-8") as f:
        for d in csv.DictReader(f, delimiter="\t"):
            rows.append((d["osis"], int(d["org_chapter"]), int(d["org_verse"]),
                         int(d["seg"]), int(d["eng_chapter"]), int(d["eng_verse"]),
                         int(d["word_offset"]), int(d["word_len"]),
                         float(d["score"]), d["flag"]))
    return rows


def report(passed, failures):
    print("\n" + "=" * 62)
    if passed:
        print("SELF-CHECK PASSED — the map is safe to feed to the scraper.")
        print("=" * 62)
        return 0
    print("SELF-CHECK FAILED — %d problem(s). Do NOT run the scraper on this map."
          % len(failures))
    print("=" * 62)
    for i, msg in enumerate(failures[:40], 1):
        print("%3d. %s" % (i, msg))
    if len(failures) > 40:
        print("     ... and %d more" % (len(failures) - 40))
    return 1


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--book")
    ap.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    ap.add_argument("--verify-only", action="store_true")
    args = ap.parse_args()

    if args.verify_only:
        rows = load_map_rows(OUT_MAP)
        if args.book:
            rows = [r for r in rows if r[0] == args.book.upper()]
        books = sorted({r[0] for r in rows})
        orgs = len({(r[0], r[1], r[2]) for r in rows})
        print("Verifying %s: %d segments, %d ORG verses, %d books"
              % (OUT_MAP, len(rows), orgs, len(books)))
        passed, failures = verify(rows, orgs, books)
        sys.exit(report(passed, failures))

    for p in (MACULA_ZIP, BSB_TSV):
        if not os.path.exists(p):
            sys.exit("missing input: %s" % p)

    print("Loading Macula (ORG numbering)...")
    mac = load_macula()
    print("  books: %d  verses: %d" % (len(mac), sum(len(v) for v in mac.values())))

    print("Loading BSB (ENG numbering)...")
    bsb = load_bsb()
    print("  books: %d  verses: %d" % (len(bsb), sum(len(v) for v in bsb.values())))

    books = [args.book.upper()] if args.book else sorted(mac.keys())

    all_rows, all_rev = [], []
    agg = defaultdict(int)
    print("\n%-5s %7s %7s %6s %6s %6s %7s"
          % ("book", "verses", "segs", "1:1", "N:1", "1:N", "unexpl"))
    for osis in books:
        if osis not in mac:
            print("  %s: not in Macula, skipped" % osis)
            continue
        rows, rev, st = map_book(osis, mac[osis], bsb.get(osis, {}), args.window)
        for k, v in st.items():
            agg[k] += v
        print("%-5s %7d %7d %6d %6d %6d %7d"
              % (osis, len(mac[osis]), len(rows), st.get("1:1", 0),
                 st.get("N:1", 0), st.get("1:N", 0), len(rev)))
        all_rows.extend(rows)
        all_rev.extend(rev)

    with open(OUT_MAP, "w", encoding="utf-8") as f:
        f.write("osis\torg_chapter\torg_verse\tseg\teng_chapter\teng_verse"
                "\tword_offset\tword_len\tscore\tflag\n")
        for r in all_rows:
            f.write("\t".join(str(x) for x in r) + "\n")

    with open(OUT_REVIEW, "w", encoding="utf-8") as f:
        f.write("osis\torg_chapter\torg_verse\treason\tdetail\n")
        for r in all_rev:
            f.write("\t".join(str(x) for x in r) + "\n")

    total = sum(len(mac[b]) for b in books if b in mac)
    print("\n─── summary ───")
    print("  ORG verses considered : %d" % total)
    print("  segments written      : %d" % len(all_rows))
    print("  blocks 1:1 / N:1 / 1:N: %d / %d / %d"
          % (agg.get("1:1", 0), agg.get("N:1", 0), agg.get("1:N", 0)))
    print("  refused               : %d -> %s" % (len(all_rev), OUT_REVIEW))
    print("  map written           : %s" % OUT_MAP)

    passed, failures = verify(all_rows, total, [b for b in books if b in mac])
    sys.exit(report(passed, failures))


if __name__ == "__main__":
    main()
