#!/usr/bin/env python3
"""
test_morphology_biblehub.py
Compares POS labels decoded by the app against BibleHub morphology reference data.

Usage
-----
# Run all tests (uses morphology_reference.json if present, falls back to inline data)
python3 scripts/test_morphology_biblehub.py

# Fetch reference data for 10 NT + 10 OT verses and save to JSON, then run tests
python3 scripts/test_morphology_biblehub.py --seed

# Re-fetch a single verse and update the JSON
python3 scripts/test_morphology_biblehub.py --fetch REV.14.1

# Run only specific verses
python3 scripts/test_morphology_biblehub.py --verse JHN.3.16 GEN.1.1

Notes
-----
- Must run on Mac — DB is APFS sparse, Linux sandbox reads it as corrupt.
- Matching uses Strong's-ID sequential alignment, not raw position, so Hebrew
  prefix segmentation differences between Macula and BibleHub don't cause false
  failures: only words that share a Strong's ID are compared.
- Hebrew BibleHub morphs can be pipe-joined ("Prep-b | N-fs"); we use the LAST
  segment (the lexical word) as the canonical POS, ignoring attached prefixes.
"""

import json
import re
import sqlite3
import sys
import urllib.request
import html as html_module
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional, List, Tuple, Dict

# ── Paths ──────────────────────────────────────────────────────────────────────
DB_PATH  = Path(__file__).parent.parent / "SourceBible/Resources/sourcebible.db"
REF_JSON = Path(__file__).parent / "morphology_reference.json"

# ── Verse list for --seed ──────────────────────────────────────────────────────
SEED_VERSES: List[str] = [
    # NT — Greek (10 verses, chosen for POS diversity)
    "JHN.1.1",    # In the beginning was the Word — noun, verb, prep, art, conj
    "JHN.3.16",   # For God so loved — adverb (οὕτως), relative pronoun (ὥστε)
    "MAT.5.3",    # Blessed are the poor — adjective, relative pronoun
    "ROM.8.28",   # All things work together — particle (δέ), adverb
    "GAL.5.22",   # Fruit of the Spirit — noun list
    "ACT.2.38",   # Peter's sermon — particle (οὖν), imperative verbs
    "LUK.2.11",   # Born this day a Savior — various
    "1CO.13.4",   # Love is patient — long verb forms
    "HEB.11.1",   # Faith is the substance — noun-heavy
    "PHP.4.13",   # I can do all things — variety
    # OT — Hebrew (10 verses, chosen for POS diversity)
    "GEN.1.1",    # In the beginning — prep, noun, verb, direct-object marker
    "GEN.1.3",    # Let there be light — imperative verb
    "PSA.23.1",   # The LORD is my shepherd — pronoun suffix, noun
    "PSA.1.1",    # Blessed is the man — adjective, participle
    "PRO.3.5",    # Trust in the LORD — imperative, preposition
    "ISA.40.31",  # Renew their strength — various verb stems
    "ISA.53.5",   # He was wounded — passive verbs
    "DEU.6.4",    # Shema — particle, adjective
    "EXO.20.3",   # No other gods — negative particle
    "JER.29.11",  # Plans to prosper — various
]

# ── OSIS book ID → BibleHub URL slug ──────────────────────────────────────────
OSIS_TO_BH_BOOK: Dict[str, str] = {
    "GEN": "genesis",        "EXO": "exodus",         "LEV": "leviticus",
    "NUM": "numbers",        "DEU": "deuteronomy",    "JOS": "joshua",
    "JDG": "judges",         "RUT": "ruth",           "1SA": "1_samuel",
    "2SA": "2_samuel",       "1KI": "1_kings",        "2KI": "2_kings",
    "1CH": "1_chronicles",   "2CH": "2_chronicles",   "EZR": "ezra",
    "NEH": "nehemiah",       "EST": "esther",         "JOB": "job",
    "PSA": "psalms",         "PRO": "proverbs",       "ECC": "ecclesiastes",
    "SNG": "songs",          "ISA": "isaiah",         "JER": "jeremiah",
    "LAM": "lamentations",   "EZK": "ezekiel",        "DAN": "daniel",
    "HOS": "hosea",          "JOL": "joel",           "AMO": "amos",
    "OBA": "obadiah",        "JON": "jonah",          "MIC": "micah",
    "NAM": "nahum",          "HAB": "habakkuk",       "ZEP": "zephaniah",
    "HAG": "haggai",         "ZEC": "zechariah",      "MAL": "malachi",
    "MAT": "matthew",        "MRK": "mark",           "LUK": "luke",
    "JHN": "john",           "ACT": "acts",           "ROM": "romans",
    "1CO": "1_corinthians",  "2CO": "2_corinthians",  "GAL": "galatians",
    "EPH": "ephesians",      "PHP": "philippians",    "COL": "colossians",
    "1TH": "1_thessalonians","2TH": "2_thessalonians","1TI": "1_timothy",
    "2TI": "2_timothy",      "TIT": "titus",          "PHM": "philemon",
    "HEB": "hebrews",        "JAS": "james",          "1PE": "1_peter",
    "2PE": "2_peter",        "1JN": "1_john",         "2JN": "2_john",
    "3JN": "3_john",         "JUD": "jude",           "REV": "revelation",
}

