#!/usr/bin/env python3
"""
fetch_biblehub_translit_hebrew.py
----------------------------------
Scrapes per-slot Hebrew transliterations from BibleHub for all OT verses.
Produces data/hebrew_translit.json keyed by verse-slot position.

Key format:  "{OSIS}:{ch}:{vs}:{display_pos}"  (1-based display word position)
Sentinel:    "{OSIS}:{ch}:{vs}:count"           (word count for ADR-020 validation)

Run once from ~/Projects/SourceBible/:
    python3 scripts/fetch_biblehub_translit_hebrew.py

Quick test (parse Psalm 1:2 from cache, no network):
    python3 scripts/fetch_biblehub_translit_hebrew.py --test

Resumes safely if interrupted — cached HTML in data/bh_cache_hebrew/.
~23,145 OT verses; ~5-6 hours first run, instant on re-run from cache.
"""

import csv, html as html_module, io, json, re, sys, time, zipfile
from pathlib import Path
import urllib.request, urllib.error

ROOT      = Path(__file__).resolve().parent.parent
DATA_DIR  = ROOT / "data"
CACHE_DIR = DATA_DIR / "bh_cache_hebrew"
OUT_FILE  = DATA_DIR / "hebrew_translit.json"
ZIP_PATH  = DATA_DIR / "macula-hebrew-main.zip"
TSV_PATH  = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"

DELAY      = 0.8   # seconds between fetches
SAVE_EVERY = 200   # persist JSON every N pages

HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

OT_SLUGS = {
    "GEN": "genesis",      "EXO": "exodus",       "LEV": "leviticus",
    "NUM": "numbers",      "DEU": "deuteronomy",   "JOS": "joshua",
    "JDG": "judges",       "RUT": "ruth",          "1SA": "1-samuel",
    "2SA": "2-samuel",     "1KI": "1-kings",       "2KI": "2-kings",
    "1CH": "1-chronicles", "2CH": "2-chronicles",  "EZR": "ezra",
    "NEH": "nehemiah",     "EST": "esther",        "JOB": "job",
    "PSA": "psalms",       "PRO": "proverbs",      "ECC": "ecclesiastes",
    "SNG": "songs",        "ISA": "isaiah",        "JER": "jeremiah",
    "LAM": "lamentations", "EZK": "ezekiel",       "DAN": "daniel",
    "HOS": "hosea",        "JOL": "joel",          "AMO": "amos",
    "OBA": "obadiah",      "JON": "jonah",         "MIC": "micah",
    "NAM": "nahum",        "HAB": "habakkuk",      "ZEP": "zephaniah",
    "HAG": "haggai",       "ZEC": "zechariah",     "MAL": "malachi",
}

# Matches all characters BibleHub uses in Hebrew transliterations.
# Ranges (non-raw string so \u escapes are processed by Python):
#   À-˿     U+00C0-U+02FF  Latin Extended A/B + IPA Extensions + Spacing Modifier Letters
#                           Covers ā ē ī ō ū ə (schwa) and IPA ʾ/ʿ modifier letters
#   Ḁ-ỿ     U+1E00-U+1EFF  Latin Extended Additional: ḥ ṭ ṣ ḇ ṯ ḏ ḵ ḡ etc.
#   ̀-ͯ     U+0300-U+036F  Combining Diacritical Marks (macron, dot-below, etc.)
#   ‘  U+2018  LEFT SINGLE QUOTATION MARK ' — BibleHub uses for ʿ (ayin)
#   ’  U+2019  RIGHT SINGLE QUOTATION MARK ' — BibleHub uses for ʾ (aleph)
TRANSLIT_RE = re.compile("[A-Za-z\xc0-˿Ḁ-ỿ̀-ͯ‘’'\\- ]+")


# ─── HTML parser ──────────────────────────────────────────────────────────────

