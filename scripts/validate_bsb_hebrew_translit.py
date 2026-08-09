#!/usr/bin/env python3
"""
validate_bsb_hebrew_translit.py — ADR-020 validation, run against BSB instead of BibleHub.

Answers one question: can `data/bsb_tables.tsv` (Berean Standard Bible Translation
Tables, PUBLIC DOMAIN since 2023-04-30) replace the BibleHub scrape as the source
of `word.xlit_slot`?

READ-ONLY. Touches nothing. Writes one report: data/bsb_translit_validation.tsv

⛔⛔ STALE — DOES NOT RUN AS-IS (audited 2026-08-07).
   This script maps BSB→Macula through the `verse_map` table, which ADR-028 phase 2
   DELETED, together with `build_verse_map.py` and `findBestMaculaVerse()`. The
   replacement is `verse_org` (155 621 rows, curated + O2-verified, cross-chapter and
   N:M aware), built by `scripts/build_versification.py`.
   To revive this script, port `load_verse_map()` to a reverse `verse_org` hop
   (`idx_verse_org_rev`); do NOT re-derive a mapping heuristically. See CLAUDE.md
   → "verse_org — версифікація (ADR-028)".

ℹ️ Sandbox note (re-measured 2026-08-07): sourcebible.db is no longer APFS-sparse
   (350 MB physical vs 342 MB logical) and READ-ONLY access from the Linux sandbox
   works — open with `mode=ro` only. Writes still happen on the Mac exclusively.
   The previous blanket "unreadable from the sandbox" note described an older file
   state and has been corrected in CLAUDE.md.

Usage:
    python3 scripts/validate_bsb_hebrew_translit.py [path/to/sourcebible.db]

Default DB: sourcebible.db (repo root)

─── What it checks ───────────────────────────────────────────────────────────
Levels 1 and 2 are ADR-020's, retargeted at BSB. Levels 3 and 4 are new and are
the ones that actually decide the swap.

  L1  COUNT_MISMATCH   Macula display-slot count != BSB Hebrew word count for a
                       verse. Same guard as _apply_bh_hebrew_translit(): on
                       mismatch the whole verse is untrustworthy, skip it.

  L2  STRONG_MISMATCH  Per slot: Macula root token's Strong's base number !=
                       BSB `Str Heb` base number. Means the translit would land
                       on the wrong word.

  L3  COVERAGE         Macula OT verses with no BSB rows at all (BSB can't fill
                       xlit_slot there) + slots that would go from filled →
                       NULL if we swapped.

  L4  DELTA            For slots BOTH sources fill: does BSB's translit differ
                       from the BibleHub value currently in xlit_slot? Split
                       into SEPARATOR_ONLY (·/- — cosmetic) vs SCHEME_DIFF
                       (real: ʾ/ʿ/å̄/ī/ē/ɛ notation) vs OTHER.

  Also reported: REGRESSION — slots BibleHub filled that BSB leaves empty.
                 GAIN       — slots BibleHub left NULL that BSB can fill.

─── Versification ────────────────────────────────────────────────────────────
BSB uses English (KJV-style) verse numbering. Macula/`word` uses MT numbering.
They diverge in 459 chapters (Psalm superscriptions etc. — see verse_map).
This script maps BSB refs → Macula refs through verse_map using the KJV row,
falling back to identity where no mapping row exists. A NO_VERSE_MAP row is
emitted if a verse looks shifted but has no mapping — that is a red flag, not
noise.

NB: the existing BibleHub scraper (fetch_biblehub_translit_hebrew.py) enumerates
MT refs from Macula and fetches biblehub.com/text/<book>/<ch>-<vs>.htm with them,
but BibleHub serves ENGLISH numbering at those URLs. In the shifted chapters it
has been fetching the wrong verse. The COUNT_MISMATCH guard nulls most of that,
which is why it never showed up as visible corruption. Worth confirming in the
L3 numbers below — if BibleHub coverage in Psalms is conspicuously low, that is
the cause, and it is another argument for the swap.
"""

import csv
import os
import re
import sys
import sqlite3
import unicodedata
from collections import defaultdict

csv.field_size_limit(1000000000)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BSB_TSV = os.path.join(REPO, "data", "bsb_tables.tsv")
REPORT = os.path.join(REPO, "data", "bsb_translit_validation.tsv")

