#!/usr/bin/env python3
"""
build_pilot_sample.py — assemble the stratified pilot sample for Ukrainian glosses.

Produces two files:

    data/pilot_sample.tsv   every triple in the sample, with full context
    data/pilot_gold.tsv     a 50-triple subset with an EMPTY uk column

The gold file exists to be filled in BY HAND, BEFORE any model runs. Acceptance
rate measured on model output is circular — a plausible wrong answer is hard to
reject once you have seen it. Comparing model output against glosses written
blind is the only honest accuracy number available, because no Ukrainian
word-level interlinear exists to compare against. That is the thing being built.

Sample: 24 verses over 8 genres — narrative, law, confession, genealogy, poetry,
wisdom, prophecy, narrative dialogue. Genre matters because the failure modes
differ: genealogy is proper nouns, law is formulaic, poetry is where rare words
and figurative sense live. Roughly a quarter of the sample's triples occur two
times or fewer in the whole OT; that tail is where quality will break, and it
must be scored separately from the high-frequency head or the number is
meaningless.

READ-ONLY on every input. Never opens sourcebible.db — the APFS sparse-file rule
in CLAUDE.md applies, and nothing here needs it.

Usage:
    python3 scripts/build_pilot_sample.py
    python3 scripts/build_pilot_sample.py --gold 80
    python3 scripts/build_pilot_sample.py --gold-only          # redraw gold only
    python3 scripts/build_pilot_sample.py --gold-only --force  # ...even over filled uk

--gold-only redraws data/pilot_gold.tsv from the existing data/pilot_sample.tsv.
Every gold triple is by construction already in the sample, so no Macula/BSB/
MyBible input is touched and the sample file is left byte-identical. Both modes
REFUSE to overwrite a gold file that already has hand-written `uk` values unless
--force is given: blind glosses are the one input here that cannot be rebuilt.
"""

import argparse
import csv
import io
import os
import re
import sqlite3
import sys
import tempfile
import zipfile
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data")

MACULA_ZIP = os.path.join(DATA, "macula-hebrew-main.zip")
MACULA_TSV = "macula-hebrew-main/WLC/tsv/macula-hebrew.tsv"
BSB_TSV = os.path.join(DATA, "bsb_tables.tsv")
UBIO_ZIP = os.path.join(DATA, "UBIO'88.zip")
GROMOV_ZIP = os.path.join(DATA, "Gromov.zip")
MAP_TSV = os.path.join(DATA, "org_to_eng.tsv")

OUT_SAMPLE = os.path.join(DATA, "pilot_sample.tsv")     # one row per token
OUT_SLOTS = os.path.join(DATA, "pilot_sample_slots.tsv")  # one row per display word
OUT_GOLD = os.path.join(DATA, "pilot_gold.tsv")         # drawn from OUT_SLOTS

# Independently measured from macula-hebrew.tsv on 2026-08-05 for these 24 verses.
# Hardcoded so a silent change in the grouping rule fails the build instead of
# quietly redefining the unit of work.
EXPECT_TOKENS, EXPECT_SLOTS, EXPECT_SLOT_UNITS = 398, 259, 209

# Reuse the app's own gloss synthesis rather than reimplementing six stages that
# would then drift. process_glosses.py is the single source of truth for what the
# reader sees in `word.gloss_display`.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from process_glosses import synthesize as _synthesize
    from process_glosses import reorder_slot as _reorder_slot
except ImportError:              # pragma: no cover - only if the file moves
    _synthesize = None
    _reorder_slot = None


def synth_gloss(raw, strongs_id):
    """gloss_display for one TOKEN, exactly as process_glosses.py would write it.

    NB the language argument: process_glosses returns Greek glosses untouched on
    `language == "G"`, but build_db.py stores 'hbo'/'grc' in `word.language`, so
    that branch never fires in the real pipeline. This pilot is Hebrew-only, so
    passing "H" is correct here either way — the mismatch is reported separately.
    """
    if _synthesize is None:
        return ""
    return _synthesize(raw, strongs_id, "H") or ""


def slot_display(grp):
    """Per-token gloss_display for one slot, AFTER the cross-token slot pass.
    Mirrors process_glosses.py exactly; the caller space-joins the non-empty
    values, which is what VerseTabContent.displayWords does."""
    vals = [synth_gloss(t["gloss"], t["strong"]) for t in grp]
    if _reorder_slot is None:
        return vals
    toks = [(t["strong"], t["morph"], t["lexical_class"]) for t in grp]
    return _reorder_slot(toks, vals)


def tier_of(f):
    """Frequency tier. Applied to TOKEN frequency on token rows and to SLOT-UNIT
    frequency on slot rows — the thresholds are the same, the unit is not."""
    try:
        f = int(f)
    except (TypeError, ValueError):
        return "tail"
    return "head" if f >= 50 else ("mid" if f > 2 else "tail")


