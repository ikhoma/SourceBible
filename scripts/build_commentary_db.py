#!/usr/bin/env python3
"""
build_commentary_db.py — build commentaries-en.db (ADR-027 canonical schema)

Standalone commentary module per ADR-027 §1 (Amendment 2026-08-28) + Amendment
2026-09-01 (language column, per-language file layout, translation_status
redefinition). Read-only against sourcebible.db (for verse_org org-anchoring)
and data/ sources. Writes commentaries-en.db fresh. NEVER touches
sourcebible.db or any file under scripts/ — this is a new, additive script
per CLAUDE.md rule #1 (explicit "кодимо" received 2026-09-01).

Sources for v1 (commentaries-en.db):
  Calvin    — data/New/Calvin-c.commentaries.PATCHED.SQLite3 (MyBible), sole
              source, no SWORD splice (see commentary-sources-audit.md,
              "Ісая 49-66 та Буття — вирішено"). Drops 6 known garbage rows.
  Henry     — data/New/Henry-c.commentaries.zip -> MHWBC.commentaries.SQLite3
              (MyBible), + manual patch: Luke 16:19-31 ("Rich Man and Lazarus")
              taken from the OLD data/matthew_henry.zip source, which has it
              intact; the New source's row for that range is mislabeled (claims
              16:1-31 but its actual text stops at v18).
  Owen      — data/New/Owen-c.commentaries.zip -> Owen-c.commentaries.SQLite3
              (MyBible), + manual patch: Heb 1:1-2, taken from the OLD
              data/OwenHebrews-commentary.cmtx source (first row, verbatim).
  Spurgeon  — TWO works bundled under source='Spurgeon-TOD' and
              'Spurgeon-VE': Treasury of David (data/chspurgeon-tod-main.zip,
              unchanged import) and Verse Expositions (new work,
              data/New/Spurgeon-c.commentaries.zip -> Spurg-c.commentaries.SQLite3).
  Edwards   — NEW author. data/New/Edwards-c.commentaries.zip ->
              Edw-c.commentaries.SQLite3 (MyBible).

Explicitly excluded (see legal/dataset-license-audit.md): the four Russian
MyBible sources (Августин/Генрі/Кальвін/Сперджен-рос) — rights not verified.

Usage (run on Mac only):
    python3 scripts/build_commentary_db.py [--out PATH] [--core-db PATH] [--data-dir PATH]
"""

import argparse
import hashlib
import html
import os
import re
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

# Reused READ-ONLY from the existing, untouched production importer — per
# CLAUDE.md rule #1 we do not modify scripts/import_commentaries.py. We only
# import a few of its pure functions (HTML/RTF strippers, the old-source
# extractors used to pull the two manual patches) and its book_id maps.
import import_commentaries as legacy  # noqa: E402


# ============================================================
#  Canonical book_id list (USFM-style, matches `book` table / verse_org)
# ============================================================

def load_canon_order(core_db_path):
    """Return the 66 book_id codes in canonical order, straight from the
    `book` table — never hand-transcribed, to avoid a silent off-by-one
    (e.g. JOL vs JOE) that would be invisible without per-book testing."""
    con = sqlite3.connect(f"file:{core_db_path}?mode=ro", uri=True)
    try:
        rows = con.execute("SELECT id FROM book ORDER BY num").fetchall()
    finally:
        con.close()
    if len(rows) != 66:
        raise RuntimeError(f"expected 66 books in `book` table, got {len(rows)}")
    return [r[0] for r in rows]


# The REAL MyBible book_number sequence — NOT a plain (position * 10). It has
# gaps reserved for non-canonical books between OT sections (Ezra-Nehemiah ->
# Esther skips 170/180; Song of Solomon -> Isaiah skips 270/280; etc.), so
# naively computing (position * 10) silently shifts every book from Esther
# onward onto the WRONG number (e.g. a naive formula gives Luke=420, Revelation=660,
# but the real file uses 490 and 730 — verified directly against
# data/New/*.commentaries.SQLite3's own DISTINCT book_number list, 66 values,
# every file checked this session agrees). This exact 66-value sequence was
# empirically derived and cross-checked against Henry-New's full-canon
# coverage in a prior session (see commentary-sources-audit.md) and
# reconfirmed directly here.
MYBIBLE_BOOK_NUMBER_SEQUENCE = [
    10, 20, 30, 40, 50, 60, 70, 80, 90, 100,
    110, 120, 130, 140, 150, 160, 190, 220, 230, 240,
    250, 260, 290, 300, 310, 330, 340, 350, 360, 370,
    380, 390, 400, 410, 420, 430, 440, 450, 460, 470,
    480, 490, 500, 510, 520, 530, 540, 550, 560, 570,
    580, 590, 600, 610, 620, 630, 640, 650, 660, 670,
    680, 690, 700, 710, 720, 730,
]


