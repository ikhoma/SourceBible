#!/usr/bin/env python3
"""
fetch_biblehub_translit_hebrew_v2.py — re-scrape BibleHub Hebrew transliterations
at the CORRECT verse, and fill the six books the v1 scraper missed entirely.

Two defects in v1 (`fetch_biblehub_translit_hebrew.py`) are fixed here:

  BUG A — wrong verse.  v1 enumerated Masoretic refs out of Macula and pasted
          them straight into the URL. BibleHub serves ENGLISH numbering there.
          In shifted chapters v1 stored a different verse's transliteration
          under the ORG key. Ps 51:7 currently shows the words of Ps 51:9.
          Fixed by translating ORG -> ENG through data/org_to_eng.tsv (produced
          by derive_org_to_eng.py) before building the URL, while continuing to
          key the JSON by the ORG ref so build_db.py needs no change.

  BUG B — six books never fetched.  v1's OT_SLUGS spelled the numbered books
          "1-samuel", "1-kings", "1-chronicles". BibleHub uses an underscore:
          "1_samuel". Every request 404'd, fetch() retried three times and
          returned None silently, and 1SA/2SA/1KI/2KI/1CH/2CH ended up with
          zero transliterations — 4,807 verses.

Also added, because the absence of it is what let BUG A live for two months:

  PER-SLOT STRONG'S VALIDATION.  ADR-020 specifies a level-2 check that was
  designed but never implemented in build_db.py. Here it runs at fetch time:
  the Strong's numbers BibleHub reports for a page are compared against the
  Macula Strong's for the ORG verse we are storing under. A page that does not
  agree is REJECTED rather than stored. Word-count parity is deliberately NOT
  used as the primary guard — a shifted verse very often has the same number of
  words, which is exactly why the existing COUNT_MISMATCH check missed this.

The HTML parser and the HTTP retry logic are imported from v1 rather than
duplicated; both were fine, only the refs and the slugs were wrong.

WRITES ONLY:  data/hebrew_translit.json          (merged, v1 entries preserved
                                                  unless --replace-shifted)
              data/hebrew_translit_rejected.tsv  (every page the validator refused)

Does not touch sourcebible.db.

Usage:
    # 0. produce the map first — this script refuses to run without it
    python3 scripts/derive_org_to_eng.py

    # 1. dry run: what would be fetched, and why
    python3 scripts/fetch_biblehub_translit_hebrew_v2.py --plan

    # 2. the two cheap, high-value passes
    python3 scripts/fetch_biblehub_translit_hebrew_v2.py --missing-only
    python3 scripts/fetch_biblehub_translit_hebrew_v2.py --shifted-only --replace-shifted

    # 3. everything (slow; only if you want a clean full rebuild)
    python3 scripts/fetch_biblehub_translit_hebrew_v2.py --all --replace-shifted

Resumable: progress is written every SAVE_EVERY pages, and any ORG key already
present is skipped unless it is being deliberately replaced.
"""

import argparse
import csv
import io
import json
import os
import re
import sys
import time
import zipfile
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

# v1 has an `if __name__ == "__main__"` guard, so importing it is safe and does
# not kick off a scrape.
from fetch_biblehub_translit_hebrew import (   # noqa: E402
    parse_hebrew_translit,
    fetch,
    DELAY,
    SAVE_EVERY,
)

DATA = os.path.join(REPO, "data")
MACULA_ZIP = os.path.join(DATA, "macula-hebrew-main.zip")
MACULA_TSV = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"
MAP_TSV = os.path.join(DATA, "org_to_eng.tsv")
OUT_JSON = os.path.join(DATA, "hebrew_translit.json")
OUT_REJECT = os.path.join(DATA, "hebrew_translit_rejected.tsv")

