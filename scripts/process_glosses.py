#!/usr/bin/env python3
"""
process_glosses.py — Gloss Synthesizer
Adds/updates word.gloss_display with clean English glosses.

Usage:
    python3 scripts/process_glosses.py sourcebible.db

Run after build_db.py, build_versification.py, import_commentaries.py.
Approx. 1 min for ~600k rows.

Pipeline (Hebrew words only; Greek returned as-is):
    Stage 1  — Untranslatable particles (H853 → "—")
    Stage 2  — Strip square brackets: "[is].the" → "the"
    Stage 3  — Strip dot-subject prefix: "he.created" → "created"
    Stage 4  — Fix construct chain order: "heart your" → "your heart"
    Stage 5  — Normalize remaining dots: "and to.peace" → "and to peace"
    Stage 6  — Proper noun safety net: preserve canonical capitalization
    Stage 7  — Never emit NULL for a non-empty gloss (see below)
    Stage 8  — Sweep stray bracket characters split across tokens (see below)

Stage 7: brackets must not reach the screen (added 2026-08-05)
-------------------------------------------------------------
Returning None for a gloss the pipeline emptied looks harmless and is not:
`DatabaseService.loadWords` reads
`COALESCE(gloss_display, gloss_macula, gloss)`, so a NULL renders the RAW
value with its brackets and dots. Measured on the real database — 1 386 Hebrew
rows, 1 381 of them sharing a slot with a meaningful token, so the reader saw
"[which] creeps", "[the] living", "[people]".

Stage 7 keeps the rule stage 2 already implies: bracketed text is dropped while
something else survives ("[is].the" → "the"); when nothing survives, the bracket
characters come off and the words stay ("[which]" → "which", "I.[am]" → "I am").
If even that is empty the result is "" — never None.

Stage 8: bracket spans split across tokens (added 2026-08-05)
------------------------------------------------------------
Stage 2 matches a balanced `[...]` pair, and Macula splits bracketed spans across
tokens the same way it splits glosses: "[those" on one row and "be]" on another,
"the.[one" here and "who].touches" there. Per row the bracket is unbalanced, so
the regex cannot see it — 2 503 rows reached the screen with half a bracket
(1 198 with a lone "[", 1 305 with a lone "]").

Since the other half lives on a different row there is no span to delete, so the
characters are swept and the words kept: "the.[one" → "the one", "who].touches"
→ "who touches".

Stage 4 also runs ACROSS a display slot (added 2026-08-05)
----------------------------------------------------------
Stages 1-6 work on one row, i.e. one Macula token. Stage 4 was written for the
Hebrew construct chain — "heart your" → "your heart" — but that phrase almost
never sits inside a single token: the noun and its pronominal suffix are two
tokens sharing one `word.slot`, and the app renders a slot as ONE word by joining
the per-token `gloss_display` values with a space
(`VerseTabContent.displayWords`).

Measured on the 24-verse pilot sample: stage 4 could fire inside a token 1 time
in 398, while the cross-token case occurred 31 times in 259 slots. So the stage
was effectively dead in the case it was written for, and Deut 6:4-6 rendered
"God our", "heart your", "being your", "strength your" in all five places.

The slot pass reassigns within a slot: the reordered phrase goes on the head
token and the suffix row is set to EMPTY STRING, so the app's join yields the
phrase once. Empty string, not NULL, is load-bearing — `DatabaseService.loadWords`
reads `COALESCE(w.gloss_display, w.gloss_macula, w.gloss)`, so NULL would fall
back to `gloss_macula` ("your") and render "your heart your".

A suffix row's `gloss_display` therefore no longer describes that row alone. That
is already how Macula's own `gloss` column behaves — it chops a slot-level phrase
across tokens, which is why the suffix token in Ps 51:7 carries "conceived.me"
while the verb carries "she". The unit of an English gloss here is the slot.
"""