def mybible_book_num_to_id(canon_order):
    """Map MyBible's actual book_number sequence (with its gaps) to our
    canonical book_id order, position by position — NOT a computed formula.
    `canon_order` must be the 66 book_id codes in canonical (num-ordered)
    sequence, e.g. from load_canon_order()."""
    if len(canon_order) != 66:
        raise RuntimeError(f"expected 66 canon books, got {len(canon_order)}")
    return dict(zip(MYBIBLE_BOOK_NUMBER_SEQUENCE, canon_order))


# ============================================================
#  Org-anchoring (ADR-027 Invariant 1)
# ============================================================

class OrgResolver:
    """Reverse-maps English (KJV-numbering) book/chapter/verse -> org (Macula)
    coordinates, backed by verse_org WHERE translation='KJV' (full 31,102-verse
    coverage, `eng` scheme — Calvin/Henry/Owen/Spurgeon/Edwards are all English
    commentaries using this same standard chapter/verse convention).

    Per ADR-027 Invariant 1: never re-derive versification heuristically —
    always go through the curated, O2/O3-verified verse_org table."""

    def __init__(self, core_db_path):
        con = sqlite3.connect(f"file:{core_db_path}?mode=ro", uri=True)
        try:
            rows = con.execute(
                "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse "
                "FROM verse_org WHERE translation='KJV'"
            ).fetchall()
        finally:
            con.close()
        if not rows:
            raise RuntimeError("verse_org has no KJV rows — wrong --core-db path?")
        self._map = {}
        self._max_verse = {}  # (book_id, chapter) -> max KJV verse number
        for book_id, ch, vs, ob, oc, ov in rows:
            self._map[(book_id, ch, vs)] = (ob, oc, ov) if ob is not None else None
            key = (book_id, ch)
            if key not in self._max_verse or vs > self._max_verse[key]:
                self._max_verse[key] = vs

    def resolve(self, book_id, chapter, verse):
        """(org_book_id, org_chapter, org_verse) or None (a genuinely unmapped
        verse — caller falls back to translation-anchored native coordinates
        per Invariant 1).

        verse=0 (a chapter-intro section, e.g. Owen's 13 chapter overviews)
        is resolved via v1 of that chapter to find the correct ORG chapter,
        then anchored at org_verse=0 — NOT a bare native-coordinate fallback.
        Opus review S4: falling back to the native chapter number is wrong
        whenever native and org chapter counts diverge for that book (e.g.
        native Malachi has 4 chapters, org Malachi only has 3 — a naive
        fallback would anchor the section to a chapter that doesn't exist)."""
        if verse == 0:
            v1 = self._map.get((book_id, chapter, 1))
            if v1 is None:
                return None
            org_book, org_chapter, _org_verse = v1
            return (org_book, org_chapter, 0)
        return self._map.get((book_id, chapter, verse))

    def max_verse(self, book_id, chapter):
        return self._max_verse.get((book_id, chapter))


# ============================================================
#  Schema (ADR-027 §1 + Amendment 2026-09-01)
# ============================================================

def setup_db(cur):
    cur.executescript("""
        DROP TABLE IF EXISTS comments;
        DROP TABLE IF EXISTS comment_verses;
        DROP TABLE IF EXISTS module_info;

        CREATE TABLE comments(
            key                 TEXT PRIMARY KEY,
            source              TEXT NOT NULL,
            language            TEXT NOT NULL,
            book_id             TEXT NOT NULL,
            start_chapter       INTEGER NOT NULL,
            start_verse         INTEGER NOT NULL,
            end_chapter         INTEGER NOT NULL,
            end_verse           INTEGER NOT NULL,
            text                TEXT NOT NULL,
            origin              TEXT NOT NULL,
            translation_status  TEXT NOT NULL,
            reviewer            TEXT,
            reviewed_at         TEXT
        );

        CREATE TABLE comment_verses(
            key      TEXT NOT NULL,
            book_id  TEXT NOT NULL,
            chapter  INTEGER NOT NULL,
            verse    INTEGER NOT NULL,
            PRIMARY KEY (key, book_id, chapter, verse)
        );
        CREATE INDEX idx_comment_verses_lookup ON comment_verses(book_id, chapter, verse);

        CREATE TABLE module_info(name TEXT PRIMARY KEY, value TEXT);
    """)