# ── BibleHub morphology → canonical POS ───────────────────────────────────────
# For Hebrew, BibleHub uses "Prep-b | N-fs" style — we take the LAST segment
# (the lexical word class) and map its first dash-token.
BH_FIRST_TOKEN_TO_POS: Dict[str, str] = {
    "Conj":     "Conjunction",
    "Prep":     "Preposition",
    "N":        "Noun",
    "V":        "Verb",
    "Art":      "Article",
    "Adj":      "Adjective",
    "Adv":      "Adverb",
    "Ptcl":     "Particle",
    "PPro":     "Pronoun",
    "DPro":     "Pronoun",
    "RPro":     "Pronoun",
    "IPro":     "Pronoun",
    "INJ":      "Interjection",
    "DirObjM":  "Particle",   # Hebrew direct-object marker — closest bucket
    "PrtNeg":   "Particle",   # Hebrew negative particle
}


def bh_morph_to_pos(bh_morph: str) -> Optional[str]:
    """
    Convert a BibleHub morphology code to a canonical POS name.

    Greek examples:  "Prep", "N-GMS", "PPro-GM3S", "V-AIA-1S"
    Hebrew examples: "V-Qal-Perf-3ms", "N-mp", "Prep-b | N-fs", "DirObjM"

    For pipe-joined Hebrew codes we take the LAST segment (the lexical word).
    """
    # Hebrew: take last pipe-segment (ignore prefix codes like "Prep-b | ...")
    last_seg = bh_morph.split("|")[-1].strip()
    # First dash-token of that segment
    first_token = last_seg.split("-")[0].strip()
    pos = BH_FIRST_TOKEN_TO_POS.get(first_token)
    if pos:
        return pos
    # Fallback: if it starts with a known prefix we don't handle explicitly
    for key, val in BH_FIRST_TOKEN_TO_POS.items():
        if first_token.startswith(key):
            return val
    return None  # unknown — skip this word in comparison


# ── MorphologyDecoder.decode() ported from Swift ──────────────────────────────
# Keep in sync with WordTabContent.swift → MorphologyDecoder

LEXICAL_CLASS_POS: Dict[str, str] = {
    "verb":  "Verb",
    "adj":   "Adjective",
    "adv":   "Adverb",
    "prep":  "Preposition",
    "cj":    "Conjunction",
    "conj":  "Conjunction",
    "pron":  "Pronoun",
    "ij":    "Interjection",
    "intj":  "Interjection",
    "art":   "Article",
    "ptcl":  "Particle",
    "rel":   "Relative Pronoun",
    "det":   "Article",
    "num":   "Adjective",
    # "om", "x" → None (no display label)
}

GREEK_POS: Dict[str, str] = {
    "N":    "Noun",
    "V":    "Verb",
    "A":    "Adjective",
    "P":    "Preposition",   # single "P" in Greek decoder = Preposition
    "ADV":  "Adverb",
    "CONJ": "Conjunction",
    "PRON": "Pronoun",
    "ART":  "Article",
    "PART": "Particle",
    "INJ":  "Interjection",
}

HEBREW_POS: Dict[str, str] = {
    "N": "Noun",
    "V": "Verb",
    "A": "Adjective",
    "T": "Particle",
    "R": "Preposition",
    "C": "Conjunction",
    "P": "Pronoun",      # "P" in Hebrew decoder = Pronoun (differs from Greek!)
    "D": "Adverb",
    "I": "Interjection",
    "S": "Pronominal Suffix",
}