import io
import os
import re
import sqlite3
import sys
from typing import Optional, List, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Particles with no English translation — displayed as em dash.
UNTRANSLATABLE = {"H853"}

# ─────────────────────────────────────────────────────────────────────────
# Курований шар (bug-051)
# ─────────────────────────────────────────────────────────────────────────
# Є токени, для яких у Macula глоса НЕМАЄ ЗОВСІМ — порожньо і в TSV `gloss`,
# і в TSV `english`, і в атрибуті `gloss` у lowfat XML. Синтезувати з нічого
# не можна, а залити «найчастішим глосом того самого Strong's» — гірше, ніж
# лишити порожньо: глос контекстний (bug-049), і модальне значення нестабільне
# (H6440 «before» — лише 23% вживань). Тому такі місця курують руками.
#
# Файл має НАЙВИЩИЙ пріоритет: перекриває будь-що, що синтезували стадії 1-8.
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CURATED  = os.path.join(REPO_DIR, "data", "glosses", "curated-glosses.tsv")


def load_curated():
    # type: () -> dict
    """word.id -> (surface, gloss). Порожній dict, якщо файлу немає."""
    out = {}
    if not os.path.exists(CURATED):
        return out
    fh = io.open(CURATED, encoding="utf-8")
    for ln in fh:
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        f = ln.split("\t")
        if len(f) < 3:
            continue
        out[f[0]] = (f[1], f[2])
    fh.close()
    return out


def verify_curated(conn, curated):
    # type: (sqlite3.Connection, dict) -> None
    """Падає, якщо id зник або surface розійшовся.

    Без цієї перевірки перенумерація позицій при перезбірці мовчки поклала б
    курований глос на ЧУЖЕ слово — помилка, яку на екрані не відрізнити від
    правильного результату.
    """
    problems = []
    cur = conn.cursor()
    for wid, (surface, _gloss) in sorted(curated.items()):
        row = cur.execute("SELECT surface FROM word WHERE id = ?", (wid,)).fetchone()
        if row is None:
            problems.append("%s — рядка немає в word" % wid)
        elif row[0] != surface:
            problems.append("%s — у БД «%s», у файлі «%s»" % (wid, row[0], surface))
    if problems:
        sys.stderr.write("\n✗ curated-glosses.tsv розійшовся з базою:\n")
        for x in problems[:20]:
            sys.stderr.write("    " + x + "\n")
        if len(problems) > 20:
            sys.stderr.write("    … ще %d\n" % (len(problems) - 20))
        sys.stderr.write("  Звір позиції перед тим, як писати глоси.\n\n")
        sys.exit(1)

# Subject pronouns Macula prepends to verb glosses with a dot.
# "he.created" → "created"; "and he.said" → "and said"
SUBJECT_PRONOUNS = {"he", "she", "it", "i", "we", "they", "you"}

# Suffix pronouns (possessives) that appear AFTER the noun in Hebrew.
# "heart your" → "your heart"; "God our" → "our God"
SUFFIX_PRONOUNS = {"my", "your", "his", "her", "our", "their", "its"}

# Canonical display form keyed by strongs_id.
# Safety net: ensures proper nouns survive pipeline transformations intact.
PROPER_NOUNS = {
    "H3068": "Yahweh",
    "H3069": "Yahweh",   # ketiv variant
    "H136":  "Lord",     # Adonai
    "H410":  "God",      # El
    "H430":  "God",      # Elohim
    "H3478": "Israel",
    "H1732": "David",
    "H3389": "Jerusalem",
    "H6726": "Zion",
    "H4714": "Egypt",
    "H894":  "Babylon",
    "H53":   "Absalom",
    "H85":   "Abraham",
    "H3327": "Isaac",
    "H3290": "Jacob",
    "H4872": "Moses",
}