def check_slot_invariants(rows, slot_rows):
    """Fail loudly. A grouping bug here silently redefines the unit of work, and
    every downstream number — coverage, cost, review hours — inherits it."""
    problems = []
    if len(rows) != EXPECT_TOKENS:
        problems.append("tokens: expected %d, got %d" % (EXPECT_TOKENS, len(rows)))
    if len(slot_rows) != EXPECT_SLOTS:
        problems.append("display slots: expected %d, got %d" % (EXPECT_SLOTS, len(slot_rows)))
    units = {(r["strong"], r["morph"], r["gloss_macula"]) for r in slot_rows}
    if len(units) != EXPECT_SLOT_UNITS:
        problems.append("unique slot units: expected %d, got %d"
                        % (EXPECT_SLOT_UNITS, len(units)))

    # Every token belongs to exactly one slot row, and no slot row invents tokens.
    tok_slots = Counter((r["osis"], r["chapter"], r["verse"], r["slot"]) for r in rows)
    for sr in slot_rows:
        k = (sr["osis"], sr["chapter"], sr["verse"], sr["slot"])
        if tok_slots.get(k) != sr["n_tokens"]:
            problems.append("slot %s: %d tokens in token file, n_tokens=%s"
                            % (k, tok_slots.get(k, 0), sr["n_tokens"]))
    if len(tok_slots) != len(slot_rows):
        problems.append("distinct slots in token file %d != slot rows %d"
                        % (len(tok_slots), len(slot_rows)))

    # pos_in_slot must be 1..n within each slot, no gaps, no repeats.
    per = defaultdict(list)
    for r in rows:
        per[(r["osis"], r["chapter"], r["verse"], r["slot"])].append(r["pos_in_slot"])
    for k, v in per.items():
        if sorted(v) != list(range(1, len(v) + 1)):
            problems.append("slot %s: pos_in_slot %s" % (k, sorted(v)))

    # pos_in_verse must be 1..n across the verse, monotone with slot order.
    perv = defaultdict(list)
    for r in rows:
        perv[(r["osis"], r["chapter"], r["verse"])].append(r["pos_in_verse"])
    for k, v in perv.items():
        if sorted(v) != list(range(1, len(v) + 1)):
            problems.append("verse %s: pos_in_verse not 1..n" % (k,))

    if problems:
        sys.exit("SLOT INVARIANTS FAILED:\n  - " + "\n  - ".join(problems))
    print("  ✓ slot invariants: %d tokens → %d slots → %d unique units"
          % (len(rows), len(slot_rows), len(units)))

# 3 verses × 8 genres. Refs are MASORETIC (Macula) numbering.
SAMPLE = {
    "GEN": ("наратив",          [(22, 1), (22, 2), (22, 3)]),
    "LEV": ("закон",            [(19, 17), (19, 18), (19, 19)]),
    "DEU": ("закон/сповідь",    [(6, 4), (6, 5), (6, 6)]),
    "1CH": ("генеалогія",       [(1, 1), (1, 2), (1, 3)]),
    "PSA": ("поезія",           [(23, 1), (23, 2), (23, 3)]),
    "PRO": ("мудрість",         [(3, 5), (3, 6), (3, 7)]),
    "ISA": ("пророцтво",        [(53, 4), (53, 5), (53, 6)]),
    "JON": ("наратив+діалог",   [(1, 1), (1, 2), (1, 3)]),
}

# MyBible book_number. Verified against each file's `books` table at run time —
# a hardcoded table that silently disagrees with the file is exactly the class
# of bug that cost this project a day on 2026-08-04.
MYBIBLE_NUM = {"GEN": 10, "LEV": 30, "DEU": 50, "1CH": 130,
               "PSA": 230, "PRO": 240, "ISA": 290, "JON": 390}

# The comment above promised verification and there was none, so JON sat at 370 —
# which is AMOS. Every Ukrainian verse shown for Jonah was Amos: the reviewer got
# Amos 1:1 under Jonah 1:1 and spent minutes trying to reconcile them before
# writing "no idea" and moving on. 7 of 60 gold rows were lost that way.
#
# Stems below are taken from the `books` tables of both modules, not from memory:
#   390 → Огієнко "Йона", Громов "ІОНИ"       370 → "Амос" / "АМОСА"
# Matching is on a lowercase stem so the two modules' different name forms
# (1-а хронiки / 1 ХРОНІК, Псалми / КНИГА ПСАЛМІВ) both pass.
MYBIBLE_STEM = {"GEN": ("бутт",), "LEV": ("левит",), "DEU": ("повторення",),
                "1CH": ("хронi", "хронік"), "PSA": ("псалм",),
                "PRO": ("приповi", "притч"), "ISA": ("іса", "исa", "иса"),
                "JON": ("йон", "іон", "ион")}


def base_num(sid):
    d = "".join(c for c in sid if c.isdigit())
    return d.lstrip("0") or "0"


