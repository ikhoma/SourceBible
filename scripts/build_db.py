#!/usr/bin/env python3
"""
SourceBible Database Builder
-----------------------------
Builds sourcebible.db from local datasets.

Local data (put files in SourceBible/data/):
  macula-hebrew-main.zip  — Clear-Bible/macula-hebrew  (MIT)
  macula-greek-main.zip   — Clear-Bible/macula-greek   (MIT)
  strongsHebrew.json      — built from Macula data
  strongsGreek.json       — built from Macula data

Translations — MyBible SQLite format (.zip or .SQLite3):
  KJV+.zip   — King James Version with Strong's   (public domain)
  ASV+.zip   — American Standard Version          (public domain)
  NASB+.zip  — New American Standard Bible        (licensed)
  RST+.zip   — Russian Synodal Translation        (public domain)

Cross-refs — downloaded automatically from OpenBible.info (CC BY 4.0)

Usage:
  python3 scripts/build_db.py
  → sourcebible.db  (copy to SourceBible/Resources/ in Xcode)
"""

import sqlite3, json, csv, os, io, re, time, zipfile, tempfile, unicodedata
from pathlib import Path

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False
    print("WARNING: requests not installed. Remote downloads disabled.")
    print("         pip3 install requests")

# ─────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────

ROOT      = Path(__file__).parent.parent
DATA_DIR  = ROOT / "data"          # local zips + manual downloads
CACHE_DIR = ROOT / "scripts" / ".cache"
OUTPUT_DB = ROOT / "sourcebible.db"