def parse_hebrew_translit(html):
    """
    Parse a BibleHub Hebrew text analysis page.
    Returns list of (heb_surface, translit, strong_num_str) in document order.

    Includes [e] words (no Strong's assigned by BH) — strong_num_str = "" for those.
    These words are non-clickable in the UI but must be present for correct slot alignment.

    BibleHub HTML structure per word row (all pages, confirmed from live inspection):

      Strong's column (strongsnt td):
        Normal:  <a href="/hebrew/3588.htm" title="Strong's Hebrew 3588: ...">3588</a>
        [e] word: href="/hebrew/.htm" with empty anchor text — no number assigned

      Hebrew column (hebrew2 td):
        <td class="hebrew2">כִּי<br>
          <span class="translit">
            <a href="/hebrew/ki_3588.htm" title="kî: But.">kî</a>
          </span>
        </td>
        [e] word: href="/hebrew/" (no word slug) — but translit anchor text is still present

    <span class="translit"> is the universal row indicator — present on every word row
    including [e] rows. Used as the row filter to avoid nav/header rows.

    Truncate at "Parallel Strong" section to prevent double-counting.
    """
    results = []

    # Truncate at parallel section (repeats word links → duplicates)
    cutoff = html.find("Parallel Strong")
    if cutoff == -1:
        cutoff = html.find(">Parallel<")
    body = html[:cutoff] if cutoff > 0 else html

    row_re = re.compile(r'<tr\b[^>]*>(.*?)</tr>', re.DOTALL | re.IGNORECASE)

    for row_m in row_re.finditer(body):
        row = row_m.group(1)

        # Universal row filter: every word row has <span class="translit">
        if 'class="translit"' not in row and "class='translit'" not in row:
            continue

        # ── Transliteration from <span class="translit"> anchor text ──────────
        span_m = re.search(
            r'<span\s+class=["\']translit["\'][^>]*>(.*?)</span>',
            row, re.IGNORECASE | re.DOTALL,
        )
        if not span_m:
            continue
        inner = re.sub(r'<[^>]+>', '', span_m.group(1))
        translit_raw = html_module.unescape(re.sub(r'[\r\n\t]+', '', inner).strip())
        m = TRANSLIT_RE.search(translit_raw)
        translit = m.group(0).strip() if m else ""
        if not translit:
            continue

        # ── Hebrew surface from hebrew2 td (text before the <br>) ─────────────
        heb_m = re.search(
            r'class=["\']hebrew2["\'][^>]*>(.*?)<br',
            row, re.IGNORECASE | re.DOTALL,
        )
        if heb_m:
            heb = html_module.unescape(re.sub(r'<[^>]+>', '', heb_m.group(1)).strip())
        else:
            # Fallback for legacy class="hb" format
            hb_m = re.search(r'class=["\']hb["\'][^>]*>([^<]+)<', row)
            heb = hb_m.group(1).strip() if hb_m else ""

        # ── Strong's number: canonical link title="Strong's Hebrew NNNN" ──────
        # [e] words have no such link → strong = "" (non-clickable in UI)
        canon_m = re.search(
            r'href=["\'][^"\']*?/hebrew/(\d+)\.htm["\'][^>]*title=["\']Strong\'s Hebrew',
            row, re.IGNORECASE,
        )
        strong = canon_m.group(1) if canon_m else ""

        results.append((heb, translit, strong))

    return results


# ─── Network ──────────────────────────────────────────────────────────────────

def fetch(url):
    """Fetch with retry + exponential backoff on 429/503."""
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            return urllib.request.urlopen(req, timeout=20).read().decode("utf-8")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return ""
            print("  HTTP %d (attempt %d): %s" % (e.code, attempt + 1, url), file=sys.stderr)
            wait = DELAY * (5 if e.code in (429, 503) else 2) * (attempt + 1)
            time.sleep(wait)
        except Exception as e:
            print("  Error %s (attempt %d): %s" % (e, attempt + 1, url), file=sys.stderr)
            time.sleep(DELAY * 2)
    return None


# ─── Verse refs from Macula Hebrew TSV ────────────────────────────────────────

def get_verse_refs():
    """Return list of (book_osis, chapter, verse) for all OT verses in Macula Hebrew TSV."""
    refs, seen = [], set()
    with zipfile.ZipFile(ZIP_PATH) as zf:
        with zf.open(TSV_PATH) as f:
            reader = csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t")
            for row in reader:
                ref_raw = row.get("ref", "").strip()
                m = re.match(r'^(\S+)\s+(\d+):(\d+)', ref_raw)
                if not m:
                    continue
                book = m.group(1).upper()
                if book not in OT_SLUGS:
                    continue
                ch = int(m.group(2))
                vs = int(m.group(3))
                key = "%s:%d:%d" % (book, ch, vs)
                if key in seen:
                    continue
                seen.add(key)
                refs.append((book, ch, vs))
    return refs


# ─── Main ─────────────────────────────────────────────────────────────────────