def make_key(source, language, book_id, start_ch, start_vs, end_ch, end_vs):
    raw = f"{source}|{language}|{book_id}|{start_ch}:{start_vs}-{end_ch}:{end_vs}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def insert_section(cur, org, source, language, book_id, start_ch, start_vs,
                    end_ch, end_vs, text, origin, translation_status,
                    reviewer=None, reviewed_at=None):
    """Insert one commentary section. Org-anchors start/end via `org`, and
    indexes EVERY verse in the native range individually (not just start+end)
    — Amendment §1 / plan-commentary-prerelease-fixes.md explicitly requires
    per-verse reverse-mapping to avoid the ADR-028 D1/D3 chapter-boundary
    error class."""
    if not text or not text.strip():
        return None

    # S7: validate the range direction before doing anything else. A source
    # data error (found: one Spurgeon-VE row, HEB 9:18 -> 9:6) would otherwise
    # be stored inverted and unvalidated. Swap and warn rather than silently
    # keep an end < start range.
    if (end_ch, end_vs) < (start_ch, start_vs):
        print(
            f"WARNING: inverted range for {source} {book_id} "
            f"{start_ch}:{start_vs}-{end_ch}:{end_vs} — swapping start/end",
            file=sys.stderr,
        )
        start_ch, start_vs, end_ch, end_vs = end_ch, end_vs, start_ch, start_vs

    def to_org_or_fallback(ch, vs):
        r = org.resolve(book_id, ch, vs)
        return r if r is not None else (book_id, ch, vs)

    org_start_book, org_start_ch, org_start_vs = to_org_or_fallback(start_ch, start_vs)
    org_end_book, org_end_ch, org_end_vs = to_org_or_fallback(end_ch, end_vs)
    if org_start_book != org_end_book:
        raise ValueError(
            f"org book mismatch for {source} {book_id} "
            f"{start_ch}:{start_vs}-{end_ch}:{end_vs}: "
            f"start->{org_start_book}, end->{org_end_book}"
        )

    base_key = make_key(source, language, org_start_book, org_start_ch, org_start_vs,
                         org_end_ch, org_end_vs)
    # Disambiguate on a genuine collision (two DIFFERENT texts mapping to the
    # same natural key — found in Calvin-c.commentaries.PATCHED.SQLite3: 28 of
    # 490 same-reference duplicate rows have differing text, not just harmless
    # verbatim repeats). An identical-text collision is a true no-op dedup.
    #
    # A differing-text collision is resolved by a DETERMINISTIC TOTAL ORDER
    # over the colliding texts' own content hashes — never by "whoever
    # arrived first" — so the outcome is the same regardless of the source
    # table's row order, which SQLite does not guarantee to be stable across
    # rebuilds/platforms (Opus review S9 — ADR-027 Invariant 2 requires
    # stable natural keys). The text with the lexicographically smaller
    # sha256 hash always holds the bare base_key; any other colliding text
    # always holds `base_key-<its own hash prefix>`. If a text with a
    # smaller hash than the current base_key occupant arrives later, the
    # existing occupant is REKEYED out of the way first, so the final
    # assignment converges to the same outcome no matter the arrival order.
    existing = cur.execute("SELECT text FROM comments WHERE key=?", (base_key,)).fetchone()
    if existing is None:
        key = base_key
    elif existing[0] == text:
        return base_key  # identical duplicate — nothing to insert
    else:
        new_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        old_hash = hashlib.sha256(existing[0].encode("utf-8")).hexdigest()
        if new_hash < old_hash:
            old_key = f"{base_key}-{old_hash[:8]}"
            clash = cur.execute("SELECT text FROM comments WHERE key=?", (old_key,)).fetchone()
            if clash is not None and clash[0] != existing[0]:
                raise RuntimeError(
                    f"unresolvable 3-way key collision for {source} {book_id} "
                    f"{start_ch}:{start_vs}-{end_ch}:{end_vs}"
                )
            if clash is None:
                cur.execute("UPDATE comments SET key=? WHERE key=?", (old_key, base_key))
                cur.execute("UPDATE comment_verses SET key=? WHERE key=?", (old_key, base_key))
            key = base_key
        else:
            key = f"{base_key}-{new_hash[:8]}"
            existing2 = cur.execute("SELECT text FROM comments WHERE key=?", (key,)).fetchone()
            if existing2 is not None:
                if existing2[0] == text:
                    return key  # identical duplicate under the disambiguated key
                raise RuntimeError(
                    f"unresolvable key collision for {source} {book_id} "
                    f"{start_ch}:{start_vs}-{end_ch}:{end_vs} (hash collision on top "
                    f"of a natural-key collision)"
                )

    cur.execute(
        "INSERT INTO comments(key,source,language,book_id,"
        "start_chapter,start_verse,end_chapter,end_verse,text,origin,"
        "translation_status,reviewer,reviewed_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (key, source, language, org_start_book, org_start_ch, org_start_vs,
         org_end_ch, org_end_vs, text, origin, translation_status, reviewer,
         reviewed_at),
    )

    if start_ch == end_ch:
        if start_vs == 0:
            # Chapter-intro section (Opus review S4): a bare verse=0 index
            # entry is never reachable by an ordinary verse lookup, which
            # defeats the entire point of importing these (Owen's 13 chapter
            # overviews, Henry's ~1254 section intros). Index it across
            # every verse of the chapter it anchors to, in addition to the
            # literal verse=0 marker, so it surfaces when reading any verse
            # in that chapter.
            mv = org.max_verse(book_id, start_ch) or max(end_vs, 1)
            chapters = [(start_ch, 0, max(end_vs, mv))]
        else:
            chapters = [(start_ch, start_vs, end_vs)]
    else:
        chapters = [(start_ch, start_vs, org.max_verse(book_id, start_ch) or start_vs)]
        for mid_ch in range(start_ch + 1, end_ch):
            mv = org.max_verse(book_id, mid_ch) or 1
            chapters.append((mid_ch, 1, mv))
        chapters.append((end_ch, 1, end_vs))

    seen = set()
    for ch, vfrom, vto in chapters:
        if vto < vfrom:
            vto = vfrom
        for v in range(vfrom, vto + 1):
            idx = to_org_or_fallback(ch, v)
            if idx in seen:
                continue
            seen.add(idx)
            cur.execute(
                "INSERT OR IGNORE INTO comment_verses(key,book_id,chapter,verse) "
                "VALUES(?,?,?,?)",
                (key, idx[0], idx[1], idx[2]),
            )
    return key