# Compiled regex patterns
_RE_BRACKET_DOT = re.compile(r'\[.*?\]\.')   # "[is]."  → ""
_RE_BRACKET     = re.compile(r'\[.*?\]')      # "[is]"   → ""  (trailing dot already gone)
_RE_SUBJ_PREFIX = re.compile(                 # optional "and/or/but " + pronoun + "."
    r'^((?:and|or|but)\s+)?([a-zA-Z]+)\.(.*)',
    re.IGNORECASE
)

# ---------------------------------------------------------------------------
# Stage 7 — brackets must never reach the screen
# ---------------------------------------------------------------------------

def unbracket(raw):
    # type: (Optional[str]) -> str
    """Last resort when stages 1-6 emptied the gloss. Returns "" never None.

    Returning None hands the row to `COALESCE(gloss_display, gloss_macula,
    gloss)` in `DatabaseService.loadWords`, which then renders the RAW value —
    brackets and dots included. Measured on the real database: 1 386 Hebrew rows
    did exactly that, 1 381 of them sharing a slot with a meaningful token, so
    the reader saw "[which] creeps", "[the] living", "[people]".

    The rule is the one stage 2 already implies, stated for the whole string:
    bracketed text is English supplied around a gloss, so it is DROPPED while
    something else survives ("[is].the" → "the"). When nothing survives, the
    bracketed text is the token's only meaning, so the brackets come off and the
    words stay ("[which]" → "which", "I.[am]" → "I am"). Deleting it would blank
    a real word; keeping the brackets shows editorial notation to a reader who
    never asked for it.
    """
    text = (raw or "").replace("[", "").replace("]", "").replace(".", " ")
    return " ".join(text.split())


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def synthesize(
    raw,            # type: Optional[str]
    strongs_id,     # type: Optional[str]
    language        # type: str
):
    # type: (...) -> Optional[str]
    """Return cleaned gloss_display for one word row. None = store NULL."""
    if not raw or not raw.strip():
        return None

    # Greek glosses are already clean — no dot notation or construct chains.
    if language == "G":
        return raw.strip()

    text = raw.strip()

    # Stage 1: untranslatable particles.
    if strongs_id and strongs_id in UNTRANSLATABLE:
        return "—"  # em dash "—"

    # Stage 2: strip square-bracket content.
    # "[is].the" → "the"; "[is].my shepherd" → "my shepherd"
    text = _RE_BRACKET_DOT.sub("", text)   # remove "[...]." first (with trailing dot)
    text = _RE_BRACKET.sub("", text)        # then any remaining "[...]"
    text = text.strip()
    if not text:
        # Whole gloss was bracketed → stage 7, not None. This early return is
        # what kept "[the]" / "[which]" / "[people]" showing raw brackets in the
        # UI even after stage 7 existed: the function left before reaching it.
        return unbracket(raw)

    # Stage 3: strip dot-encoded subject pronoun prefix.
    # "he.created" → "created"; "and he.said" → "and said"; "let.it.be" → unchanged
    m = _RE_SUBJ_PREFIX.match(text)
    if m:
        prefix  = (m.group(1) or "").strip()   # "and" / "or" / "but" / ""
        pronoun = m.group(2).lower()
        rest    = m.group(3)
        if pronoun in SUBJECT_PRONOUNS:
            text = ((prefix + " " + rest).strip()) if prefix else rest

    # Stage 4: fix construct chain word order.
    # "heart your" → "your heart"; "God our" → "our God"
    # Only handles simple case: last token is a suffix pronoun.
    words = text.split()
    if len(words) >= 2 and words[-1].lower() in SUFFIX_PRONOUNS:
        pronoun_word = words[-1]
        noun_parts   = words[:-1]
        text = pronoun_word + " " + " ".join(noun_parts)

    # Stage 5: normalize remaining dots to spaces.
    # "and to.peace" → "and to peace"; "let.it.be" → "let it be"
    text = text.replace(".", " ")
    text = " ".join(text.split())   # collapse multiple spaces

    # Stage 6: proper noun safety net — override with canonical form when
    # the processed gloss matches (case-insensitively) the expected form.
    if strongs_id and strongs_id in PROPER_NOUNS:
        canonical = PROPER_NOUNS[strongs_id]
        parts = text.split()
        if len(parts) == 1:
            text = canonical
        elif parts[-1].lower() == canonical.lower():
            # e.g. "of david" → "of David"
            text = " ".join(parts[:-1]) + " " + canonical

    # Stage 7 — see unbracket() and the module docstring.
    if not text:
        return unbracket(raw)

    # Stage 8: sweep stray bracket characters.
    #
    # Stage 2 only matches a BALANCED pair, and Macula splits bracketed spans
    # across tokens exactly as it splits glosses: "[those" sits on one token and
    # "be]" on another, "the.[one" here and "who].touches" there. Per token the
    # bracket is unbalanced, so `\[.*?\]` cannot see it, and 2 503 rows reached
    # the screen with a half-bracket. Measured on the real database: 1 198 rows
    # carried a lone "[", 1 305 a lone "]".
    #
    # Dropping the characters and keeping the words is the only repair available:
    # the other half of the pair is on a different row, so there is no span to
    # delete. "the.[one" → "the one", "who].touches" → "who touches".
    if "[" in text or "]" in text:
        text = " ".join(text.replace("[", "").replace("]", "").split())
        if not text:
            return ""

    return text