DATA_DIR.mkdir(parents=True, exist_ok=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# ─────────────────────────────────────────────
# Books
# ─────────────────────────────────────────────

BOOKS = [
    ( 1,"GEN","OT","Genesis",        50),
    ( 2,"EXO","OT","Exodus",         40),
    ( 3,"LEV","OT","Leviticus",      27),
    ( 4,"NUM","OT","Numbers",        36),
    ( 5,"DEU","OT","Deuteronomy",    34),
    ( 6,"JOS","OT","Joshua",         24),
    ( 7,"JDG","OT","Judges",         21),
    ( 8,"RUT","OT","Ruth",            4),
    ( 9,"1SA","OT","1 Samuel",       31),
    (10,"2SA","OT","2 Samuel",       24),
    (11,"1KI","OT","1 Kings",        22),
    (12,"2KI","OT","2 Kings",        25),
    (13,"1CH","OT","1 Chronicles",   29),
    (14,"2CH","OT","2 Chronicles",   36),
    (15,"EZR","OT","Ezra",           10),
    (16,"NEH","OT","Nehemiah",       13),
    (17,"EST","OT","Esther",         10),
    (18,"JOB","OT","Job",            42),
    (19,"PSA","OT","Psalms",        150),
    (20,"PRO","OT","Proverbs",       31),
    (21,"ECC","OT","Ecclesiastes",   12),
    (22,"SNG","OT","Song of Solomon", 8),
    (23,"ISA","OT","Isaiah",         66),
    (24,"JER","OT","Jeremiah",       52),
    (25,"LAM","OT","Lamentations",    5),
    (26,"EZK","OT","Ezekiel",        48),
    (27,"DAN","OT","Daniel",         12),
    (28,"HOS","OT","Hosea",          14),
    (29,"JOL","OT","Joel",            3),
    (30,"AMO","OT","Amos",            9),
    (31,"OBA","OT","Obadiah",         1),
    (32,"JON","OT","Jonah",           4),
    (33,"MIC","OT","Micah",           7),
    (34,"NAM","OT","Nahum",           3),
    (35,"HAB","OT","Habakkuk",        3),
    (36,"ZEP","OT","Zephaniah",       3),
    (37,"HAG","OT","Haggai",          2),
    (38,"ZEC","OT","Zechariah",      14),
    (39,"MAL","OT","Malachi",         4),
    (40,"MAT","NT","Matthew",        28),
    (41,"MRK","NT","Mark",           16),
    (42,"LUK","NT","Luke",           24),
    (43,"JHN","NT","John",           21),
    (44,"ACT","NT","Acts",           28),
    (45,"ROM","NT","Romans",         16),
    (46,"1CO","NT","1 Corinthians",  16),
    (47,"2CO","NT","2 Corinthians",  13),
    (48,"GAL","NT","Galatians",       6),
    (49,"EPH","NT","Ephesians",       6),
    (50,"PHP","NT","Philippians",     4),
    (51,"COL","NT","Colossians",      4),
    (52,"1TH","NT","1 Thessalonians", 5),
    (53,"2TH","NT","2 Thessalonians", 3),
    (54,"1TI","NT","1 Timothy",       6),
    (55,"2TI","NT","2 Timothy",       4),
    (56,"TIT","NT","Titus",           3),
    (57,"PHM","NT","Philemon",        1),
    (58,"HEB","NT","Hebrews",        13),
    (59,"JAS","NT","James",           5),
    (60,"1PE","NT","1 Peter",         5),
    (61,"2PE","NT","2 Peter",         3),
    (62,"1JN","NT","1 John",          5),
    (63,"2JN","NT","2 John",          1),
    (64,"3JN","NT","3 John",          1),
    (65,"JUD","NT","Jude",            1),
    (66,"REV","NT","Revelation",     22),
]

NUM_TO_OSIS = {b[0]: b[1] for b in BOOKS}
VALID_OSIS  = {b[1] for b in BOOKS}   # fast membership check

# ─────────────────────────────────────────────
# Schema
# ─────────────────────────────────────────────

SCHEMA = """
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS book (
    id        TEXT PRIMARY KEY,
    num       INTEGER UNIQUE,
    testament TEXT,
    name_en   TEXT,
    chapters  INTEGER
);

CREATE TABLE IF NOT EXISTS translation (
    id       TEXT PRIMARY KEY,
    name     TEXT,
    language TEXT
);

CREATE TABLE IF NOT EXISTS verse (
    id          TEXT PRIMARY KEY,   -- 'KJV|GEN|1|1'
    translation TEXT NOT NULL,
    book_id     TEXT NOT NULL,
    chapter     INTEGER NOT NULL,
    verse       INTEGER NOT NULL,
    text        TEXT NOT NULL,
    FOREIGN KEY (translation) REFERENCES translation(id),
    FOREIGN KEY (book_id)     REFERENCES book(id)
);

CREATE TABLE IF NOT EXISTS word (
    id           TEXT PRIMARY KEY,  -- 'GEN|1|1|1'
    book_id      TEXT NOT NULL,
    chapter      INTEGER NOT NULL,
    verse        INTEGER NOT NULL,
    position     INTEGER NOT NULL,
    surface      TEXT NOT NULL,
    lemma        TEXT,
    strongs_id   TEXT,
    morph        TEXT,
    gloss        TEXT,
    language     TEXT NOT NULL,
    xlit         TEXT,              -- contextual transliteration from Macula TSV (simplified, e.g. "ba", "reshayim")
    gloss_macula TEXT,              -- contextual gloss from Macula XML lowfat (e.g. "he.walked")
    syntax_role  TEXT,              -- Macula syntactic role: v=predicate, s=subject, o=object, etc.
    greek        TEXT,              -- LXX Greek equivalent surface form (e.g. "ἐπορεύθη")
    greek_strong TEXT,              -- LXX Greek Strong's number (e.g. "G4198")
    after_char   TEXT,              -- trailing char from Macula XML `after` attr (maqaf ־, sof pasuq ׃, paseq ׀)
    lexical_class TEXT,             -- Macula TSV `class` field: noun/verb/adj/adv/prep/cj/pron/ij/intj/art/ptcl/rel/num/om/x
    slot         INTEGER,           -- Macula !N group position (multiple tokens share same slot = one display word)
    xlit_slot    TEXT,              -- BibleHub per-slot transliteration (keyed by verse-slot position via ADR-020)
    FOREIGN KEY (book_id)    REFERENCES book(id),
    FOREIGN KEY (strongs_id) REFERENCES strongs(id)
);

CREATE TABLE IF NOT EXISTS strongs (
    id              TEXT PRIMARY KEY,
    language        TEXT NOT NULL,
    original        TEXT,
    transliteration TEXT,       -- academic xlit (openscriptures): rēʾšiyṯ
    xlit_simple     TEXT,       -- simplified xlit (STEPBible):     reshit
    pronunciation   TEXT,
    part_of_speech  TEXT,
    short_def       TEXT,
    long_def        TEXT        -- full BDB / Abbott-Smith (STEPBible)
);

CREATE TABLE IF NOT EXISTS cross_reference (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    from_book    TEXT NOT NULL,
    from_chapter INTEGER NOT NULL,
    from_verse   INTEGER NOT NULL,
    to_book      TEXT NOT NULL,
    to_chapter   INTEGER NOT NULL,
    to_verse     INTEGER NOT NULL,
    votes        INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (from_book) REFERENCES book(id),
    FOREIGN KEY (to_book)   REFERENCES book(id)
);

-- Translator footnotes (from .commentaries.SQLite3 files and <n> tags).
-- marker matches <f>[1]</f> anchors in verse.text.
-- verse_to allows range footnotes (chapter_from:verse_from – chapter_to:verse_to).
CREATE TABLE IF NOT EXISTS footnote (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    translation  TEXT NOT NULL,
    book_id      TEXT NOT NULL,
    chapter_from INTEGER NOT NULL,
    verse_from   INTEGER NOT NULL,
    chapter_to   INTEGER NOT NULL,
    verse_to     INTEGER NOT NULL,
    marker       TEXT,              -- '[1]', '[2]', … — matches <f> anchor in text
    text         TEXT NOT NULL,
    FOREIGN KEY (translation) REFERENCES translation(id),
    FOREIGN KEY (book_id)     REFERENCES book(id)
);

CREATE TABLE IF NOT EXISTS book_name (
    book_id        TEXT NOT NULL,
    translation_id TEXT NOT NULL,
    long_name      TEXT NOT NULL,
    short_name     TEXT NOT NULL,
    sort_order     INTEGER NOT NULL,
    PRIMARY KEY (book_id, translation_id),
    FOREIGN KEY (book_id)        REFERENCES book(id),
    FOREIGN KEY (translation_id) REFERENCES translation(id)
);
CREATE INDEX IF NOT EXISTS idx_book_name_tid ON book_name(translation_id);

CREATE INDEX IF NOT EXISTS idx_verse_loc    ON verse(translation, book_id, chapter, verse);
CREATE INDEX IF NOT EXISTS idx_word_verse   ON word(book_id, chapter, verse);
CREATE INDEX IF NOT EXISTS idx_word_slot    ON word(book_id, chapter, verse, slot);
CREATE INDEX IF NOT EXISTS idx_word_strongs ON word(strongs_id);
CREATE INDEX IF NOT EXISTS idx_xref_from   ON cross_reference(from_book, from_chapter, from_verse);
CREATE INDEX IF NOT EXISTS idx_xref_to     ON cross_reference(to_book, to_chapter, to_verse);
CREATE INDEX IF NOT EXISTS idx_footnote_loc ON footnote(translation, book_id, chapter_from, verse_from);
"""

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

def download(url, cache_name, binary=False):
    """Download with cache. Returns bytes (binary) or str."""
    cache_file = CACHE_DIR / cache_name
    if cache_file.exists():
        print(f"    [cache] {cache_name}")
        return cache_file.read_bytes() if binary else cache_file.read_text(encoding="utf-8")
    if not HAS_REQUESTS:
        raise RuntimeError("requests not installed")
    print(f"    [download] {url}")
    for attempt in range(3):
        try:
            r = requests.get(url, timeout=60)
            r.raise_for_status()
            cache_file.write_bytes(r.content)
            return r.content if binary else r.text
        except Exception as e:
            print(f"      Attempt {attempt+1} failed: {e}")
            time.sleep(2)
    raise RuntimeError(f"Failed to download {url}")


def normalize_strongs(raw, lang_prefix=""):
    """Normalize to 'H1234' / 'G1234'. Handles bare numbers if lang_prefix given."""
    if not raw:
        return None
    first = raw.strip().split()[0]
    if not first:
        return None
    # If no H/G prefix, add from lang_prefix
    if first[0].isdigit() and lang_prefix:
        first = lang_prefix + first
    m = re.match(r'^([HG])0*(\d+)([a-z]?)$', first, re.IGNORECASE)
    if m:
        return f"{m.group(1).upper()}{m.group(2)}{m.group(3)}"
    return None


def parse_macula_ref(ref):
    """
    Parse 'GEN 1:1!1' or 'MAT 1:1!1' → (osis_id, chapter, verse, position).
    Refs use OSIS IDs directly (GEN, EXO, MAT...).
    """
    m = re.match(r'^(\S+)\s+(\d+):(\d+)(?:!(\d+))?', ref)
    if not m:
        return None
    book_code = m.group(1).upper()
    ch  = int(m.group(2))
    vs  = int(m.group(3))
    pos = int(m.group(4)) if m.group(4) else 1
    if book_code not in VALID_OSIS:
        return None
    return book_code, ch, vs, pos

# ─────────────────────────────────────────────
# Step 1 — Books
# ─────────────────────────────────────────────

def import_books(cur):
    print("\n[1/6] Importing books...")
    cur.executemany(
        "INSERT OR IGNORE INTO book (id, num, testament, name_en, chapters) VALUES (?,?,?,?,?)",
        [(b[1], b[0], b[2], b[3], b[4]) for b in BOOKS]
    )
    print(f"  {len(BOOKS)} books imported.")

# ─────────────────────────────────────────────
# Step 2 — Macula Hebrew (from local zip)
# ─────────────────────────────────────────────

MACULA_HEB_ZIP  = DATA_DIR / "macula-hebrew-main.zip"
MACULA_HEB_TSV  = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"

def import_macula_hebrew(cur):
    print("\n[2/6] Importing Macula Hebrew...")
    if not MACULA_HEB_ZIP.exists():
        print(f"  SKIP: {MACULA_HEB_ZIP} not found.")
        print(f"  → Download macula-hebrew-main.zip from GitHub and put it in data/")
        return

    with zipfile.ZipFile(MACULA_HEB_ZIP) as zf:
        with zf.open(MACULA_HEB_TSV) as f:
            raw = io.TextIOWrapper(f, encoding="utf-8")
            rows = parse_macula_tsv(raw, language="hbo", strongs_col="strongnumberx", lang_prefix="H")

    cur.executemany(
        "INSERT OR IGNORE INTO word (id,book_id,chapter,verse,position,surface,lemma,strongs_id,morph,gloss,language,xlit,lexical_class,slot) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows
    )
    print(f"  {len(rows):,} Hebrew words imported.")

# ─────────────────────────────────────────────
# Step 4 — Macula Greek (from local zip)
# ─────────────────────────────────────────────

MACULA_GRK_ZIP  = DATA_DIR / "macula-greek-main.zip"
MACULA_GRK_TSV  = "macula-greek-main/Nestle1904/tsv/macula-greek-Nestle1904.tsv"

def import_macula_greek(cur):
    print("\n[3/6] Importing Macula Greek...")
    if not MACULA_GRK_ZIP.exists():
        print(f"  SKIP: {MACULA_GRK_ZIP} not found.")
        print(f"  → Download macula-greek-main.zip from GitHub and put it in data/")
        return

    # Load BibleHub transliterations if available (produced by fetch_biblehub_translit.py).
    # Keys are normalized Greek surface forms; values are per-form transliterations.
    bh_translit_path = DATA_DIR / "greek_translit.json"
    bh_translit: dict = {}
    if bh_translit_path.exists():
        import json as _json
        bh_translit = _json.loads(bh_translit_path.read_text("utf-8"))
        print(f"  BibleHub translit loaded: {len(bh_translit):,} entries")
    else:
        print(f"  No greek_translit.json found — run fetch_biblehub_translit.py for surface xlit")

    with zipfile.ZipFile(MACULA_GRK_ZIP) as zf:
        with zf.open(MACULA_GRK_TSV) as f:
            raw = io.TextIOWrapper(f, encoding="utf-8")
            rows = parse_macula_tsv(raw, language="grc", strongs_col="strong",
                                    lang_prefix="G", xlit_lookup=bh_translit)

    cur.executemany(
        "INSERT OR IGNORE INTO word (id,book_id,chapter,verse,position,surface,lemma,strongs_id,morph,gloss,language,xlit,lexical_class,slot) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows
    )
    print(f"  {len(rows):,} Greek words imported.")


def parse_macula_tsv(fileobj, language, strongs_col, lang_prefix, xlit_lookup: dict = {}):
    """Parse a Macula consolidated TSV (file-like object). Returns word rows.

    The Macula Hebrew TSV uses word-group position numbers (PSA 1:2!3 can have
    multiple tokens: a prefix בְּ and the root תּוֹרָה both share position !3).
    We assign each non-empty token a *sequential* position within its verse so
    nothing is dropped.  Greek has one token per position so this is a no-op
    there, but it's safe for both corpora.

    xlit_lookup: optional {normalized_greek_form: transliteration} from BibleHub.
    When provided, per-form surface xlit is used instead of the TSV column fallback.
    """
    rows = []
    reader = csv.DictReader(fileobj, delimiter="\t")
    # sequential token counter per (osis, chapter, verse)
    verse_seq: dict = {}

    for row in reader:
        ref = row.get("ref", "").strip()
        parsed = parse_macula_ref(ref)
        if not parsed:
            continue
        osis, ch, vs, slot = parsed          # slot = Macula !N group position; multiple tokens share same slot

        surface = row.get("text", "").strip()
        if not surface:
            # Some rows are empty morphological markers (e.g. ה locative) — skip them
            continue

        lemma   = row.get("lemma", "").strip() or None
        morph   = row.get("morph", "").strip() or None
        gloss   = (row.get("english") or row.get("gloss") or "").strip() or None

        raw_strongs = row.get(strongs_col, "").strip()
        strongs_id  = normalize_strongs(raw_strongs, lang_prefix)

        # Transliteration priority:
        # 1. BibleHub per-form xlit (keyed on normalized form — strip trailing punct)
        # 2. TSV transliteration/translit column (Hebrew only; Greek TSV has none)
        normalized = row.get("normalized", surface).strip()
        norm_key   = normalized.rstrip(" ,.:;·’‘’’’")
        xlit       = xlit_lookup.get(norm_key) or xlit_lookup.get(surface.rstrip(" ,.:;·’‘’’"))
        if not xlit:
            raw_xlit = (row.get("transliteration") or row.get("translit") or "").strip()
            xlit = simplify_xlit(raw_xlit) or None

        # Macula lexical class — overrides morph-derived POS for edge cases like
        # H835a (אַשְׁרֵי) which has morph 'Ncmpc' (noun) but class 'ij' (interjection).
        lexical_class = row.get("class", "").strip() or None

        verse_key = (osis, ch, vs)
        pos = verse_seq.get(verse_key, 0) + 1
        verse_seq[verse_key] = pos

        word_id = f"{osis}|{ch}|{vs}|{pos}"
        rows.append((word_id, osis, ch, vs, pos, surface, lemma,
                     strongs_id, morph, gloss, language, xlit, lexical_class, slot))
    return rows

# ─────────────────────────────────────────────
# Step 3b — Enrich Hebrew words from Macula XML lowfat
#   Reads per-chapter XML files from macula-hebrew-main.zip/WLC/lowfat/
#   Populates: gloss_macula, syntax_role, greek, greek_strong
#   (xlit is already populated from TSV in import_macula_hebrew — skip here)
#   Matching: by Strong's occurrence index within each verse (same strategy
#   as migrate_macula_to_word.py — robust to count mismatches)
# ─────────────────────────────────────────────

# Maps our OSIS book IDs → Macula Hebrew 3-letter abbreviations used in filenames
_MACULA_HEB_ABBR = {
    '1CH':'1Ch','1KI':'1Ki','1SA':'1Sa','2CH':'2Ch','2KI':'2Ki','2SA':'2Sa',
    'AMO':'Amo','DAN':'Dan','DEU':'Deu','ECC':'Ecc','EST':'Est','EXO':'Exo',
    'EZK':'Ezk','EZR':'Ezr','GEN':'Gen','HAB':'Hab','HAG':'Hag','HOS':'Hos',
    'ISA':'Isa','JDG':'Jdg','JER':'Jer','JOB':'Job','JOL':'Jol','JON':'Jon',
    'JOS':'Jos','LAM':'Lam','LEV':'Lev','MAL':'Mal','MIC':'Mic','NAM':'Nam',
    'NEH':'Neh','NUM':'Num','OBA':'Oba','PRO':'Pro','PSA':'Psa','RUT':'Rut',
    'SNG':'Sng','ZEC':'Zec','ZEP':'Zep',
}


def _xml_nodes_for_chapter(zf, book_id, book_num, chapter):
    """
    Read a Macula Hebrew lowfat XML chapter file from the zip.
    Returns {verse_num: [list of w.attrib dicts in document order]}.
    """
    import xml.etree.ElementTree as ET
    abbr = _MACULA_HEB_ABBR.get(book_id)
    if not abbr:
        return {}
    filename = f"macula-hebrew-main/WLC/lowfat/{book_num:02d}-{abbr}-{chapter:03d}-lowfat.xml"
    try:
        xml_bytes = zf.read(filename)
    except KeyError:
        return {}
    root = ET.fromstring(xml_bytes)
    result = {}
    for w in root.iter('w'):
        ref = w.get('ref', '')
        m = re.search(r':(\d+)!', ref)
        if not m:
            continue
        v = int(m.group(1))
        result.setdefault(v, []).append(w.attrib)
    return result


def _xml_match_verse(db_words, mac_words, strong_attr='strongnumberx'):
    """
    Match DB word rows to Macula XML nodes using Strong's occurrence index.
    Robust against count mismatches between TSV and XML.

    db_words:    list of (word_id, verse, position, strongs_id)
    mac_words:   list of w.attrib dicts from XML
    strong_attr: XML attribute name for Strong's number
                 ('strongnumberx' for Hebrew, 'strong' for Greek)
    Returns: list of (word_id, mac_attrib | None)
    """
    from collections import defaultdict

    def _norm(s):
        """'H1980' → '1980', 'G1063' → '1063', '0835a' → '835a'"""
        if not s:
            return ''
        return s.lstrip('H').lstrip('G').lstrip('0') or '0'

    mac_by_strong = defaultdict(list)
    for mac in mac_words:
        key = _norm(mac.get(strong_attr, ''))
        mac_by_strong[key].append(mac)

    occ_counter = defaultdict(int)
    result = []
    for db_row in db_words:
        word_id, _, _, strongs_id = db_row
        key = _norm(strongs_id)
        occ_counter[key] += 1
        n = occ_counter[key]
        candidates = mac_by_strong.get(key, [])
        mac = candidates[n - 1] if len(candidates) >= n else None
        result.append((word_id, mac))
    return result


def enrich_macula_from_xml(cur):
    """
    Populate gloss_macula, syntax_role, greek, greek_strong from Macula Hebrew XML lowfat.
    Runs after import_macula_hebrew() which already filled xlit from TSV.
    """
    print("\n[3b] Enriching Hebrew words from Macula XML lowfat...")
    if not MACULA_HEB_ZIP.exists():
        print(f"  SKIP: {MACULA_HEB_ZIP} not found.")
        return

    cur.execute("""
        SELECT b.id, b.num, w.chapter
        FROM word w
        JOIN book b ON b.id = w.book_id
        WHERE w.language = 'hbo'
        GROUP BY b.id, b.num, w.chapter
        ORDER BY b.num, w.chapter
    """)
    chapters = cur.fetchall()
    print(f"  Processing {len(chapters)} Hebrew chapters...")

    total_updated  = 0
    total_no_match = 0

    with zipfile.ZipFile(MACULA_HEB_ZIP) as zf:
        for book_id, book_num, chapter in chapters:
            macula_ch = _xml_nodes_for_chapter(zf, book_id, book_num, chapter)
            if not macula_ch:
                continue

            cur.execute("""
                SELECT id, verse, position, strongs_id
                FROM word
                WHERE book_id=? AND chapter=? AND language='hbo'
                ORDER BY verse, position
            """, (book_id, chapter))
            db_words = cur.fetchall()

            db_by_verse = {}
            for row in db_words:
                db_by_verse.setdefault(row[1], []).append(row)

            updates = []
            for verse, db_verse_words in db_by_verse.items():
                mac_verse = macula_ch.get(verse, [])
                pairs = _xml_match_verse(db_verse_words, mac_verse)
                for word_id, mac in pairs:
                    if mac is None:
                        total_no_match += 1
                        continue
                    greek_strong = mac.get('greekstrong', '')
                    if greek_strong:
                        greek_strong = 'G' + greek_strong
                    # .strip() removes surrounding whitespace; empty result → NULL (space-only = no char)
                    raw_after = mac.get('after', '').strip()
                    after_char = raw_after if raw_after else None
                    updates.append((
                        mac.get('gloss', '')     or None,   # gloss_macula
                        mac.get('role', '')      or None,   # syntax_role
                        mac.get('greek', '')     or None,   # greek
                        greek_strong             or None,   # greek_strong
                        after_char,                         # after_char
                        word_id,
                    ))

            if updates:
                cur.executemany("""
                    UPDATE word
                    SET gloss_macula=?, syntax_role=?, greek=?, greek_strong=?, after_char=?
                    WHERE id=?
                """, updates)
                total_updated += len(updates)

    print(f"  Updated  : {total_updated:,} words")
    print(f"  No match : {total_no_match:,} (columns left NULL)")


# ─────────────────────────────────────────────
# Step 3c — Enrich Greek words from Macula Greek XML lowfat
#   Reads per-book XML files from macula-greek-main.zip/Nestle1904/lowfat/
#   Populates: after_char
#   One file per NT book (unlike Hebrew which is one file per chapter).
#   OSIS book IDs match Macula ref abbreviations directly (MAT, MRK, JHN…).
# ─────────────────────────────────────────────

_MACULA_GRK_FILES = {
    'MAT': '01-matthew',    'MRK': '02-mark',       'LUK': '03-luke',
    'JHN': '04-john',       'ACT': '05-acts',        'ROM': '06-romans',
    '1CO': '07-1corinthians','2CO': '08-2corinthians','GAL': '09-galatians',
    'EPH': '10-ephesians',  'PHP': '11-philippians', 'COL': '12-colossians',
    '1TH': '13-1thessalonians','2TH': '14-2thessalonians',
    '1TI': '15-1timothy',   '2TI': '16-2timothy',   'TIT': '17-titus',
    'PHM': '18-philemon',   'HEB': '19-hebrews',    'JAS': '20-james',
    '1PE': '21-1peter',     '2PE': '22-2peter',     '1JN': '23-1john',
    '2JN': '24-2john',      '3JN': '25-3john',      'JUD': '26-jude',
    'REV': '27-revelation',
}


def _xml_nodes_for_book(zf, book_id):
    """
    Read a Macula Greek lowfat XML book file from the zip.
    Returns {(chapter, verse): [list of w.attrib dicts in document order]}.
    """
    import xml.etree.ElementTree as ET
    fname = _MACULA_GRK_FILES.get(book_id)
    if not fname:
        return {}
    path = f'macula-greek-main/Nestle1904/lowfat/{fname}.xml'
    try:
        xml_bytes = zf.read(path)
    except KeyError:
        return {}
    root = ET.fromstring(xml_bytes)
    result = {}
    for w in root.iter('w'):
        ref = w.get('ref', '')
        # Format: 'JHN 3:16!2'
        m = re.match(r'\w+ (\d+):(\d+)!', ref)
        if not m:
            continue
        ch, vs = int(m.group(1)), int(m.group(2))
        result.setdefault((ch, vs), []).append(w.attrib)
    return result


def enrich_macula_greek_from_xml(cur):
    """
    Populate after_char for Greek words from Macula Greek XML lowfat.
    Runs after import_macula_greek() which already filled surface/morph/xlit from TSV.
    """
    print("\n[3c] Enriching Greek words (after_char) from Macula Greek XML lowfat...")
    if not MACULA_GRK_ZIP.exists():
        print(f"  SKIP: {MACULA_GRK_ZIP} not found.")
        return

    cur.execute("""
        SELECT DISTINCT book_id FROM word WHERE language = 'grc' ORDER BY book_id
    """)
    book_ids = [r[0] for r in cur.fetchall()]
    print(f"  Processing {len(book_ids)} Greek books...")

    total_updated  = 0
    total_no_match = 0

    with zipfile.ZipFile(MACULA_GRK_ZIP) as zf:
        for book_id in book_ids:
            nodes = _xml_nodes_for_book(zf, book_id)
            if not nodes:
                continue

            cur.execute("""
                SELECT id, verse, position, strongs_id
                FROM word
                WHERE book_id=? AND language='grc'
                ORDER BY chapter, verse, position
            """, (book_id,))
            db_words = cur.fetchall()

            # Group by (chapter, verse) — extract chapter from word id 'MAT|1|1|1'
            db_by_cv = {}
            for row in db_words:
                parts = row[0].split('|')
                if len(parts) >= 3:
                    cv = (int(parts[1]), int(parts[2]))
                    db_by_cv.setdefault(cv, []).append(row)

            updates = []
            for cv, db_cv_words in db_by_cv.items():
                mac_cv = nodes.get(cv, [])
                pairs = _xml_match_verse(db_cv_words, mac_cv, strong_attr='strong')
                for word_id, mac in pairs:
                    if mac is None:
                        total_no_match += 1
                        continue
                    raw_after = mac.get('after', '').strip()
                    after_char = raw_after if raw_after else None
                    if after_char is not None:
                        updates.append((after_char, word_id))

            if updates:
                cur.executemany(
                    "UPDATE word SET after_char=? WHERE id=?",
                    updates
                )
                total_updated += len(updates)

    print(f"  Updated  : {total_updated:,} words")
    print(f"  No match : {total_no_match:,} (columns left NULL)")


# ─────────────────────────────────────────────
# Step 4c — Verify xlit integrity (fail-fast)
#   Detects sub-entries that inherited wrong xlit from an unrelated base entry.
#   If any violations found → raises SystemExit so a corrupted DB is never shipped.
# ─────────────────────────────────────────────

def verify_xlit_integrity(cur):
    """
    Assert no sub-entry inherited xlit from an unrelated base Strong's entry.
    Safe sub-entries (same original word, e.g. H7927 / H7927a = Shechem)
    are excluded by the `sub.original != base.original` condition.
    Raises SystemExit with diagnostic output if violations found.
    """
    print("\n[4d] Verifying xlit integrity (sub-entry contamination check)...")
    rows = cur.execute("""
        SELECT sub.id, sub.transliteration, base.transliteration AS base_xlit,
               sub.original, base.original AS base_original
        FROM   strongs sub
        JOIN   strongs base
               ON base.id = RTRIM(sub.id, 'abcdefghijklmnopqrstuvwxyz')
        WHERE  base.id != sub.id
          AND  sub.transliteration IS NOT NULL
          AND  sub.transliteration != ''
          AND  sub.transliteration = base.transliteration
          AND  sub.original != base.original
    """).fetchall()

    if rows:
        print(f"  WARNING: {len(rows)} potential sub-entry xlit violation(s) — auto-nulling transliteration:")
        ids_to_null = []
        for r in rows:
            print(f"    {r[0]} '{r[3]}' had xlit '{r[1]}' == base '{r[4]}' → SET transliteration=NULL")
            ids_to_null.append((r[0],))
        # NULL out only the `transliteration` column (academic xlit from strongs JSON).
        # xlit_simple (from TBESH exact match) is kept — TBESH has correct per-entry data.
        cur.executemany("UPDATE strongs SET transliteration = NULL WHERE id = ?", ids_to_null)
        print(f"  Nulled {len(ids_to_null)} academic transliterations. xlit_simple (TBESH) preserved.")
        print(f"  Note: review these entries — most are proper-noun variants with same root xlit.")
    else:
        print("  ✓ 0 violations — xlit integrity OK")


# ─────────────────────────────────────────────
# Step 5 — Strong's Lexicon
# ─────────────────────────────────────────────

# NOTE: import_strongs (openscriptures strongsHebrew/Greek.json) REMOVED 2026-07-15.
# It was the original Strong's source but became fully redundant: _seed_strongs_stubs
# seeds every ID from Macula, import_stepbible_lexicons (TBESH/TBESG) fills the
# definitions, and _backfill_strongs_originals_from_macula fills `original`. Proven
# identical: a full rebuild WITHOUT this step produces the same strongs table
# (14,712 rows / 14,712 short_def / 14,204 long_def) as before. The dead step only
# emitted a confusing "requests not installed / 0 entries" warning. Do not resurrect.


def _seed_strongs_stubs(cur):
    """
    INSERT stub rows (id, language) for every Strong's ID found in the Macula TSV files.

    Purpose: the word table has FOREIGN KEY (strongs_id) REFERENCES strongs(id).
    If the openscriptures JSON download fails, import_strongs() inserts nothing and
    import_macula_hebrew() dies with IntegrityError.

    This function guarantees the strongs table contains at least a stub row for every
    ID referenced by Macula, so the FK constraint is always satisfiable.
    TBESH UPDATE in import_stepbible_lexicons() later fills xlit_simple and long_def.

    Uses INSERT OR IGNORE so it is safe to run after a partial import_strongs().
    """
    sources = [
        (MACULA_HEB_ZIP, MACULA_HEB_TSV, "strongnumberx", "H"),
        (MACULA_GRK_ZIP, MACULA_GRK_TSV, "strong",        "G"),
    ]
    total = 0
    for zip_path, tsv_path, col, prefix in sources:
        if not zip_path.exists():
            continue
        ids = set()
        with zipfile.ZipFile(zip_path) as zf:
            with zf.open(tsv_path) as f:
                reader = csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t")
                for row in reader:
                    sid = normalize_strongs(row.get(col, "").strip(), prefix)
                    if sid:
                        ids.add(sid)
        lang = "hbo" if prefix == "H" else "grc"
        cur.executemany(
            "INSERT OR IGNORE INTO strongs (id, language) VALUES (?, ?)",
            [(sid, lang) for sid in ids],
        )
        total += len(ids)
    print(f"  Strongs stubs seeded: {total:,} unique IDs")


# ─────────────────────────────────────────────
# Step 4b — STEPBible TBESH / TBESG
#   Fills long_def (BDB for Hebrew, Abbott-Smith for Greek)
#   and xlit_simple (simplified transliteration) for every Strong's entry.
#   Runs as UPDATE after import_strongs() so the rows already exist.
#
#   Source: STEPBible-Data (Tyndale House, Cambridge) — CC BY 4.0
#   Files:  TBESH … Hebrew.txt  /  TBESG … Greek.txt
#
# File format (tab-separated, header line starts with #):
#   Columns vary by file; we detect them from the header.
#   Key columns: Strongs, Lemma, Transliteration, MorphCode,
#                ShortDefinition (or Gloss), LongDefinition (or Definition)
# ─────────────────────────────────────────────

def _find_stepbible_file(prefix: str):
    """Find a STEPBible lexicon file by prefix (e.g. 'TBESH' or 'TBESG').
    Accepts any filename starting with that prefix — handles both short names
    (TBESH.txt) and the full downloaded names (TBESH - Translators Brief ... .txt).
    """
    matches = sorted(DATA_DIR.glob(f"{prefix}*.txt"))
    return matches[0] if matches else None

STEPBIBLE_LEXICONS = {
    "H": (
        "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/"
        "TBESH%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Hebrew%20-%20STEPBible.org%20CC%20BY.txt",
        "TBESH.txt",
        "TBESH",   # prefix for _find_stepbible_file
    ),
    "G": (
        "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/"
        "TBESG%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Greek%20-%20STEPBible.org%20CC%20BY.txt",
        "TBESG.txt",
        "TBESG",   # prefix for _find_stepbible_file
    ),
}

def _parse_stepbible_file(text):
    """
    Parse a STEPBible TSV lexicon file (TBESH / TBESG format).

    File structure:
      - Multi-line preamble (prose, no tabs)
      - Column header row: tab-separated, first cell is 'eStrong'
      - Separator: '====...' line
      - Data rows: tab-separated, first cell is a Strong's ID like G0001 / H0001

    Returns a list of dicts keyed by lowercased column names.
    Only rows whose first cell looks like a bare Strong's ID (H/G + digits) are
    included — disambiguation variants (G0001G =, etc.) are skipped.
    """
    import re
    lines = text.splitlines()
    header = None
    rows = []
    # Matches a Strong's ID row: H0001 or G0001, optionally with a lowercase suffix (H1471a, H6213a).
    # IMPORTANT: ~542 Hebrew IDs exist in TBESH ONLY as suffixed entries (no bare H1471, H6213, etc.).
    # The old regex r'^[HG]\d{4,5}\t' silently skipped 1 424 rows — June 2026 bug.
    data_re = re.compile(r'^[HG]\d{4,5}[a-z]?\t')

    for line in lines:
        # Detect the header: the line with 'eStrong' AND 'dStrong' as first two tab cells
        if header is None:
            if "\t" in line:
                parts = line.split("\t")
                if (parts[0].strip().lower().startswith("estrong") and
                        len(parts) >= 7 and
                        parts[1].strip().lower().startswith("dstrong")):
                    header = [c.strip().lower() for c in parts]
            continue

        # Skip separators, empty lines, section markers
        stripped = line.strip()
        if not stripped or stripped.startswith("=") or stripped.startswith("$") or stripped.startswith("-"):
            continue

        # Only parse Strong's ID rows (bare or suffixed)
        if not data_re.match(line):
            continue

        parts = line.split("\t")
        row = {}
        for i, col in enumerate(header):
            row[col] = parts[i].strip() if i < len(parts) else ""
        rows.append(row)

    return rows


def _find_col(row, *candidates):
    """Return the value of the first matching column name (case-insensitive)."""
    for c in candidates:
        if c in row:
            v = row[c].strip()
            if v:
                return v
    return ""


def _clean_stepbible_html(text: str) -> str:
    """Strip HTML / markup from STEPBible lexicon definition fields.

    Handles:
      <b>word</b>          → word (keep content)
      <BR /> / <br>        → newline
      <ref='Act.1.1'>Act.1:1</ref>  → Act.1:1 (keep visible text)
      <a href=...>Refs Xth c.BC+</a>  → drop entirely (citation links)
      <i>text</i>          → text
      <Level2>, <Level3>   → drop tag, keep content
      (AS), (ML), (MT)     → keep (source attribution)
      HTML entities        → decode common ones
    """
    import re
    s = text

    # Drop citation anchor links entirely: <a href="javascript:void(0)" title="...">TEXT</a>
    s = re.sub(r'<a\b[^>]*>.*?</a>', '', s, flags=re.IGNORECASE | re.DOTALL)

    # <ref='Book.ch.v'>text</ref> → text
    s = re.sub(r"<ref='[^']*'>([^<]*)</ref>", r'\1', s, flags=re.IGNORECASE)

    # <BR /> / <br> / <br/> → newline
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.IGNORECASE)

    # <Level2>, <Level3>, </Level2>, </Level3> → strip tag
    s = re.sub(r'</?Level\d+>', '', s, flags=re.IGNORECASE)

    # All remaining tags (<b>, </b>, <i>, </i>, etc.) → strip
    s = re.sub(r'<[^>]+>', '', s)

    # HTML entities
    s = s.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>') \
         .replace('&nbsp;', ' ').replace('&#39;', "'").replace('&quot;', '"')

    # Collapse excessive blank lines (more than 2 consecutive newlines)
    s = re.sub(r'\n{3,}', '\n\n', s)

    # Trim leading/trailing whitespace
    return s.strip()