# Corrected slugs. The six numbered books are the whole of BUG B; every other
# entry is carried over from v1 unchanged, including "songs" for SNG which is
# correct as-is.
OT_SLUGS = {
    "GEN": "genesis",       "EXO": "exodus",        "LEV": "leviticus",
    "NUM": "numbers",       "DEU": "deuteronomy",   "JOS": "joshua",
    "JDG": "judges",        "RUT": "ruth",          "1SA": "1_samuel",
    "2SA": "2_samuel",      "1KI": "1_kings",       "2KI": "2_kings",
    "1CH": "1_chronicles",  "2CH": "2_chronicles",  "EZR": "ezra",
    "NEH": "nehemiah",      "EST": "esther",        "JOB": "job",
    "PSA": "psalms",        "PRO": "proverbs",      "ECC": "ecclesiastes",
    "SNG": "songs",         "ISA": "isaiah",        "JER": "jeremiah",
    "LAM": "lamentations",  "EZK": "ezekiel",       "DAN": "daniel",
    "HOS": "hosea",         "JOL": "joel",          "AMO": "amos",
    "OBA": "obadiah",       "JON": "jonah",         "MIC": "micah",
    "NAM": "nahum",         "HAB": "habakkuk",      "ZEP": "zephaniah",
    "HAG": "haggai",        "ZEC": "zechariah",     "MAL": "malachi",
}

HELPER_STRONGS = {
    "1886a", "871a", "3509a", "1930a", "2050b", "2050c", "2050d", "5105b",
}

# Fraction of BibleHub's Strong's for a page that must be found in the Macula
# verse we intend to store it under. Below this the page is rejected.
ACCEPT_AGREEMENT = 0.70

# Below this the page is treated as a different verse and refused. Between
# ACCEPT_MARGINAL and ACCEPT_AGREEMENT the page is stored but flagged.
#
# Both numbers come from the measured distribution on 2026-08-04, not from
# taste. Verses that genuinely held another verse's words scored 0.00, 0.00,
# 0.00, 0.08, 0.12, 0.14, 0.17, 0.17 — never above 0.17. Verses that held the
# RIGHT words but disagreed with Macula on a lexeme id or two scored 0.33, 0.50,
# 0.54, 0.57, 0.60, 0.62, 0.67, 0.69. The two populations are separated by an
# empty band from 0.17 to 0.33, so the boundary belongs inside that band.
#
# A single flat bar at 0.70 refused 30 correct verses: on a three-word verse one
# differing Strong's is 0.67. Their books — Genesis 34, Job 18, Proverbs 7, Song
# 2 — have no versification divergence at all, which is what identified them as
# false rejections rather than a lower standard.
ACCEPT_MARGINAL = 0.30


def base_num(sid):
    if not sid:
        return ""
    digits = "".join(c for c in str(sid) if c.isdigit())
    return digits.lstrip("0") or "0"


def sub_key(sid):
    if not sid:
        return ""
    return (str(sid).strip().lstrip("H").lstrip("0")) or "0"


# ─── Inputs ───────────────────────────────────────────────────────────────────

def load_macula_strongs():
    """-> {(osis, ch, vs): [strongs_base, ...]} in ORG numbering, helpers removed."""
    out = defaultdict(list)
    ref_re = re.compile(r"^(\S+)\s+(\d+):(\d+)")
    with zipfile.ZipFile(MACULA_ZIP) as z:
        with z.open(MACULA_TSV) as f:
            for row in csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t"):
                m = ref_re.match((row.get("ref") or "").strip())
                if not m:
                    continue
                book = m.group(1).upper()
                if book not in OT_SLUGS:
                    continue
                sid = (row.get("strongnumberx") or "").strip()
                if not sid or sub_key(sid) in HELPER_STRONGS:
                    continue
                b = base_num(sid)
                if b:
                    out[(book, int(m.group(2)), int(m.group(3)))].append(b)
    return out