# ---------------------------------------------------------------------------
# Stage 4 across a display slot
# ---------------------------------------------------------------------------

def is_enclitic(morph, lexical_class):
    # type: (Optional[str], Optional[str]) -> bool
    """Mirrors VerseTabContent.isEnclitic."""
    if (lexical_class or "") == "x":
        return True
    return (morph or "").startswith("S")


def head_index(toks):
    # type: (List[Tuple]) -> int
    """Index of the last non-enclitic token — VerseTabContent.headToken."""
    for i in range(len(toks) - 1, -1, -1):
        if not is_enclitic(toks[i][1], toks[i][2]):
            return i
    return len(toks) - 1


def reorder_slot(toks, vals):
    # type: (List[Tuple], List[Optional[str]]) -> List[Optional[str]]
    """Apply the construct-chain reorder across one display slot.

    `toks` is [(row_id, morph, lexical_class), …] in reading order; `vals` the
    already per-token-synthesised glosses. Returns a new list of the same length.

    Fires only when the LAST non-empty gloss in the slot is a suffix pronoun and
    something precedes it — the same condition stage 4 uses inside a token, just
    evaluated over the slot the reader actually sees. Anything else is returned
    untouched, so single-token slots and verb+suffix slots (`he.leads.me`, whose
    tail is not a possessive) behave exactly as before.
    """
    if len(toks) < 2:
        return vals
    idx = [i for i, v in enumerate(vals) if (v or "").strip()]
    if len(idx) < 2:
        return vals

    last = idx[-1]
    tail = (vals[last] or "").strip()
    if tail.lower() not in SUFFIX_PRONOUNS:
        return vals
    # The possessive must actually be carried by a suffix token; a standalone word
    # that merely looks like one is not a construct chain.
    if not is_enclitic(toks[last][1], toks[last][2]):
        return vals

    hi = head_index(toks)
    if hi == last:                       # head IS the possessive — nothing to move
        return vals

    # The possessive goes immediately before the HEAD, not in front of the whole
    # slot. A leading preposition or conjunction keeps its place: "in heart your"
    # must become "in your heart", not "your in heart", and "and pains our" must
    # become "and our pains". Getting this wrong shipped both of those to the
    # screen for one build.
    before = [(vals[i] or "").strip() for i in idx if i < hi]
    after = [(vals[i] or "").strip() for i in idx if hi < i < last]
    head_val = (vals[hi] or "").strip()
    phrase = " ".join([w for w in before if w] + [tail] +
                      ([head_val] if head_val else []) +
                      [w for w in after if w])
    phrase = " ".join(phrase.split())
    if not phrase:
        return vals

    out = list(vals)
    for i in idx:
        out[i] = ""                      # empty string, NOT None — see module docstring
    out[hi] = phrase
    return out


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def add_column_if_missing(conn):
    # type: (sqlite3.Connection) -> None
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(word)")
    cols = [row[1] for row in cur.fetchall()]
    if "gloss_display" not in cols:
        cur.execute("ALTER TABLE word ADD COLUMN gloss_display TEXT")
        conn.commit()
        print("  Added column word.gloss_display")
    else:
        print("  Column word.gloss_display already exists — overwriting values")