def simplify_xlit(academic: str) -> str:
    """
    Convert an academic/scholarly transliteration to a simplified Latin form
    suitable for display in the app (e.g. ʾašrēy → ashrey, bə → be).

    Used for two purposes:
      1. Fallback for Strong's IDs that have no TBESH entry (strongs.xlit_simple).
      2. Per-token contextual xlit from Macula transliteration attributes (word.xlit).

    Macula-specific notes:
      - ḇ = bet spirant (no dagesh) → rendered as 'v' (e.g. ḇə → ve, môšaḇ → moshav)
      - ṯ = tav spirant → 't' (not 'th') for simplified modern-style
      - Boundary markers (trailing/leading - and :) are stripped (Macula maqqef notation)

    Convention: ו is rendered as 'v' (av, a.vad), matching TBESH style.
    """
    if not academic:
        return ''
    s = academic.strip()
    # Strip Macula morpheme-boundary markers (maqqef hyphen, end-of-clause colon)
    s = s.strip('-').strip(':').strip()
    if not s:
        return ''
    # A word-final shewa (ə) in Hebrew is always silent (shewa nach) — drop it.
    # This prevents hālaḵə → halakhe; it should be halakh.
    # Must be done BEFORE the ə→e replacement below.
    s = re.sub(r'ə$', '', s)
    # Order matters: multi-char sequences must come before their single-char prefixes
    replacements = [
        # Aleph / Ayin breath marks → drop
        ('ʾ', ''), ('ʿ', ''),
        # Spirantized consonants (Macula uses precomposed chars, e.g. ḇ U+1E07)
        # Must come before generic sibilant/emphatic mappings below
        ('ḇ', 'v'),  ('Ḇ', 'V'),   # bet without dagesh → v
        ('ṯ', 't'),  ('Ṯ', 'T'),   # tav without dagesh → t (simplified, not 'th')
        ('ḏ', 'd'),  ('Ḏ', 'D'),   # dalet without dagesh → d
        ('ḡ', 'g'),  ('Ḡ', 'G'),   # gimel without dagesh → g
        # Hebrew sibilants / emphatics
        ('š', 'sh'), ('Š', 'Sh'),
        ('ṭ', 't'),  ('Ṭ', 'T'),
        ('ṣ', 'ts'), ('Ṣ', 'Ts'),
        ('ḥ', 'ch'), ('Ḥ', 'Ch'),
        ('ḵ', 'kh'), ('Ḵ', 'Kh'),
        ('ś', 's'),  ('Ś', 'S'),
        # Plural construct / vocalic endings
        ('ərê', 'rey'),
        ('erê', 'rey'),
        ('rê', 'rey'),
        # Shewa
        ('ə', 'e'),
        # Vav: wə/wā/wi/wō/wū must come before bare w
        ('wə', 've'), ('wā', 'va'), ('wi', 'vi'), ('wō', 'vo'), ('wū', 'vu'),
        ('w',  'v'),
        # Greek extras (in case Greek academic strings slip in)
        ('β', 'v'), ('γ', 'g'), ('θ', 'th'), ('φ', 'ph'),
        ('χ', 'ch'), ('ψ', 'ps'), ('ξ', 'x'),
    ]
    for src, dst in replacements:
        s = s.replace(src, dst)
    # Strip remaining combining diacritics (macrons, dots-below, long marks, etc.)
    s = ''.join(
        c for c in unicodedata.normalize('NFD', s)
        if unicodedata.category(c) != 'Mn'
    )
    # Drop any remaining non-ASCII (safety net)
    s = re.sub(r'[^\x00-\x7F]', '', s)
    s = s.lower().strip()
    # Guard 1: strip trailing 'e' from silent-shewa suffix on final kaf
    # (הָלַךְ֙ → hālaḵə → halakhe → halakh; דֶּרֶךְ֙ → derekhe → derekh)
    if s.endswith('khe'):
        s = s[:-1]
    # Guard 2: strip mater-lectionis yod after i-vowel at word end.
    # Macula writes 'kiy' for כִּי (hiriq + yod as vowel letter) but the
    # spoken form is simply 'ki'. The yod is not a consonant here.
    # Applies broadly: kiy→ki, biy→bi, niy→ni, etc.
    # Does NOT affect 'ay' (patah+yod) or 'ey' (tsere+yod) which are diphthongs.
    if s.endswith('iy'):
        s = s[:-1]  # kiy→ki, niy→ni, biy→bi
    return s