# ─── Macula ───────────────────────────────────────────────────────────────────

def load_macula(wanted):
    """-> (rows_by_verse, token_triple_freq, slot_unit_freq, masoretic_psalm_verse_counts)

    The `ref` field is `PSA 51:7!5`; `!5` is the DISPLAY SLOT. Several tokens can
    share one slot and the app renders them as ONE word
    (`VerseTabContent.displayWords`). The first version of this script matched
    `^(\\S+)\\s+(\\d+):(\\d+)` and threw `!N` away, so the sample could not express
    a display word at all and every count here measured tokens instead of what is
    on screen. Both frequencies are now built in the same pass, so the two units
    can be compared on numbers instead of argued about.
    """
    by_verse = defaultdict(list)
    freq = Counter()             # (strong, morph, gloss) per TOKEN
    slot_freq = Counter()        # slot unit: ((strong, morph)…, joined gloss)
    psalm_verses = defaultdict(set)
    ref_re = re.compile(r"^(\S+)\s+(\d+):(\d+)(?:!(\d+))?")

    cur_slot = None              # (osis, ch, vs, slot) currently being accumulated
    cur_toks = []

    def flush(toks):
        if toks:
            slot_freq[slot_unit_key(toks)] += 1

    with zipfile.ZipFile(MACULA_ZIP) as z:
        with z.open(MACULA_TSV) as f:
            for r in csv.DictReader(io.TextIOWrapper(f, "utf-8"), delimiter="\t"):
                sid = (r.get("strongnumberx") or "").strip()
                gloss = (r.get("gloss") or "").strip()
                if not sid or not gloss:
                    continue
                morph = (r.get("morph") or "").strip()
                freq[(sid, morph, gloss)] += 1
                m = ref_re.match((r.get("ref") or "").strip())
                if not m:
                    continue
                key = (m.group(1).upper(), int(m.group(2)), int(m.group(3)))
                slot = int(m.group(4)) if m.group(4) else 1
                if key[0] == "PSA":
                    psalm_verses[key[1]].add(key[2])

                tok = {
                    "surface": (r.get("text") or "").strip(),
                    "xlit": (r.get("transliteration") or "").strip(),
                    "lemma": (r.get("stronglemma") or "").strip(),
                    "strong": sid, "morph": morph, "pos": (r.get("pos") or "").strip(),
                    "gloss": gloss,
                    "english": (r.get("english") or "").strip(),
                    "lexical_class": (r.get("class") or "").strip(),
                    "after": (r.get("after") or "").strip(),
                    "slot": slot,
                }

                ident = key + (slot,)
                if ident != cur_slot:
                    flush(cur_toks)
                    cur_slot, cur_toks = ident, []
                cur_toks.append(tok)

                if key in wanted:
                    by_verse[key].append(tok)
    flush(cur_toks)
    return by_verse, freq, slot_freq, {c: len(v) for c, v in psalm_verses.items()}


# ─── display slots ───────────────────────────────────────────────────────────
#
# Mirrors VerseTabContent.displayWords / headToken. Any change here must be made
# there too, and the other way round: if the two drift, the pilot measures a unit
# the reader never sees. That is the whole reason this file was reworked.

def is_enclitic(tok):
    """Matches VerseTabContent.isEnclitic: enclitic particle, or pronominal suffix."""
    return tok["lexical_class"] == "x" or tok["morph"].startswith("S")


def head_token(toks):
    """Last non-enclitic token. NOT the first non-helper — that older rule picked
    the leading preposition and was wrong on ~8.5% of Hebrew words (ADR-020)."""
    for t in reversed(toks):
        if not is_enclitic(t):
            return t
    return toks[-1]


def slot_unit_key(toks):
    """Identity of a display word, for frequency and for the gold draw."""
    return (tuple((t["strong"], t["morph"]) for t in toks),
            ".".join(t["gloss"] for t in toks))


def group_slots(toks):
    """-> [[tok, …], …] consecutive tokens sharing a slot, in reading order."""
    groups, cur, cur_slot = [], [], None
    for t in toks:
        if t["slot"] != cur_slot:
            if cur:
                groups.append(cur)
            cur, cur_slot = [t], t["slot"]
        else:
            cur.append(t)
    if cur:
        groups.append(cur)
    return groups


# ─── BSB phrase gloss ─────────────────────────────────────────────────────────

