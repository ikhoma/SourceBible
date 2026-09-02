#!/usr/bin/env python3
"""
test_build_commentary_db.py — verification suite for commentaries-en.db.

Runs read-only against an already-built commentaries-en.db (default:
<repo_root>/commentaries-en.db) plus sourcebible.db (for verse_org
cross-checks). Does NOT rebuild the DB itself — run
`scripts/build_commentary_db.py` first.

Usage:
    python3 -m pytest scripts/test_build_commentary_db.py -v
    # or point at a specific DB:
    COMMENTARY_DB=/path/to/commentaries-en.db python3 -m pytest scripts/test_build_commentary_db.py -v
"""

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_commentary_db as bcd  # noqa: E402

DB_PATH = os.environ.get("COMMENTARY_DB", str(ROOT / "commentaries-en.db"))
CORE_DB_PATH = os.environ.get("CORE_DB", str(ROOT / "sourcebible.db"))


class FakeOrg:
    """Test double for the org-anchoring dependency used by insert_section()
    and mybible_ranges() — lets unit tests control the native->org mapping
    directly instead of depending on real verse_org data, so a test can
    require a DIVERGENT native/org pair (Opus review S1: a suite that only
    ever probes references where org happens to equal native KJV has zero
    power to catch org-anchoring being broken or disabled)."""

    def __init__(self, mapping=None, max_verses=None):
        self.mapping = mapping or {}
        self.max_verses = max_verses or {}

    def resolve(self, book_id, chapter, verse):
        return self.mapping.get((book_id, chapter, verse))

    def max_verse(self, book_id, chapter):
        return self.max_verses.get((book_id, chapter))


def _fresh_comment_db():
    con = sqlite3.connect(":memory:")
    cur = con.cursor()
    bcd.setup_db(cur)
    return con, cur

CANON_BOOK_IDS = {
    "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA",
    "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO",
    "ECC", "SNG", "ISA", "JER", "LAM", "EZK", "DAN", "HOS", "JOL", "AMO",
    "OBA", "JON", "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL", "MAT",
    "MRK", "LUK", "JHN", "ACT", "ROM", "1CO", "2CO", "GAL", "EPH", "PHP",
    "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM", "HEB", "JAS", "1PE",
    "2PE", "1JN", "2JN", "3JN", "JUD", "REV",
}

EXPECTED_SOURCES = {"Calvin", "Henry", "Owen", "Spurgeon-TOD", "Spurgeon-VE", "Edwards"}


@pytest.fixture(scope="module")
def db():
    if not os.path.exists(DB_PATH):
        pytest.skip(f"commentaries-en.db not found at {DB_PATH} — run scripts/build_commentary_db.py first")
    con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    yield con
    con.close()


@pytest.fixture(scope="module")
def core_db():
    if not os.path.exists(CORE_DB_PATH):
        pytest.skip(f"sourcebible.db not found at {CORE_DB_PATH}")
    con = sqlite3.connect(f"file:{CORE_DB_PATH}?mode=ro", uri=True)
    yield con
    con.close()


# ============================================================
#  Schema shape (ADR-027 §1 + Amendment 2026-09-01)
# ============================================================

def test_tables_exist(db):
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"comments", "comment_verses", "module_info"} <= tables


def test_comments_columns(db):
    cols = {r[1] for r in db.execute("PRAGMA table_info(comments)")}
    expected = {
        "key", "source", "language", "book_id", "start_chapter", "start_verse",
        "end_chapter", "end_verse", "text", "origin", "translation_status",
        "reviewer", "reviewed_at",
    }
    assert expected <= cols


def test_comment_verses_columns(db):
    cols = {r[1] for r in db.execute("PRAGMA table_info(comment_verses)")}
    assert {"key", "book_id", "chapter", "verse"} <= cols


def test_language_is_en_for_all_rows_in_v1(db):
    rows = db.execute("SELECT DISTINCT language FROM comments").fetchall()
    assert rows == [("en",)], f"v1 (commentaries-en.db) must be all language='en', got {rows}"


def test_translation_status_enum(db):
    rows = {r[0] for r in db.execute("SELECT DISTINCT translation_status FROM comments")}
    allowed = {"source", "raw-mt", "reviewed", "final"}
    assert rows <= allowed, f"unexpected translation_status values: {rows - allowed}"
    # v1 is 100% pre-existing trusted text, not our own MT pipeline output.
    assert rows == {"source"}


