#!/usr/bin/env python3
"""
fetch_biblehub_translit.py
--------------------------
Scrapes per-form Greek transliterations from BibleHub for all NT verses.
Produces data/greek_translit.json: { normalized_form: transliteration }

Run once from ~/Projects/SourceBible/:
    python3 scripts/fetch_biblehub_translit.py

Resumes safely if interrupted -- already-fetched pages are cached in
data/bh_cache/ so you never re-fetch a completed verse.
All 7,943 pages are already cached; re-run just re-parses them instantly.
"""

import csv, io, json, re, sys, time, unicodedata, zipfile
from pathlib import Path
import urllib.request, urllib.error

ROOT      = Path(__file__).resolve().parent.parent
DATA_DIR  = ROOT / "data"
CACHE_DIR = DATA_DIR / "bh_cache"
OUT_FILE  = DATA_DIR / "greek_translit.json"
ZIP_PATH  = DATA_DIR / "macula-greek-main.zip"
TSV_PATH  = "macula-greek-main/Nestle1904/tsv/macula-greek-Nestle1904.tsv"

DELAY = 0.6

BOOK_SLUGS = {
    "MAT": "matthew",      "MRK": "mark",          "LUK": "luke",
    "JHN": "john",         "ACT": "acts",           "ROM": "romans",
    "1CO": "1-corinthians","2CO": "2-corinthians",  "GAL": "galatians",
    "EPH": "ephesians",    "PHP": "philippians",    "COL": "colossians",
    "1TH": "1-thessalonians","2TH":"2-thessalonians","1TI":"1-timothy",
    "2TI": "2-timothy",    "TIT": "titus",          "PHM": "philemon",
    "HEB": "hebrews",      "JAS": "james",          "1PE": "1-peter",
    "2PE": "2-peter",      "1JN": "1-john",         "2JN": "2-john",
    "3JN": "3-john",       "JUD": "jude",           "REV": "revelation",
}

HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

GREEK_RE = re.compile(r"[Ͱ-Ͽἀ-῿]")


def normalize_key(s):
    """
    Normalize a Greek surface form for use as a lookup key:
    1. Strip all non-Greek chars from both ends (brackets, *, apostrophes, etc.)
    2. Convert varia (grave U+0300) → oxia (acute U+0301) so BibleHub contextual
       forms (γὰρ) match Macula normalized forms (γάρ).
    """
    s = s.strip()
    while s and not GREEK_RE.match(s[0]):
        s = s[1:]
    while s and not GREEK_RE.match(s[-1]):
        s = s[:-1]
    # grave → acute: NFD decompose, swap combining chars, recompose NFC
    nfd = unicodedata.normalize('NFD', s)
    nfd = nfd.replace('̀', '́')   # combining grave → combining acute
    return unicodedata.normalize('NFC', nfd)


def parse_translit(html):
    """
    BibleHub actual HTML structure per word row:
      <td class="greek2" valign="top">ἀρχῇ<br />
        <span class="translit"><a href="/greek/arche__746.htm" title="archē: beginning.">archē</a>
      </td>
    Greek text is before <br/>, transliteration is the link text.
    Capture everything before <br/> with [^<]* to handle all bracket/marker variants:
      [οὖν], ‹γὰρ›, λέγοντες*, μετ’, (σχολάζοντα), {καὶ, etc.
    normalize_key strips non-Greek chars from both ends.
    """
    pattern = re.compile(
        r"class=\"greek2\"[^>]*>"
        r"([^<]*?)"
        r"<br\s*/?>"
        r".*?"
        r"href=\"/greek/[^\"]+\"[^>]*>"
        r"([A-Za-zāēīōūȳ’’ ]+)"
        r"</a>",
        re.UNICODE | re.DOTALL,
    )
    result = {}
    for greek_raw, translit in pattern.findall(html):
        key = normalize_key(greek_raw)
        translit = translit.strip()
        if key and translit and GREEK_RE.search(key):
            result[key] = translit
    return result


def fetch(url):
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        return urllib.request.urlopen(req, timeout=15).read().decode("utf-8")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return ""
        print("  HTTP %d: %s" % (e.code, url), file=sys.stderr)
        return None
    except Exception as e:
        print("  Error %s: %s" % (e, url), file=sys.stderr)
        return None


def get_verse_refs():
    refs, seen = [], set()
    with zipfile.ZipFile(ZIP_PATH) as zf:
        with zf.open(TSV_PATH) as f:
            reader = csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t")
            for row in reader:
                raw = row.get("ref", "")
                parts = raw.split()
                if len(parts) < 2:
                    continue
                book = parts[0]
                if book not in BOOK_SLUGS:
                    continue
                cv = parts[1].split("!")[0]
                key = "%s:%s" % (book, cv)
                if key in seen:
                    continue
                seen.add(key)
                ch, vs = cv.split(":")
                refs.append((book, int(ch), int(vs)))
    return refs


def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    translit = {}
    if OUT_FILE.exists():
        translit = json.loads(OUT_FILE.read_text("utf-8"))
        print("Loaded %d existing entries from %s" % (len(translit), OUT_FILE.name))

    refs  = get_verse_refs()
    total = len(refs)
    print("NT verses to process: %d" % total)

    fetched = errors = skipped = 0

    for i, (book, ch, vs) in enumerate(refs, 1):
        cache_file = CACHE_DIR / ("%s_%d_%d.html" % (book, ch, vs))

        if cache_file.exists():
            html = cache_file.read_text("utf-8")
            skipped += 1
        else:
            slug = BOOK_SLUGS[book]
            url  = "https://biblehub.com/text/%s/%d-%d.htm" % (slug, ch, vs)
            html = fetch(url)
            if html is None:
                errors += 1
                time.sleep(DELAY * 3)
                continue
            cache_file.write_text(html, "utf-8")
            fetched += 1
            time.sleep(DELAY)

        pairs = parse_translit(html)
        translit.update(pairs)

        if i % 200 == 0 or i == total:
            OUT_FILE.write_text(
                json.dumps(translit, ensure_ascii=False, indent=2), "utf-8"
            )
            print("  [%4d/%d  %4.1f%%]  fetched=%d cached=%d errors=%d entries=%d" % (
                i, total, i / total * 100, fetched, skipped, errors, len(translit)
            ))

    OUT_FILE.write_text(json.dumps(translit, ensure_ascii=False, indent=2), "utf-8")
    print("\nDone. %d transliterations -> %s" % (len(translit), OUT_FILE))


if __name__ == "__main__":
    main()