def load_bsb(eng_refs):
    """
    -> {(osis, eng_ch, eng_vs): {strong_base: phrase}}

    BSB assigns whole translation phrases to Hebrew slots and stores rows in
    ENGLISH reading order, so it is not a second morpheme-level opinion — it is
    a check on whether the phrase reads sensibly. Keyed by Strong's, which is
    order-independent.
    """
    names = {"GEN": "Genesis", "LEV": "Leviticus", "DEU": "Deuteronomy",
             "1CH": "1 Chronicles", "PSA": "Psalm", "PRO": "Proverbs",
             "ISA": "Isaiah", "JON": "Jonah"}
    inv = {v: k for k, v in names.items()}
    want = {(names[o], c, v) for (o, c, v) in eng_refs}
    out = defaultdict(dict)
    csv.field_size_limit(10 ** 7)
    vid_re = re.compile(r"^(.*?)\s+(\d+):(\d+)\s*$")
    cur = None
    with open(BSB_TSV, encoding="utf-8", errors="replace", newline="") as f:
        rd = csv.reader(f, delimiter="\t")
        next(rd, None)
        for row in rd:
            if len(row) <= 18:
                continue
            vid = (row[12] or "").strip()
            if vid:
                m = vid_re.match(vid)
                cur = (m.group(1).strip(), int(m.group(2)), int(m.group(3))) if m else None
            if cur not in want or (row[4] or "").strip() != "Hebrew":
                continue
            g = (row[18] or "").strip()
            s = base_num((row[10] or "").strip())
            if g and s and g != "-":
                out[(inv[cur[0]], cur[1], cur[2])].setdefault(s, g)
    return out


# ─── MyBible translations (Огієнко, Громов) ───────────────────────────────────

def load_mybible(zip_path, label):
    """
    -> (verses_dict, numbering_note)
       verses_dict[(book_number, chapter, verse)] = text

    Numbering is NOT assumed. The file's own `info` table is read for
    `russian_numbering`, and the value is reported so the caller can decide.
    Psalms is where this bites: Огієнко follows Synodal numbering, so MT 23 is
    its 22. Guessing here would rebuild bug-033 one layer up.
    """
    tmp = tempfile.mkdtemp()
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(tmp)
    db = None
    for root, _d, files in os.walk(tmp):
        for fn in files:
            if fn.endswith(".SQLite3") and not any(
                    k in fn.lower() for k in ("commentar", "dictionar", "crossref")):
                db = os.path.join(root, fn)
    if not db:
        return {}, "%s: SQLite3 not found" % label
    con = sqlite3.connect(db)
    note = "%s: " % label
    try:
        info = dict(con.execute("SELECT name, value FROM info"))
        note += "russian_numbering=%s" % info.get("russian_numbering", "(not set)")
    except Exception as e:
        note += "info unreadable (%s)" % e
    verify_mybible_numbers(con, label)
    verses = {}
    for b, c, v, t in con.execute("SELECT book_number, chapter, verse, text FROM verses"):
        verses[(b, c, v)] = re.sub(r"<[^>]+>", "", t or "").strip()
    return verses, note


def verify_mybible_numbers(con, label):
    """Check MYBIBLE_NUM against the file's own `books` table. Exit non-zero on
    any disagreement.

    This is the check the comment on MYBIBLE_NUM claimed to perform and did not.
    Its absence put Amos under Jonah in every Ukrainian column of the sample, and
    nothing failed — the reviewer found it by reading the verses. A hardcoded
    table that silently disagrees with the file is the same class of bug as
    bug-033, and it now costs a build instead of an afternoon.
    """
    try:
        names = dict(con.execute("SELECT book_number, long_name FROM books"))
    except Exception as e:
        sys.exit("%s: cannot read `books` table (%s) — refusing to trust "
                 "MYBIBLE_NUM unverified" % (label, e))

    problems = []
    for osis, bn in sorted(MYBIBLE_NUM.items()):
        got = (names.get(bn) or "").strip()
        if not got:
            problems.append("%s → %d: no such book in this module" % (osis, bn))
            continue
        stems = MYBIBLE_STEM.get(osis, ())
        if not any(s in got.lower() for s in stems):
            near = ", ".join("%d=%r" % (n, names[n]) for n in sorted(names)
                            if any(s in (names[n] or "").lower() for s in stems))
            problems.append("%s → %d is %r, expected a name containing %s%s"
                            % (osis, bn, got, " or ".join(stems),
                               ("; found at " + near) if near else ""))
    if problems:
        sys.exit("%s: MYBIBLE_NUM disagrees with the module's own `books` "
                 "table:\n  - %s" % (label, "\n  - ".join(problems)))


def resolve_psalm_offset(verses, book_num, mt_counts):
    """
    Work out, per Masoretic psalm, which chapter of a Ukrainian Psalter holds it.

    -> {mt_chapter: uk_chapter}

    Ukrainian Bibles follow Synodal/LXX psalm numbering, which runs one behind
    the Masoretic over most of the Psalter. The file's own `russian_numbering`
    flag cannot be trusted: Огієнко sets it, Громов does not, and both are in
    fact Synodal. Metadata that disagrees with the data is exactly what ADR-028
    documented for the UBS reference.

    So the offset is measured, not declared. Psalm verse counts are distinctive,
    so for each Masoretic psalm the candidate Ukrainian chapters (n, n-1) are
    compared on verse count and the match is taken. Where neither matches the
    psalm is left unresolved rather than guessed — a wrong psalm is worse than a
    blank cell, and this is precisely the failure that produced bug-033.
    """
    uk_counts = Counter()
    for (b, c, _v) in verses:
        if b == book_num:
            uk_counts[c] += 1
    out = {}
    for mt_ch, mt_n in mt_counts.items():
        for cand in (mt_ch - 1, mt_ch):          # Synodal first: it is the norm
            if uk_counts.get(cand) == mt_n:
                out[mt_ch] = cand
                break
    return out