def test_expected_sources_present(db):
    rows = {r[0] for r in db.execute("SELECT DISTINCT source FROM comments")}
    assert rows == EXPECTED_SOURCES, f"missing or unexpected sources: {EXPECTED_SOURCES ^ rows}"


def test_no_russian_sources_leaked_into_v1(db):
    """The four RU MyBible sources are explicitly excluded pending rights
    verification (legal/dataset-license-audit.md) — regression guard."""
    rows = {r[0] for r in db.execute("SELECT DISTINCT source FROM comments")}
    ru_markers = {"Августин", "Генрі-рос", "Кальвін-рос", "Сперджен-рос"}
    assert not (rows & ru_markers)


# ============================================================
#  Hash-key integrity
# ============================================================

def test_key_uniqueness(db):
    total = db.execute("SELECT count(*) FROM comments").fetchone()[0]
    distinct = db.execute("SELECT count(DISTINCT key) FROM comments").fetchone()[0]
    assert total == distinct, f"{total - distinct} duplicate keys in comments"


def test_comment_verses_reference_existing_comments(db):
    orphans = db.execute(
        "SELECT count(*) FROM comment_verses cv "
        "LEFT JOIN comments c ON c.key = cv.key WHERE c.key IS NULL"
    ).fetchone()[0]
    assert orphans == 0, f"{orphans} comment_verses rows reference a nonexistent comments.key"


def test_every_comment_has_at_least_one_verse_index_row(db):
    orphans = db.execute(
        "SELECT count(*) FROM comments c "
        "LEFT JOIN comment_verses cv ON cv.key = c.key WHERE cv.key IS NULL"
    ).fetchone()[0]
    assert orphans == 0, f"{orphans} comments rows have no comment_verses index entry"


# ============================================================
#  Content-fix regressions (commentary-sources-audit.md findings)
# ============================================================

def test_calvin_no_garbage_book_id(db):
    """The 6 garbage book_number rows (NULL/7137/7241/7245/7294/7295) must
    never surface as a book_id in the output."""
    rows = {r[0] for r in db.execute("SELECT DISTINCT book_id FROM comments WHERE source='Calvin'")}
    assert rows <= CANON_BOOK_IDS, f"garbage book_id leaked into Calvin: {rows - CANON_BOOK_IDS}"


def test_calvin_isaiah_49_to_66_present(db):
    """SWORD stops at Isaiah 48; MyBible-PATCHED (the sole source now) has
    49-66 in full — this was the original open question, now resolved."""
    chapters = {r[0] for r in db.execute(
        "SELECT DISTINCT start_chapter FROM comments WHERE source='Calvin' AND book_id='ISA' "
        "AND start_chapter BETWEEN 49 AND 66"
    )}
    assert len(chapters) >= 10, f"expected substantial Isaiah 49-66 coverage, got chapters: {sorted(chapters)}"


def test_calvin_no_sword_index_bleed_defect(db):
    """Regression guard for the 44-section SWORD index/next-book-bleed defect
    (commentary-sources-audit.md, 'Ісая 49-66 та Буття — вирішено'). No
    Calvin section should be absurdly larger than its neighbors or contain
    the module's own scripture-index appendix."""
    rows = db.execute(
        "SELECT book_id, start_chapter, start_verse, length(text) FROM comments "
        "WHERE source='Calvin' AND (text LIKE '%Index of Scripture References%' OR text LIKE '%Indexes.%')"
    ).fetchall()
    # A couple of small trailing-index fragments (~2-3k chars) are expected and
    # harmless (verified in MyBible directly); anything large is the old bleed.
    huge = [r for r in rows if r[3] > 10000]
    assert not huge, f"SWORD-style index bleed detected in MyBible output: {huge}"


def test_henry_luke_16_patch_present(db):
    row = db.execute(
        "SELECT text, origin FROM comments WHERE source='Henry' AND book_id='LUK' "
        "AND start_chapter=16 AND start_verse=19"
    ).fetchone()
    assert row is not None, "Henry Luke 16:19-31 patch section missing"
    text, origin = row
    assert "Lazarus" in text
    assert "patch" in origin


def test_henry_luke_16_1_18_not_falsely_claiming_19_31(db):
    """The New source's own row for this range was mislabeled 16:1-31 while
    only containing 16:1-18 — must be truncated, not left overclaiming."""
    row = db.execute(
        "SELECT end_verse, text FROM comments WHERE source='Henry' AND book_id='LUK' "
        "AND start_chapter=16 AND start_verse=1"
    ).fetchone()
    assert row is not None
    end_verse, text = row
    assert end_verse == 18, f"expected the New-source Luke 16:1 row truncated to end_verse=18, got {end_verse}"
    assert "Lazarus" not in text