def import_stepbible_lexicons(cur):
    print("\n[4b] Importing STEPBible TBESH/TBESG (BDB + transliteration)...")
    total_updated = 0

    for lang_prefix, (url, cache_name, file_prefix) in STEPBIBLE_LEXICONS.items():
        raw = None
        local_path = _find_stepbible_file(file_prefix)
        if local_path:
            print(f"  [local] {local_path.name}")
            raw = local_path.read_text(encoding="utf-8", errors="replace")
        else:
            try:
                raw = download(url, cache_name)
                # Save to data/ for future runs
                save_path = DATA_DIR / cache_name
                save_path.write_text(raw, encoding="utf-8")
            except Exception as e:
                print(f"  WARNING: STEPBible {lang_prefix}: {e}")
                print(f"  → Download manually from:")
                print(f"    {url}")
                print(f"    Save any file named {file_prefix}*.txt in data/")
                continue

        rows = _parse_stepbible_file(raw)
        if not rows:
            print(f"  WARNING: no rows parsed from {cache_name} — check file format")
            continue

        # Debug: show detected columns from first row
        print(f"  Columns detected: {list(rows[0].keys())[:10]}")

        updated = 0
        skipped = 0
        # The last column always holds the lexical definition in STEPBible files,
        # regardless of its verbose header name.
        last_col = list(rows[0].keys())[-1] if rows else None

        for row in rows:
            # Resolve Strong's ID — STEPBible uses 'eStrong#' (Hebrew) or 'eStrong' (Greek)
            raw_id = _find_col(row, "estrong#", "estrong",
                               "strongs", "strongsextended", "strongsnumber", "id")
            sid = normalize_strongs(raw_id, lang_prefix)
            if not sid:
                skipped += 1
                continue

            xlit_simple = _find_col(row, "transliteration", "xlit", "translit", "pronunciation")
            # TBESH/TBESG col 6 = "Gloss" — brief English gloss
            short_def   = _find_col(row, "gloss")
            long_def    = _find_col(row, "longdefinition", "definition", "fulldefinition",
                                         "longdef", "bdb", "abbottsmith", "meaning")
            # Last-resort: use the last column (always the definition in STEPBible files)
            if not long_def and last_col:
                long_def = row.get(last_col, "")

            long_def = _clean_stepbible_html(long_def)

            # Truncate to avoid bloat
            xlit_simple = xlit_simple[:100]
            short_def   = short_def[:200]
            long_def    = long_def[:5000]

            # UPDATE: fill xlit_simple / short_def / long_def from TBESH/TBESG.
            #
            # DIRECTION: suffixed row → its own strongs row (H1471a → strongs WHERE id='H1471a').
            # IMPORTANT: do NOT propagate base → extended (H871 Atharim → H871a inseparable bet) —
            # those are unrelated words that happen to share the same numeric range.
            #
            # NOTE: strongs.original is NOT populated here — it comes from Macula
            # word.lemma in _backfill_strongs_originals_from_macula() which runs
            # after the word table is populated.
            #
            # NULL-safe conditions: stub rows have NULL (not ''), so use IS NULL OR = ''.
            cur.execute("""
                UPDATE strongs
                SET
                    xlit_simple     = CASE WHEN ? != ''                                                      THEN ? ELSE xlit_simple     END,
                    transliteration = CASE WHEN (transliteration IS NULL OR transliteration = '') AND ? != '' THEN ? ELSE transliteration END,
                    short_def       = CASE WHEN (short_def IS NULL OR short_def = '') AND ? != ''            THEN ? ELSE short_def       END,
                    long_def        = CASE WHEN ? != ''                                                      THEN ? ELSE long_def        END
                WHERE id = ?
            """, (
                xlit_simple, xlit_simple,
                xlit_simple, xlit_simple,
                short_def,   short_def,
                long_def,    long_def,
                sid,
            ))
            if cur.rowcount:
                updated += 1

            # For suffixed TBESH entries (H1471a, H6213a, etc.), also propagate to the base ID
            # (H1471, H6213). Macula tags these words using the bare number — without this step
            # those strongs rows stay NULL even after a full rebuild.
            # Safety: only fill if the base row's fields are currently NULL/empty (won't overwrite
            # a base entry that already has its own TBESH data, e.g. H3887 verb לוּץ).
            import re as _re
            m_base = _re.match(r'^([HG]\d+)[a-z]$', sid)
            if m_base:
                base_sid = m_base.group(1)
                cur.execute("""
                    UPDATE strongs SET
                        xlit_simple = CASE WHEN (xlit_simple IS NULL OR xlit_simple = '') AND ? != '' THEN ? ELSE xlit_simple END,
                        short_def   = CASE WHEN (short_def   IS NULL OR short_def   = '') AND ? != '' THEN ? ELSE short_def   END,
                        long_def    = CASE WHEN (long_def    IS NULL OR long_def    = '') AND ? != '' THEN ? ELSE long_def    END
                    WHERE id = ?
                """, (xlit_simple, xlit_simple, short_def, short_def, long_def, long_def, base_sid))
                if cur.rowcount:
                    updated += 1

        print(f"  {lang_prefix}: {updated:,} rows updated, {skipped} skipped (bad Strong's ID)")
        total_updated += updated

    print(f"  Total updated: {total_updated:,}")