# ============================================================
#  MyBible source helpers
# ============================================================

def mybible_ranges(cur, book_number, book_id, org):
    """Yield (chapter_from, verse_from, chapter_to, verse_to, text) for every
    row of a MyBible `commentaries` table for one book. verse_number_to is
    frequently NULL in these files (a row marks where a section STARTS, not
    its extent) — infer the end verse from the next row's start (same
    chapter) minus 1, or the chapter's max KJV verse if it's the last row of
    the chapter."""
    rows = cur.execute(
        "SELECT chapter_number_from, verse_number_from, chapter_number_to, "
        "verse_number_to, text, rowid FROM commentaries WHERE book_number=? "
        "ORDER BY chapter_number_from, verse_number_from, rowid",
        (book_number,),
    ).fetchall()
    n = len(rows)
    for i, (ch_from, vs_from, ch_to, vs_to, text, _rowid) in enumerate(rows):
        if ch_to is not None and vs_to is not None:
            yield ch_from, vs_from, ch_to, vs_to, text
            continue
        # S8: this branch assumes the section never crosses a chapter
        # boundary when verse_number_to is NULL. True of every file checked
        # this session (0 occurrences) — fail loudly instead of silently
        # dropping the tail of the range if that ever changes.
        if ch_to is not None and ch_to != ch_from:
            raise RuntimeError(
                f"mybible_ranges: book_number={book_number} {ch_from}:{vs_from} "
                f"has chapter_number_to={ch_to} but verse_number_to is NULL — "
                f"the single-chapter end-inference below would silently drop "
                f"the multi-chapter span (Opus review S8)."
            )
        # S6: find the next row that genuinely STARTS LATER in this chapter
        # (skip over same-verse duplicate/overlapping rows) — comparing only
        # against the immediate next row let a same-start duplicate collapse
        # this range to a single verse and silently drop real coverage.
        end_vs = None
        for j in range(i + 1, n):
            if rows[j][0] != ch_from:
                break
            if rows[j][1] > vs_from:
                end_vs = rows[j][1] - 1
                break
        if end_vs is None:
            end_vs = org.max_verse(book_id, ch_from) or vs_from
        if end_vs < vs_from:
            end_vs = vs_from
        yield ch_from, vs_from, ch_from, end_vs, text