def test_owen_heb_1_1_2_patch_present(db):
    row = db.execute(
        "SELECT text, origin FROM comments WHERE source='Owen' AND book_id='HEB' "
        "AND start_chapter=1 AND start_verse=1"
    ).fetchone()
    assert row is not None, "Owen Heb 1:1-2 patch section missing"
    text, origin = row
    assert len(text) > 1000
    assert "patch" in origin


def test_owen_chapter_overview_has_synthesized_heading(db):
    """Ivan's decision 2026-09-02: Owen's chapter overviews have NO heading
    in the raw source (unlike Henry's own 'BOOK NAME / CHAP. N.') — a
    heading in Henry's own style must be synthesized so a reader can tell
    the overview apart from the verse-specific commentary that follows."""
    row = db.execute(
        "SELECT text FROM comments WHERE source='Owen' AND book_id='HEB' "
        "AND start_chapter=2 AND start_verse=0"
    ).fetchone()
    assert row is not None, "Owen chapter 2 overview missing"
    assert row[0].startswith("HEBREWS\n\nCHAPTER 2 — OVERVIEW\n\n"), row[0][:80]


def test_owen_book_intro_has_synthesized_heading(db):
    row = db.execute(
        "SELECT text FROM comments WHERE source='Owen' AND book_id='HEB' "
        "AND start_chapter=0 AND start_verse=0"
    ).fetchone()
    assert row is not None, "Owen book-level intro missing"
    assert row[0].startswith("HEBREWS\n\nINTRODUCTION\n\n"), row[0][:80]


def test_henry_chapter_overview_heading_untouched(db):
    """Sanity check: Henry already has its own native heading — the Owen-only
    heading synthesis must not double it up or otherwise alter it."""
    row = db.execute(
        "SELECT text FROM comments WHERE source='Henry' AND book_id='GEN' "
        "AND start_chapter=1 AND start_verse=0"
    ).fetchone()
    assert row is not None
    assert row[0].startswith("G E N E S I S\n\nCHAP. I.\n\n"), row[0][:80]
    assert row[0].count("CHAP. I.") == 1, "heading must not be duplicated"


# ============================================================
#  Pure-function unit tests (no built DB required)
# ============================================================

def test_unescape_entities_decodes_numeric_entities():
    """Opus review S3: the old hand-rolled unescaper only handled 7 named
    entities, silently leaving ~72k numeric entities (&#945;, &#x3b1;, ...)
    undecoded across 4,441 sections — mostly Greek/Hebrew script in Calvin's
    quotations."""
    text = "before &#945; middle &#x3b1; after &amp; &nbsp;end"
    result = bcd._unescape_entities(text)
    assert "&#945;" not in result and "&#x3b1;" not in result
    assert "α" in result  # Greek small alpha, decoded from both decimal and hex forms
    assert "&amp;" not in result and "&" in result


def test_no_unresolved_numeric_html_entities(db):
    """DB-level regression guard for the same defect (S3), per the Opus
    review's own suggested check."""
    n = db.execute("SELECT count(*) FROM comments WHERE text GLOB '*&#[0-9]*;*'").fetchone()[0]
    assert n == 0, f"{n} sections still contain unresolved numeric HTML entities"


def test_unescape_entities_resolves_double_escaping():
    """Second-round review finding N1: Calvin's raw source has some DOUBLY
    escaped markup (e.g. '&amp;gt;' for a literal '>') — a single
    html.unescape() pass only partially resolves it ('&amp;gt;' -> '&gt;',
    left encoded). Must resolve fully."""
    result = bcd._unescape_entities("Pa&amp;gt;ntwn me&amp;lt;n")
    assert result == "Pa>ntwn me<n", result


def test_unescape_entities_normalizes_invisible_soft_hyphen_and_nbsp():
    """Second-round review finding N2: &#173;/&#160; decode to the invisible
    U+00AD (soft hyphen) / non-breaking U+00A0 — but Calvin's source uses
    &#173; as a VISIBLE dash/hyphen ('loving&#173;kindness', a quote
    attribution '&#173; Phillips'). Leaving it as an invisible codepoint
    silently swallows readable punctuation and breaks text search."""
    result = bcd._unescape_entities("loving&#173;kindness said&#160;he")
    assert "\u00ad" not in result and "\u00a0" not in result
    assert result == "loving-kindness said he", result


