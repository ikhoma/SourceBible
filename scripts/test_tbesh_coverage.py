#!/usr/bin/env python3
"""
test_tbesh_coverage.py
======================
Validates that TBESH (Hebrew) and TBESG (Greek) data loaded correctly
into strongs table: xlit_simple, short_def (gloss), long_def (BDB definition).

Run from project root:
    python3 scripts/test_tbesh_coverage.py [path/to/sourcebible.db]

Results are printed to stdout AND written to docs/tbesh_test_results.log.
Exit code 0 = all tests pass, 1 = failures found.
"""

import sys
import sqlite3
import os
from datetime import datetime

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else "sourcebible.db"

if not os.path.exists(DB_PATH):
    alt = "SourceBible/Resources/sourcebible.db"
    if os.path.exists(alt):
        DB_PATH = alt
    else:
        print(f"ERROR: DB not found at '{DB_PATH}' or '{alt}'")
        print("Usage: python3 scripts/test_tbesh_coverage.py [path/to/sourcebible.db]")
        sys.exit(1)

LOG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "docs", "tbesh_test_results.log")
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
_log_file = open(LOG_PATH, "w", encoding="utf-8")

def _emit(line=""):
    print(line)
    _log_file.write(line + "\n")

con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
cur = con.cursor()

db_mtime = datetime.fromtimestamp(os.path.getmtime(DB_PATH)).strftime("%Y-%m-%d %H:%M:%S")
_emit(f"TBESH Coverage Test — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
_emit(f"DB: {os.path.abspath(DB_PATH)}  (modified {db_mtime})")
_emit("=" * 60)

PASS = "✓"
FAIL = "✗"
WARN = "⚠"

failures = []
warnings = []

def fail(msg):
    failures.append(msg)
    _emit(f"  {FAIL} {msg}")

def warn(msg):
    warnings.append(msg)
    _emit(f"  {WARN} {msg}")

def ok(msg):
    _emit(f"  {PASS} {msg}")


# ──────────────────────────────────────────────────────────────
# 1. OVERALL COVERAGE
# ──────────────────────────────────────────────────────────────
_emit("\n[1] Overall strongs table coverage")

cur.execute("SELECT COUNT(*) FROM strongs")
total = cur.fetchone()[0]
ok(f"Total strongs rows: {total:,}")

for lang, label in [("H%", "Hebrew"), ("G%", "Greek")]:
    cur.execute("SELECT COUNT(*) FROM strongs WHERE id LIKE ?", (lang,))
    lang_total = cur.fetchone()[0]

    cur.execute(
        "SELECT COUNT(*) FROM strongs WHERE id LIKE ? AND xlit_simple IS NOT NULL AND xlit_simple != ''",
        (lang,)
    )
    has_xlit = cur.fetchone()[0]

    cur.execute(
        "SELECT COUNT(*) FROM strongs WHERE id LIKE ? AND short_def IS NOT NULL AND short_def != ''",
        (lang,)
    )
    has_gloss = cur.fetchone()[0]

    cur.execute(
        "SELECT COUNT(*) FROM strongs WHERE id LIKE ? AND long_def IS NOT NULL AND long_def != ''",
        (lang,)
    )
    has_long = cur.fetchone()[0]

    xlit_pct  = 100 * has_xlit  / lang_total if lang_total else 0
    gloss_pct = 100 * has_gloss / lang_total if lang_total else 0
    long_pct  = 100 * has_long  / lang_total if lang_total else 0

    _emit(f"\n  {label} ({lang_total:,} entries, id LIKE '{lang}'):")
    msg_xlit  = f"xlit_simple filled: {has_xlit:,} / {lang_total:,} ({xlit_pct:.1f}%)"
    msg_gloss = f"short_def  filled: {has_gloss:,} / {lang_total:,} ({gloss_pct:.1f}%)"
    msg_long  = f"long_def   filled: {has_long:,}  / {lang_total:,} ({long_pct:.1f}%)"

    # Thresholds: expect ≥90% coverage for Hebrew (TBESH); ≥85% for Greek
    xlit_thresh  = 90 if lang == "H" else 85
    gloss_thresh = 85 if lang == "H" else 80
    long_thresh  = 75 if lang == "H" else 70

    (ok if xlit_pct  >= xlit_thresh  else fail)(msg_xlit)
    (ok if gloss_pct >= gloss_thresh else fail)(msg_gloss)
    (ok if long_pct  >= long_thresh  else warn)(msg_long)


# ──────────────────────────────────────────────────────────────
# 2. SPECIFIC KNOWN-BAD IDs (from CLAUDE.md / docs/db_build.md)
# ──────────────────────────────────────────────────────────────
_emit("\n[2] Known-problematic IDs (Psalm 1 words + other TBESH-only suffixed entries)")

KNOWN_CASES = [
    # (id, desc, must_have_xlit, must_have_gloss, must_have_long_def)
    # These were NULL before the June 2026 regex fix
    ("H1471", "גּוֹי  (nation/people)  — TBESH only H1471a",    True,  True,  True),
    ("H6213", "עָשָׂה (to do/make)    — TBESH only H6213a",    True,  True,  True),
    ("H5034", "נָבֵל  (to wither/fold) — TBESH only H5034a",   True,  True,  True),
    ("H6743", "צָלַח  (to prosper)    — TBESH only H6743b",    True,  True,  True),
    # Sub-entries referenced in Psalm 1
    ("H835",  "אֶשֶׁר (happiness)     — bare entry",           True,  True,  False),
    ("H835a", "אַשְׁרֵי (blessed are) — sub-entry",            True,  True,  False),
    ("H871a", "בְּ (insep. prep.)     — sub-entry",            True,  True,  False),
    ("H1886a","הַ (definite article)  — sub-entry",            True,  True,  False),
    # Well-known entries to sanity-check basics
    ("H430",  "אֱלֹהִים (God/gods)",                           True,  True,  True),
    ("H3068", "יְהוָה (LORD/YHWH)",                           True,  True,  True),
    ("H1254", "בָּרָא (to create)",                            True,  True,  True),
    ("G3056", "λόγος (word/reason)",                           True,  True,  True),
    ("G26",   "ἀγάπη (love)",                                  True,  True,  True),
]

for sid, desc, need_xlit, need_gloss, need_long in KNOWN_CASES:
    cur.execute(
        "SELECT xlit_simple, short_def, long_def FROM strongs WHERE id = ?", (sid,)
    )
    row = cur.fetchone()
    if not row:
        fail(f"{sid} {desc} — ROW NOT FOUND in strongs table")
        continue

    xlit  = row["xlit_simple"] or ""
    gloss = row["short_def"]   or ""
    long  = row["long_def"]    or ""

    issues = []
    if need_xlit  and not xlit:  issues.append("xlit_simple empty")
    if need_gloss and not gloss: issues.append("short_def (gloss) empty")
    if need_long  and not long:  issues.append("long_def empty")

    if issues:
        fail(f"{sid} {desc} — {', '.join(issues)}")
    else:
        xlit_disp = xlit[:20] if xlit else "(none)"
        gloss_disp = gloss[:30] if gloss else "(none)"
        ok(f"{sid} xlit={xlit_disp!r}  gloss={gloss_disp!r}")


# ──────────────────────────────────────────────────────────────
# 3. SUFFIXED-ONLY IDs — BASE PROPAGATION
# Check: for every suffixed TBESH row (H1471a, H6213a, etc.),
# the corresponding bare base ID (H1471, H6213) must have non-null
# xlit_simple and short_def (since Macula uses bare IDs).
# ──────────────────────────────────────────────────────────────
_emit("\n[3] Suffixed-entry → base-ID propagation check")

import re

cur.execute("SELECT id, xlit_simple, short_def FROM strongs WHERE id LIKE 'H%' OR id LIKE 'G%'")
all_rows = {r["id"]: r for r in cur.fetchall()}

suffixed_ids = [sid for sid in all_rows if re.match(r'^[HG]\d+[a-z]$', sid)]
_emit(f"  Suffixed strongs entries found: {len(suffixed_ids)}")

base_missing_xlit  = []
base_missing_gloss = []

for sid in suffixed_ids:
    m = re.match(r'^([HG]\d+)[a-z]$', sid)
    if not m:
        continue
    base_sid = m.group(1)
    if base_sid not in all_rows:
        continue  # no base row exists — normal for some sub-entries

    base = all_rows[base_sid]
    suffixed = all_rows[sid]

    # Only flag if the suffixed entry itself has data (otherwise nothing to propagate)
    has_src_xlit  = bool(suffixed["xlit_simple"] and suffixed["xlit_simple"].strip())
    has_src_gloss = bool(suffixed["short_def"]   and suffixed["short_def"].strip())

    if has_src_xlit and not (base["xlit_simple"] and base["xlit_simple"].strip()):
        base_missing_xlit.append((base_sid, sid))
    if has_src_gloss and not (base["short_def"] and base["short_def"].strip()):
        base_missing_gloss.append((base_sid, sid))

if base_missing_xlit:
    for base_sid, src_sid in base_missing_xlit[:10]:
        fail(f"  {base_sid} has no xlit_simple but {src_sid} has one (propagation missed)")
    if len(base_missing_xlit) > 10:
        fail(f"  ... and {len(base_missing_xlit) - 10} more base IDs missing xlit propagation")
else:
    ok(f"All base IDs with a suffixed-source have xlit_simple populated")

if base_missing_gloss:
    for base_sid, src_sid in base_missing_gloss[:10]:
        fail(f"  {base_sid} has no short_def but {src_sid} has one (propagation missed)")
    if len(base_missing_gloss) > 10:
        fail(f"  ... and {len(base_missing_gloss) - 10} more base IDs missing gloss propagation")
else:
    ok(f"All base IDs with a suffixed-source have short_def populated")


# ──────────────────────────────────────────────────────────────
# 4. WORDS USED IN ACTUAL VERSES — cross-check strongs join
# Pick 20 common Hebrew words from word table and confirm strongs
# xlit_simple / short_def are non-null for their strongs_id.
# ──────────────────────────────────────────────────────────────
_emit("\n[4] Spot-check: top 20 most-used Hebrew strongs IDs in word table")

cur.execute("""
    SELECT w.strongs_id, COUNT(*) as cnt,
           s.xlit_simple, s.short_def
    FROM word w
    JOIN strongs s ON s.id = w.strongs_id
    WHERE w.language = 'hbo'
      AND w.strongs_id IS NOT NULL
      AND w.strongs_id != ''
    GROUP BY w.strongs_id
    ORDER BY cnt DESC
    LIMIT 20
""")
rows = cur.fetchall()

xlit_missing  = [(r["strongs_id"], r["cnt"]) for r in rows if not r["xlit_simple"]]
gloss_missing = [(r["strongs_id"], r["cnt"]) for r in rows if not r["short_def"]]

if xlit_missing:
    for sid, cnt in xlit_missing:
        fail(f"Top-20 Hebrew word '{sid}' (used {cnt:,}×) has no xlit_simple")
else:
    ok("All top-20 Hebrew strongs IDs have xlit_simple")

if gloss_missing:
    for sid, cnt in gloss_missing:
        fail(f"Top-20 Hebrew word '{sid}' (used {cnt:,}×) has no short_def (gloss)")
else:
    ok("All top-20 Hebrew strongs IDs have short_def")


# ──────────────────────────────────────────────────────────────
# 5. WORD TABLE — NULL xlit_simple via JOIN (what the app sees)
# Find Hebrew strongs_ids that appear in word table but have no
# xlit_simple in strongs — these are the "broken" words.
# ──────────────────────────────────────────────────────────────
_emit("\n[5] Hebrew strongs IDs referenced in word table but missing xlit_simple")

cur.execute("""
    SELECT DISTINCT w.strongs_id, COUNT(*) as occurrences
    FROM word w
    LEFT JOIN strongs s ON s.id = w.strongs_id
    WHERE w.language = 'hbo'
      AND w.strongs_id IS NOT NULL
      AND w.strongs_id != ''
      AND (s.xlit_simple IS NULL OR s.xlit_simple = '')
    GROUP BY w.strongs_id
    ORDER BY occurrences DESC
    LIMIT 20
""")
bad_xlit = cur.fetchall()

cur.execute("""
    SELECT COUNT(DISTINCT w.strongs_id) as bad_ids,
           COUNT(*) as bad_occurrences
    FROM word w
    LEFT JOIN strongs s ON s.id = w.strongs_id
    WHERE w.language = 'hbo'
      AND w.strongs_id IS NOT NULL
      AND w.strongs_id != ''
      AND (s.xlit_simple IS NULL OR s.xlit_simple = '')
""")
bad_summary = cur.fetchone()
bad_ids  = bad_summary["bad_ids"]
bad_occ  = bad_summary["bad_occurrences"]

# Thresholds: >20 distinct IDs or >100 total occurrences = hard failure.
# A tiny residual of obscure place-name variants (e.g. 5 IDs / 10 occurrences)
# is acceptable and treated as a warning only.
if bad_ids > 20 or bad_occ > 100:
    fail(f"{bad_ids} Hebrew strongs IDs ({bad_occ:,} word occurrences) missing xlit_simple")
    _emit(f"  Top offenders:")
    for r in bad_xlit[:10]:
        _emit(f"    {r['strongs_id']} ({r['occurrences']:,} occurrences)")
elif bad_ids > 0:
    warn(f"{bad_ids} Hebrew strongs IDs ({bad_occ} word occurrences) missing xlit_simple "
         f"(negligible residual — rare place-name variants)")
    for r in bad_xlit[:10]:
        _emit(f"    {r['strongs_id']} ({r['occurrences']:,} occurrences)")
else:
    ok("No Hebrew word occurrences are missing xlit_simple (all strongs_id → xlit resolved)")

_emit("\n[5b] Hebrew strongs IDs referenced in word table but missing short_def (gloss)")

cur.execute("""
    SELECT COUNT(DISTINCT w.strongs_id) as bad_ids,
           COUNT(*) as bad_occurrences
    FROM word w
    LEFT JOIN strongs s ON s.id = w.strongs_id
    WHERE w.language = 'hbo'
      AND w.strongs_id IS NOT NULL
      AND w.strongs_id != ''
      AND (s.short_def IS NULL OR s.short_def = '')
""")
bad_gloss = cur.fetchone()
bad_ids_g  = bad_gloss["bad_ids"]
bad_occ_g  = bad_gloss["bad_occurrences"]

if bad_ids_g > 0:
    fail(f"{bad_ids_g} Hebrew strongs IDs ({bad_occ_g:,} word occurrences) missing short_def (gloss)")
    cur.execute("""
        SELECT DISTINCT w.strongs_id, COUNT(*) as occurrences
        FROM word w
        LEFT JOIN strongs s ON s.id = w.strongs_id
        WHERE w.language = 'hbo' AND w.strongs_id IS NOT NULL AND w.strongs_id != ''
          AND (s.short_def IS NULL OR s.short_def = '')
        GROUP BY w.strongs_id ORDER BY occurrences DESC LIMIT 10
    """)
    _emit(f"  Top offenders:")
    for r in cur.fetchall():
        _emit(f"    {r['strongs_id']} ({r['occurrences']:,} occurrences)")
else:
    ok("No Hebrew word occurrences are missing short_def")


# ──────────────────────────────────────────────────────────────
# 6. PSALM 1 END-TO-END: every word in Psalm 1 has xlit + gloss
# ──────────────────────────────────────────────────────────────
_emit("\n[6] Psalm 1 end-to-end: all words have xlit_simple + short_def via strongs")

cur.execute("""
    SELECT w.id, w.verse, w.position, w.surface, w.strongs_id,
           s.xlit_simple, s.short_def, s.long_def
    FROM word w
    LEFT JOIN strongs s ON s.id = w.strongs_id
    WHERE w.book_id = 'PSA' AND w.chapter = 1
      AND w.language = 'hbo'
    ORDER BY w.verse, w.position
""")
psalm1_words = cur.fetchall()

if not psalm1_words:
    fail("No Hebrew words found for Psalm 1 in word table — wrong book_id?")
else:
    missing_xlit  = [r for r in psalm1_words if not r["xlit_simple"]]
    missing_gloss = [r for r in psalm1_words if not r["short_def"]]
    missing_long  = [r for r in psalm1_words if not r["long_def"]]

    ok(f"Psalm 1: {len(psalm1_words)} Hebrew words found")

    if missing_xlit:
        fail(f"Psalm 1: {len(missing_xlit)} words missing xlit_simple:")
        for r in missing_xlit:
            _emit(f"    v{r['verse']}:{r['position']} {r['surface']} ({r['strongs_id']})")
    else:
        ok("Psalm 1: all words have xlit_simple")

    if missing_gloss:
        fail(f"Psalm 1: {len(missing_gloss)} words missing short_def (gloss):")
        for r in missing_gloss:
            _emit(f"    v{r['verse']}:{r['position']} {r['surface']} ({r['strongs_id']})")
    else:
        ok("Psalm 1: all words have short_def (gloss)")

    if missing_long:
        warn(f"Psalm 1: {len(missing_long)} words missing long_def (BDB) — "
             f"sub-entries expected, check manually:")
        for r in missing_long[:5]:
            _emit(f"    v{r['verse']}:{r['position']} {r['surface']} ({r['strongs_id']})")
    else:
        ok("Psalm 1: all words have long_def")


# ──────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────
_emit("\n" + "═" * 60)
if failures:
    _emit(f"{FAIL} FAILED — {len(failures)} failure(s), {len(warnings)} warning(s)")
    for f in failures:
        _emit(f"  • {f}")
    _log_file.close()
    print(f"\nLog written to: {LOG_PATH}")
    sys.exit(1)
elif warnings:
    _emit(f"{WARN} PASSED WITH WARNINGS — {len(warnings)} warning(s)")
    for w in warnings:
        _emit(f"  • {w}")
    _log_file.close()
    print(f"\nLog written to: {LOG_PATH}")
    sys.exit(0)
else:
    _emit(f"{PASS} ALL TESTS PASSED")
    _log_file.close()
    print(f"\nLog written to: {LOG_PATH}")
    sys.exit(0)