# ============================================================
#  Strippers
# ============================================================
# Two DISTINCT formats found in data/New/ this session (verified by direct
# inspection, 2026-09-01) — NOT one shared format as first assumed:
#   - Henry-New (MHWBC): old-style HTML — <TABLE>/<TR>/<TD> section headers,
#     <P>/<SPAN>/<I> paragraphs, &nbsp; runs. Needs its own converter.
#   - Owen-New / Spurgeon-VE / Edwards: a different, simpler format — bare
#     self-closing <p/> paragraph markers, <i>/<b> inline emphasis,
#     <a href='B:...'>verse ref</a> links. These three genuinely match.
# Both converters map block boundaries to '\n\n' (never a bare '\n' per tag),
# which is the actual fix for the live single-'\n' artifact class
# (commentary-sources-audit.md, доповнення 2026-09-01).

def strip_p_tag_format(html: str) -> str:
    """Owen-New / Spurgeon-VE / Edwards shared format."""
    text = html
    text = re.sub(r"(?i)<p\s*/?>", "\n\n", text)
    text = re.sub(r"(?i)</p>", "\n\n", text)
    text = re.sub(r"(?i)<a\s+[^>]*>", "", text)
    text = re.sub(r"(?i)</a>", "", text)
    text = re.sub(r"(?i)</?(?:i|b|u|em|strong|span)[^>]*>", "", text)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = _unescape_entities(text)
    return _collapse_whitespace(text)