def load_map():
    """
    -> {(osis, org_ch, org_vs): {"segs": [(eng_ch, eng_vs, offset, length), ...],
                                 "shifted": bool}}

    The map is a SEGMENT map, not a verse map: one ORG verse may take a slice of
    an ENG verse (English folds a psalm superscription into verse 1, so two MT
    verses share one ENG page) or span several ENG verses (a long MT verse split
    in English). Segments are ordered by `seg`.

    Slicing happens here, at fetch time, so what gets written to the JSON is
    still "ORG verse -> its own words, in order". build_db.py's contract is
    unchanged.
    """
    if not os.path.exists(MAP_TSV):
        sys.exit(
            "missing %s\n"
            "Run:  python3 scripts/derive_org_to_eng.py\n"
            "This script will not guess verse numbers — that is the bug it fixes."
            % MAP_TSV
        )
    tmp = defaultdict(list)
    shifted = {}
    with open(MAP_TSV, encoding="utf-8") as f:
        rdr = csv.DictReader(f, delimiter="\t")
        if "word_offset" not in (rdr.fieldnames or []):
            sys.exit(
                "%s is in the old verse-to-verse format.\n"
                "Re-run:  python3 scripts/derive_org_to_eng.py" % MAP_TSV
            )
        for row in rdr:
            key = (row["osis"], int(row["org_chapter"]), int(row["org_verse"]))
            tmp[key].append((int(row["seg"]), int(row["eng_chapter"]),
                             int(row["eng_verse"]), int(row["word_offset"]),
                             int(row["word_len"])))
            if "SHIFTED" in (row.get("flag") or ""):
                shifted[key] = True
    out = {}
    for key, segs in tmp.items():
        segs.sort()
        out[key] = {"segs": [(c, v, o, l) for (_s, c, v, o, l) in segs],
                    "shifted": shifted.get(key, False)}
    return out


def load_existing():
    if os.path.exists(OUT_JSON):
        with open(OUT_JSON, encoding="utf-8") as f:
            return json.load(f)
    return {}


# ─── Validation ───────────────────────────────────────────────────────────────

def as_word(w):
    """
    Normalise one parsed word to a dict.

    v1's `parse_hebrew_translit()` returns 3-tuples of (surface, translit,
    strong); entries already stored in the JSON are dicts. Both flow through the
    same code here, so everything is normalised at the boundary rather than
    every call site having to know which shape it holds.
    """
    if isinstance(w, dict):
        return w
    if isinstance(w, (tuple, list)) and len(w) >= 3:
        return {"surface": w[0], "translit": w[1], "strong": w[2]}
    return {"surface": "", "translit": "", "strong": ""}


def split_page(words, claimant_strongs):
    """
    Divide one BibleHub page between the ORG verses that share it.

    words:            the page's words, in order, as parsed from BibleHub
    claimant_strongs: [[strongs], ...] — Macula Strong's for each ORG verse
                      claiming this page, in text order

    -> [(start, end), ...] one span per claimant, tiling the page exactly.

    The boundaries are recomputed here from the LIVE page rather than taken from
    the map's word_offset/word_len, because those lengths come from BSB and BSB
    does not always tokenise a verse the same way BibleHub does. On a page with
    one claimant that mismatch merely produced a slice one word past the end —
    visible, and rejected. On a shared page it would have moved the boundary by
    a word and still scored 0.83 against Macula, passing the 0.70 guard silently.
    Deriving the split from the page itself removes that failure mode entirely:
    the map only has to say WHICH verses share the page and in what order.
    """
    n = len(words)
    if len(claimant_strongs) == 1:
        return [(0, n)]

    spans = []
    pos = 0
    for idx, mac_list in enumerate(claimant_strongs):
        last = (idx == len(claimant_strongs) - 1)
        start = pos
        if last:
            pos = n
        else:
            pool = defaultdict(int)
            for s in mac_list:
                pool[s] += 1
            misses = 0
            while pos < n:
                b = base_num(as_word(words[pos]).get("strong", ""))
                if b and pool[b] > 0:
                    pool[b] -= 1
                    misses = 0
                    pos += 1
                elif misses == 0 and pos + 1 < n and pool.get(
                        base_num(as_word(words[pos + 1]).get("strong", "")), 0) > 0:
                    misses = 1          # tolerate one word neither side explains
                    pos += 1
                else:
                    break
            if pos == start:            # consumed nothing — refuse the whole page
                return None
        spans.append((start, pos))
    return spans


def agreement(bh_words, mac_strongs):
    """
    Fraction of BibleHub Strong's for this page that occur in the Macula verse
    we are about to file it under. Multiset comparison, normalised by BibleHub,
    which is the coarser tokenisation.
    """
    if not bh_words or not mac_strongs:
        return 0.0
    pool = defaultdict(int)
    for s in mac_strongs:
        pool[s] += 1
    hit = 0
    for w in bh_words:
        b = base_num(as_word(w).get("strong", ""))
        if b and pool[b] > 0:
            pool[b] -= 1
            hit += 1
    return hit / len(bh_words)