def test_no_double_escaped_entities_in_db(db):
    """DB-level regression guard for N1."""
    n = db.execute(
        "SELECT count(*) FROM comments WHERE text GLOB '*&gt;*' OR text GLOB '*&lt;*'"
    ).fetchone()[0]
    assert n == 0, f"{n} sections still contain double-escaped &gt;/&lt;"


def test_no_invisible_soft_hyphen_or_nbsp_in_db(db):
    """DB-level regression guard for N2."""
    n = db.execute(
        "SELECT count(*) FROM comments WHERE text LIKE '%' || char(173) || '%' "
        "OR text LIKE '%' || char(160) || '%'"
    ).fetchone()[0]
    assert n == 0, f"{n} sections still contain an invisible soft hyphen or nbsp"


def test_fix_single_newline_artifact_preserves_double_newlines():
    """Opus review S2: the old fix (`re.sub(r'\\n+', ' ', text)`) collapsed
    EVERY newline, including genuine '\\n\\n' paragraph breaks — measured at
    101 real breaks destroyed in Owen's patch, 99 in Henry's. Only a LONE
    single '\\n' is the artifact; an existing '\\n\\n' must survive."""
    text = "Para one line one\nPara one line two\n\nPara two starts\nstill para two\n\n\nPara three"
    result = bcd.fix_single_newline_artifact(text)
    assert result.count("\n\n") >= 2, f"real paragraph breaks were destroyed: {result!r}"
    assert "one\nPara" not in result, "lone mid-sentence newline was not collapsed"
    assert "Para one line one Para one line two" in result
    assert "Para two starts still para two" in result


# ============================================================
#  Rendering-artifact regression (single mid-sentence '\n' bug class)
# ============================================================

def _max_single_newline_run_ratio(text):
    """Fraction of newlines in `text` that are single ('\\n' not preceded or
    followed by another '\\n') — the live _strip_henry_html/_strip_rtf bug
    signature. A clean paragraph-based text should have ~0 of these outside
    of genuine short lines of poetry/verse quotation."""
    newline_positions = [m.start() for m in re.finditer(r"\n", text)]
    if not newline_positions:
        return 0.0
    singles = 0
    for pos in newline_positions:
        prev_is_nl = pos > 0 and text[pos - 1] == "\n"
        next_is_nl = pos + 1 < len(text) and text[pos + 1] == "\n"
        if not prev_is_nl and not next_is_nl:
            singles += 1
    return singles / len(newline_positions)


@pytest.mark.parametrize("source", ["Henry", "Owen", "Spurgeon-VE", "Edwards"])
def test_no_single_newline_artifact_on_long_sections(db, source):
    """Regression guard for the documented defect class (commentary-sources-audit.md,
    доповнення 2026-09-01): the live parser turns every HTML/RTF tag into a
    bare '\\n', producing hundreds of mid-sentence breaks. Our new strippers
    must not reproduce it. Checks the 5 longest sections by length; the two
    manual patches (Luke 16:19-31, Heb 1:1-2) are checked explicitly in
    test_no_single_newline_artifact_in_patches below, since they go through
    the OLD, defective strippers and might not land in a plain top-5 scan
    once the corpus has thousands of sections."""
    rows = db.execute(
        "SELECT text FROM comments WHERE source=? ORDER BY length(text) DESC LIMIT 5",
        (source,),
    ).fetchall()
    assert rows, f"no rows found for source={source}"
    for (text,) in rows:
        ratio = _max_single_newline_run_ratio(text)
        assert ratio < 0.3, (
            f"{source}: {ratio:.0%} of newlines are lone single breaks "
            f"(mid-sentence artifact) in a {len(text)}-char section"
        )