def _decode_greek(code: str) -> Optional[str]:
    first = code.split("-")[0].upper()
    return GREEK_POS.get(first)


def _decode_hebrew(code: str) -> Optional[str]:
    return HEBREW_POS.get(code[0]) if code else None


def app_decode(morph: Optional[str], lexical_class: Optional[str]) -> Optional[str]:
    """
    Port of MorphologyDecoder.decode(morph, lexicalClass:) from Swift.
    lexical_class is authoritative — applied as override after morph decode.
    This reflects the fix for the G3326/G846 swap bug.
    """
    if not morph:
        return None
    morph_result = _decode_greek(morph) if "-" in morph else _decode_hebrew(morph)
    if lexical_class:
        cls_pos = LEXICAL_CLASS_POS.get(lexical_class)
        if cls_pos:
            return cls_pos
    return morph_result


# ── BibleHub scraper ──────────────────────────────────────────────────────────

class BHTableParser(HTMLParser):
    """
    Pulls (strongs_id, surface, bh_morph) rows from a BibleHub text analysis page.
    Handles both Greek (/greek/NNN) and Hebrew (/hebrew/NNN) Strong's URL patterns.
    """

    def __init__(self):
        super().__init__()
        self._in_td    = False
        self._td_index = 0   # 0=Strong's col, 1=surface col, 2=English col, 3=morph col
        self._td_buf   = ""
        self._in_anchor   = False
        self._cur_strong  = None
        self._cur_surface = None
        self._rows: List[Tuple[str, str, str]] = []

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._td_index = 0
            self._cur_strong = self._cur_surface = None
        elif tag == "td":
            self._in_td     = True
            self._td_buf    = ""
            self._in_anchor = False
        elif tag == "a" and self._in_td:
            self._in_anchor = True
            if self._td_index == 0:
                href = dict(attrs).get("href", "")
                m = re.search(r"/(greek|hebrew)/(\d+)", href)
                if m:
                    prefix = "G" if m.group(1) == "greek" else "H"
                    self._cur_strong = f"{prefix}{m.group(2)}"

    def handle_endtag(self, tag):
        if tag == "a":
            self._in_anchor = False
            return
        if tag != "td" or not self._in_td:
            return
        text = html_module.unescape(self._td_buf).strip()
        if self._td_index == 1:
            self._cur_surface = text.strip()
        elif self._td_index == 3:
            bh_morph = text.strip()
            if self._cur_strong and self._cur_surface and bh_morph:
                self._rows.append((self._cur_strong, self._cur_surface, bh_morph))
        self._td_index += 1
        self._in_td = False

    def handle_data(self, data):
        if not self._in_td:
            return
        # Column 1 (surface): skip anchor text — it's the transliteration link.
        # Column 3 (morphology): keep anchor text — the code IS the link text.
        if self._td_index == 1 and self._in_anchor:
            return
        self._td_buf += data

    @property
    def rows(self) -> List[Tuple[str, str, str]]:
        return self._rows