# ─────────────────────────────────────────────
# Step 5 — Translations (MyBible SQLite format)
# ─────────────────────────────────────────────
#
# Each entry: (translation_id, full_name, language, path_to_zip_or_sqlite)
# Accepts both .zip (containing a .SQLite3 inside) and bare .SQLite3 files.
# Text is normalized: <S>1234</S> Strong's tags and <pb/> markers are stripped.

TRANSLATIONS = [
    ("KJV",  "King James Version",          "en", DATA_DIR / "KJV+.zip"),
    ("ASV",  "American Standard Version",   "en", DATA_DIR / "ASV+.zip"),
    ("NASB", "New American Standard Bible", "en", DATA_DIR / "NASB+.zip"),
    ("RST",  "Синодальний переклад",        "ru", DATA_DIR / "RST+.zip"),
    # ⚠️ LICENSED — не розповсюджувати публічно без дозволу (як NASB). Огієнко НЕ
    # суспільне надбання: права United Bible Societies / Українське біблійне
    # товариство (© 2009), PD ~2042/2058 (ADR-029). Додано для dev/beta; НЕ
    # шипити в публічний App Store до письмової ліцензії від УБТ. Без Strong's
    # (strong_numbers=false) → «Оригінал» працює через verse_org, word-study ні.
    ("UBIO", "Біблія в пер. Івана Огієнка", "uk", DATA_DIR / "UBIO'88.zip"),
]