def strip_henry_new_html(html: str) -> str:
    """Henry-New (MHWBC) format — old-style HTML tables/paragraphs. Converts
    genuine block boundaries to '\\n\\n'; everything else (inline SPAN/I/B,
    TR/TD structure) is dropped without inserting a line break, unlike the
    live _strip_henry_html() which turns every tag into a bare '\\n'."""
    text = html
    text = re.sub(r"(?i)<script[^>]*>.*?</script>", " ", text, flags=re.DOTALL)
    text = re.sub(r"(?i)<style[^>]*>.*?</style>", " ", text, flags=re.DOTALL)
    text = re.sub(r"(?i)</?(?:table|tr)[^>]*>", "\n\n", text)
    text = re.sub(r"(?i)</?p[^>]*>", "\n\n", text)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</?(?:td|th|span|i|b|u|em|strong)[^>]*>", "", text)
    text = re.sub(r"(?i)<hr[^>]*>", "\n\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = _unescape_entities(text)
    return _collapse_whitespace(text)


def _unescape_entities(text: str) -> str:
    """Decode both named (&amp;, &nbsp;, ...) and numeric (&#945;, &#x3b1;, ...)
    HTML entities. The old hand-rolled version only handled 7 named entities
    and silently left ~72k numeric entities undecoded (mostly Greek/Hebrew
    script in Calvin's quotations) — html.unescape() handles the full set."""
    text = text.replace("&nbsp;", " ")
    return html.unescape(text)


def _collapse_whitespace(text: str) -> str:
    lines = [re.sub(r"[ \t]{2,}", " ", l).strip() for l in text.split("\n")]
    text = "\n".join(lines)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def fix_single_newline_artifact(text: str) -> str:
    """Heal text that came through one of the OLD strippers (_strip_henry_html
    / _strip_rtf), which convert every HTML tag / RTF control word to a bare
    '\n' — producing hundreds of mid-sentence line breaks
    (commentary-sources-audit.md, доповнення 2026-09-01). We reuse those old
    functions ONLY to extract the two manual patches (Luke 16:19-31, Heb
    1:1-2) from their old sources, so the same artifact would otherwise leak
    into those two sections even though the New MyBible sources are clean of
    it.

    CORRECTION (post Opus-review, 2026-09-02): the old strippers do also
    produce a meaningful number of GENUINE '\n\n' paragraph breaks (measured:
    101 in Owen's patch, 99 in Henry's patch) — an earlier version of this
    function collapsed those too, turning both patches into a single
    231k/40k-char wall of text. Only a LONE single '\n' (not adjacent to
    another '\n') is the artifact; an existing '\n\n' is real structure and
    must survive untouched."""
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    return re.sub(r" {2,}", " ", text).strip()


# ============================================================
#  Importers
# ============================================================

CALVIN_GARBAGE_BOOK_NUMBERS = {7137, 7241, 7245, 7294, 7295}  # + NULL, handled separately


def import_calvin(cur, org, mybible_path, book_num_to_id):
    """Sole source for Calvin (see commentary-sources-audit.md — SWORD has a
    44-section index-bleed defect this MyBible source does not have; no
    SWORD splice anywhere, including Isaiah 49-66)."""
    con = sqlite3.connect(f"file:{mybible_path}?mode=ro", uri=True)
    total = 0
    try:
        cur2 = con.cursor()
        for book_number, book_id in book_num_to_id.items():
            for ch_from, vs_from, ch_to, vs_to, text in mybible_ranges(cur2, book_number, book_id, org):
                clean = strip_p_tag_format(text)  # handles both plain text and light <i>/<p/> markup gracefully
                key = insert_section(
                    cur, org, "Calvin", "en", book_id, ch_from, vs_from, ch_to, vs_to,
                    clean, origin="MyBible:Calvin-c.PATCHED", translation_status="source",
                )
                if key:
                    total += 1
    finally:
        con.close()
    return total


def import_henry(cur, org, new_mybible_path, old_zip_path, book_num_to_id):
    """New MyBible source (MHWBC) + manual patch: the New source's Luke 16
    row claims 16:1-31 but its actual text stops at v18 (verified 2026-09-01
    — no 'Lazarus' anywhere in it). Truncate that row to 16:1-18 and splice
    in the real 16:19-31 ('Rich Man and Lazarus') section from the OLD
    data/matthew_henry.zip source, where it is intact."""
    con = sqlite3.connect(f"file:{new_mybible_path}?mode=ro", uri=True)
    total = 0
    try:
        cur2 = con.cursor()
        for book_number, book_id in book_num_to_id.items():
            for ch_from, vs_from, ch_to, vs_to, text in mybible_ranges(cur2, book_number, book_id, org):
                clean = strip_henry_new_html(text)
                if book_id == "LUK" and ch_from == 16 and vs_from == 1 and ch_to == 16 and vs_to == 31:
                    ch_to, vs_to = 16, 18  # truncate to what this row actually contains
                key = insert_section(
                    cur, org, "Henry", "en", book_id, ch_from, vs_from, ch_to, vs_to,
                    clean, origin="MyBible:Henry-c(MHWBC)", translation_status="source",
                )
                if key:
                    total += 1
    finally:
        con.close()

    # Patch: Luke 16:19-31 from the old source.
    with zipfile.ZipFile(old_zip_path) as z:
        raw_html = z.read("MHC42016.HTM").decode("latin-1", errors="replace")
    sects = legacy._henry_extract_sections(raw_html)
    patch = next((tx for vs, tx in sects if min(vs) == 19 and max(vs) == 31), None)
    if patch is None:
        raise RuntimeError("Henry Luke 16:19-31 patch section not found in old source")
    patch = fix_single_newline_artifact(patch)
    key = insert_section(
        cur, org, "Henry", "en", "LUK", 16, 19, 16, 31, patch,
        origin="patch:matthew_henry.zip(old)", translation_status="source",
    )
    if key:
        total += 1
    return total


def import_owen(cur, org, new_mybible_path, old_cmtx_path):
    """New MyBible source (book_number=650, Hebrews only) + manual patch:
    Heb 1:1-2 is the OLD .cmtx source's very first row, verbatim (missing
    entirely from the New source — verified 2026-09-01)."""
    con = sqlite3.connect(f"file:{new_mybible_path}?mode=ro", uri=True)
    total = 0
    try:
        cur2 = con.cursor()
        for ch_from, vs_from, ch_to, vs_to, text in mybible_ranges(cur2, 650, "HEB", org):
            clean = strip_p_tag_format(text)
            key = insert_section(
                cur, org, "Owen", "en", "HEB", ch_from, vs_from, ch_to, vs_to,
                clean, origin="MyBible:Owen-c", translation_status="source",
            )
            if key:
                total += 1
    finally:
        con.close()

    # Patch: Heb 1:1-2 from the old .cmtx source (first row, verbatim).
    src = sqlite3.connect(old_cmtx_path)
    try:
        row = src.execute(
            "SELECT ChapterBegin, ChapterEnd, VerseBegin, VerseEnd, Comments "
            "FROM Verses WHERE ChapterBegin=1 AND ChapterEnd=1 AND VerseBegin=1 AND VerseEnd=2"
        ).fetchone()
    finally:
        src.close()
    if row is None:
        raise RuntimeError("Owen Heb 1:1-2 patch row not found in old .cmtx source")
    ch_begin, ch_end, vs_begin, vs_end, rtf = row
    clean = fix_single_newline_artifact(legacy._strip_rtf(rtf))
    key = insert_section(
        cur, org, "Owen", "en", "HEB", ch_begin, vs_begin, ch_end, vs_end, clean,
        origin="patch:OwenHebrews-commentary.cmtx(old)", translation_status="source",
    )
    if key:
        total += 1
    return total


def import_spurgeon_tod(cur, org, zip_path):
    """Treasury of David — unchanged source, re-targeted at the new schema."""
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
                body = parts[i + 1]
                i += 2
                verse_nums = legacy._parse_verse_header(header)
                if not verse_nums:
                    continue
                text = legacy._strip_spurgeon_md(body)
                if not text:
                    continue
                start_vs, end_vs = min(verse_nums), max(verse_nums)
                key = insert_section(
                    cur, org, "Spurgeon-TOD", "en", "PSA", psalm_num, start_vs,
                    psalm_num, end_vs, text,
                    origin="chspurgeon-tod-main.zip", translation_status="source",
                )
                if key:
                    total += 1
    return total


def import_spurgeon_ve(cur, org, mybible_path, book_num_to_id):
    """Verse Expositions — new second Spurgeon work."""
    con = sqlite3.connect(f"file:{mybible_path}?mode=ro", uri=True)
    total = 0
    try:
        cur2 = con.cursor()
        for book_number, book_id in book_num_to_id.items():
            for ch_from, vs_from, ch_to, vs_to, text in mybible_ranges(cur2, book_number, book_id, org):
                clean = strip_p_tag_format(text)
                key = insert_section(
                    cur, org, "Spurgeon-VE", "en", book_id, ch_from, vs_from, ch_to, vs_to,
                    clean, origin="MyBible:Spurgeon-c(VE)", translation_status="source",
                )
                if key:
                    total += 1
    finally:
        con.close()
    return total


def import_edwards(cur, org, mybible_path, book_num_to_id):
    """New author."""
    con = sqlite3.connect(f"file:{mybible_path}?mode=ro", uri=True)
    total = 0
    try:
        cur2 = con.cursor()
        for book_number, book_id in book_num_to_id.items():
            for ch_from, vs_from, ch_to, vs_to, text in mybible_ranges(cur2, book_number, book_id, org):
                clean = strip_p_tag_format(text)
                key = insert_section(
                    cur, org, "Edwards", "en", book_id, ch_from, vs_from, ch_to, vs_to,
                    clean, origin="MyBible:Edwards-c", translation_status="source",
                )
                if key:
                    total += 1
    finally:
        con.close()
    return total


# ============================================================
#  module_info (Amendment 2026-09-01 — language-bundle level, not one author)
# ============================================================

def source_row_count(cur, source):
    """Actual `comments` row count for one source — the ground truth, unlike
    an importer's raw per-call counter (which overcounts by the number of
    identical-text dedup no-ops it returned a key for; Opus review S5: e.g.
    Calvin's counter said 13564 while only 13281 rows actually exist)."""
    return cur.execute("SELECT count(*) FROM comments WHERE source=?", (source,)).fetchone()[0]


# ADR-027 §1 requires module_info to carry schema_version/min_app_version
# (line: "module_info(name, value) -- author, version, schema_version,
# min_app_version, book_versions(JSON)"). Amendment 2026-09-01 rescoped
# module_info to the language-bundle level but did not drop this
# requirement (Opus review S10). Bump SCHEMA_VERSION whenever the table
# shape or key semantics of comments/comment_verses/module_info changes.
SCHEMA_VERSION = 1
MIN_APP_VERSION = "1.0.0"


def write_module_info(cur, sources):
    import json
    import datetime

    cur.execute("INSERT INTO module_info(name,value) VALUES('language', ?)", ("en",))
    cur.execute(
        "INSERT INTO module_info(name,value) VALUES('schema_version', ?)",
        (str(SCHEMA_VERSION),),
    )
    cur.execute(
        "INSERT INTO module_info(name,value) VALUES('min_app_version', ?)",
        (MIN_APP_VERSION,),
    )
    cur.execute(
        "INSERT INTO module_info(name,value) VALUES('sources', ?)",
        (json.dumps(sources, ensure_ascii=False),),
    )
    cur.execute(
        "INSERT INTO module_info(name,value) VALUES('built_at', ?)",
        (datetime.datetime.now(datetime.timezone.utc).isoformat(),),
    )
    # NOTE (Opus review S10, not yet resolved): this field is named
    # book_versions per the ADR-027 §1 contract, but currently holds section
    # COUNTS per source/book, not version identifiers — the ADR's intended
    # semantics for incremental/OTA book updates are not implemented yet.
    # Left as-is (documented follow-up in commentary-sources-audit.md)
    # since v1 ships as one non-OTA per-language file with no per-book
    # update mechanism to version against.
    book_versions = {}
    for row in cur.execute("SELECT source, book_id, count(*) FROM comments GROUP BY source, book_id"):
        book_versions.setdefault(row[0], {})[row[1]] = row[2]
    cur.execute(
        "INSERT INTO module_info(name,value) VALUES('book_versions', ?)",
        (json.dumps(book_versions, ensure_ascii=False),),
    )


# ============================================================
#  Orchestration
# ============================================================

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "commentaries-en.db"))
    ap.add_argument("--core-db", default=str(ROOT / "sourcebible.db"),
                     help="read-only source of verse_org for org-anchoring")
    ap.add_argument("--data-dir", default=str(ROOT / "data"))
    args = ap.parse_args()

    data = Path(args.data_dir)
    new = data / "New"

    if os.path.exists(args.out):
        os.remove(args.out)

    print(f"Loading verse_org (KJV) from {args.core_db} ...")
    org = OrgResolver(args.core_db)
    canon_order = load_canon_order(args.core_db)
    book_num_to_id = mybible_book_num_to_id(canon_order)

    con = sqlite3.connect(args.out)
    cur = con.cursor()
    setup_db(cur)

    sources_meta = []

    with tempfile.TemporaryDirectory(prefix="commentary_build_") as tmp:
        tmp = Path(tmp)

        def extract_one(zip_path, inner_name, subdir):
            dest_dir = tmp / subdir
            dest_dir.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_path) as z:
                z.extract(inner_name, path=str(dest_dir))
            return str(dest_dir / inner_name)

        # --- Calvin ---
        print("Importing Calvin (MyBible-PATCHED, sole source)...")
        calvin_path = str(new / "Calvin-c.commentaries.PATCHED.SQLite3")
        n = import_calvin(cur, org, calvin_path, book_num_to_id)
        actual = source_row_count(cur, "Calvin")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Calvin", "origin": "MyBible:Calvin-c.PATCHED", "n_sections": actual})

        # --- Henry ---
        print("Importing Henry (MyBible New source + Luke 16:19-31 patch)...")
        henry_path = extract_one(new / "Henry-c.commentaries.zip", "MHWBC.commentaries.SQLite3", "henry")
        n = import_henry(cur, org, henry_path, str(data / "matthew_henry.zip"), book_num_to_id)
        actual = source_row_count(cur, "Henry")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Henry", "origin": "MyBible:Henry-c(MHWBC)+patch", "n_sections": actual})

        # --- Owen ---
        print("Importing Owen (MyBible New source + Heb 1:1-2 patch)...")
        owen_path = extract_one(new / "Owen-c.commentaries.zip", "Owen-c.commentaries.SQLite3", "owen")
        n = import_owen(cur, org, owen_path, str(data / "OwenHebrews-commentary.cmtx"))
        actual = source_row_count(cur, "Owen")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Owen", "origin": "MyBible:Owen-c+patch", "n_sections": actual})

        # --- Spurgeon: Treasury of David (unchanged) ---
        print("Importing Spurgeon - Treasury of David (unchanged source)...")
        n = import_spurgeon_tod(cur, org, str(data / "chspurgeon-tod-main.zip"))
        actual = source_row_count(cur, "Spurgeon-TOD")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Spurgeon-TOD", "origin": "chspurgeon-tod-main.zip", "n_sections": actual})

        # --- Spurgeon: Verse Expositions (new) ---
        print("Importing Spurgeon - Verse Expositions (new work)...")
        spurgeon_ve_path = extract_one(new / "Spurgeon-c.commentaries.zip", "Spurg-c.commentaries.SQLite3", "spurgeon_ve")
        n = import_spurgeon_ve(cur, org, spurgeon_ve_path, book_num_to_id)
        actual = source_row_count(cur, "Spurgeon-VE")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Spurgeon-VE", "origin": "MyBible:Spurgeon-c(VE)", "n_sections": actual})

        # --- Edwards (new author) ---
        print("Importing Edwards (new author)...")
        edwards_path = extract_one(new / "Edwards-c.commentaries.zip", "Edw-c.commentaries.SQLite3", "edwards")
        n = import_edwards(cur, org, edwards_path, book_num_to_id)
        actual = source_row_count(cur, "Edwards")
        print(f"  {actual} sections ({n} insert calls, {n - actual} dedup no-ops)")
        sources_meta.append({"source": "Edwards", "origin": "MyBible:Edwards-c", "n_sections": actual})

    write_module_info(cur, sources_meta)
    con.commit()

    total_comments = cur.execute("SELECT count(*) FROM comments").fetchone()[0]
    total_verses = cur.execute("SELECT count(*) FROM comment_verses").fetchone()[0]
    print(f"\nDone. {total_comments} comment sections, {total_verses} verse-index rows -> {args.out}")
    con.close()


if __name__ == "__main__":
    main()