# ─── Audit of the produced (or existing) JSON ─────────────────────────────────

# ORG refs whose stored Strong's sequence is checked by name. These are verses
# where the two numbering systems are known to diverge, so a v1-era JSON will
# fail them and a correctly re-scraped one will pass. Expected leading Strong's
# are the Macula values for the ORG verse — the check is content identity, not
# a transliteration string, so it is immune to notation differences.
AUDIT_ANCHORS = [
    ("PSA", 51, 7, "the verse from the bug report — MT 51:7, English 51:5"),
    ("PSA", 3, 2, "one-line superscription"),
    ("JON", 2, 1, "MT 2:1 = English 1:17"),
    ("MAL", 3, 19, "MT 3:19 = English 4:1"),
    ("JOL", 3, 1, "MT 3:1 = English 2:28"),
    ("GEN", 1, 1, "control — must pass in any build"),
    ("1SA", 1, 1, "BUG B canary — zero coverage before the slug fix"),
    ("1CH", 1, 1, "BUG B canary"),
]

SUSPECT_FLOOR = 0.30     # below this an entry is treated as outright wrong


def audit(store, mac):
    """
    Compare every stored verse against Macula. -> (passed, failures, rows)

    This is the check that should have existed in June. It does not care how the
    JSON was produced: v1 entries, v2 entries and hand-patched entries are all
    scored the same way.
    """
    failures = []
    rows = []
    buckets = {"OK": 0, "SUSPECT": 0, "CORRUPT": 0, "NO_MACULA": 0}
    per_book = defaultdict(lambda: {"OK": 0, "SUSPECT": 0, "CORRUPT": 0})

    for key in store:
        if not key.endswith(":count"):
            continue
        base = key[: -len(":count")]
        try:
            book, ch, vs = base.split(":")
            ch, vs = int(ch), int(vs)
        except ValueError:
            continue
        n = store[key]
        words = []
        for pos in range(1, int(n) + 1):
            w = store.get("%s:%d" % (base, pos))
            if isinstance(w, dict):
                words.append(w)
        mac_list = mac.get((book, ch, vs))
        if not mac_list:
            buckets["NO_MACULA"] += 1
            continue
        agr = agreement(words, mac_list)
        if agr >= ACCEPT_AGREEMENT:
            b = "OK"
        elif agr >= SUSPECT_FLOOR:
            b = "SUSPECT"
        else:
            b = "CORRUPT"
        buckets[b] += 1
        per_book[book][b] += 1
        if b != "OK":
            rows.append((book, ch, vs, b, "%.2f" % agr,
                         store.get("%s:eng" % base, "unknown"),
                         " ".join(base_num(w.get("strong", "")) for w in words[:6]),
                         " ".join(mac_list[:6])))

    # Verses that exist in Macula but have no entry at all. Scoring only what is
    # stored made an audit that purges bad entries self-congratulatory: the
    # 2026-08-04 repair refused 30 verses, deleted their stale rows, and the
    # audit then reported "every stored verse agrees" — true, and silent about
    # the 30 that were no longer there. Absence is a coverage hole and has to be
    # counted, not skipped.
    absent = sorted(k for k in mac if ("%s:%d:%d:count" % k) not in store)

    total = sum(buckets[k] for k in ("OK", "SUSPECT", "CORRUPT"))
    print("\n─── stored verses scored against Macula ───")
    print("  OK       (agreement >= %.2f) : %6d" % (ACCEPT_AGREEMENT, buckets["OK"]))
    print("  SUSPECT  (%.2f .. %.2f)      : %6d" % (SUSPECT_FLOOR, ACCEPT_AGREEMENT, buckets["SUSPECT"]))
    print("  CORRUPT  (< %.2f)            : %6d   <- wrong verse" % (SUSPECT_FLOOR, buckets["CORRUPT"]))
    print("  no Macula verse to compare   : %6d" % buckets["NO_MACULA"])
    if total:
        bad = buckets["SUSPECT"] + buckets["CORRUPT"]
        print("  bad share                    : %.2f%%" % (100.0 * bad / total))

    worst = sorted(per_book.items(),
                   key=lambda kv: -(kv[1]["CORRUPT"] + kv[1]["SUSPECT"]))[:10]
    if worst and (worst[0][1]["CORRUPT"] + worst[0][1]["SUSPECT"]):
        print("\n  worst books:")
        for b, d in worst:
            if d["CORRUPT"] + d["SUSPECT"] == 0:
                continue
            print("    %-4s corrupt=%-5d suspect=%-5d ok=%d" % (b, d["CORRUPT"], d["SUSPECT"], d["OK"]))

    print("\n─── anchors ───")
    run = ok = 0
    for book, ch, vs, note in AUDIT_ANCHORS:
        base = "%s:%d:%d" % (book, ch, vs)
        n = store.get("%s:count" % base)
        mac_list = mac.get((book, ch, vs))
        if not mac_list:
            continue
        run += 1
        if n is None:
            failures.append("ANCHOR ABSENT   %s %d:%d has no entry at all — %s"
                            % (book, ch, vs, note))
            print("  ✗ %-4s %3d:%-3d  no entry        %s" % (book, ch, vs, note))
            continue
        words = [store.get("%s:%d" % (base, p)) for p in range(1, int(n) + 1)]
        words = [w for w in words if isinstance(w, dict)]
        agr = agreement(words, mac_list)
        if agr >= ACCEPT_AGREEMENT:
            ok += 1
            print("  ✓ %-4s %3d:%-3d  agreement=%.2f  eng=%-7s %s"
                  % (book, ch, vs, agr, store.get("%s:eng" % base, "?"), note))
        else:
            failures.append(
                "ANCHOR WRONG    %s %d:%d agreement %.2f — stored Strong's [%s] vs "
                "Macula [%s]. This verse is showing another verse's transliteration."
                % (book, ch, vs, agr,
                   " ".join(base_num(w.get("strong", "")) for w in words[:6]),
                   " ".join(mac_list[:6])))
            print("  ✗ %-4s %3d:%-3d  agreement=%.2f  %s" % (book, ch, vs, agr, note))
    print("  %d/%d anchors passed" % (ok, run))

    print("\n─── coverage ───")
    print("  Macula OT verses      : %d" % len(mac))
    print("  with a stored entry   : %d" % (len(mac) - len(absent)))
    print("  with NO entry at all  : %d   <- these show the per-token xlit instead"
          % len(absent))
    if absent:
        from collections import Counter as _C
        per = _C(k[0] for k in absent)
        print("    by book: %s" % ", ".join("%s:%d" % kv for kv in per.most_common(10)))
        print("    first few: %s" % ", ".join("%s %d:%d" % k for k in absent[:8]))

    if buckets["CORRUPT"]:
        failures.append("%d verse(s) scored below %.2f — these are storing another "
                        "verse's transliteration and must be re-fetched."
                        % (buckets["CORRUPT"], SUSPECT_FLOOR))
    if absent:
        failures.append("%d Macula verse(s) have no transliteration at all. That is a "
                        "coverage hole, not a pass — see data/hebrew_translit_rejected.tsv "
                        "for why each one was refused." % len(absent))

    out = os.path.join(DATA, "hebrew_translit_audit.tsv")
    with open(out, "w", encoding="utf-8") as f:
        f.write("osis\torg_chapter\torg_verse\tverdict\tagreement\tstored_eng"
                "\tstored_strongs\tmacula_strongs\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")
    print("\n  audit rows written: %s (%d)" % (out, len(rows)))

    return (len(failures) == 0), failures


