#!/usr/bin/env python3
"""
import_commentaries.py — Import all public-domain commentaries into sourcebible.db

Sources (all in data/):
  CalvinCommentaries.zip          — SWORD zCom, OSIS XML, Public Domain
  matthew_henry.zip               — HTML files (MHC{bb}{ccc}.HTM), Public Domain
  chspurgeon-tod-main.zip         — Markdown, Psalms only, MIT
  OwenHebrews-commentary.cmtx    — SQLite/RTF, Hebrews only

Usage (run on Mac only — APFS sparse file):
    python3 scripts/import_commentaries.py [path/to/sourcebible.db]

Default DB path: SourceBible/Resources/sourcebible.db

Schema
──────
  comments       — one row per original commentary section (authorial structure preserved)
  comment_verses — one lookup row per verse covered; FK → comments.id

Lookup: user taps verse → find comment_id in comment_verses → load full text from comments.
Never fragment a commentary section just because it spans multiple verses.

─── LICENSING NOTE — Owen ────────────────────────────────────────────────────
OwenHebrews-commentary.cmtx is public domain text but was obtained under a
licence that prohibits selling it or bundling it in any commercial package.
The app may distribute this data for FREE. If a subscription/paid model is
introduced in the future, this source must be replaced with a different
public-domain edition of Owen's Hebrews commentary (e.g. from CCEL or similar)
before the paid tier ships.
───────────────────────────────────────────────────────────────────────────────
"""

import sys
import os
import re
import struct
import zlib
import zipfile
import sqlite3

# ─── Book number → DB book_id ────────────────────────────────────────────────
BOOK_NUM_TO_ID = {
     1: "GEN",  2: "EXO",  3: "LEV",  4: "NUM",  5: "DEU",
     6: "JOS",  7: "JDG",  8: "RUT",  9: "1SA", 10: "2SA",
    11: "1KI", 12: "2KI", 13: "1CH", 14: "2CH", 15: "EZR",
    16: "NEH", 17: "EST", 18: "JOB", 19: "PSA", 20: "PRO",
    21: "ECC", 22: "SNG", 23: "ISA", 24: "JER", 25: "LAM",
    26: "EZK", 27: "DAN", 28: "HOS", 29: "JOL", 30: "AMO",
    31: "OBA", 32: "JON", 33: "MIC", 34: "NAM", 35: "HAB",
    36: "ZEP", 37: "HAG", 38: "ZEC", 39: "MAL",
    40: "MAT", 41: "MRK", 42: "LUK", 43: "JHN", 44: "ACT",
    45: "ROM", 46: "1CO", 47: "2CO", 48: "GAL", 49: "EPH",
    50: "PHP", 51: "COL", 52: "1TH", 53: "2TH", 54: "1TI",
    55: "2TI", 56: "TIT", 57: "PHM", 58: "HEB", 59: "JAS",
    60: "1PE", 61: "2PE", 62: "1JN", 63: "2JN", 64: "3JN",
    65: "JUD", 66: "REV",
}

# OSIS abbreviation → DB book_id  (Calvin)
OSIS_TO_DB = {
    "Gen": "GEN", "Exod": "EXO", "Lev": "LEV", "Num": "NUM", "Deut": "DEU",
    "Josh": "JOS", "Judg": "JDG", "Ruth": "RUT", "1Sam": "1SA", "2Sam": "2SA",
    "1Kgs": "1KI", "2Kgs": "2KI", "1Chr": "1CH", "2Chr": "2CH",
    "Ezra": "EZR", "Neh": "NEH", "Esth": "EST", "Job": "JOB",
    "Ps": "PSA", "Prov": "PRO", "Eccl": "ECC", "Song": "SNG",
    "Isa": "ISA", "Jer": "JER", "Lam": "LAM", "Ezek": "EZK",
    "Dan": "DAN", "Hos": "HOS", "Joel": "JOL", "Amos": "AMO",
    "Obad": "OBA", "Jonah": "JON", "Mic": "MIC", "Nah": "NAM",
    "Hab": "HAB", "Zeph": "ZEP", "Hag": "HAG", "Zech": "ZEC", "Mal": "MAL",
    "Matt": "MAT", "Mark": "MRK", "Luke": "LUK", "John": "JHN",
    "Acts": "ACT", "Rom": "ROM", "1Cor": "1CO", "2Cor": "2CO",
    "Gal": "GAL", "Eph": "EPH", "Phil": "PHP", "Col": "COL",
    "1Thess": "1TH", "2Thess": "2TH", "1Tim": "1TI", "2Tim": "2TI",
    "Titus": "TIT", "Phlm": "PHM", "Heb": "HEB", "Jas": "JAS",
    "1Pet": "1PE", "2Pet": "2PE", "1John": "1JN", "2John": "2JN",
    "3John": "3JN", "Jude": "JUD", "Rev": "REV",
}