def test_no_single_newline_artifact_in_patches(db):
    """Explicit check on the two manual patches (Luke 16:19-31, Heb 1:1-2) —
    both are extracted via the OLD, defective strippers (_strip_henry_html /
    _strip_rtf) and must be healed before insertion."""
    patches = [
        ("Henry", "LUK", 16, 19),
        ("Owen", "HEB", 1, 1),
    ]
    for source, book_id, ch, vs in patches:
        row = db.execute(
            "SELECT text FROM comments WHERE source=? AND book_id=? AND start_chapter=? AND start_verse=?",
            (source, book_id, ch, vs),
        ).fetchone()
        assert row is not None, f"patch section missing: {source} {book_id} {ch}:{vs}"
        text = row[0]
        ratio = _max_single_newline_run_ratio(text)
        assert ratio < 0.3, (
            f"{source} {book_id} {ch}:{vs} patch: {ratio:.0%} of newlines are lone "
            f"single breaks (mid-sentence artifact)"
        )
        # S2 regression: a blanket '\n+' -> ' ' fix would drive real paragraph
        # breaks to zero. Both patches are known to contain genuine '\n\n'
        # structure (measured this session: 101 in Owen's patch, 99 in
        # Henry's) — a passing ratio check alone can't catch that class of
        # over-correction, since destroying ALL newlines also yields ratio 0.
        assert text.count("\n\n") > 20, (
            f"{source} {book_id} {ch}:{vs} patch has only {text.count(chr(10) + chr(10))} "
            f"'\\n\\n' paragraph breaks — looks like real structure was destroyed"
        )


# ============================================================
#  Org-anchoring (ADR-027 Invariant 1)
# ============================================================

def test_comments_book_id_is_canonical(db):
    rows = {r[0] for r in db.execute("SELECT DISTINCT book_id FROM comments")}
    assert rows <= CANON_BOOK_IDS, f"non-canonical book_id in comments: {rows - CANON_BOOK_IDS}"


def test_comment_verses_book_id_is_canonical(db):
    rows = {r[0] for r in db.execute("SELECT DISTINCT book_id FROM comment_verses")}
    assert rows <= CANON_BOOK_IDS, f"non-canonical book_id in comment_verses: {rows - CANON_BOOK_IDS}"


def test_spot_check_org_anchoring_matches_verse_org(db, core_db):
    """Cross-check against the live built DB, using references where native
    and org coordinates DIVERGE (verified directly against verse_org, see
    commentary-sources-audit.md / this session's Opus review S1 — the
    original version of this test only probed GEN 1:1 / MAT 1:1 / HEB 1:1 /
    REV 22:21, which are all points where org == native KJV, so a mutation
    test that disabled org-anchoring entirely still passed every assertion
    here). Kept as an integration sanity check; the mutation-resistant unit
    test is test_insert_section_anchors_to_org_not_native_coordinates below,
    which controls the mapping directly instead of relying on real data."""
    checks = [
        ("1KI", 4, 21), ("1CH", 6, 1), ("JOL", 3, 1),
        ("MAL", 4, 1), ("PSA", 3, 1), ("1SA", 20, 42),
    ]
    for book_id, ch, vs in checks:
        row = core_db.execute(
            "SELECT org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation='KJV' AND book_id=? AND chapter=? AND verse=?",
            (book_id, ch, vs),
        ).fetchone()
        assert row is not None, f"verse_org has no KJV row for {book_id} {ch}:{vs}"
        org_book, org_ch, org_vs = row
        assert (org_book, org_ch, org_vs) != (book_id, ch, vs), (
            f"test fixture error: {book_id} {ch}:{vs} does not diverge from "
            f"its org coordinates — pick a different probe"
        )
        present = db.execute(
            "SELECT count(*) FROM comment_verses WHERE book_id=? AND chapter=? AND verse=?",
            (org_book, org_ch, org_vs),
        ).fetchone()[0]
        assert present > 0, (
            f"expected at least one comment_verses row at org coords "
            f"{org_book} {org_ch}:{org_vs} (native {book_id} {ch}:{vs}), found none"
        )


def test_insert_section_anchors_to_org_not_native_coordinates():
    """Unit-level, mutation-resistant org-anchoring check (Opus review S1).
    Controls the native->org mapping directly via FakeOrg so a divergent
    pair is guaranteed — a broken or disabled resolver (e.g. `to_org_or_fallback`
    returning the native coordinate unchanged) fails this immediately,
    unlike the real-data spot check above which can only use whatever
    divergent pairs happen to exist."""
    con, cur = _fresh_comment_db()
    org = FakeOrg(mapping={("GEN", 1, 1): ("GEN", 2, 5)}, max_verses={("GEN", 2): 25})
    key = bcd.insert_section(
        cur, org, "TestSrc", "en", "GEN", 1, 1, 1, 1, "sample text",
        origin="unit-test", translation_status="source",
    )
    assert key is not None
    row = cur.execute(
        "SELECT book_id, start_chapter, start_verse, end_chapter, end_verse "
        "FROM comments WHERE key=?",
        (key,),
    ).fetchone()
    assert row == ("GEN", 2, 5, 2, 5), f"comments row must store ORG coordinates, got {row}"

    verses = cur.execute(
        "SELECT book_id, chapter, verse FROM comment_verses WHERE key=?", (key,)
    ).fetchall()
    assert verses == [("GEN", 2, 5)], f"comment_verses must index the ORG coordinate, got {verses}"
    assert ("GEN", 1, 1) not in verses, (
        "the native coordinate must not appear for this key — this is exactly "
        "the assertion that a disabled/broken org-anchoring would fail"
    )