def report(passed, failures):
    print("\n" + "=" * 62)
    if passed:
        print("AUDIT PASSED — every stored verse agrees with Macula.")
        print("=" * 62)
        return 0
    print("AUDIT FAILED — %d problem(s)." % len(failures))
    print("=" * 62)
    for i, msg in enumerate(failures[:30], 1):
        print("%3d. %s" % (i, msg))
    if len(failures) > 30:
        print("     ... and %d more" % (len(failures) - 30))
    return 1


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--verify", action="store_true",
                   help="audit the existing JSON against Macula and exit, no network. "
                        "Safe to run before anything else — it quantifies the damage.")
    g.add_argument("--plan", action="store_true",
                   help="print what would be fetched and exit, no network")
    g.add_argument("--repair", action="store_true",
                   help="re-fetch only what is currently wrong: verses with no "
                        "entry, plus verses whose stored words disagree with "
                        "Macula. Cheap — normally a few dozen pages. Run this "
                        "after a full pass to mop up whatever the guard refused.")
    g.add_argument("--missing-only", action="store_true",
                   help="only ORG verses with no entry at all (fixes BUG B)")
    g.add_argument("--fix-only", action="store_true",
                   help="every ORG verse whose page is not simply 'this whole ENG "
                        "verse': shifted, merged (shares its ENG verse), or split "
                        "across pages. Fixes BUG A. Selecting on the shifted flag "
                        "alone missed psalm superscriptions — same verse number, "
                        "but only part of the page belongs to them.")
    g.add_argument("--shifted-only", action="store_true",
                   help="deprecated alias of --fix-only, kept so older notes still run")
    g.add_argument("--all", action="store_true")
    ap.add_argument("--replace-shifted", action="store_true",
                    help="overwrite existing entries; without this, present keys "
                         "are kept and the corrupt values survive")
    ap.add_argument("--book", help="restrict to one OSIS book id")
    ap.add_argument("--limit", type=int, help="stop after N pages (smoke test)")
    args = ap.parse_args()

    print("Loading Macula Strong's...")
    mac = load_macula_strongs()
    print("  ORG verses: %d" % len(mac))

    if args.verify:
        store = load_existing()
        print("JSON entries: %d" % len(store))
        if not store:
            sys.exit("data/hebrew_translit.json is empty or missing — nothing to audit")
        passed, failures = audit(store, mac)
        sys.exit(report(passed, failures))

    vmap = load_map()
    print("Loaded ORG->ENG map: %d rows" % len(vmap))

    store = load_existing()
    print("Existing JSON entries: %d" % len(store))

    # An ENG verse claimed by more than one ORG verse is a merge: none of the
    # sharers may be given the whole page. This is computed from the map rather
    # than from the shifted flag, because a merged superscription keeps its verse
    # number — MT 4:1 -> ENG 4:1 — and so carries no shifted flag while still
    # being wrong in the current JSON.
    eng_claims = defaultdict(set)
    for key, entry in vmap.items():
        for (ec, ev, _o, _l) in entry["segs"]:
            eng_claims[(key[0], ec, ev)].add(key)

    def needs_fix(key, entry):
        if entry["shifted"]:
            return True
        if len(entry["segs"]) > 1:                 # split across pages
            return True
        for (ec, ev, off, _l) in entry["segs"]:
            if off != 0:
                return True
            if len(eng_claims[(key[0], ec, ev)]) > 1:   # shares its page
                return True
        return False

    def stored_words(key):
        base = "%s:%d:%d" % key
        n = store.get("%s:count" % base)
        if not isinstance(n, int):
            return None
        return [store.get("%s:%d" % (base, p)) for p in range(1, n + 1)]

    def is_bad(key):
        """True if this verse has no entry, or its stored words disagree with Macula."""
        ws = stored_words(key)
        if ws is None:
            return True
        return agreement([w for w in ws if w], mac.get(key, [])) < ACCEPT_AGREEMENT

    fix_mode = args.fix_only or args.shifted_only
    targets = []
    unmapped = 0
    for (book, ch, vs) in sorted(mac.keys()):
        if args.book and book != args.book.upper():
            continue
        key = (book, ch, vs)
        mapped = vmap.get(key)
        if not mapped:
            unmapped += 1
            continue
        have = ("%s:%d:%d:count" % (book, ch, vs)) in store
        if args.repair and not is_bad(key):
            continue
        if args.missing_only and have:
            continue
        if fix_mode and not needs_fix(key, mapped):
            continue
        if (have and not args.replace_shifted and not args.missing_only
                and not fix_mode and not args.repair):
            continue
        targets.append((book, ch, vs, mapped["segs"], mapped["shifted"], have))

    # A page shared by two ORG verses is fetched once, so pages < verses.
    pages = {(t[0], s[0], s[1]) for t in targets for s in t[3]}
    multi = sum(1 for t in targets if len(t[3]) > 1)

    print("\nORG verses to rebuild : %d" % len(targets))
    print("  distinct pages to fetch  : %d" % len(pages))
    print("  of which shifted (BUG A) : %d" % sum(1 for t in targets if t[4]))
    print("  of which absent  (BUG B) : %d" % sum(1 for t in targets if not t[5]))
    print("  verses spanning >1 page  : %d" % multi)
    print("  ORG verses with no map row, skipped: %d" % unmapped)
    est = len(pages) * DELAY / 60.0
    print("  estimated wall clock at %.1fs/page: %.0f min" % (DELAY, est))

    if args.plan:
        print("\nFirst 15 planned verses:")
        for t in targets[:15]:
            desc = ", ".join("%d:%d[%d:%d]" % (c, v, o, o + l) for (c, v, o, l) in t[3])
            print("  %s %d:%d  ->  /%s/  %s%s"
                  % (t[0], t[1], t[2], OT_SLUGS[t[0]], desc,
                     "   [SHIFTED]" if t[4] else ""))
        print("\n  notation: eng_ch:eng_vs[start:end] — the slice of that page's")
        print("  word list that belongs to this Masoretic verse.")
        return

    # Who shares each page, in text order. Used to re-derive slice boundaries
    # from the live page instead of trusting BSB's word counts.
    page_claimants = defaultdict(list)
    for key, entry in vmap.items():
        for (ec, ev, off, _l) in entry["segs"]:
            page_claimants[(key[0], ec, ev)].append((off, key))
    for pk in page_claimants:
        page_claimants[pk].sort()

    rejects = []
    done = ok = rejected = failed = marginal = 0
    page_cache = {}          # (book, eng_ch, eng_vs) -> word list, or None if dead
    span_cache = {}          # (book, eng_ch, eng_vs) -> {org_key: (start, end)}
    fetched = 0

    def get_page(book, eng_ch, eng_vs):
        """Fetch and parse one BibleHub page, once. -> (words, error_or_None)"""
        nonlocal fetched
        ck = (book, eng_ch, eng_vs)
        if ck in page_cache:
            return page_cache[ck], (None if page_cache[ck] else "CACHED_FAILURE")
        url = "https://biblehub.com/text/%s/%d-%d.htm" % (OT_SLUGS[book], eng_ch, eng_vs)
        html = fetch(url)
        fetched += 1
        time.sleep(DELAY)
        if not html:
            page_cache[ck] = None
            return None, "FETCH_FAILED"
        raw = parse_hebrew_translit(html)
        if not raw:
            page_cache[ck] = None
            return None, "PARSE_EMPTY"
        words = [as_word(w) for w in raw]      # v1 hands back 3-tuples
        page_cache[ck] = words
        return words, None

    for (book, ch, vs, segs, _shifted, _have) in targets:
        if args.limit and done >= args.limit:
            break
        done += 1
        ref = "%s %d:%d" % (book, ch, vs)
        desc = ",".join("%d:%d" % (c, v) for (c, v, _o, _l) in segs)

        # Gather this ORG verse's words by slicing each segment out of its page.
        collected = []
        err = None
        for (eng_ch, eng_vs, _off, _ln) in segs:
            words, e = get_page(book, eng_ch, eng_vs)
            if e:
                err = e
                break
            pk = (book, eng_ch, eng_vs)
            if pk not in span_cache:
                claimants = page_claimants.get(pk) or [(0, (book, ch, vs))]
                spans = split_page(words, [mac.get(k, []) for (_o, k) in claimants])
                span_cache[pk] = (None if spans is None else
                                  {k: sp for ((_o, k), sp) in zip(claimants, spans)})
            table = span_cache[pk]
            if table is None:
                err = "PAGE_SPLIT_FAILED(%d claimants share this page)" % len(
                    page_claimants.get(pk, []))
                break
            span = table.get((book, ch, vs))
            if span is None:
                err = "NOT_A_CLAIMANT(page %d:%d)" % (eng_ch, eng_vs)
                break
            collected.extend(words[span[0]:span[1]])

        if err:
            failed += 1
            rejects.append((book, ch, vs, desc, "", err, "", ""))
            continue

        agr = agreement(collected, mac.get((book, ch, vs), []))
        if ACCEPT_MARGINAL <= agr < ACCEPT_AGREEMENT:
            # Right verse, one or two lexeme ids differ. Store it — refusing
            # here leaves the verse with no transliteration at all, which is a
            # worse answer than a correct one carrying a known small caveat.
            marginal += 1
            rejects.append((book, ch, vs, desc, "stored anyway",
                            "MARGINAL_ACCEPTED", "%.2f" % agr, ref))
        elif agr < ACCEPT_MARGINAL:
            rejected += 1
            # Refusing to write is only half the job. Whatever is already stored
            # under this key was written by v1 under the wrong verse number, so
            # leaving it in place means "rejected" quietly resolves to "keep
            # showing another verse's transliteration" — which is exactly what
            # happened to nine Psalms verses on 2026-08-04. If the existing
            # entry is no better than what we just refused, purge it so the app
            # falls back to the per-token xlit. A wrong answer removed beats a
            # wrong answer preserved; a *good* existing entry is left alone.
            purged = ""
            if is_bad((book, ch, vs)) and stored_words((book, ch, vs)) is not None:
                base = "%s:%d:%d" % (book, ch, vs)
                n = store.get("%s:count" % base)
                if isinstance(n, int):
                    for p in range(1, n + 1):
                        store.pop("%s:%d" % (base, p), None)
                store.pop("%s:count" % base, None)
                store.pop("%s:eng" % base, None)
                purged = "stale entry purged"
            rejects.append((book, ch, vs, desc, purged, "STRONG_DISAGREEMENT",
                            "%.2f" % agr, ref))
            continue

        key = "%s:%d:%d" % (book, ch, vs)
        # Clear any stale positions from a previous, longer entry before writing.
        old = store.get("%s:count" % key)
        if isinstance(old, int):
            for p in range(1, old + 1):
                store.pop("%s:%d" % (key, p), None)
        for pos, w in enumerate(collected, 1):
            store["%s:%d" % (key, pos)] = {
                "translit": w.get("translit", ""),
                "surface": w.get("surface", ""),
                "strong": w.get("strong", ""),
            }
        store["%s:count" % key] = len(collected)
        store["%s:eng" % key] = desc          # provenance, incl. multi-page verses
        ok += 1

        if done % SAVE_EVERY == 0:
            with open(OUT_JSON, "w", encoding="utf-8") as f:
                json.dump(store, f, ensure_ascii=False)
            print("  verses %d/%d  pages=%d  ok=%d rejected=%d failed=%d"
                  % (done, len(targets), fetched, ok, rejected, failed))

    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(store, f, ensure_ascii=False)

    with open(OUT_REJECT, "w", encoding="utf-8") as f:
        f.write("osis\torg_chapter\torg_verse\teng_segments\t-"
                "\treason\tagreement\tref\n")
        for r in rejects:
            f.write("\t".join(str(x) for x in r) + "\n")

    print("\n─── done ───")
    print("  verses    : %d" % done)
    print("  pages     : %d  (shared pages fetched once)" % fetched)
    print("  stored    : %d" % ok)
    print("  marginal  : %d  (right verse, %.2f..%.2f — stored and flagged)"
          % (marginal, ACCEPT_MARGINAL, ACCEPT_AGREEMENT))
    print("  rejected  : %d  (below %.2f — treated as a different verse, NOT written)"
          % (rejected, ACCEPT_MARGINAL))
    print("  failed    : %d  (network or parse)" % failed)
    print("  json      : %s  (%d entries)" % (OUT_JSON, len(store)))
    print("  rejects   : %s" % OUT_REJECT)
    if rejected:
        print("\n  A non-zero reject count is the validator doing its job, not a")
        print("  failure. Review the file before re-running with a lower threshold.")


if __name__ == "__main__":
    main()