# ─── DB helpers ──────────────────────────────────────────────────────────────

def insert_section(cur, source, book_id, start_ch, start_vs, end_ch, end_vs, text):
    """Insert one commentary section; return its row id."""
    cur.execute(
        "INSERT INTO comments(source,book_id,start_chapter,start_verse,"
        "end_chapter,end_verse,text) VALUES(?,?,?,?,?,?,?)",
        (source, book_id, start_ch, start_vs, end_ch, end_vs, text),
    )
    return cur.lastrowid


def insert_verse_index(cur, comment_id, book_id, chapter, verse):
    cur.execute(
        "INSERT OR IGNORE INTO comment_verses(comment_id,book_id,chapter,verse)"
        " VALUES(?,?,?,?)",
        (comment_id, book_id, chapter, verse),
    )


def index_range(cur, comment_id, book_id, start_ch, start_vs, end_ch, end_vs):
    """Create comment_verses rows for every verse in [start..end]."""
    if start_ch == end_ch:
        for v in range(start_vs, end_vs + 1):
            insert_verse_index(cur, comment_id, book_id, start_ch, v)
    else:
        # Multi-chapter range — just index start and end verses
        # (cross-chapter ranges are rare; exact verse counts not needed)
        insert_verse_index(cur, comment_id, book_id, start_ch, start_vs)
        insert_verse_index(cur, comment_id, book_id, end_ch, end_vs)


# ============================================================
#  CALVIN — OSIS-direct section parsing
# ============================================================
#
# The BZV verse-ordinal index slices the OSIS at arbitrary byte offsets that
# do NOT respect section boundaries, producing truncated/mid-sentence text.
# The correct approach (per spec) is to parse the decompressed OSIS blocks
# directly: every <div annotateRef="..." sID="..." type="section"/> is one
# commentary unit. Text runs from that marker to the next section marker.

# Matches ONLY sID (start) section markers — osisID is absent on eID markers.
_CALVIN_SID = re.compile(
    r'<div annotateRef="Bible:([^"]+)" annotateType="commentary"'
    r' osisID="[^"]*" sID="[^"]*" type="section"/>'
)