def run_test():
    """
    Sanity-check parser against verses across different book types.
    Fetches from BibleHub if not cached; prints all words for visual inspection.

    exp_count = 0  → skip count check (visual inspection only)
    anch_slot = 0  → skip anchor check
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # (book_osis, ch, vs, slug, expected_count, anchor_slot_1based, anchor_strong, anchor_substr)
    # anchor_substr: ASCII-safe substring expected in the translit (empty = skip translit check)
    tests = [
        # ── Round 1: original 7 ────────────────────────────────────────────────
        ("PSA",  1,  2, "psalms",       9, 5, "2656", "ep"),     # ḥep̄-ṣōw
        ("GEN",  1,  1, "genesis",      7, 3, "430",  ""),       # ĕ-lō-hîm
        ("DEU",  6,  4, "deuteronomy",  6, 1, "8085", "ma"),     # šə-maʿ
        ("PRO",  3,  5, "proverbs",     9, 3, "3068", "ah"),     # Yah-weh
        ("ISA", 40,  8, "isaiah",       8, 7, "6965", ""),       # yā-qūm
        ("JON",  1,  1, "jonah",        8, 3, "3068", "ah"),     # Yah-weh
        ("PSA", 23,  1, "psalms",       6, 4, "7462", ""),       # rō-ʿî
        # ── Round 2: 7 more — Law/Writings/Prophets/Wisdom/Minor ──────────────
        ("EXO", 20,  2, "exodus",       0, 0, "",     ""),       # Ten Commandments preamble
        ("LEV", 19, 18, "leviticus",    0, 0, "",     ""),       # love your neighbour
        ("JOB", 38,  4, "job",          0, 0, "",     ""),       # where were you?
        ("ZEC",  9,  9, "zechariah",    0, 0, "",     ""),       # Palm Sunday
        ("RUT",  1, 16, "ruth",         0, 0, "",     ""),       # where you go I will go
        ("JER", 29, 11, "jeremiah",     0, 0, "",     ""),       # plans for peace
        ("MAL",  3, 10, "malachi",      0, 0, "",     ""),       # bring the full tithe
    ]

    passed = failed = 0

    for (book, ch, vs, slug, exp_count, anch_slot, anch_strong, anch_substr) in tests:
        label = "%s %d:%d" % (book, ch, vs)
        cache_file = CACHE_DIR / ("%s_%d_%d.html" % (book, ch, vs))

        if not cache_file.exists():
            url  = "https://biblehub.com/text/%s/%d-%d.htm" % (slug, ch, vs)
            sys.stdout.write("Fetching %-14s ... " % label)
            sys.stdout.flush()
            html = fetch(url)
            if not html:
                print("FETCH FAILED")
                failed += 1
                continue
            cache_file.write_text(html, "utf-8")
            time.sleep(DELAY)
        else:
            html = cache_file.read_text("utf-8")

        words = parse_hebrew_translit(html)
        count_ok    = (exp_count == 0) or (len(words) == exp_count)
        anch_word   = words[anch_slot - 1] if anch_slot > 0 and len(words) >= anch_slot else None
        strong_ok   = (not anch_strong) or (anch_word and anch_word[2] == anch_strong)
        translit_ok = (not anch_substr) or (anch_word and anch_substr in anch_word[1])
        ok = count_ok and strong_ok and translit_ok

        status = "✓" if ok else "✗"
        if ok:
            passed += 1
        else:
            failed += 1

        print("\n%s %s  (%d words%s)" % (
            status, label, len(words),
            "" if count_ok else "  ← expected %d" % exp_count
        ))
        for i, (heb, translit, strong) in enumerate(words, 1):
            anchor_marker = " ←" if anch_slot > 0 and i == anch_slot else ""
            print("  %2d. %-30s  H%-6s%s" % (i, translit, strong, anchor_marker))

    print("\n%d/%d passed" % (passed, passed + failed))


def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    translit = {}
    if OUT_FILE.exists():
        translit = json.loads(OUT_FILE.read_text("utf-8"))
        print("Loaded %d existing entries from %s" % (len(translit), OUT_FILE.name))

    refs  = get_verse_refs()
    total = len(refs)
    print("OT verses to process: %d" % total)

    fetched = errors = skipped = 0

    for i, (book, ch, vs) in enumerate(refs, 1):
        cache_file = CACHE_DIR / ("%s_%d_%d.html" % (book, ch, vs))

        if cache_file.exists():
            html = cache_file.read_text("utf-8")
            skipped += 1
        else:
            slug = OT_SLUGS[book]
            url  = "https://biblehub.com/text/%s/%d-%d.htm" % (slug, ch, vs)
            html = fetch(url)
            if html is None:
                errors += 1
                time.sleep(DELAY * 3)
                continue
            cache_file.write_text(html, "utf-8")
            fetched += 1
            time.sleep(DELAY)

        words = parse_hebrew_translit(html)
        if not words:
            continue

        # Store positional entries
        for pos, (heb, t, strong) in enumerate(words, 1):
            key = "%s:%d:%d:%d" % (book, ch, vs, pos)
            translit[key] = {"translit": t, "surface": heb, "strong": strong}

        # Count sentinel for ADR-020 validation
        translit["%s:%d:%d:count" % (book, ch, vs)] = len(words)

        if i % SAVE_EVERY == 0 or i == total:
            OUT_FILE.write_text(
                json.dumps(translit, ensure_ascii=False, indent=2), "utf-8"
            )
            print("  [%5d/%d  %4.1f%%]  fetched=%d cached=%d errors=%d entries=%d" % (
                i, total, i / total * 100, fetched, skipped, errors, len(translit)
            ))

    OUT_FILE.write_text(json.dumps(translit, ensure_ascii=False, indent=2), "utf-8")
    print("\nDone. %d entries -> %s" % (len(translit), OUT_FILE))


if __name__ == "__main__":
    if "--test" in sys.argv:
        run_test()
    else:
        main()