# Used ONLY to decide which slots are display words (a slot with no non-helper token
# is not rendered). NOT used to pick a slot's head — see head_token(). Same set as
# build_db.py; incomplete (missing H3807a לְ, H4480 מִן) but that only matters for head
# selection, which no longer uses it.
HELPER_STRONGS = {
    "H1886a", "H871a", "H3509a", "H1930a",
    "H2050b", "H2050c", "H2050d", "H5105b",
}


def is_enclitic(lexical_class, morph):
    """Pronominal suffix (morph 'Sp3ms'…) or enclitic particle (class 'x')."""
    return lexical_class == "x" or (morph or "").startswith("S")


def head_token(tokens):
    """
    The head (root) of a slot: the last token that is not an enclitic.

    Hebrew builds a slot as [proclitics…] HEAD [enclitics…] — inseparable prepositions,
    the article and the waw attach to the front; pronominal suffixes to the back.

    Mirrors VerseTabContent.headToken(of:). Keep the two in sync until the build emits
    an explicit `word.is_head` column (see ADR).

    tokens: list of (word_id, slot, strongs_id, xlit_slot, lexical_class, morph)
    """
    for t in reversed(tokens):
        if not is_enclitic(t[4], t[5]):
            return t
    return tokens[-1]

# BSB book name → OSIS id used in the `word` table.
BSB_BOOK_TO_OSIS = {
    "Genesis": "GEN", "Exodus": "EXO", "Leviticus": "LEV", "Numbers": "NUM",
    "Deuteronomy": "DEU", "Joshua": "JOS", "Judges": "JDG", "Ruth": "RUT",
    "1 Samuel": "1SA", "2 Samuel": "2SA", "1 Kings": "1KI", "2 Kings": "2KI",
    "1 Chronicles": "1CH", "2 Chronicles": "2CH", "Ezra": "EZR",
    "Nehemiah": "NEH", "Esther": "EST", "Job": "JOB", "Psalm": "PSA",
    "Proverbs": "PRO", "Ecclesiastes": "ECC", "Song of Solomon": "SNG",
    "Isaiah": "ISA", "Jeremiah": "JER", "Lamentations": "LAM",
    "Ezekiel": "EZK", "Daniel": "DAN", "Hosea": "HOS", "Joel": "JOL",
    "Amos": "AMO", "Obadiah": "OBA", "Jonah": "JON", "Micah": "MIC",
    "Nahum": "NAM", "Habakkuk": "HAB", "Zephaniah": "ZEP", "Haggai": "HAG",
    "Zechariah": "ZEC", "Malachi": "MAL",
}

# Column indices (0-based) in bsb_tables.tsv, verified against the 3rd-printing file:
#   0 Heb Sort | 1 Greek Sort | 2 BSB Sort | 3 Verse | 4 Language |
#   5 WLC/Nestle Base | 6 WLC/Nestle variants | 7 Translit | 8 Parsing (short) |
#   9 Parsing (long) | 10 Str Heb | 11 Str Grk | 12 VerseId | ...
# NB: Str Heb is 10, NOT 11. Column 11 is Str Grk and is empty on every Hebrew
# row — reading it there makes the L2 Strong's check silently pass on everything.
C_HEB_SORT = 0
C_LANGUAGE = 4
C_TRANSLIT = 7
C_STR_HEB = 10
C_VERSE_ID = 12

# The OT is not entirely Hebrew. BSB tags Dan 2:4b–7:28, Ezra 4:8–6:18 / 7:12–26
# and Jer 10:11 as 'Aramaic' (4,826 word rows). Macula stores them under
# language='hbo' alongside Hebrew, so both must be accepted here or those
# passages show up as a phantom coverage gap.
OT_LANGUAGES = ("Hebrew", "Aramaic")

# Characters that mark BSB's alternate (academic) transliteration scheme.
SCHEME_CHARS = set("ʾʿåɛīēōūǝ̄")  # U+0304 = combining macron


def base_num(sid):
    """'H3887a' -> '3887'; 'H3808' -> '3808'; '' -> ''."""
    if not sid:
        return ""
    return "".join(c for c in sid if c.isdigit())


def norm_sep(t):
    """BSB writes syllable breaks with U+00B7 middle dot; xlit_slot uses '-'."""
    return t.replace("·", "-").strip()


def classify_delta(bh, bsb):
    """Why do these two transliterations of the same slot differ?"""
    if bh == bsb:
        return "IDENTICAL"
    if norm_sep(bh) == norm_sep(bsb):
        return "SEPARATOR_ONLY"
    if SCHEME_CHARS & set(bsb):
        return "SCHEME_DIFF"
    # Strip all diacritics from both and compare skeletons.
    def skel(s):
        d = unicodedata.normalize("NFD", s)
        return "".join(c for c in d if not unicodedata.combining(c)).replace("-", "").lower()
    if skel(bh) == skel(bsb):
        return "DIACRITIC_DIFF"
    return "OTHER"