def test_org_resolver_verse_zero_anchors_via_chapter_v1(tmp_path):
    """Opus review S4 (part 1): a chapter-intro section's verse=0 must be
    resolved via that chapter's verse 1 to find the correct ORG chapter —
    NOT a bare native-coordinate fallback, which can point at a chapter that
    doesn't exist in org at all (e.g. native Malachi has 4 chapters, org
    Malachi only has 3)."""
    db_path = tmp_path / "mini_core.db"
    con = sqlite3.connect(str(db_path))
    con.execute(
        "CREATE TABLE verse_org(translation TEXT, book_id TEXT, chapter INTEGER, "
        "verse INTEGER, org_book_id TEXT, org_chapter INTEGER, org_verse INTEGER)"
    )
    con.execute("INSERT INTO verse_org VALUES('KJV','MAL',4,1,'MAL',3,19)")
    con.commit()
    con.close()

    org = bcd.OrgResolver(str(db_path))
    result = org.resolve("MAL", 4, 0)
    assert result == ("MAL", 3, 0), (
        f"chapter-intro verse=0 must anchor via v1's org chapter, got {result} "
        f"— a native-coordinate fallback would give ('MAL', 4, 0), a chapter "
        f"that does not exist in org"
    )


def test_insert_section_chapter_intro_indexed_only_at_org_chapter_verse_one():
    """Opus review S4 (part 2), revised per Ivan's decision 2026-09-02: a
    verse=0 chapter-intro section indexed ONLY at verse=0 is unreachable by
    any ordinary verse-based lookup — but fanning it out across the WHOLE
    chapter (an earlier version of this fix) made it resurface on every
    verse, indistinguishable from real verse-specific commentary. It must
    surface exactly once: at verse 1 of the ORG chapter, where the reader
    naturally encounters it before the verse-specific commentary.

    Uses a mapping where native chapter 1's own v1 (via the verse=0 special
    case) resolves to a DIFFERENT org chapter (5) than the native chapter
    number, to prove the index lands on the ORG chapter's own verse 1 — not
    on whatever org verse native chapter 1's verse 1 happens to map to (a
    real failure mode: native/org chapter boundaries don't always align, so
    that mapping can land on an arbitrary org verse, not verse 1)."""
    con, cur = _fresh_comment_db()
    # FakeOrg is a plain passthrough (unlike the real OrgResolver, it does
    # NOT special-case verse=0 by looking up v1) — so org_start_ch is
    # controlled directly via the (book,chapter,0) mapping entry, simulating
    # "this native chapter's intro anchors to org chapter 5".
    org = FakeOrg(
        mapping={("HEB", 1, 0): ("HEB", 5, 0), ("HEB", 1, 1): ("HEB", 5, 26)},
        max_verses={},
    )
    key = bcd.insert_section(
        cur, org, "Owen", "en", "HEB", 1, 0, 1, 0, "chapter overview text",
        origin="unit-test", translation_status="source",
    )
    rows = cur.execute("SELECT book_id, chapter, verse FROM comment_verses WHERE key=?", (key,)).fetchall()
    assert rows == [("HEB", 5, 1)], (
        f"expected exactly one row at org chapter 5 verse 1 (not verse 26, "
        f"where native chapter 1's own verse 1 happens to map), got {rows}"
    )


def test_insert_section_book_level_intro_indexed_at_org_chapter_one_verse_one():
    """Second-round review finding N3, revised per Ivan's decision
    2026-09-02: a BOOK-level intro (start_chapter=0, e.g. Owen's 'Volumes 1
    and 2 provide a thorough introduction...') used to fabricate a phantom
    (book, 0, 1) index row (N3) or sit unreachable at (book, 0, 0). Now it
    surfaces at the book's natural entry point — org chapter 1, verse 1 —
    same principle as the chapter-overview case above."""
    con, cur = _fresh_comment_db()
    org = FakeOrg(mapping={}, max_verses={})  # chapter 0 never resolves -> native fallback
    key = bcd.insert_section(
        cur, org, "Owen", "en", "HEB", 0, 0, 0, 0, "book-level intro text",
        origin="unit-test", translation_status="source",
    )
    rows = cur.execute("SELECT book_id, chapter, verse FROM comment_verses WHERE key=?", (key,)).fetchall()
    assert rows == [("HEB", 1, 1)], f"expected only chapter 1 verse 1 indexed, got {rows}"


