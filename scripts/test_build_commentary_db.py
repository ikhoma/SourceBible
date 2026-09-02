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
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = os.environ.get("COMMENTARY_DB", str(ROOT / "commentaries-en.db"))
CORE_DB_PATH = os.environ.get("CORE_DB", str(ROOT / "sourcebible.db"))

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
        ratio = _max_single_newline_run_ratio(row[0])
        assert ratio < 0.3, (
            f"{source} {book_id} {ch}:{vs} patch: {ratio:.0%} of newlines are lone "
            f"single breaks (mid-sentence artifact)"
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
    """Pick a handful of well-known, versification-stable references and
    confirm the org coordinates stored in comments/comment_verses agree with
    what verse_org (translation='KJV') says directly — a live cross-check,
    not just internal self-consistency."""
    checks = [("GEN", 1, 1), ("MAT", 1, 1), ("HEB", 1, 1), ("REV", 22, 21)]
    for book_id, ch, vs in checks:
        row = core_db.execute(
            "SELECT org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation='KJV' AND book_id=? AND chapter=? AND verse=?",
            (book_id, ch, vs),
        ).fetchone()
        assert row is not None, f"verse_org has no KJV row for {book_id} {ch}:{vs}"
        org_book, org_ch, org_vs = row
        present = db.execute(
            "SELECT count(*) FROM comment_verses WHERE book_id=? AND chapter=? AND verse=?",
            (org_book, org_ch, org_vs),
        ).fetchone()[0]
        assert present > 0, (
            f"expected at least one comment_verses row at org coords "
            f"{org_book} {org_ch}:{org_vs} (native {book_id} {ch}:{vs}), found none"
        )


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


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-v"]))