def load_bsb(path):
    """
    -> {(osis, ch, vs_english): [(translit, strongs), ...]} in Hebrew word order.

    Rows are ordered by `Heb Sort` (col 1), which is the original Hebrew word
    order. The file's natural order is BSB *English* order — using it directly
    would silently scramble the slot alignment.
    """
    if not os.path.exists(path):
        sys.exit("✗ %s not found.\n  Download: curl -L -o %s https://bereanbible.com/bsb_tables.tsv"
                 % (path, path))

    raw = defaultdict(list)
    unknown_books = set()
    cur_ref = None

    with open(path, encoding="utf-8-sig") as f:
        reader = csv.reader(f, delimiter="\t")
        next(reader, None)  # header
        for row in reader:
            if len(row) <= C_VERSE_ID:
                continue
            vid = row[C_VERSE_ID].strip()
            if vid:
                cur_ref = vid  # VerseId is set on the verse's first row only
            if cur_ref is None:
                continue
            if row[C_LANGUAGE].strip() not in OT_LANGUAGES:
                continue
            translit = norm_sep(row[C_TRANSLIT])
            if not translit:
                continue

            m = re.match(r"^(.*)\s+(\d+):(\d+)$", cur_ref)
            if not m:
                continue
            book_name, ch, vs = m.group(1), int(m.group(2)), int(m.group(3))
            osis = BSB_BOOK_TO_OSIS.get(book_name)
            if not osis:
                unknown_books.add(book_name)
                continue

            try:
                heb_sort = int(row[C_HEB_SORT])
            except ValueError:
                heb_sort = 10 ** 9

            raw[(osis, ch, vs)].append(
                (heb_sort, translit, row[C_STR_HEB].strip())
            )

    if unknown_books:
        ot = [b for b in unknown_books if b not in ("Matthew", "Mark", "Luke")]
        if ot:
            print("  ⚠  unmapped book names (ignored): %s" % sorted(ot)[:5])

    # Keep heb_sort in the tuple: when several English verses merge onto one MT verse
    # (see bsb_by_macula in main), the concatenated list must be re-sorted into Hebrew
    # order, and heb_sort is the only thing that can do that.
    out = {}
    n_words = n_strongs = 0
    for k, items in raw.items():
        items.sort(key=lambda x: x[0])
        out[k] = items                       # [(heb_sort, translit, strongs), ...]
        n_words += len(items)
        n_strongs += sum(1 for _, _, s in items if s)

    # Sanity gate. If the Strong's column is empty, the L2 per-slot alignment
    # check below compares nothing and reports a perfect 0.00% mismatch — a
    # false pass that looks exactly like a clean result. Refuse to run.
    if n_words and n_strongs == 0:
        sys.exit("✗ Str Heb (col %d) is empty on all %d OT word rows.\n"
                 "  The column indices are wrong for this file — L2 would "
                 "silently pass on every slot.\n"
                 "  Check the header row and fix C_STR_HEB." % (C_STR_HEB, n_words))
    if n_words:
        print("  BSB OT word rows: %d  (Strong's on %.1f%%)"
              % (n_words, 100.0 * n_strongs / n_words))
    return out