def pick_verse(verses, book_num, ch, vs, psalm_map):
    """
    -> (text, numbering_label)

    The label travels with the row so a reader of the TSV can see which chapter
    the Ukrainian text actually came from instead of trusting that it lines up.
    """
    if book_num == 230:
        uk_ch = psalm_map.get(ch)
        if uk_ch is None:
            return "", "UNRESOLVED"
        t = verses.get((book_num, uk_ch, vs), "")
        return t, ("direct" if uk_ch == ch else "synodal(%d→%d)" % (ch, uk_ch))
    return verses.get((book_num, ch, vs), ""), "direct"


# ─── Main ─────────────────────────────────────────────────────────────────────

# ─── gold subset ──────────────────────────────────────────────────────────────
#
# Deliberately NOT proportional to the corpus. The head sits near the ceiling and
# needs only a "not broken" check; the tail is where quality breaks and where the
# number has to survive being quoted. Precision goes where the uncertainty is.
TIER_SHARE = (("head", 0.24), ("mid", 0.33), ("tail", 0.43))

# No single book may carry more than this share of the gold set. The first
# version had no such bound: its stratified pass had a ceiling of 3 tiers x 8
# books = 24 picks, and the `while len(gold) < args.gold` top-up filled the
# remaining 28 of 50 straight off the top of `rows` — which start at 1CH and DEU.
# Result was DEU 23 + 1CH 9 out of 50, and tail = 8.
MAX_BOOK_SHARE = 0.20


class GoldError(Exception):
    """Selection could not meet the stated invariants. Never downgrade this to a
    warning: a gold set that quietly stops being stratified still produces a
    number, and the number gets quoted."""


def triple_of(r):
    return (r["strong"], r["morph"], r["gloss_macula"])


def first_by_triple(rows):
    """Unique triples, first occurrence wins. Deterministic — `rows` is in file
    order (book, chapter, verse, position), so no RNG and no seed to remember."""
    out = {}
    for r in rows:
        out.setdefault(triple_of(r), r)
    return out


def tier_quotas(n, supply):
    """Split n across tiers by TIER_SHARE, clamped to what the sample actually
    holds, remainder pushed to tiers that still have room.
    -> (quotas dict, notes list). Notes name every clamp out loud."""
    quotas, notes = {}, []
    for tier, share in TIER_SHARE:
        quotas[tier] = min(int(round(n * share)), supply.get(tier, 0))
    guard = 0
    while sum(quotas.values()) != n and guard < 10000:
        guard += 1
        short = n - sum(quotas.values())
        if short > 0:
            room = [t for t, _s in TIER_SHARE if supply.get(t, 0) > quotas[t]]
            step = 1
        else:
            room = [t for t, _s in TIER_SHARE if quotas[t] > 0]
            step = -1
        if not room:
            break
        for t in room:
            if sum(quotas.values()) == n:
                break
            quotas[t] += step
    for tier, share in TIER_SHARE:
        want = int(round(n * share))
        if quotas[tier] != want:
            notes.append("%s: policy asked %d, sample supplies %d"
                         % (tier, want, quotas[tier]))
    return quotas, notes


def check_gold(gold, rows, n=None, quotas=None):
    """Raise GoldError, with numbers, on any violation. Pure — no I/O, so a test
    can point it at any candidate selection, including the old algorithm's."""
    problems = []
    sample_triples = {triple_of(r) for r in rows}
    gold_triples = [triple_of(r) for r in gold]

    if n is not None and len(gold) != n:
        problems.append("size: asked %d, got %d" % (n, len(gold)))

    dupes = [t for t, c in Counter(gold_triples).items() if c > 1]
    if dupes:
        problems.append("duplicate triples: %d (%s…)" % (len(dupes), dupes[:3]))

    outside = [t for t in gold_triples if t not in sample_triples]
    if outside:
        problems.append("triples absent from the sample: %d" % len(outside))

    filled = [r for r in gold if (r.get("uk") or "").strip()]
    if filled:
        problems.append("`uk` must ship empty, %d rows carry a value" % len(filled))

    if gold:
        books = Counter(r["osis"] for r in gold)
        cap = max(1, int(MAX_BOOK_SHARE * len(gold)))
        over = [(b, c) for b, c in books.most_common() if c > cap]
        if over:
            problems.append("book share > %.0f%% (cap %d of %d): %s"
                            % (MAX_BOOK_SHARE * 100, cap, len(gold),
                               ", ".join("%s=%d" % (b, c) for b, c in over)))

    if quotas is not None:
        got = Counter(r["tier"] for r in gold)
        for tier, want in sorted(quotas.items()):
            if got[tier] != want:
                problems.append("tier %s: quota %d, got %d" % (tier, want, got[tier]))
        # Every (book, tier) cell that HAS supply must be represented, whenever
        # the quota is large enough to go round once. 1CH legitimately has no
        # head and no tail triples — absence there is data, not a bug.
        uniq = first_by_triple(rows)
        cells = defaultdict(list)
        for r in uniq.values():
            cells[(r["tier"], r["osis"])].append(r)
        present = {(r["tier"], r["osis"]) for r in gold}
        for tier, want in sorted(quotas.items()):
            tier_books = sorted({o for (t, o) in cells if t == tier})
            if want >= len(tier_books):
                missing = [b for b in tier_books if (tier, b) not in present]
                if missing:
                    problems.append("tier %s: quota %d covers %d books but misses %s"
                                    % (tier, want, len(tier_books), ", ".join(missing)))

    if problems:
        raise GoldError("gold selection failed %d invariant(s):\n  - %s"
                        % (len(problems), "\n  - ".join(problems)))