def _detect_sqlite_schema(con):
    """
    Inspect an unknown Bible SQLite and return (table, book_col, ch_col, vs_col, text_col).
    Supports MyBible, e-Sword, scrollmapper SQLite, and generic schemas.
    """
    cur = con.cursor()
    tables = {r[0].lower(): r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    # Candidate table names in priority order
    for tname_lower in ("verses", "bible", "verse", "t"):
        if tname_lower not in tables:
            continue
        tname = tables[tname_lower]
        cols  = {r[1].lower(): r[1] for r in cur.execute(f"PRAGMA table_info('{tname}')")}

        # Map to canonical column names
        book_col = next((cols[c] for c in ("book_number","book","b","bnumber","bk") if c in cols), None)
        ch_col   = next((cols[c] for c in ("chapter","c","chap","ch") if c in cols), None)
        vs_col   = next((cols[c] for c in ("verse","v","ver","vs") if c in cols), None)
        text_col = next((cols[c] for c in ("text","t","scripture","versetext","content","verse_text") if c in cols), None)

        if all([book_col, ch_col, vs_col, text_col]):
            return tname, book_col, ch_col, vs_col, text_col

    raise RuntimeError(f"Cannot detect Bible schema. Tables: {list(tables.keys())}")


def _build_book_mapping(src, tname, book_col):
    """
    Build {book_number → OSIS_id} dynamically by sorting the distinct book numbers
    found in the file and assigning them positionally to canonical OT then NT books.

    MyBible always uses numbers < 470 for OT and ≥ 470 for NT, regardless of
    whether a particular module follows the standard ×10 numbering (10,20,…,390)
    or some other variant. Positional assignment is therefore robust to any
    non-standard ordering within the module (e.g. KJV+ placing Esther at 190
    instead of the standard Psalms position).
    """
    nums     = sorted(int(r[0]) for r in src.execute(f'SELECT DISTINCT "{book_col}" FROM "{tname}"'))
    ot_nums  = [n for n in nums if n < 470]
    nt_nums  = [n for n in nums if n >= 470]
    ot_osis  = [b[1] for b in BOOKS if b[2] == "OT"]   # 39 books in order
    nt_osis  = [b[1] for b in BOOKS if b[2] == "NT"]   # 27 books in order
    mapping  = {}
    for i, num in enumerate(ot_nums):
        if i < len(ot_osis):
            mapping[num] = ot_osis[i]
    for i, num in enumerate(nt_nums):
        if i < len(nt_osis):
            mapping[num] = nt_osis[i]
    return mapping


def _open_mybible_sqlite(path):
    """
    Open a MyBible SQLite — accepts either a bare .SQLite3 file or a .zip
    containing one. Returns (sqlite3.Connection, tmp_path_or_None).
    Caller must close the connection and delete tmp_path if not None.
    """
    path = Path(path)
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as z:
            # Pick the main bible file (not commentaries, not mappings)
            candidates = [n for n in z.namelist()
                          if n.lower().endswith(".sqlite3") and "comment" not in n.lower()]
            if not candidates:
                candidates = [n for n in z.namelist() if n.lower().endswith(".sqlite3")]
            if not candidates:
                raise RuntimeError(f"No .SQLite3 found inside {path.name}")
            data = z.read(candidates[0])
        tmp = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
        tmp.write(data)
        tmp.close()
        return sqlite3.connect(tmp.name), tmp.name
    else:
        return sqlite3.connect(str(path)), None



# Only strip legacy bracket-style Strong's [S1234] — an older format some modules use.
# <S>1234</S> tags are KEPT in verse.text so the app parser can render them.
# <pb/> is also kept — it marks paragraph boundaries (verse starts a new paragraph/pericope).
# All other semantic tags (<J>, <n>, <t>, <i>, <e>, <f>, <br/>) are preserved as-is.
_STRIP_RE = re.compile(r'\[S\d+[a-z]?\]')

def _clean_verse(text):
    """Strip legacy bracket Strong's markers and collapse whitespace.
    All XML-style tags are intentionally preserved for app-side parsing."""
    return re.sub(r'\s+', ' ', _STRIP_RE.sub('', text)).strip()


def _extract_book_names(src, book_mapping):
    """
    Read long_name / short_name from a MyBible `books` table.
    Returns list of (osis_id, long_name, short_name, sort_order).
    Falls back to empty list if the table doesn't exist (some stripped modules omit it).
    """
    try:
        # No ORDER BY: sources that store rows in their canonical order (e.g. RST
        # stores Synodal NT order: Catholic Epistles before Paul's Epistles) will
        # produce the correct sort_order automatically.  Sources whose SQLite engine
        # returns rows by primary key (book_number) fall back to Protestant canonical
        # order, which is the correct default for KJV/ASV/NASB.
        rows = src.execute(
            "SELECT book_number, long_name, short_name FROM books"
        ).fetchall()
    except Exception:
        return []

    result = []
    for sort_order, (book_num, long_name, short_name) in enumerate(rows):
        osis = book_mapping.get(int(book_num))
        if osis and long_name:
            result.append((osis, long_name.strip(), (short_name or long_name).strip(), sort_order))
    return result


def import_translations(cur):
    print("\n[5/6] Importing translations...")
    for (tid, name, lang, db_path) in TRANSLATIONS:
        db_path = Path(db_path)
        if not db_path.exists():
            print(f"  SKIP [{tid}]: {db_path.name} not found in data/")
            continue

        print(f"  [{tid}] {db_path.name}  —  {name}")
        cur.execute(
            "INSERT OR IGNORE INTO translation (id, name, language) VALUES (?,?,?)",
            (tid, name, lang)
        )

        try:
            src, tmp_path = _open_mybible_sqlite(db_path)
        except Exception as e:
            print(f"    ERROR opening: {e}")
            continue

        try:
            tname, bcol, ccol, vcol, tcol = _detect_sqlite_schema(src)
        except RuntimeError as e:
            print(f"    ERROR schema: {e}")
            src.close()
            if tmp_path:
                os.unlink(tmp_path)
            continue

        book_mapping = _build_book_mapping(src, tname, bcol)

        # Extract and store translation-native book names
        book_name_rows = _extract_book_names(src, book_mapping)
        if book_name_rows:
            cur.executemany(
                "INSERT OR REPLACE INTO book_name "
                "(book_id, translation_id, long_name, short_name, sort_order) VALUES (?,?,?,?,?)",
                [(osis, tid, long, short, order) for (osis, long, short, order) in book_name_rows]
            )
            print(f"    {len(book_name_rows)} book names extracted.")
        else:
            # Fallback: use name_en from BOOKS constant with canonical sort_order
            fallback = [(b[1], tid, b[3], b[3], b[0] - 1) for b in BOOKS]
            cur.executemany(
                "INSERT OR IGNORE INTO book_name "
                "(book_id, translation_id, long_name, short_name, sort_order) VALUES (?,?,?,?,?)",
                fallback
            )
            print(f"    No `books` table found — using name_en fallback.")

        # Log mapping for diagnostics — useful when adding new translations
        mapping_log = CACHE_DIR / f"book_mapping_{tid}.json"
        import json as _json
        with open(mapping_log, "w") as f:
            _json.dump({str(k): v for k, v in sorted(book_mapping.items())}, f, indent=2)
        print(f"    Book mapping ({len(book_mapping)} books) saved → {mapping_log.name}")
        print(f"    First 5: { {k: book_mapping[k] for k in sorted(book_mapping)[:5]} }")

        rows = []
        for row in src.execute(f'SELECT "{bcol}","{ccol}","{vcol}","{tcol}" FROM "{tname}"'):
            osis = book_mapping.get(int(row[0]))
            if not osis:
                continue
            ch, vs = int(row[1]), int(row[2])
            text = _clean_verse(row[3] or "")
            if not text:
                continue
            rows.append((f"{tid}|{osis}|{ch}|{vs}", tid, osis, ch, vs, text))

        src.close()
        if tmp_path:
            os.unlink(tmp_path)

        cur.executemany(
            "INSERT OR IGNORE INTO verse (id, translation, book_id, chapter, verse, text) VALUES (?,?,?,?,?,?)",
            rows
        )
        print(f"    {len(rows):,} verses imported.")


# ─────────────────────────────────────────────
# Step 6 — Footnotes from .commentaries files
# ─────────────────────────────────────────────
#
# MyBible translations with Strong's often ship a companion .commentaries.SQLite3.
# Its `commentaries` table has:
#   book_number, chapter_number_from, verse_number_from,
#   chapter_number_to, verse_number_to, marker, text
# `marker` like '[1]' matches <f>[1]</f> anchors in verse.text.

def import_footnotes(cur):
    print("\n[6/7] Importing footnotes from .commentaries files...")
    total = 0

    for (tid, _name, _lang, db_path) in TRANSLATIONS:
        db_path = Path(db_path)
        if not db_path.exists():
            continue

        # Derive companion path: KJV+.zip → KJV+.commentaries.SQLite3 (in same dir)
        # or unzip and look for *.commentaries.SQLite3 inside the zip
        comp_rows = _load_commentaries(db_path, tid)
        if not comp_rows:
            print(f"  [{tid}] no commentaries file — skipped")
            continue

        # We need the book mapping for this translation to convert book_number → OSIS
        try:
            src, tmp_path = _open_mybible_sqlite(db_path)
            tname, bcol, *_ = _detect_sqlite_schema(src)
            book_mapping = _build_book_mapping(src, tname, bcol)
            src.close()
            if tmp_path:
                os.unlink(tmp_path)
        except Exception as e:
            print(f"  [{tid}] ERROR building book mapping: {e}")
            continue

        rows = []
        for (book_num, ch_from, vs_from, ch_to, vs_to, marker, text) in comp_rows:
            osis = book_mapping.get(int(book_num))
            if not osis or not text:
                continue
            rows.append((tid, osis,
                         int(ch_from), int(vs_from),
                         int(ch_to),   int(vs_to),
                         marker, text.strip()))

        cur.executemany(
            "INSERT INTO footnote "
            "(translation, book_id, chapter_from, verse_from, chapter_to, verse_to, marker, text) "
            "VALUES (?,?,?,?,?,?,?,?)",
            rows
        )
        print(f"  [{tid}] {len(rows)} footnotes imported.")
        total += len(rows)

    print(f"  Total: {total} footnotes.")


def _load_commentaries(translation_path, tid):
    """
    Given a translation path (zip or SQLite3), find and return rows from
    its companion .commentaries.SQLite3 — either inside the zip or alongside it.
    Returns list of (book_number, ch_from, vs_from, ch_to, vs_to, marker, text)
    or empty list if none found.
    """
    translation_path = Path(translation_path)

    # Strategy 1: zip file may contain a .commentaries.SQLite3 entry
    if translation_path.suffix.lower() == ".zip":
        try:
            with zipfile.ZipFile(translation_path) as z:
                comp_entries = [n for n in z.namelist()
                                if "commentar" in n.lower() and n.lower().endswith(".sqlite3")]
                if comp_entries:
                    data = z.read(comp_entries[0])
                    tmp = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
                    tmp.write(data); tmp.close()
                    rows = _read_commentaries_db(tmp.name)
                    os.unlink(tmp.name)
                    return rows
        except Exception as e:
            print(f"    [{tid}] zip commentaries error: {e}")

    # Strategy 2: sibling file like KJV+.commentaries.SQLite3 in same directory
    stem = translation_path.stem   # e.g. "KJV+"
    sibling = translation_path.parent / f"{stem}.commentaries.SQLite3"
    if sibling.exists():
        return _read_commentaries_db(str(sibling))

    return []


def _read_commentaries_db(path):
    """Read all rows from a MyBible commentaries SQLite3 file."""
    try:
        conn = sqlite3.connect(path)
        rows = conn.execute(
            "SELECT book_number, chapter_number_from, verse_number_from, "
            "       chapter_number_to, verse_number_to, marker, text "
            "FROM commentaries"
        ).fetchall()
        conn.close()
        return rows
    except Exception as e:
        print(f"    commentaries read error: {e}")
        return []


# ─────────────────────────────────────────────
# Step 7 — OpenBible Cross-References
# ─────────────────────────────────────────────

OPENBIBLE_URL  = "https://a.openbible.info/data/cross-references.zip"
MIN_VOTES      = 3

# OpenBible book abbreviations → OSIS IDs
OPENBIBLE_BOOK = {
    "Gen":"GEN","Exod":"EXO","Lev":"LEV","Num":"NUM","Deut":"DEU",
    "Josh":"JOS","Judg":"JDG","Ruth":"RUT","1Sam":"1SA","2Sam":"2SA",
    "1Kgs":"1KI","2Kgs":"2KI","1Chr":"1CH","2Chr":"2CH","Ezra":"EZR",
    "Neh":"NEH","Esth":"EST","Job":"JOB","Ps":"PSA","Prov":"PRO",
    "Eccl":"ECC","Song":"SNG","Isa":"ISA","Jer":"JER","Lam":"LAM",
    "Ezek":"EZK","Dan":"DAN","Hos":"HOS","Joel":"JOL","Amos":"AMO",
    "Obad":"OBA","Jonah":"JON","Mic":"MIC","Nah":"NAM","Hab":"HAB",
    "Zeph":"ZEP","Hag":"HAG","Zech":"ZEC","Mal":"MAL",
    "Matt":"MAT","Mark":"MRK","Luke":"LUK","John":"JHN","Acts":"ACT",
    "Rom":"ROM","1Cor":"1CO","2Cor":"2CO","Gal":"GAL","Eph":"EPH",
    "Phil":"PHP","Col":"COL","1Thess":"1TH","2Thess":"2TH",
    "1Tim":"1TI","2Tim":"2TI","Titus":"TIT","Phlm":"PHM",
    "Heb":"HEB","Jas":"JAS","1Pet":"1PE","2Pet":"2PE",
    "1John":"1JN","2John":"2JN","3John":"3JN","Jude":"JUD","Rev":"REV",
}

def parse_openbible_ref(ref):
    parts = ref.strip().split(".")
    if len(parts) != 3:
        return None
    osis = OPENBIBLE_BOOK.get(parts[0])
    if not osis:
        return None
    try:
        return osis, int(parts[1]), int(parts[2])
    except ValueError:
        return None

def import_cross_references(cur):
    print("\n[6/6] Importing cross-references...")
    # Check data/ folder first (same convention as all other source files),
    # then fall back to .cache/, then try downloading.
    local = DATA_DIR / "openbible_xref.zip"
    if local.exists():
        print(f"  [local] openbible_xref.zip")
        raw_bytes = local.read_bytes()
    else:
        try:
            raw_bytes = download(OPENBIBLE_URL, "openbible_xref.zip", binary=True)
        except Exception as e:
            print(f"  WARNING: {e}. Skipping cross-references.")
            print(f"  → Download manually: {OPENBIBLE_URL}")
            print(f"  → Save as: data/openbible_xref.zip")
            return

    with zipfile.ZipFile(io.BytesIO(raw_bytes)) as zf:
        tsv_name = next((n for n in zf.namelist()
                         if n.endswith((".txt", ".tsv", ".csv")) and "/" not in n.lstrip("/")), None)
        if not tsv_name:
            # fallback: first non-directory entry
            tsv_name = next(n for n in zf.namelist() if not n.endswith("/"))
        tsv_text = zf.read(tsv_name).decode("utf-8")

    rows, skipped_v, skipped_p = [], 0, 0
    for line in tsv_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        try:
            votes = int(parts[2])
        except ValueError:
            continue
        if votes < MIN_VOTES:
            skipped_v += 1
            continue
        f = parse_openbible_ref(parts[0])
        t = parse_openbible_ref(parts[1])
        if not f or not t:
            skipped_p += 1
            continue
        rows.append((f[0], f[1], f[2], t[0], t[1], t[2], votes))

    cur.executemany(
        "INSERT INTO cross_reference (from_book,from_chapter,from_verse,to_book,to_chapter,to_verse,votes) "
        "VALUES (?,?,?,?,?,?,?)",
        rows
    )
    print(f"  {len(rows):,} cross-references (votes ≥ {MIN_VOTES})")
    print(f"  Skipped: {skipped_v:,} low-vote | {skipped_p:,} unparseable")

# ─────────────────────────────────────────────
# Step 7 — Finalize
# ─────────────────────────────────────────────

def _backfill_strongs_originals_from_macula(cur):
    """
    Populate strongs.original (Hebrew/Greek script lemma) from word.lemma.

    Runs AFTER both import_macula_hebrew() and import_macula_greek() so the
    word table is fully populated.  Uses the first non-empty lemma found for
    each Strong's ID — Macula lemmas are normalised lexical forms so any row
    for that ID gives the same (or equivalent) value.

    This replaces the old openscriptures JSON approach: we never need
    strongsHebrew.json / strongsGreek.json for the original-script column.
    """
    print("\n[6b] Backfilling strongs.original from Macula word.lemma...")
    cur.execute("""
        UPDATE strongs
        SET original = (
            SELECT lemma FROM word
            WHERE word.strongs_id = strongs.id
              AND lemma IS NOT NULL AND lemma != ''
            LIMIT 1
        )
        WHERE (original IS NULL OR original = '')
          AND EXISTS (
                SELECT 1 FROM word
                WHERE word.strongs_id = strongs.id
                  AND lemma IS NOT NULL AND lemma != ''
              )
    """)
    print(f"  Backfilled: {cur.rowcount:,} Strong's entries got original from Macula")


def _apply_xlit_fallback(cur):
    """
    DEPRECATED — no longer called in the build pipeline.

    Previously derived xlit_simple from strongs.transliteration (openscriptures
    academic notation like ʾašrēy) via simplify_xlit().  Superseded by
    _apply_word_table_xlit_fallback which uses word.xlit / xlit_slot from
    TBESH and BibleHub — the actual authoritative sources for xlit_simple.

    Kept for reference; remove in a future cleanup sprint.
    """
    print("\n[4c] Applying xlit_simple fallback for entries without TBESH data...")
    cur.execute(
        "SELECT id, transliteration FROM strongs "
        "WHERE (xlit_simple IS NULL OR xlit_simple = '') "
        "  AND transliteration IS NOT NULL AND transliteration != ''"
    )
    rows = cur.fetchall()
    updated = 0
    for sid, academic in rows:
        simplified = simplify_xlit(academic)
        if simplified:
            cur.execute(
                "UPDATE strongs SET xlit_simple = ? WHERE id = ?",
                (simplified, sid)
            )
            updated += 1
    print(f"  Fallback filled: {updated:,} entries")


def _apply_word_table_xlit_fallback(cur):
    """
    4th and final fallback for strongs entries that survived all previous steps
    with no xlit_simple or short_def.

    Targets ~507 Macula sub-entry stubs (H871a, H1886a, H2050b, H3807a, ...)
    that are:
      - NOT in the openscriptures JSON (only bare IDs there)
      - NOT in TBESH (covers morphological vocabulary, not every Macula sub-entry)
      - Have no academic 'transliteration' (stub rows only have id + language)

    Three-pass strategy for xlit_simple (in priority order):
      Pass 1: word.xlit     — per-occurrence Macula TSV transliteration (most tokens)
      Pass 2: word.xlit_slot — BibleHub combined slot translit (covers suffix tokens
                               where word.xlit is NULL, e.g. H2050c וֹ, H3509b כּ)
      Pass 3: hardcoded suffix dict — known Macula pronominal-suffix IDs not in TBESH
      Pass 4: base-entry fallback — rare proper-name variants (H758a → H758 xlit)

    For short_def: one pass using word.gloss (most common value per strongs_id).

    Must run AFTER import_macula_hebrew and import_macula_greek so the word table
    is populated.  Safe to re-run (only fills NULL/empty fields).
    """
    print("\n[4d] Applying word-table xlit/gloss fallback for remaining stubs...")
    total_xlit = 0

    # Pass 1: word.xlit (standalone token transliteration)
    cur.execute("""
        UPDATE strongs
        SET xlit_simple = (
            SELECT w.xlit
            FROM word w
            WHERE w.strongs_id = strongs.id
              AND w.xlit IS NOT NULL AND w.xlit != ''
            GROUP BY w.xlit
            ORDER BY COUNT(*) DESC
            LIMIT 1
        )
        WHERE (xlit_simple IS NULL OR xlit_simple = '')
          AND EXISTS (
              SELECT 1 FROM word w
              WHERE w.strongs_id = strongs.id
                AND w.xlit IS NOT NULL AND w.xlit != ''
          )
    """)
    pass1 = cur.rowcount
    total_xlit += pass1

    # Pass 2: word.xlit_slot (BibleHub combined slot translit — covers suffix tokens
    # like H2050c וֹ whose word.xlit is NULL because they are bound morphemes)
    cur.execute("""
        UPDATE strongs
        SET xlit_simple = (
            SELECT w.xlit_slot
            FROM word w
            WHERE w.strongs_id = strongs.id
              AND w.xlit_slot IS NOT NULL AND w.xlit_slot != ''
            GROUP BY w.xlit_slot
            ORDER BY COUNT(*) DESC
            LIMIT 1
        )
        WHERE (xlit_simple IS NULL OR xlit_simple = '')
          AND EXISTS (
              SELECT 1 FROM word w
              WHERE w.strongs_id = strongs.id
                AND w.xlit_slot IS NOT NULL AND w.xlit_slot != ''
          )
    """)
    pass2 = cur.rowcount
    total_xlit += pass2

    # Pass 3: hardcoded xlit for known Macula pronominal-suffix IDs.
    # These are morphological sub-entries unique to the Macula annotation scheme —
    # they don't appear in TBESH, openscriptures, or BibleHub (hence NULL in all
    # prior passes).  Transliterations follow the simplified convention used by TBESH.
    SUFFIX_XLIT = {
        # vav conjunction/suffix variants
        "H2050c": "o",    # וֹ  3ms pronominal suffix (holam)
        "H2050d": "va",   # וָ  vav + qamets (before some gutturals)
        # definite article variants
        "H1886c": "ha",   # הָ  article + patach furtive
        "H1886d": "he",   # הֶ  article before guttural with segol
        # pronominal suffixes (3ms, 1cp, etc.)
        "H1930a": "hu",   # הוּ 3ms suffix (alternate spelling)
        "H5105b": "nu",   # נּוּ 1cp suffix (-enu / -nu)
        "H5105a": "ni",   # נִּי 1cs suffix (-ni)
        # inseparable preposition variants
        "H3509a": "k",    # כְּ  inseparable kaf (sheva)
        "H3509b": "ka",   # כַּ  inseparable kaf (patach)
        "H3509c": "ko",   # כּ   inseparable kaf (other vowel)
        # lamed variants occasionally sub-entered by Macula
        "H3808a": "l",    # לְ  inseparable lamed
        "H3808b": "la",   # לַ
        # Rare OT place-name variants whose base IDs never appear in Macula word table
        # (no base row exists → pass 4 base-fallback can't resolve them)
        "H3565a": "kor-a.shan",   # כּוֹר עָשָׁן  Kor-ashan
        "H3592a": "ki.don",       # כִּידוֹן      Kidon
        "H5225a": "na.kon",       # נָכוֹן        Nacon
        "H5626a": "se.ra",        # שֶׁרַע         Serah
        "H5886a": "en-hak.ko.re", # עֵין הַקּוֹרֵא En-hakkore
    }
    pass3 = 0
    for sid, xlit_val in SUFFIX_XLIT.items():
        cur.execute(
            "UPDATE strongs SET xlit_simple = ? WHERE id = ? AND (xlit_simple IS NULL OR xlit_simple = '')",
            (xlit_val, sid)
        )
        pass3 += cur.rowcount
    total_xlit += pass3

    # Pass 4: base-entry fallback for remaining rare sub-entries (proper-name variants
    # like H758a/b/c, H425b, H8407a, H2361a — a handful of occurrences each).
    # Strip the suffix letter and copy xlit_simple from the base strongs entry.
    import re as _re
    cur.execute("""
        SELECT id FROM strongs
        WHERE (xlit_simple IS NULL OR xlit_simple = '')
          AND EXISTS (SELECT 1 FROM word w WHERE w.strongs_id = strongs.id)
    """)
    still_missing = [r[0] for r in cur.fetchall()]
    pass4 = 0
    for sid in still_missing:
        m = _re.match(r'^([HG]\d+)[a-z]$', sid)
        if not m:
            continue
        base_sid = m.group(1)
        cur.execute("SELECT xlit_simple FROM strongs WHERE id = ? AND xlit_simple IS NOT NULL AND xlit_simple != ''",
                    (base_sid,))
        row = cur.fetchone()
        if row:
            cur.execute("UPDATE strongs SET xlit_simple = ? WHERE id = ?", (row[0], sid))
            pass4 += 1
    total_xlit += pass4

    # short_def: most common word.gloss for this strongs_id
    cur.execute("""
        UPDATE strongs
        SET short_def = (
            SELECT w.gloss
            FROM word w
            WHERE w.strongs_id = strongs.id
              AND w.gloss IS NOT NULL AND w.gloss != ''
            GROUP BY w.gloss
            ORDER BY COUNT(*) DESC
            LIMIT 1
        )
        WHERE (short_def IS NULL OR short_def = '')
          AND EXISTS (
              SELECT 1 FROM word w
              WHERE w.strongs_id = strongs.id
                AND w.gloss IS NOT NULL AND w.gloss != ''
          )
    """)
    gloss_filled = cur.rowcount

    print(f"  Word-table fallback xlit: pass1={pass1} (word.xlit), "
          f"pass2={pass2} (xlit_slot), pass3={pass3} (suffix dict), "
          f"pass4={pass4} (base fallback) = {total_xlit} total")
    print(f"  Word-table fallback short_def: {gloss_filled:,} filled")


def build_verse_fts(cur, con):
    """FTS5 virtual table for full-text search across all verse translations.

    Uses content='verse' so only the inverted index is stored (no text duplication).
    verse_fts.rowid == verse.rowid → JOIN back to get book_id/chapter/verse/translation.

    Tokenizer: unicode61 with remove_diacritics=2 (strips combining marks before indexing).
    This means "αβγ" and "αβγ̈" tokenize identically — useful for accented Biblical Greek.

    NOTE: content tables are read-only at runtime; rebuild happens here at build time only.
    """
    print("\nBuilding FTS5 verse index...")
    t0 = time.time()

    cur.executescript("""
        DROP TABLE IF EXISTS verse_fts;

        CREATE VIRTUAL TABLE verse_fts USING fts5(
            text,
            content='verse',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );

        -- Populate the shadow tables from the content table.
        -- 'rebuild' scans the content table and fills all FTS internals.
        INSERT INTO verse_fts(verse_fts) VALUES('rebuild');
    """)
    con.commit()

    cur.execute("SELECT COUNT(*) FROM verse_fts")
    count = cur.fetchone()[0]
    print(f"  verse_fts: {count:,} rows ({time.time() - t0:.1f}s)")


def build_search_terms(cur, con):
    """Deduplicated word list for autocomplete suggestions (predictive search).

    Extracts all words from cleaned verse texts across all translations.
    Stores lowercase terms with occurrence frequency so the iOS app can do fast
    prefix suggestions:  SELECT term FROM search_terms WHERE term GLOB 'prefix*'
                         ORDER BY freq DESC LIMIT 8

    Terms are stored lowercase → callers must lowercase their prefix before querying.
    Minimum word length: 2 chars. Minimum frequency: 2 occurrences (filters noise/typos).
    """
    print("\nBuilding search_terms for autocomplete...")
    t0 = time.time()

    # Strip all MyBible markup tags before tokenizing
    tag_re  = re.compile(r'<[^>]+>')
    word_re = re.compile(r"[\wЀ-ӿ']+", re.UNICODE)  # ASCII + Cyrillic + apostrophe

    term_freq: dict[str, int] = {}

    cur.execute("SELECT text FROM verse")
    for (raw_text,) in cur.fetchall():
        clean = tag_re.sub(' ', raw_text)
        for w in word_re.findall(clean):
            w_lower = w.lower()
            if len(w_lower) >= 2:
                term_freq[w_lower] = term_freq.get(w_lower, 0) + 1

    # Keep only terms that appear at least twice (filters single-verse hapax and noise)
    terms = [(t, f) for t, f in term_freq.items() if f >= 2]
    terms.sort(key=lambda x: -x[1])   # most frequent first

    cur.executescript("""
        DROP TABLE IF EXISTS search_terms;
        CREATE TABLE search_terms (
            term TEXT PRIMARY KEY,
            freq INTEGER NOT NULL DEFAULT 1
        );
    """)

    cur.executemany(
        "INSERT OR IGNORE INTO search_terms(term, freq) VALUES (?, ?)",
        terms
    )
    con.commit()

    print(f"  search_terms: {len(terms):,} unique words ({time.time() - t0:.1f}s)")

    # V1.5 placeholder — embeddings will live here
    # build_verse_vectors(cur, con)


def finalize(cur, con):
    print("\nFinalizing...")
    cur.execute("PRAGMA optimize")
    cur.execute("ANALYZE")
    # Ensure DB is in DELETE journal mode (not WAL) so it can be bundled as a single file
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    cur.execute("PRAGMA journal_mode=DELETE")
    for tbl in ("book","translation","verse","word","strongs","footnote",
                "cross_reference","search_terms"):
        cur.execute(f"SELECT COUNT(*) FROM {tbl}")
        print(f"  {tbl}: {cur.fetchone()[0]:,} rows")
    # FTS5 shadow tables don't report via COUNT(*) on the virtual table the same way
    cur.execute("SELECT COUNT(*) FROM verse_fts")
    print(f"  verse_fts:  {cur.fetchone()[0]:,} rows")
    con.commit()
    mb = OUTPUT_DB.stat().st_size / 1_048_576
    print(f"\n✓ Done: {OUTPUT_DB}  ({mb:.1f} MB)")
    print("\nNext: drag sourcebible.db into Xcode → SourceBible/Resources/")
    print("      Make sure 'Copy items if needed' and your app target are checked.")

# ─────────────────────────────────────────────
# Step 2b — Apply BibleHub Hebrew transliterations (positional)
# ─────────────────────────────────────────────

# Macula-internal helper tokens that BibleHub never assigns a transliteration to.
# These are empty morphological slots (e.g. H871a = preposition בְּ that fuses into
# the following word's display form).  Slots where ALL tokens are helpers are not
# counted as "display words" for the purpose of aligning with BibleHub position keys.
HELPER_STRONGS = {"H1886a", "H871a", "H3509a", "H1930a",
                  "H2050b", "H2050c", "H2050d", "H5105b"}


def _apply_bh_hebrew_translit(cur):
    """
    Populate word.xlit_slot for all OT Hebrew words using BibleHub positional translit.
    Reads data/hebrew_translit.json (produced by fetch_biblehub_translit_hebrew.py).

    Match logic (ADR-020):
    - For each verse, get all (word_id, slot, strongs_id) from Macula.
    - "Display slots": distinct slot values containing >= 1 non-helper token, sorted asc.
    - BH display word K maps to display_slot[K-1].
    - All Macula tokens sharing that slot get xlit_slot = BH transliteration at position K.
    - If len(display_slots) != BH count: skip with COUNT_MISMATCH (no corruption).
    """
    bh_path = DATA_DIR / "hebrew_translit.json"
    if not bh_path.exists():
        print("\n[2b] Skipping BH Hebrew xlit — hebrew_translit.json not found.")
        print("     Run: python3 scripts/fetch_biblehub_translit_hebrew.py")
        return

    bh_data = json.loads(bh_path.read_text("utf-8"))
    print(f"\n[2b] Applying BH Hebrew transliterations ({len(bh_data):,} entries)...")

    # Fetch all OT Hebrew verses
    cur.execute("""
        SELECT DISTINCT book_id, chapter, verse
        FROM word WHERE language = 'hbo'
        ORDER BY book_id, chapter, verse
    """)
    verses = cur.fetchall()

    updates = []
    updated = skipped = mismatch = 0

    for (book_id, ch, vs) in verses:
        verse_key = "%s:%d:%d" % (book_id, ch, vs)

        bh_count = bh_data.get("%s:count" % verse_key)
        if bh_count is None:
            skipped += 1
            continue

        cur.execute("""
            SELECT id, slot, strongs_id
            FROM word
            WHERE book_id=? AND chapter=? AND verse=? AND language='hbo'
            ORDER BY slot, position
        """, (book_id, ch, vs))
        tokens = cur.fetchall()
        if not tokens:
            continue

        # Compute display slots (distinct slot values with >= 1 non-helper token)
        slot_has_display = {}
        for (wid, tok_slot, sids) in tokens:
            if tok_slot is None:
                continue
            if tok_slot not in slot_has_display:
                slot_has_display[tok_slot] = False
            if sids not in HELPER_STRONGS:
                slot_has_display[tok_slot] = True

        display_slots = sorted(k for k, v in slot_has_display.items() if v)

        if len(display_slots) != bh_count:
            mismatch += 1
            continue

        # Map each display slot -> BH translit
        slot_to_xlit = {}
        for bh_pos, dslot in enumerate(display_slots, 1):
            entry = bh_data.get("%s:%d" % (verse_key, bh_pos))
            if entry and isinstance(entry, dict):
                t = entry.get("translit", "")
                if t:
                    slot_to_xlit[dslot] = t

        for (wid, tok_slot, sids) in tokens:
            if tok_slot is not None and tok_slot in slot_to_xlit:
                # Only set xlit_slot on the ROOT (non-helper) token.
                # Helper tokens (H1886a, H871a, etc.) fall back to their own
                # per-token xlit/xlitSimple so they don't show the combined
                # slot translit (e.g. hā-'îš) where their own short form belongs.
                if sids not in HELPER_STRONGS:
                    updates.append((slot_to_xlit[tok_slot], wid))
                    updated += 1

        if len(updates) >= 5000:
            cur.executemany("UPDATE word SET xlit_slot=? WHERE id=?", updates)
            updates.clear()

    if updates:
        cur.executemany("UPDATE word SET xlit_slot=? WHERE id=?", updates)

    print("  xlit_slot set for %d tokens (%d verses skipped, %d count mismatches)" % (
        updated, skipped, mismatch
    ))


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

def main():
    print("=" * 55)
    print("  SourceBible Database Builder")
    print("=" * 55)
    print(f"  Output:  {OUTPUT_DB}")
    print(f"  Data:    {DATA_DIR}")
    print(f"  Cache:   {CACHE_DIR}")

    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    con = sqlite3.connect(OUTPUT_DB)
    cur = con.cursor()
    cur.executescript(SCHEMA)
    con.commit()

    import_books(cur);              con.commit()
    _seed_strongs_stubs(cur);       con.commit()   # seeds every Macula Strong's ID (FK); was a safety net for import_strongs, now the sole seeder
    import_stepbible_lexicons(cur); con.commit()   # enriches strongs with BDB + xlit_simple (TBESH/TBESG, exact ID only)
    import_stepbible_lexicons(cur); con.commit()   # enriches strongs with BDB + xlit_simple (TBESH/TBESG, exact ID only)
    # _apply_xlit_fallback removed: it derived xlit_simple from openscriptures academic
    # transliteration (ʾašrēy-style notation), which is neither TBESH nor BH format.
    # _apply_word_table_xlit_fallback (below, after Macula import) handles the same
    # cases better using actual word.xlit / xlit_slot values from TBESH and BH sources.
    verify_xlit_integrity(cur);     con.commit()   # fail-fast: abort if any sub-entry got wrong xlit from base entry
    import_macula_hebrew(cur);      con.commit()   # populates word table (surface, lemma, morph, gloss, xlit, slot from TSV)
    _apply_bh_hebrew_translit(cur); con.commit()   # populates xlit_slot from BH positional translit (ADR-020)
    enrich_macula_from_xml(cur);    con.commit()   # populates gloss_macula, syntax_role, greek, greek_strong from XML
    import_macula_greek(cur);            con.commit()
    enrich_macula_greek_from_xml(cur);   con.commit()   # populates after_char for Greek words
    _backfill_strongs_originals_from_macula(cur); con.commit()  # fills strongs.original from word.lemma (Macula)
    _apply_word_table_xlit_fallback(cur); con.commit()          # fills xlit_simple/short_def for ~507 sub-entry stubs not in TBESH
    import_translations(cur);            con.commit()
    import_footnotes(cur);          con.commit()
    import_cross_references(cur);   con.commit()
    build_verse_fts(cur, con);      con.commit()   # FTS5 index for text search
    build_search_terms(cur, con);   con.commit()   # autocomplete word list
    finalize(cur, con)
    con.close()

if __name__ == "__main__":
    main()