def fetch_biblehub(verse_key: str) -> List[Tuple[str, str, str]]:
    """Fetch and parse a BibleHub text analysis page. verse_key = 'REV.14.1'"""
    parts = verse_key.split(".")
    if len(parts) != 3:
        raise ValueError(f"verse_key must be BOOK.CH.V, got {verse_key!r}")
    book, ch, v = parts
    slug = OSIS_TO_BH_BOOK.get(book.upper())
    if not slug:
        raise ValueError(f"Unknown book OSIS ID: {book!r}")
    url = f"https://biblehub.com/text/{slug}/{ch}-{v}.htm"
    print(f"  → {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read().decode("utf-8", errors="replace")
    parser = BHTableParser()
    parser.feed(body)
    if not parser.rows:
        print(f"    WARNING: no rows parsed — page structure may have changed")
    return parser.rows


# ── Reference data (inline fallback) ─────────────────────────────────────────
# Only REV.14.1 is hardcoded — the known-bug verse.
# Run --seed to populate morphology_reference.json for the full 20-verse suite.

INLINE_REFERENCE: Dict[str, List[Tuple[str, str, str]]] = {
    "REV.14.1": [
        ("G2532", "Καὶ",           "Conj"),
        ("G3708", "εἶδον",         "V-AIA-1S"),
        ("G2532", "καὶ",           "Conj"),
        ("G3708", "ἰδοὺ",          "V-AMA-2S"),
        ("G3588", "τὸ",            "Art-NNS"),
        ("G721",  "Ἀρνίον",        "N-NNS"),
        ("G2476", "ἑστὸς",         "V-RPA-NNS"),
        ("G1909", "ἐπὶ",           "Prep"),
        ("G3588", "τὸ",            "Art-ANS"),
        ("G3735", "ὄρος",          "N-ANS"),
        ("G4622", "Σιών",          "N-GFS"),
        ("G2532", "καὶ",           "Conj"),
        ("G3326", "μετ'",          "Prep"),
        ("G846",  "αὐτοῦ",         "PPro-GM3S"),
        ("G1540", "ἑκατὸν",        "Adj-NFP"),
        ("G5062", "τεσσεράκοντα",  "Adj-NFP"),
        ("G5064", "τέσσαρες",      "Adj-NFP"),
        ("G5505", "χιλιάδες",      "N-NFP"),
        ("G2192", "ἔχουσαι",       "V-PPA-NFP"),
        ("G3588", "τὸ",            "Art-ANS"),
        ("G3686", "ὄνομα",         "N-ANS"),
        ("G846",  "αὐτοῦ",         "PPro-GM3S"),
        ("G2532", "καὶ",           "Conj"),
        ("G3588", "τὸ",            "Art-ANS"),
        ("G3686", "ὄνομα",         "N-ANS"),
        ("G3588", "τοῦ",           "Art-GMS"),
        ("G3962", "Πατρὸς",        "N-GMS"),
        ("G846",  "αὐτοῦ",         "PPro-GM3S"),
        ("G1125", "γεγραμμένον",   "V-RPM/P-ANS"),
        ("G1909", "ἐπὶ",           "Prep"),
        ("G3588", "τῶν",           "Art-GNP"),
        ("G3359", "μετώπων",       "N-GNP"),
        ("G846",  "αὐτῶν",         "PPro-GM3P"),
    ],
}


def load_reference() -> Dict[str, List[Tuple[str, str, str]]]:
    """Load reference data: JSON if present, otherwise inline fallback."""
    if REF_JSON.exists():
        with open(REF_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        # JSON stores lists-of-lists; convert to lists-of-tuples
        return {k: [tuple(row) for row in rows] for k, rows in data.items()}
    return dict(INLINE_REFERENCE)


def save_reference(data: Dict[str, List[Tuple[str, str, str]]]) -> None:
    with open(REF_JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"Saved {len(data)} verses to {REF_JSON}")


# ── Matching ──────────────────────────────────────────────────────────────────

def align_by_strongs(
    bh_rows: List[Tuple[str, str, str]],
    db_rows: List[Tuple]
) -> List[Tuple[str, str, str, str, str]]:
    """
    Align BibleHub words to DB words by Sequential Strong's ID matching.

    Why: Hebrew Macula splits prefixes into separate rows (e.g. the prep prefix
    בְּ is its own entry), so word counts between BH and DB differ. Matching
    only rows that share a Strong's ID keeps the comparison sound.

    Returns list of (strong_id, surface, expected_pos, app_pos, db_morph_info)
    for every matched pair.
    """
    # Build ordered list of (strong_id, morph, lexical_class) from DB
    # skipping rows with no Strong's ID (prefix-only entries)
    db_words = [
        (row[0], row[1] or "", row[2])   # (strongs_id, morph, lexical_class)
        for row in db_rows
        if row[0]  # strongs_id not null
    ]

    results = []
    db_idx = 0

    for bh_strong, bh_surface, bh_morph in bh_rows:
        expected_pos = bh_morph_to_pos(bh_morph)
        if expected_pos is None:
            # Unknown POS code — skip (e.g. rare BH codes we don't map)
            continue

        # Advance db_idx until we find a matching Strong's
        matched = False
        for i in range(db_idx, len(db_words)):
            db_strong, db_morph, db_class = db_words[i]
            if db_strong == bh_strong:
                app_pos = app_decode(db_morph, db_class) or "—"
                debug = f"morph={db_morph!r} class={db_class!r}"
                results.append((bh_strong, bh_surface, expected_pos, app_pos, debug))
                db_idx = i + 1
                matched = True
                break

        if not matched:
            # BH word not found in DB — record as missing
            results.append((bh_strong, bh_surface, expected_pos, "MISSING", ""))

    return results


# ── Test runner ───────────────────────────────────────────────────────────────

def run_tests(verse_keys: Optional[List[str]] = None) -> None:
    if not DB_PATH.exists():
        print(f"ERROR: DB not found at {DB_PATH}")
        print("Run this script from the project root on Mac.")
        sys.exit(1)

    reference = load_reference()
    keys = verse_keys or sorted(reference.keys())
    if not keys:
        print("No test data. Run --seed first.")
        sys.exit(1)

    con = sqlite3.connect(str(DB_PATH))
    total = passed = skipped = 0

    for verse_key in keys:
        if verse_key not in reference:
            print(f"\n  {verse_key}: no reference data (run --fetch {verse_key})")
            continue

        bh_rows = reference[verse_key]
        book_id, ch_str, v_str = verse_key.split(".")
        ch, v = int(ch_str), int(v_str)

        db_rows = con.execute("""
            SELECT strongs_id, morph, lexical_class, surface
            FROM word
            WHERE book_id = ? AND chapter = ? AND verse = ?
            ORDER BY position
        """, (book_id, ch, v)).fetchall()

        print(f"\n{'='*66}")
        print(f"  {verse_key}  (BH: {len(bh_rows)} words, DB: {len(db_rows)} rows)")
        print(f"{'='*66}")

        if not db_rows:
            print(f"  ERROR: no rows in DB (book not imported?)")
            total += 1
            continue

        aligned = align_by_strongs(bh_rows, db_rows)

        for strong, surface, expected, app_pos, debug in aligned:
            if app_pos == "MISSING":
                print(f"  [?] MISSING  {surface:<22} {strong:<8}  expected={expected}")
                skipped += 1
                continue
            total += 1
            ok = app_pos.lower() == expected.lower()
            if ok:
                passed += 1
                print(f"  [✓] {surface:<24} {strong:<8}  {expected}")
            else:
                print(f"  [✗] {surface:<24} {strong:<8}"
                      f"  expected={expected:<16} got={app_pos:<16}  {debug}")

    con.close()
    print(f"\n{'='*66}")
    print(f"  {passed}/{total} passed"
          + (f"  ({skipped} skipped — Strong's not found in DB)" if skipped else ""))
    if passed < total:
        sys.exit(1)


# ── Seed / fetch commands ─────────────────────────────────────────────────────

def cmd_seed() -> None:
    """Fetch all SEED_VERSES from BibleHub and save to morphology_reference.json."""
    # Start from existing JSON so --seed is additive (won't lose other verses)
    data: Dict[str, List] = {}
    if REF_JSON.exists():
        with open(REF_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)

    print(f"Fetching {len(SEED_VERSES)} verses from BibleHub…\n")
    ok = failed = 0
    for verse_key in SEED_VERSES:
        print(f"[{ok+failed+1:2d}/{len(SEED_VERSES)}] {verse_key}")
        try:
            rows = fetch_biblehub(verse_key)
            if rows:
                data[verse_key] = rows
                print(f"       {len(rows)} words")
                ok += 1
            else:
                print(f"       SKIPPED (0 rows)")
                failed += 1
        except Exception as e:
            print(f"       ERROR: {e}")
            failed += 1

    save_reference(data)
    print(f"\nDone: {ok} fetched, {failed} failed.")
    print("Run tests now? python3 scripts/test_morphology_biblehub.py")


def cmd_fetch(verse_key: str) -> None:
    """Re-fetch a single verse and update morphology_reference.json."""
    data: Dict[str, List] = {}
    if REF_JSON.exists():
        with open(REF_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
    print(f"Fetching {verse_key}…")
    rows = fetch_biblehub(verse_key)
    if rows:
        data[verse_key] = rows
        save_reference(data)
        print(f"Updated {verse_key} ({len(rows)} words).")
    else:
        print("No rows parsed — not saved.")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    args = sys.argv[1:]

    if not args:
        run_tests()
    elif args[0] == "--seed":
        cmd_seed()
        run_tests()
    elif args[0] == "--fetch":
        if len(args) < 2:
            print("Usage: --fetch BOOK.CH.V")
            sys.exit(1)
        cmd_fetch(args[1])
    elif args[0] == "--verse":
        run_tests(args[1:])
    else:
        print(__doc__)
        sys.exit(1)