def load_verse_map(cur):
    """-> {(book_id, ch, english_verse): macula_verse} from the KJV mapping."""
    vm = {}
    try:
        cur.execute(
            "SELECT book_id, chapter, trans_verse, macula_verse "
            "FROM verse_map WHERE translation = 'KJV'"
        )
    except sqlite3.OperationalError:
        print("  ⚠  no verse_map table — falling back to identity numbering.")
        print("     Run: python3 build_verse_map.py sourcebible.db")
        return vm
    for book_id, ch, tv, mv in cur.fetchall():
        vm[(book_id, ch, tv)] = mv
    return vm


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "sourcebible.db")
    if not os.path.exists(db_path):
        sys.exit("✗ DB not found: %s" % db_path)

    print("=" * 64)
    print("  BSB Hebrew transliteration — ADR-020 fit validation")
    print("=" * 64)
    print("  DB:  %s" % db_path)
    print("  BSB: %s" % BSB_TSV)

    bsb = load_bsb(BSB_TSV)
    print("\n  BSB verses with Hebrew translit: %d" % len(bsb))

    con = sqlite3.connect(db_path)
    cur = con.cursor()

    vmap = load_verse_map(cur)
    print("  verse_map rows (KJV):            %d" % len(vmap))

    # Macula OT verses.
    cur.execute("""
        SELECT DISTINCT book_id, chapter, verse
        FROM word WHERE language = 'hbo'
        ORDER BY book_id, chapter, verse
    """)
    macula_verses = cur.fetchall()
    print("  Macula OT verses:                %d\n" % len(macula_verses))

    # Re-key BSB from English numbering onto Macula numbering, mapping FORWARD through
    # verse_map (which is english -> macula).
    #
    # Do NOT invert verse_map into a macula -> english dict. The relation is many-to-one:
    # several English verses can land on one MT verse (English splits what MT keeps whole).
    # A dict inversion silently keeps whichever key was written last, so we end up comparing
    # a Macula verse against an ARBITRARY member of its English group — the counts then
    # differ for a reason that has nothing to do with BSB. That bug produced 785 phantom
    # COUNT_MISMATCHes, 100% of them on remapped verses, dominated by an off-by-one.
    #
    # Correct: map every BSB English verse forward to its MT verse and concatenate the word
    # lists of all English verses that share an MT target, restoring Hebrew order by Heb Sort.
    bsb_by_macula = defaultdict(list)
    merged_from = defaultdict(list)            # macula ref -> [english verses], for reporting
    for (b, c, ev), words_ in bsb.items():
        mv = vmap.get((b, c, ev), ev)          # identity where no mapping row exists
        bsb_by_macula[(b, c, mv)].extend(words_)
        merged_from[(b, c, mv)].append(ev)
    for k in bsb_by_macula:
        bsb_by_macula[k].sort(key=lambda x: x[0])            # restore Hebrew order
        bsb_by_macula[k] = [(t, s) for _, t, s in bsb_by_macula[k]]

    rows = []          # report rows
    stats = defaultdict(int)
    per_book_gap = defaultdict(int)

    for (book_id, ch, mvs) in macula_verses:
        stats["verses_total"] += 1

        bsb_words = bsb_by_macula.get((book_id, ch, mvs))

        # ── Macula display slots ──
        # Display-slot detection still uses HELPER_STRONGS (a slot of pure glue is not a
        # word). HEAD selection uses head_token() — the rule the app now uses.
        cur.execute("""
            SELECT id, slot, strongs_id, xlit_slot, lexical_class, morph
            FROM word
            WHERE book_id=? AND chapter=? AND verse=? AND language='hbo'
            ORDER BY slot, position
        """, (book_id, ch, mvs))
        tokens = cur.fetchall()
        if not tokens:
            continue

        slot_has_display = {}
        slot_tokens = defaultdict(list)
        for t in tokens:
            slot, sid = t[1], t[2]
            if slot is None:
                continue
            slot_tokens[slot].append(t)
            if slot not in slot_has_display:
                slot_has_display[slot] = False
            if sid not in HELPER_STRONGS:
                slot_has_display[slot] = True

        display_slots = sorted(k for k, v in slot_has_display.items() if v)

        # slot -> (head strongs_id, slot-level xlit_slot)
        # xlit_slot is read from ANY token in the slot that carries it (it is a slot-level
        # value); build_db.py still writes it onto the leading preposition.
        slot_root = {}
        for slot, toks in slot_tokens.items():
            head = head_token(toks)
            existing = next((t[3] for t in toks if t[3]), None)
            slot_root[slot] = (head[2], existing)

        # ── L3: coverage ──
        if not bsb_words:
            stats["verses_no_bsb"] += 1
            per_book_gap[book_id] += 1
            filled = sum(1 for s in display_slots
                         if slot_root.get(s, ("", None))[1])
            stats["slots_lost_no_bsb"] += filled
            rows.append(("NO_BSB_VERSE", "%s %d:%d" % (book_id, ch, mvs), "", "", "",
                         "", "", "macula_slots=%d currently_filled=%d"
                         % (len(display_slots), filled)))
            continue

        # ── L1: per-verse count parity ──
        if len(display_slots) != len(bsb_words):
            stats["verses_count_mismatch"] += 1
            src = merged_from.get((book_id, ch, mvs), [mvs])
            rows.append(("COUNT_MISMATCH", "%s %d:%d" % (book_id, ch, mvs), "", "", "",
                         "", "", "macula_slots=%d bsb_words=%d (from english v%s)"
                         % (len(display_slots), len(bsb_words),
                            "+".join(str(v) for v in sorted(src)))))
            continue

        stats["verses_ok"] += 1

        # ── L2 + L4: per-slot ──
        for i, slot in enumerate(display_slots):
            stats["slots_total"] += 1
            bsb_translit, bsb_strong = bsb_words[i]
            root_sid, existing = slot_root.get(slot, ("", None))

            if root_sid and bsb_strong:
                if base_num(root_sid) != base_num(bsb_strong):
                    stats["slots_strong_mismatch"] += 1
                    rows.append(("STRONG_MISMATCH", "%s %d:%d" % (book_id, ch, mvs),
                                 str(slot), "", root_sid, bsb_translit,
                                 "H" + bsb_strong,
                                 "base %s != %s" % (base_num(root_sid),
                                                    base_num(bsb_strong))))
                    continue

            stats["slots_bsb_ok"] += 1

            if not existing:
                stats["slots_gain"] += 1     # BibleHub left NULL, BSB fills it
                continue

            kind = classify_delta(existing, bsb_translit)
            stats["delta_" + kind.lower()] += 1
            if kind not in ("IDENTICAL", "SEPARATOR_ONLY"):
                rows.append(("DELTA_" + kind, "%s %d:%d" % (book_id, ch, mvs),
                             str(slot), "", root_sid, bsb_translit, "",
                             "biblehub=%s bsb=%s" % (existing, bsb_translit)))

    # ── Report ──
    header = ["type", "ref", "slot", "macula_surf", "macula_strong",
              "bsb_translit", "bsb_strong", "detail"]
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\t".join(header) + "\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")

    vt = stats["verses_total"] or 1
    st = stats["slots_total"] or 1

    def pct(n, d):
        return "%5.2f%%" % (100.0 * n / (d or 1))

    print("─" * 64)
    print("  VERSES")
    print("    total (Macula OT)      %6d" % stats["verses_total"])
    print("    no BSB rows            %6d  %s   ← L3 coverage gap"
          % (stats["verses_no_bsb"], pct(stats["verses_no_bsb"], vt)))
    print("    count mismatch         %6d  %s   ← L1 (skipped, as ADR-020)"
          % (stats["verses_count_mismatch"], pct(stats["verses_count_mismatch"], vt)))
    print("    usable                 %6d  %s"
          % (stats["verses_ok"], pct(stats["verses_ok"], vt)))
    print()
    print("  SLOTS (in usable verses)")
    print("    total                  %6d" % stats["slots_total"])
    print("    Strong's mismatch      %6d  %s   ← L2 (would be NULL)"
          % (stats["slots_strong_mismatch"], pct(stats["slots_strong_mismatch"], st)))
    print("    BSB would fill         %6d  %s"
          % (stats["slots_bsb_ok"], pct(stats["slots_bsb_ok"], st)))
    print("      ├─ gain (was NULL)   %6d" % stats["slots_gain"])
    print("      ├─ identical         %6d" % stats["delta_identical"])
    print("      ├─ separator only    %6d   (cosmetic · vs -)" % stats["delta_separator_only"])
    print("      ├─ diacritic diff    %6d" % stats["delta_diacritic_diff"])
    print("      ├─ scheme diff       %6d   (ʾ ʿ å̄ ī ē ɛ)" % stats["delta_scheme_diff"])
    print("      └─ other             %6d   ← inspect these" % stats["delta_other"])
    print()
    print("    slots lost to no-BSB   %6d   ← REGRESSION if we swap"
          % stats["slots_lost_no_bsb"])
    print()
    if per_book_gap:
        worst = sorted(per_book_gap.items(), key=lambda kv: -kv[1])[:8]
        print("  Coverage gap by book:  " +
              ", ".join("%s=%d" % (b, n) for b, n in worst))
        print()
    print("  Report: %s  (%d rows)" % (REPORT, len(rows)))
    print("─" * 64)
    print("""
  READING THE RESULT
    Swap is safe if:  count mismatch < ~5%, Strong's mismatch < ~2%,
                      'other' deltas ~0, and slots_lost_no_bsb is small
                      (or concentrated in verses where xlit_slot was already NULL).
    Swap is unsafe if: coverage gap is large in real reading books, or
                      'other' deltas are non-trivial — that means BSB's word
                      division disagrees with Macula's slots, not just its spelling.
""")

    con.close()


if __name__ == "__main__":
    main()