def _strip_osis(raw: str) -> str:
    """OSIS XML → clean plain text."""
    text = re.sub(r"<note\b[^>]*>.*?</note>", " ", raw, flags=re.DOTALL)
    text = re.sub(r'<div\s+eID="[^"]*"\s+type="x-p"\s*/>', "\n\n", text)
    text = re.sub(r"<lb\s*/>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    text = text.replace("&apos;", "'").replace("&quot;", '"')
    lines = [re.sub(r"[ \t]+", " ", l).strip() for l in text.split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def _parse_osis_ref(ref: str):
    """
    Parse 'Gen.1.1' → ('GEN', 1, 1) or 'Ps.1' → ('PSA', 1, None).
    Returns None if ref is unrecognisable.
    """
    parts = ref.split(".")
    book_id = OSIS_TO_DB.get(parts[0])
    if not book_id:
        return None
    try:
        ch = int(parts[1])
        vs = int(parts[2]) if len(parts) >= 3 else None
        return book_id, ch, vs
    except (IndexError, ValueError):
        return None


def import_calvin(zip_path: str, cur) -> int:
    total = 0
    with zipfile.ZipFile(zip_path) as z:
        for side in ("ot", "nt"):
            prefix = f"modules/comments/zcom/calvincommentaries/{side}"
            bzs = z.read(f"{prefix}.bzs")
            bzz = z.read(f"{prefix}.bzz")
            blocks = [struct.unpack_from("<III", bzs, i * 12)
                      for i in range(len(bzs) // 12)]

            for off, comp, _ in blocks:
                if comp == 0:
                    continue
                block_text = zlib.decompress(
                    bzz[off: off + comp]
                ).decode("utf-8", errors="replace")

                # Find all sID section starts in this block
                markers = [
                    (m.start(), m.group(1))
                    for m in _CALVIN_SID.finditer(block_text)
                ]
                if not markers:
                    continue

                for i, (pos, ref) in enumerate(markers):
                    end_pos = markers[i + 1][0] if i + 1 < len(markers) else len(block_text)
                    parsed = _parse_osis_ref(ref)
                    if parsed is None:
                        continue
                    book_id, ch, vs = parsed

                    raw = block_text[pos:end_pos]
                    text = _strip_osis(raw)
                    if not text:
                        continue

                    if vs is None:
                        # Chapter-level intro (e.g. 'Ps.1') — store but don't
                        # add to per-verse index; verse 0 = chapter overview.
                        comment_id = insert_section(
                            cur, "Calvin", book_id, ch, 0, ch, 0, text
                        )
                    else:
                        comment_id = insert_section(
                            cur, "Calvin", book_id, ch, vs, ch, vs, text
                        )
                        insert_verse_index(cur, comment_id, book_id, ch, vs)
                        total += 1

    return total


# ============================================================
#  MATTHEW HENRY — HTML per-chapter files
# ============================================================

def _strip_henry_html(html: str) -> str:
    text = re.sub(r"(?i)<script[^>]*>.*?</script>", " ", html, flags=re.DOTALL)
    text = re.sub(r"(?i)<style[^>]*>.*?</style>", " ", text, flags=re.DOTALL)
    text = re.sub(r"(?i)<(?:p|br|tr|/tr|/td|/th|hr)[^>]*>", "\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&")
    text = text.replace("&lt;", "<").replace("&gt;", ">")
    text = text.replace("&quot;", '"').replace("&#39;", "'").replace("&apos;", "'")
    lines = [re.sub(r" {2,}", " ", l).strip() for l in text.split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


_HENRY_CLUSTER_GAP = 1500  # max chars between a verse anchor and the TABLE it precedes


def _henry_extract_sections(html: str):
    """
    Returns [(verse_list, text), ...] — one entry per commentary section.
    verse_list = list of verse ints explicitly declared by Henry for that section.

    Henry marks each section boundary with a block of verse anchors immediately
    followed by a <TABLE> section header.  Some sections also have an optional
    <A NAME="SecN"> anchor between the verse cluster and the TABLE, but many do
    not (e.g. Genesis 2:4-7 has no SecN).

    The reliable pattern is therefore:
        <A NAME="Ge2_4"> <A NAME="Ge2_5"> ... <A NAME="Ge2_7">
        <TABLE ...>  ← section header (title, date, horizontal rule)
        <P> ... commentary text ...

    Algorithm:
    1. Find all <TABLE> positions where at least one verse anchor appears within
       _HENRY_CLUSTER_GAP chars before it — these are section-header tables.
    2. For each such TABLE, collect all verse anchors within the gap before it
       as the section's explicit verse list.
    3. Section content = from the TABLE to the next section TABLE (or end of file).
    4. The verse list is used directly — Henry always lists every verse explicitly,
       so no range inference is needed.
    """
    # bug-010: each chapter file ends with a `<!-- (End Body) -->` comment followed by
    # the site footer (TOC / Previous / Next / Back-to-BiblesNet / Free Download /
    # Contact Us). The final section is sliced to len(html), so that boilerplate leaked
    # into the commentary body. Truncate at the body-end marker first. One file
    # (Habakkuk 1) writes it malformed as `<! -- (End Body) -->`, hence the tolerant \s*.
    html = re.split(r"<!\s*--\s*\(End Body\)\s*-->", html, maxsplit=1)[0]

    verse_re = re.compile(r'^[A-Za-z]+\d+_(\d+)$')

    # All named anchors in document order
    anchors = [(m.start(), m.group(1))
               for m in re.finditer(r'<A\s+NAME="([^"]+)"', html, re.IGNORECASE)]

    # --- Step 1: find section-header TABLE positions ---
    # A TABLE is a section header iff there is at least one verse anchor within
    # _HENRY_CLUSTER_GAP chars before it.
    section_tables = []  # [(table_pos, [verse_ints])]

    for tm in re.finditer(r'<TABLE\b', html, re.IGNORECASE):
        tpos = tm.start()
        cluster = sorted(set(
            int(verse_re.match(name).group(1))
            for pos, name in anchors
            if verse_re.match(name) and 0 < tpos - pos <= _HENRY_CLUSTER_GAP
        ))
        if cluster:
            section_tables.append((tpos, cluster))

    if not section_tables:
        return []

    # --- Step 2: build result list ---
    result = []
    for i, (tpos, cluster) in enumerate(section_tables):
        end_pos = section_tables[i + 1][0] if i + 1 < len(section_tables) else len(html)
        text = _strip_henry_html(html[tpos:end_pos])
        if text:
            result.append((cluster, text))

    return result


def import_henry(zip_path: str, cur) -> int:
    total = 0
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            m = re.match(r'MHC(\d{2})(\d{3})\.HTM$', name, re.IGNORECASE)
            if not m:
                continue
            book_num = int(m.group(1))
            chapter  = int(m.group(2))
            if chapter == 0:
                continue
            book_id = BOOK_NUM_TO_ID.get(book_num)
            if not book_id:
                continue

            html  = z.read(name).decode("latin-1", errors="replace")
            sects = [(vs, tx) for vs, tx in _henry_extract_sections(html) if vs]
            for i, (verses, text) in enumerate(sects):
                start_vs = min(verses)
                end_vs   = max(verses)

                # Extend the verse index to next section's start - 1 so that
                # in-body verse anchors (e.g. Ge3_9-13 deep in section v6-8)
                # still resolve to the correct commentary block.
                # The comments table stores the explicit cluster range (start/end);
                # comment_verses covers the extended range for lookup.
                if i + 1 < len(sects):
                    next_start   = min(sects[i + 1][0])
                    extended_end = next_start - 1
                else:
                    extended_end = end_vs

                comment_id = insert_section(
                    cur, "Henry", book_id, chapter, start_vs, chapter, end_vs, text
                )
                for v in range(start_vs, extended_end + 1):
                    insert_verse_index(cur, comment_id, book_id, chapter, v)
                total += 1
    return total


# ============================================================
#  SPURGEON — Treasury of David (Markdown, Psalms only)
# ============================================================

def _parse_verse_header(header: str):
    h = header.strip().lstrip("#").strip()
    m = re.match(r'Verses?\s+(\d+)\s*[-–]\s*(\d+)$', h, re.IGNORECASE)
    if m:
        return list(range(int(m.group(1)), int(m.group(2)) + 1))
    m = re.match(r'Verses?\s+(\d+)\s*(?:&|and)\s*(\d+)$', h, re.IGNORECASE)
    if m:
        return [int(m.group(1)), int(m.group(2))]
    m = re.match(r'Verses?\s+(\d+)$', h, re.IGNORECASE)
    if m:
        return [int(m.group(1))]
    return []


def _strip_spurgeon_md(text: str) -> str:
    text = re.sub(r'^>\s*', '', text, flags=re.MULTILINE)
    text = text.replace("&mdash;", "—")
    text = re.sub(r'&[a-z]+;', ' ', text)
    text = re.sub(r'\*{1,3}([^*]+)\*{1,3}', r'\1', text)
    text = re.sub(r'_{1,2}([^_]+)_{1,2}', r'\1', text)
    text = re.sub(r'!\[.*?\]\(.*?\)', '', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)
    lines = [re.sub(r' {2,}', ' ', l).strip() for l in text.split('\n')]
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()


def import_spurgeon(zip_path: str, cur) -> int:
    total = 0
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            m = re.search(r'psalm-(\d+)\.md$', name)
            if not m:
                continue
            psalm_num = int(m.group(1))
            content = z.read(name).decode("utf-8", errors="replace")

            expo_m = re.search(r'^## Exposition', content, re.MULTILINE)
            if not expo_m:
                continue
            next_sec = re.search(r'^## ', content[expo_m.end():], re.MULTILINE)
            expo_end = expo_m.end() + next_sec.start() if next_sec else len(content)
            exposition = content[expo_m.end():expo_end]

            parts = re.split(r'^(### .+)$', exposition, flags=re.MULTILINE)
            i = 1
            while i + 1 < len(parts):
                header = parts[i]
                body   = parts[i + 1]
                i += 2
                verse_nums = _parse_verse_header(header)
                if not verse_nums:
                    continue
                text = _strip_spurgeon_md(body)
                if not text:
                    continue
                start_vs = min(verse_nums)
                end_vs   = max(verse_nums)
                comment_id = insert_section(
                    cur, "Spurgeon", "PSA", psalm_num, start_vs,
                    psalm_num, end_vs, text
                )
                for v in verse_nums:
                    insert_verse_index(cur, comment_id, "PSA", psalm_num, v)
                total += 1
    return total


# ============================================================
#  JOHN OWEN — Exposition of Hebrews (.cmtx = SQLite + RTF)
# ============================================================
#
# LICENSING NOTE: See module docstring — free distribution only.
# Replace source if a paid/subscription tier is introduced.

_BS = chr(92)
_SQ = chr(39)


def _strip_rtf(rtf: str) -> str:
    out   = []
    i     = 0
    n     = len(rtf)
    stack = [(0, False)]   # (font_id, ignore)

    def font():   return stack[-1][0]
    def ignore(): return stack[-1][1]

    while i < n:
        c = rtf[i]
        if c == '{':
            j = i + 1
            while j < n and rtf[j] in ' \t\r\n':
                j += 1
            if rtf[j:j+2] == _BS + '*':
                stack.append((font(), True))
                i = j + 2
            else:
                stack.append((font(), ignore()))
                i += 1
        elif c == '}':
            if len(stack) > 1: stack.pop()
            i += 1
        elif c == _BS:
            nxt = rtf[i+1] if i+1 < n else ''
            if nxt == _SQ:
                bv = int(rtf[i+2:i+4], 16)
                if not ignore():
                    enc = 'cp1253' if font() == 1 else 'cp1252'
                    try: out.append(bytes([bv]).decode(enc))
                    except Exception: pass
                i += 4
            elif nxt == 'u' and i+2 < n and (rtf[i+2].isdigit() or rtf[i+2] == '-'):
                m = re.match(r'\\u(-?[0-9]+)', rtf[i:])
                if m:
                    cp = int(m.group(1))
                    if cp < 0: cp += 65536
                    if not ignore(): out.append(chr(cp))
                    i += len(m.group(0))
                    if i < n and rtf[i] == ' ': i += 1
                    if i < n:
                        if rtf[i] == _BS and i+1 < n and rtf[i+1] == _SQ: i += 4
                        elif rtf[i] == '?': i += 1
                else:
                    i += 1
            elif nxt.isalpha():
                m = re.match(r'\\([a-zA-Z]+)(-?[0-9]+)? ?', rtf[i:])
                if m:
                    word, num = m.group(1), m.group(2)
                    if not ignore():
                        if word in ('par', 'pard'): out.append('\n')
                        elif word == 'line': out.append('\n')
                        elif word == 'tab': out.append('\t')
                        elif word == 'f' and num is not None:
                            stack[-1] = (int(num), stack[-1][1])
                    i += len(m.group(0))
                else:
                    i += 2
            else:
                if not ignore() and nxt in (_BS, '{', '}'): out.append(nxt)
                i += 2
        else:
            if not ignore(): out.append(c)
            i += 1

    text = ''.join(out)
    lines = [re.sub(r'[ \t]{2,}', ' ', l).strip() for l in text.split('\n')]
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()


def _heb_chapter_verse_count(cur, chapter: int) -> int:
    """Return the number of verses in Hebrews chapter N from the verse table."""
    row = cur.execute(
        "SELECT MAX(verse) FROM verse WHERE book_id='HEB' AND chapter=?", (chapter,)
    ).fetchone()
    return row[0] if row and row[0] else 50  # safe fallback


def import_owen(db_path: str, cur) -> int:
    if not os.path.exists(db_path):
        return 0
    total = 0
    src = sqlite3.connect(db_path)
    for ch_begin, ch_end, vs_begin, vs_end, rtf in src.execute(
        "SELECT ChapterBegin, ChapterEnd, VerseBegin, VerseEnd, Comments FROM Verses"
    ):
        text = _strip_rtf(rtf)
        if not text:
            continue
        comment_id = insert_section(
            cur, "Owen", "HEB", ch_begin, vs_begin, ch_end, vs_end, text
        )
        # Expand the verse range for the lookup index.
        # Single-chapter range: straightforward.
        # Multi-chapter range: use actual verse counts from the verse table instead
        # of the old min(v_e, v_s + 50) heuristic which could miss verses in longer
        # chapters if Owen data is ever extended.
        if ch_begin == ch_end:
            for v in range(vs_begin, vs_end + 1):
                insert_verse_index(cur, comment_id, "HEB", ch_begin, v)
        else:
            for ch in range(ch_begin, ch_end + 1):
                v_s = vs_begin if ch == ch_begin else 1
                v_e = vs_end   if ch == ch_end   else _heb_chapter_verse_count(cur, ch)
                for v in range(v_s, v_e + 1):
                    insert_verse_index(cur, comment_id, "HEB", ch, v)
        total += 1
    src.close()
    return total


# ============================================================
#  DB setup
# ============================================================

def setup_db(cur):
    # Drop legacy single-table model
    cur.execute("DROP TABLE IF EXISTS commentary")
    cur.execute("DROP TABLE IF EXISTS comment_verses")
    cur.execute("DROP TABLE IF EXISTS comments")

    cur.execute("""
        CREATE TABLE comments (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            source        TEXT    NOT NULL,
            book_id       TEXT    NOT NULL,
            start_chapter INTEGER NOT NULL,
            start_verse   INTEGER NOT NULL,
            end_chapter   INTEGER NOT NULL,
            end_verse     INTEGER NOT NULL,
            text          TEXT    NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE comment_verses (
            comment_id INTEGER NOT NULL,
            book_id    TEXT    NOT NULL,
            chapter    INTEGER NOT NULL,
            verse      INTEGER NOT NULL,
            PRIMARY KEY (book_id, chapter, verse, comment_id)
        )
    """)
    cur.execute(
        "CREATE INDEX idx_cv ON comment_verses(book_id, chapter, verse)"
    )


# ============================================================
#  Entry point
# ============================================================

def main():
    db_path  = sys.argv[1] if len(sys.argv) > 1 else "SourceBible/Resources/sourcebible.db"
    data_dir = "data"

    paths = {
        "calvin":   os.path.join(data_dir, "CalvinCommentaries.zip"),
        "henry":    os.path.join(data_dir, "matthew_henry.zip"),
        "spurgeon": os.path.join(data_dir, "chspurgeon-tod-main.zip"),
        "owen":     os.path.join(data_dir, "OwenHebrews-commentary.cmtx"),
    }

    for label, p in paths.items():
        if not os.path.exists(p):
            print(f"❌  {label}: {p} not found — skipping")

    if not os.path.exists(db_path):
        print(f"❌  DB not found: {db_path}")
        sys.exit(1)

    print(f"→ Opening {db_path}")
    conn = sqlite3.connect(db_path)
    cur  = conn.cursor()
    setup_db(cur)

    if os.path.exists(paths["calvin"]):
        print("→ Importing Calvin (OSIS-direct)...")
        n = import_calvin(paths["calvin"], cur)
        print(f"   Calvin:   {n:>6} verse sections")

    if os.path.exists(paths["henry"]):
        print("→ Importing Matthew Henry (HTML)...")
        n = import_henry(paths["henry"], cur)
        print(f"   Henry:    {n:>6} sections")

    if os.path.exists(paths["spurgeon"]):
        print("→ Importing Spurgeon — Treasury of David (Markdown)...")
        n = import_spurgeon(paths["spurgeon"], cur)
        print(f"   Spurgeon: {n:>6} sections")

    if os.path.exists(paths["owen"]):
        print("→ Importing Owen — Exposition of Hebrews (SQLite/RTF)...")
        n = import_owen(paths["owen"], cur)
        print(f"   Owen:     {n:>6} sections")

    conn.commit()
    n_comments = cur.execute("SELECT COUNT(*) FROM comments").fetchone()[0]
    n_verses   = cur.execute("SELECT COUNT(*) FROM comment_verses").fetchone()[0]
    conn.close()
    print(f"✓ Done: {n_comments} commentary sections, {n_verses} verse index rows in {db_path}")


if __name__ == "__main__":
    main()