def test_no_chapter_zero_index_rows_in_db(db):
    """DB-level regression guard: chapter=0 must never appear in
    comment_verses — both the old phantom-verse-1 bug (N3) and the bare
    verse=0 marker are gone now that book-level intros anchor to (book,1,1)."""
    n = db.execute("SELECT count(*) FROM comment_verses WHERE chapter=0").fetchone()[0]
    assert n == 0, f"{n} comment_verses rows still at chapter=0 (should anchor to chapter 1, verse 1)"


def test_no_chapter_or_book_intro_indexed_at_verse_zero_or_across_whole_chapter(db):
    """DB-level regression guard for the revised S4/N3 design: a chapter- or
    book-intro section (comments.start_verse=0) must index EXACTLY ONE
    comment_verses row (verse 1 of its chapter), never the bare verse=0
    marker and never a full-chapter fan-out."""
    rows = db.execute("SELECT key FROM comments WHERE start_verse=0").fetchall()
    assert rows, "expected at least some verse=0 (chapter/book intro) sections"
    bad = []
    for (key,) in rows:
        verses = db.execute(
            "SELECT chapter, verse FROM comment_verses WHERE key=?", (key,)
        ).fetchall()
        if len(verses) != 1 or verses[0][1] != 1:
            bad.append((key, verses))
    assert not bad, f"{len(bad)} intro sections not indexed as exactly one verse-1 row: {bad[:5]}"


# ============================================================
#  mybible_ranges() end-verse inference (pure, no DB fixture required)
# ============================================================

def test_mybible_ranges_skips_duplicate_same_verse_start():
    """Opus review S6: comparing only against the IMMEDIATE next row let a
    same-(chapter,verse) duplicate (found: 491 cases in Calvin) collapse the
    range to a degenerate single verse instead of running to the next
    genuinely later verse — silently dropping real coverage from the index."""
    con = sqlite3.connect(":memory:")
    cur = con.cursor()
    cur.execute(
        "CREATE TABLE commentaries(book_number INTEGER, chapter_number_from INTEGER, "
        "verse_number_from INTEGER, chapter_number_to INTEGER, verse_number_to INTEGER, text TEXT)"
    )
    cur.execute("INSERT INTO commentaries VALUES(10,1,1,NULL,NULL,'first')")
    cur.execute("INSERT INTO commentaries VALUES(10,1,1,NULL,NULL,'second')")
    cur.execute("INSERT INTO commentaries VALUES(10,1,5,NULL,NULL,'third')")
    con.commit()
    org = FakeOrg(max_verses={("GEN", 1): 10})
    ranges = list(bcd.mybible_ranges(cur, 10, "GEN", org))
    assert ranges == [
        (1, 1, 1, 4, "first"),
        (1, 1, 1, 4, "second"),
        (1, 5, 1, 10, "third"),
    ], ranges


def test_mybible_ranges_raises_on_unsupported_multichapter_null_verse_to():
    """Opus review S8: verse_number_to NULL with chapter_number_to present
    and different from chapter_number_from is a format the end-inference
    logic doesn't support (0 occurrences in known data) — must fail loudly,
    not silently drop the multi-chapter tail."""
    con = sqlite3.connect(":memory:")
    cur = con.cursor()
    cur.execute(
        "CREATE TABLE commentaries(book_number INTEGER, chapter_number_from INTEGER, "
        "verse_number_from INTEGER, chapter_number_to INTEGER, verse_number_to INTEGER, text TEXT)"
    )
    cur.execute("INSERT INTO commentaries VALUES(10,1,1,2,NULL,'x')")
    con.commit()
    org = FakeOrg()
    with pytest.raises(RuntimeError):
        list(bcd.mybible_ranges(cur, 10, "GEN", org))


# ============================================================
#  insert_section() edge cases
# ============================================================