def pick_gold(rows, n):
    """-> (gold rows, report lines). Round-robin over books inside each tier, so
    no single book can dominate and no unstratified top-up pass exists."""
    uniq = first_by_triple(rows)
    cells = defaultdict(list)
    for r in uniq.values():
        cells[(r["tier"], r["osis"])].append(r)

    supply = Counter()
    for (tier, _osis), v in cells.items():
        supply[tier] += len(v)

    quotas, notes = tier_quotas(n, supply)
    if sum(quotas.values()) != n:
        raise GoldError("sample holds %d unique triples, cannot draw %d "
                        "(head/mid/tail supply = %d/%d/%d)"
                        % (len(uniq), n, supply["head"], supply["mid"], supply["tail"]))

    gold = []
    for tier, _share in TIER_SHARE:
        books = sorted({o for (t, o) in cells if t == tier})
        cursor = dict((b, 0) for b in books)
        picked, progress = 0, True
        while picked < quotas[tier] and progress:
            progress = False
            for b in books:
                if picked >= quotas[tier]:
                    break
                bucket = cells[(tier, b)]
                if cursor[b] < len(bucket):
                    gold.append(bucket[cursor[b]])
                    cursor[b] += 1
                    picked += 1
                    progress = True
        if picked < quotas[tier]:
            raise GoldError("tier %s: quota %d, only %d triples available"
                            % (tier, quotas[tier], picked))

    check_gold(gold, rows, n, quotas)

    report = ["  quotas          : " + " / ".join(
        "%s %d" % (t, quotas[t]) for t, _s in TIER_SHARE)]
    for note in notes:
        report.append("  ! clamped        : " + note)
    books = Counter(r["osis"] for r in gold)
    report.append("  book mix        : " + ", ".join(
        "%s=%d" % (b, c) for b, c in sorted(books.items())))
    report.append("  max book share  : %.0f%% (cap %.0f%%)"
                  % (100.0 * max(books.values()) / len(gold), MAX_BOOK_SHARE * 100))
    report.append("  cells (book x tier), triples available vs drawn:")
    drawn = Counter((r["tier"], r["osis"]) for r in gold)
    report.append("    %-5s %8s %8s %8s" % ("book", "head", "mid", "tail"))
    for b in sorted({o for (_t, o) in cells}):
        cols = []
        for t, _s in TIER_SHARE:
            cols.append("%d/%d" % (drawn[(t, b)], len(cells[(t, b)])))
        report.append("    %-5s %8s %8s %8s" % (b, cols[0], cols[1], cols[2]))
    return gold, report


def read_tsv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def filled_uk(path):
    """How many hand-written glosses the existing gold file already holds."""
    if not os.path.exists(path):
        return 0
    return sum(1 for r in read_tsv(path) if (r.get("uk") or "").strip())


def guard_gold_overwrite(force):
    n = filled_uk(OUT_GOLD)
    if n and not force:
        sys.exit("REFUSING to overwrite %s — it already holds %d hand-written "
                 "`uk` value(s), and blind glosses cannot be rebuilt.\n"
                 "Copy the file aside first, then pass --force." % (OUT_GOLD, n))