def fetch_rows(conn):
    # type: (sqlite3.Connection) -> List[Tuple]
    """Ordered by (book, chapter, verse, position) so tokens of one slot are
    contiguous — the slot pass groups on adjacency, exactly as the view does."""
    cur = conn.cursor()
    cur.execute("""
        SELECT id, gloss_macula, gloss, strongs_id, language,
               book_id, chapter, verse, slot, morph, lexical_class
        FROM   word
        ORDER  BY book_id, chapter, verse, position
    """)
    return cur.fetchall()


def flush_batch(conn, batch):
    # type: (sqlite3.Connection, List[Tuple]) -> None
    conn.executemany(
        "UPDATE word SET gloss_display = ? WHERE id = ?",
        batch
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/process_glosses.py <path/to/sourcebible.db>")
        sys.exit(1)

    db_path = sys.argv[1]
    print("Gloss Synthesizer")
    print("  DB: {}".format(db_path))

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")

    add_column_if_missing(conn)

    curated = load_curated()
    if curated:
        verify_curated(conn, curated)
        print("  Курованих глосів: {} (звірено з surface)".format(len(curated)))

    print("  Fetching word rows...")
    rows = fetch_rows(conn)
    total = len(rows)
    print("  Processing {:,} rows...".format(total))

    BATCH_SIZE = 5000
    batch    = []
    changed  = 0
    reordered = 0

    # Slot accumulator. A slot is a run of adjacent rows sharing
    # (book_id, chapter, verse, slot); NULL slot (Greek) never groups.
    cur_key  = None
    cur_toks = []        # [(row_id, morph, lexical_class), …]
    cur_vals = []        # synthesised gloss per token
    cur_raws = []

    def emit():
        """Apply the slot pass and queue the slot's rows."""
        nonlocal changed, reordered, batch
        if not cur_toks:
            return
        out = reorder_slot(cur_toks, cur_vals)
        if out != cur_vals:
            reordered += 1
        for (rid, _m, _c), val, raw in zip(cur_toks, out, cur_raws):
            batch.append((val, rid))
            if val != raw:
                changed += 1

    for idx, r in enumerate(rows, 1):
        (row_id, gloss_macula, gloss_short, strongs_id, language,
         book_id, chapter, verse, slot, morph, lexical_class) = r
        raw    = gloss_macula or gloss_short
        result = synthesize(raw, strongs_id, language or "")
        # Курований шар — після всіх стадій, перекриває їхній результат.
        if row_id in curated:
            result = curated[row_id][1]

        key = None if slot is None else (book_id, chapter, verse, slot)
        if key is None or key != cur_key:
            emit()
            cur_toks, cur_vals, cur_raws = [], [], []
            cur_key = key
        cur_toks.append((row_id, morph, lexical_class))
        cur_vals.append(result)
        cur_raws.append(raw)
        if key is None:                  # standalone row, nothing to group with
            emit()
            cur_toks, cur_vals, cur_raws = [], [], []

        if len(batch) >= BATCH_SIZE:
            flush_batch(conn, batch)
            batch = []

        if idx % 100000 == 0:
            pct = idx * 100 // total
            print("  {:,}/{:,} ({}%)".format(idx, total, pct))

    emit()
    if batch:
        flush_batch(conn, batch)

    conn.close()
    print("  Done. {:,} rows changed, {:,} slot(s) reordered across tokens."
          .format(changed, reordered))


if __name__ == "__main__":
    main()