def test_insert_section_swaps_inverted_range():
    """Opus review S7: a source data error (found: one Spurgeon-VE row,
    HEB 9:18 -> 9:6) must be swapped to a valid direction with a warning,
    not stored inverted and unvalidated."""
    con, cur = _fresh_comment_db()
    org = FakeOrg(max_verses={("HEB", 9): 28})
    key = bcd.insert_section(
        cur, org, "TestSrc", "en", "HEB", 9, 18, 9, 6, "inverted range text",
        origin="unit-test", translation_status="source",
    )
    row = cur.execute(
        "SELECT start_chapter, start_verse, end_chapter, end_verse FROM comments WHERE key=?",
        (key,),
    ).fetchone()
    assert row == (9, 6, 9, 18), f"expected the range swapped to a valid direction, got {row}"


def test_insert_section_key_disambiguation_is_content_based_not_positional():
    """Opus review S9: the old positional suffix (base_key, base_key-2, ...)
    depended on SQLite's non-guaranteed tie-break order for equal
    (chapter,verse) source rows — not stable across rebuilds. The suffix
    must instead be derived from the TEXT itself, so the FINAL key assigned
    to each of two colliding texts does not depend on insertion order.

    (An individual call's *return value* can be transiently stale if a
    later call rekeys that row out of the way — insert_section rekeys the
    existing occupant, not the caller's already-returned string — so this
    checks the converged database state after both inserts, not the two
    return values against each other.)"""
    org = FakeOrg()  # no mapping entries -> native-coordinate fallback throughout

    con1, cur1 = _fresh_comment_db()
    bcd.insert_section(cur1, org, "TestSrc", "en", "GEN", 1, 1, 1, 1, "text A",
                        origin="o", translation_status="source")
    bcd.insert_section(cur1, org, "TestSrc", "en", "GEN", 1, 1, 1, 1, "text B",
                        origin="o", translation_status="source")
    rows1 = {t: k for k, t in cur1.execute("SELECT key, text FROM comments").fetchall()}

    con2, cur2 = _fresh_comment_db()
    bcd.insert_section(cur2, org, "TestSrc", "en", "GEN", 1, 1, 1, 1, "text B",
                        origin="o", translation_status="source")
    bcd.insert_section(cur2, org, "TestSrc", "en", "GEN", 1, 1, 1, 1, "text A",
                        origin="o", translation_status="source")
    rows2 = {t: k for k, t in cur2.execute("SELECT key, text FROM comments").fetchall()}

    assert rows1["text A"] != rows1["text B"]
    assert rows1 == rows2, (
        f"final key assignment differs depending on insertion order: {rows1} vs {rows2}"
    )

    # Also: comment_verses must have been rekeyed in lockstep, not left
    # pointing at a stale key after a rekey.
    orphans = cur1.execute(
        "SELECT count(*) FROM comment_verses cv LEFT JOIN comments c ON c.key = cv.key "
        "WHERE c.key IS NULL"
    ).fetchone()[0]
    assert orphans == 0


# ============================================================
#  module_info
# ============================================================

def test_module_info_shape(db):
    info = dict(db.execute("SELECT name, value FROM module_info").fetchall())
    assert info.get("language") == "en"
    sources = json.loads(info["sources"])
    assert {s["source"] for s in sources} == EXPECTED_SOURCES
    book_versions = json.loads(info["book_versions"])
    assert EXPECTED_SOURCES <= set(book_versions.keys())
    assert "built_at" in info


def test_module_info_has_schema_version_and_min_app_version(db):
    """ADR-027 §1 requires schema_version/min_app_version in module_info;
    Amendment 2026-09-01 rescoped module_info but did not drop this
    (Opus review S10)."""
    info = dict(db.execute("SELECT name, value FROM module_info").fetchall())
    assert "schema_version" in info
    assert "min_app_version" in info


def test_module_info_sources_n_sections_matches_actual_rows(db):
    """Opus review S5: the printed/stored n_sections used to be the raw
    per-call insert-counter, which overcounts by however many identical-text
    dedup no-ops it returned a key for (measured: Calvin said 13564 vs 13281
    actual rows). Must match `SELECT count(*) ... WHERE source=?` exactly."""
    info = dict(db.execute("SELECT name, value FROM module_info").fetchall())
    sources = json.loads(info["sources"])
    for s in sources:
        actual = db.execute(
            "SELECT count(*) FROM comments WHERE source=?", (s["source"],)
        ).fetchone()[0]
        assert s["n_sections"] == actual, (
            f"module_info.sources n_sections for {s['source']} is "
            f"{s['n_sections']} but actual comments rows = {actual}"
        )


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-v"]))