def write_gold(gold, cols):
    with open(OUT_GOLD, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(gold)


# Token level: one row per Macula token. Source of truth, keeps `slot` so the
# display grouping can be re-derived or checked.
COLS = ["osis", "genre", "chapter", "verse", "pos_in_verse",
        "slot", "pos_in_slot",
        "surface", "xlit", "lemma", "strong", "morph", "pos", "lexical_class",
        "gloss_macula", "gloss_en", "gloss_display", "gloss_bsb",
        "freq_ot", "freq_slot_ot", "tier",
        "uk_ohienko_verse", "uk_ohienko_numbering",
        "uk_gromov_verse", "uk_gromov_numbering", "uk"]

# Slot level: one row per DISPLAY WORD — the unit the reader actually sees and
# the unit the gold set is drawn from. `strong`/`morph`/`gloss_macula` hold the
# COMBINED values, so they are the unit's identity; `head_*` carry the app's
# head-token fields (tap target, transliteration).
SLOT_COLS = ["osis", "genre", "chapter", "verse", "slot", "n_tokens",
             "surface", "xlit", "strong", "morph", "gloss_macula",
             "gloss_en", "gloss_display", "gloss_bsb",
             "head_strong", "head_morph", "head_lemma", "head_pos",
             "freq_slot_ot", "tier",
             "uk_ohienko_verse", "uk_ohienko_numbering",
             "uk_gromov_verse", "uk_gromov_numbering", "uk"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", type=int, default=60)
    ap.add_argument("--gold-only", action="store_true",
                    help="redraw data/pilot_gold.tsv from the existing "
                         "pilot_sample.tsv; no other input is read or written")
    ap.add_argument("--force", action="store_true",
                    help="allow overwriting a gold file with hand-written uk values")
    args = ap.parse_args()

    if args.gold_only:
        if not os.path.exists(OUT_SLOTS):
            sys.exit("missing input: %s (run without --gold-only first)" % OUT_SLOTS)
        guard_gold_overwrite(args.force)
        rows = read_tsv(OUT_SLOTS)
        gold, report = pick_gold(rows, args.gold)
        write_gold(gold, SLOT_COLS)
        print("─── gold redrawn from %s ───" % OUT_SLOTS)
        print("  sample rows     : %d (%d unique triples)"
              % (len(rows), len(first_by_triple(rows))))
        for line in report:
            print(line)
        print("\n  %s  (%d rows — FILL THE `uk` COLUMN BY HAND, BEFORE running "
              "any model)" % (OUT_GOLD, len(gold)))
        return

    guard_gold_overwrite(args.force)

    for p in (MACULA_ZIP, BSB_TSV):
        if not os.path.exists(p):
            sys.exit("missing input: %s" % p)

    wanted = {(b, c, v) for b, (_g, vs) in SAMPLE.items() for (c, v) in vs}
    print("Loading Macula…")
    by_verse, freq, slot_freq, mt_psalm_counts = load_macula(wanted)

    # ORG -> ENG for the BSB lookup, using the map built for bug-033.
    org2eng = {}
    if os.path.exists(MAP_TSV):
        for d in csv.DictReader(open(MAP_TSV, encoding="utf-8"), delimiter="\t"):
            if d["seg"] == "0":
                org2eng[(d["osis"], int(d["org_chapter"]), int(d["org_verse"]))] = (
                    d["osis"], int(d["eng_chapter"]), int(d["eng_verse"]))
    else:
        print("  ! org_to_eng.tsv missing — BSB lookup falls back to identity refs")
    eng_refs = {org2eng.get(k, k) for k in wanted}

    print("Loading BSB…")
    bsb = load_bsb(eng_refs)

    print("Loading Ukrainian translations…")
    ubio, n1 = load_mybible(UBIO_ZIP, "Огієнко") if os.path.exists(UBIO_ZIP) else ({}, "Огієнко: absent")
    grm, n2 = load_mybible(GROMOV_ZIP, "Громов") if os.path.exists(GROMOV_ZIP) else ({}, "Громов: absent")
    print("   " + n1)
    print("   " + n2)

    # Measured, not declared. See resolve_psalm_offset().
    ps_ubio = resolve_psalm_offset(ubio, 230, mt_psalm_counts)
    ps_grm = resolve_psalm_offset(grm, 230, mt_psalm_counts)
    for lab, pm in (("Огієнко", ps_ubio), ("Громов", ps_grm)):
        shown = [(c, pm.get(c)) for (b, (_g, vv)) in SAMPLE.items() if b == "PSA"
                 for (c, _v) in vv]
        uniq = sorted(set(shown))
        print("   %s Псалми: %s  (розвʼязано %d/%d глав)"
              % (lab, ", ".join("МТ%d→%s" % (c, u if u else "?") for c, u in uniq),
                 len(pm), len(mt_psalm_counts)))

    rows, slot_rows = [], []
    for osis, (genre, verses) in sorted(SAMPLE.items()):
        bn = MYBIBLE_NUM[osis]
        for (ch, vs) in verses:
            key = (osis, ch, vs)
            eng = org2eng.get(key, key)
            oh, ohn = pick_verse(ubio, bn, ch, vs, ps_ubio)
            gr, grn = pick_verse(grm, bn, ch, vs, ps_grm)
            toks = by_verse.get(key, [])
            uk_ctx = {"uk_ohienko_verse": oh, "uk_ohienko_numbering": ohn,
                      "uk_gromov_verse": gr, "uk_gromov_numbering": grn, "uk": ""}

            # Group first, then emit both levels from the same grouping — so the
            # two files cannot disagree about where a display word begins.
            pos = 0
            for grp in group_slots(toks):
                sf = slot_freq[slot_unit_key(grp)]

                # ── token level ──
                for j, w in enumerate(grp, 1):
                    pos += 1
                    f = freq[(w["strong"], w["morph"], w["gloss"])]
                    r = {
                        "osis": osis, "genre": genre, "chapter": ch, "verse": vs,
                        "pos_in_verse": pos, "slot": w["slot"], "pos_in_slot": j,
                        "surface": w["surface"], "xlit": w["xlit"], "lemma": w["lemma"],
                        "strong": w["strong"], "morph": w["morph"], "pos": w["pos"],
                        "lexical_class": w["lexical_class"],
                        "gloss_macula": w["gloss"], "gloss_en": w["english"],
                        "gloss_display": synth_gloss(w["gloss"], w["strong"]),
                        "gloss_bsb": bsb.get(eng, {}).get(base_num(w["strong"]), ""),
                        "freq_ot": f, "freq_slot_ot": sf, "tier": tier_of(f),
                    }
                    r.update(uk_ctx)
                    rows.append(r)

                # ── slot level: the unit actually rendered ──
                head = head_token(grp)
                sr = {
                    "osis": osis, "genre": genre, "chapter": ch, "verse": vs,
                    "slot": grp[0]["slot"], "n_tokens": len(grp),
                    # displayText join: surface + after_char, exactly like the view
                    "surface": "".join(t["surface"] + t["after"] for t in grp),
                    "xlit": head["xlit"],
                    "strong": "+".join(t["strong"] for t in grp),
                    "morph": "·".join(t["morph"] for t in grp if t["morph"]),
                    "gloss_macula": ".".join(t["gloss"] for t in grp),
                    "gloss_en": " ".join(t["english"] for t in grp if t["english"]),
                    # Per-token synthesis, then the SLOT pass, then space-join —
                    # the same three steps, in the same order, that
                    # process_glosses.py + VerseTabContent.displayWords perform.
                    # Without the slot pass this column showed "God our" while the
                    # app showed "our God", i.e. the pilot measured a gloss the
                    # reader never sees.
                    "gloss_display": " ".join(g for g in slot_display(grp) if g),
                    "gloss_bsb": bsb.get(eng, {}).get(base_num(head["strong"]), ""),
                    "head_strong": head["strong"], "head_morph": head["morph"],
                    "head_lemma": head["lemma"], "head_pos": head["pos"],
                    "freq_slot_ot": sf, "tier": tier_of(sf),
                }
                sr.update(uk_ctx)
                slot_rows.append(sr)

    with open(OUT_SAMPLE, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(OUT_SLOTS, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SLOT_COLS, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(slot_rows)

    check_slot_invariants(rows, slot_rows)

    # Gold is drawn from SLOT rows: that is the unit on screen and the unit a
    # reviewer edits. Drawing it from token rows would hand-score half a word.
    gold, gold_report = pick_gold(slot_rows, args.gold)
    write_gold(gold, SLOT_COLS)

    triples = {(r["strong"], r["morph"], r["gloss_macula"]) for r in rows}
    units = {(r["strong"], r["morph"], r["gloss_macula"]) for r in slot_rows}
    tiers = Counter(r["tier"] for r in slot_rows)
    print("\n─── sample ───")
    print("  verses          : %d" % len(wanted))
    print("  tokens          : %d" % len(rows))
    print("  display slots   : %d  (%.2f tokens/slot)"
          % (len(slot_rows), float(len(rows)) / max(1, len(slot_rows))))
    print("  unique triples  : %d  (token unit — for comparison only)" % len(triples))
    print("  unique SLOT units: %d  ← the unit of work" % len(units))
    print("  head/mid/tail   : %d / %d / %d  (over slots)"
          % (tiers["head"], tiers["mid"], tiers["tail"]))
    print("  BSB gloss filled: %d/%d" % (sum(1 for r in rows if r["gloss_bsb"]), len(rows)))
    print("  Огієнко filled  : %d/%d verses"
          % (len({(r['osis'], r['chapter'], r['verse']) for r in rows if r['uk_ohienko_verse']}), len(wanted)))
    print("  Громов filled   : %d/%d verses"
          % (len({(r['osis'], r['chapter'], r['verse']) for r in rows if r['uk_gromov_verse']}), len(wanted)))
    print("\n─── gold ───")
    for line in gold_report:
        print(line)

    print("\n  %s  (%d rows)" % (OUT_SAMPLE, len(rows)))
    print("  %s  (%d rows — FILL THE `uk` COLUMN BY HAND, BEFORE running any model)"
          % (OUT_GOLD, len(gold)))


if __name__ == "__main__":
    main()
