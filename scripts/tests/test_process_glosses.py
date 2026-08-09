#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Invariants for the slot pass in scripts/process_glosses.py.

What broke
----------
Stage 4 of the gloss pipeline fixes Hebrew construct-chain order — "heart your"
→ "your heart". It ran per row, i.e. per Macula token, but the phrase it targets
spans a display SLOT: the noun and its pronominal suffix are two tokens with the
same `word.slot`, and the app joins their `gloss_display` with a space
(`VerseTabContent.displayWords`).

Measured on the real 24-verse sample: the intra-token case occurs 1 time in 398
tokens, the cross-token case 31 times in 259 slots. Deut 6:4-6 rendered "God
our", "heart your", "being your", "strength your" in all five places.

`test_shema_reorders` and `test_verb_plus_suffix_is_left_alone` are the pair that
matters: the first fails on the pre-fix code, the second fails on an over-eager
fix that reorders every slot ending in a suffix token.

Data
----
fixtures/pilot_tokens_slice.tsv — verbatim token rows from data/pilot_sample.tsv,
tracked in git, covering construct chains, verb+suffix slots, single-token slots
and three-token slots. The two long verse-text columns are blanked: they carry
copyrighted translation text and this fixture, unlike data/, is tracked. Nothing
here reads them.

No network, no database. `sourcebible.db` is never opened.

    python3 -m unittest discover scripts/tests
"""

import csv
import collections
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
REPO = os.path.dirname(SCRIPTS)
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

import process_glosses as pg  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "pilot_tokens_slice.tsv")
LIVE = os.path.join(REPO, "data", "pilot_sample.tsv")


def read_tsv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def slots_of(rows):
    """-> OrderedDict[(osis, ch, vs, slot)] = [row, …] in reading order."""
    g = collections.OrderedDict()
    for r in sorted(rows, key=lambda r: (r["osis"], int(r["chapter"]),
                                         int(r["verse"]), int(r["pos_in_verse"]))):
        g.setdefault((r["osis"], r["chapter"], r["verse"], int(r["slot"])), []).append(r)
    return g


def trails_possessive(vals):
    """True when the LAST NON-EMPTY GLOSS of a slot is a bare possessive.

    Deliberately not "the last WORD of the joined phrase". Macula puts whole
    phrases on a suffix token — "knew.her", "had.taken.her" — so 1 Kings 1:4
    joins to "he knew her", whose last word is "her" while its last value is
    "knew her". The word-level test flags 159 such slots across the corpus as
    defects and would demand they become "her he knew". Measured, not assumed:
    by value the corpus has 0 trailing possessives, by word 159.
    """
    ne = [v.strip() for v in vals if v and v.strip()]
    if len(ne) < 2:
        return False
    return ne[-1].lower() in pg.SUFFIX_PRONOUNS


def run_slot(group):
    """Feed one real slot through per-token synthesis + the slot pass.
    -> (values written per token, what the app would render)"""
    toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
    vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H") for r in group]
    out = pg.reorder_slot(toks, vals)
    joined = " ".join(v for v in out if v and v.strip())
    return out, joined


class SlotPassTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.slots = slots_of(read_tsv(FIXTURE))

    def find(self, osis, ch, vs, slot):
        key = (osis, ch, vs, slot)
        self.assertIn(key, self.slots, "fixture lacks slot %s" % (key,))
        return self.slots[key]

    # ── the defect ────────────────────────────────────────────────────────────

    def test_shema_reorders(self):
        """Deut 6:4-6 construct chains must read possessive-first."""
        cases = [("DEU", "6", "4", 4), ("DEU", "6", "5", 6), ("DEU", "6", "5", 8)]
        for osis, ch, vs, slot in cases:
            group = self.find(osis, ch, vs, slot)
            out, joined = run_slot(group)
            words = joined.split()
            self.assertGreater(len(words), 1, "slot %s collapsed to %r" % (slot, joined))
            self.assertIn(words[0].lower(), pg.SUFFIX_PRONOUNS,
                          "%s %s:%s slot %d renders %r — possessive is not first"
                          % (osis, ch, vs, slot, joined))
            self.assertFalse(trails_possessive(out),
                             "%s %s:%s slot %d still trails the possessive: %r"
                             % (osis, ch, vs, slot, joined))

    def test_pre_fix_behaviour_was_wrong(self):
        """Control: without the slot pass the same slots trail the possessive.
        A test that only asserts the new output cannot show the old was broken."""
        bad = 0
        for (osis, ch, vs, slot), group in self.slots.items():
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            if trails_possessive(vals):
                bad += 1
        self.assertGreater(bad, 0,
                           "fixture contains no construct chain — it cannot "
                           "demonstrate the defect")

    # ── the over-eager fix this must not become ───────────────────────────────

    def test_verb_plus_suffix_is_left_alone(self):
        """`he` + `makes.me.lie.down` ends in a suffix TOKEN but not in a
        possessive. Reordering it would produce "makes me lie down he"."""
        for osis, ch, vs, slot in (("PSA", "23", "2", 3), ("PSA", "23", "2", 7),
                                   ("PSA", "23", "3", 3), ("ISA", "53", "4", 6)):
            group = self.find(osis, ch, vs, slot)
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            self.assertEqual(pg.reorder_slot(toks, vals), vals,
                             "%s %s:%s slot %d was reordered and should not be"
                             % (osis, ch, vs, slot))

    def test_leading_particle_keeps_its_place(self):
        """The possessive moves in front of the NOUN, not in front of the slot.

        Both cases below shipped wrong for one build: the first version of the
        slot pass produced "your in heart" and "our and pains" because it put the
        possessive at the head of the whole phrase. Three-token slots with a
        leading preposition or conjunction are the shape that exposes it, and the
        fixture had none until this test was written."""
        cases = [(("LEV", "19", "17", 5), "in your heart"),
                 (("ISA", "53", "4", 5), "and our pains")]
        for (osis, ch, vs, slot), expect in cases:
            group = self.find(osis, ch, vs, slot)
            _out, joined = run_slot(group)
            self.assertEqual(joined, expect,
                             "%s %s:%s slot %d → %r" % (osis, ch, vs, slot, joined))

    def test_possessive_never_precedes_a_particle(self):
        """Corpus-shaped invariant: after the pass, no slot may start with a
        possessive followed by a preposition or conjunction gloss."""
        PARTICLES = {"in", "and", "on", "to", "with", "from", "of", "at", "for",
                     "by", "so", "or", "but", "than", "the"}
        for key, group in self.slots.items():
            _out, joined = run_slot(group)
            w = joined.split()
            if len(w) >= 2 and w[0].lower() in pg.SUFFIX_PRONOUNS:
                self.assertNotIn(w[1].lower(), PARTICLES,
                                 "slot %s reads %r" % (key, joined))

    def test_single_token_slots_untouched(self):
        for key, group in self.slots.items():
            if len(group) != 1:
                continue
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            self.assertEqual(pg.reorder_slot(toks, vals), vals, "slot %s" % (key,))

    # ── the COALESCE trap ─────────────────────────────────────────────────────

    def test_emptied_rows_are_empty_string_not_none(self):
        """`DatabaseService.loadWords` reads
        COALESCE(gloss_display, gloss_macula, gloss). A None here would fall back
        to gloss_macula and render the possessive twice — "your heart your"."""
        found = 0
        for key, group in self.slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            out = pg.reorder_slot(toks, vals)
            if out == vals:
                continue
            found += 1
            blanked = [v for v in out if v == ""]
            self.assertTrue(blanked, "slot %s reordered but blanked nothing" % (key,))
            for v in out:
                self.assertIsNotNone(v, "slot %s wrote None" % (key,))
        self.assertGreater(found, 0, "no slot reordered — nothing was verified")

    def test_phrase_lands_on_the_head_token(self):
        """The phrase must sit on the same token the view treats as head, or the
        tap target and the visible gloss belong to different words."""
        for key, group in self.slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            out = pg.reorder_slot(toks, vals)
            if out == vals:
                continue
            hi = pg.head_index(toks)
            self.assertTrue((out[hi] or "").strip(),
                            "slot %s: head token %d is empty" % (key, hi))
            self.assertFalse(pg.is_enclitic(toks[hi][1], toks[hi][2]),
                             "slot %s: head token is an enclitic" % (key,))

    def test_no_word_is_lost_or_duplicated(self):
        """Reordering may move words, never add or drop them."""
        for key, group in self.slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            out = pg.reorder_slot(toks, vals)
            before = sorted(" ".join(v for v in vals if v and v.strip()).split())
            after = sorted(" ".join(v for v in out if v and v.strip()).split())
            self.assertEqual(before, after, "slot %s: %r -> %r" % (key, vals, out))

    def test_idempotent(self):
        for key, group in self.slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            once = pg.reorder_slot(toks, vals)
            twice = pg.reorder_slot(toks, once)
            self.assertEqual(once, twice, "slot %s not idempotent" % (key,))

    # ── stage 7: brackets must not reach the screen ────────────────────────────

    def test_bracket_only_glosses_keep_their_words(self):
        """A gloss that is entirely bracketed is the token's only meaning, so the
        brackets come off and the words stay. Real values from the database, with
        their live counts: [the] 247, [who] 191, [is] 109, [which] 94."""
        for raw, expect in (("[the]", "the"), ("[who]", "who"), ("[is]", "is"),
                            ("[which]", "which"), ("[people]", "people"),
                            ("[men]", "men"), ("[one]", "one")):
            self.assertEqual(pg.synthesize(raw, "H1886a", "H"), expect,
                             "raw %r" % raw)

    def test_bracketed_copula_after_a_pronoun(self):
        """`I.[am]` used to end up NULL: stage 2 removed "[am]", stage 3 stripped
        the subject pronoun, nothing was left. These 5 rows stood alone in their
        slot, so the display word had no gloss at all and COALESCE showed the raw
        string."""
        for raw, expect in (("I.[am]", "I am"), ("it.[was]", "it was"),
                            ("they.[were]", "they were"),
                            ("you.[are]", "you are"), ("he.[was]", "he was")):
            self.assertEqual(pg.synthesize(raw, "H589", "H"), expect,
                             "raw %r" % raw)

    def test_partial_brackets_are_still_dropped(self):
        """Stage 2's original behaviour must not change: while something survives
        the bracketed filler is deleted, not un-bracketed."""
        self.assertEqual(pg.synthesize("[is].the", "H1886a", "H"), "the")
        self.assertEqual(pg.synthesize("[is].my shepherd", "H7462b", "H"),
                         "my shepherd")

    def test_never_none_for_a_non_empty_hebrew_gloss(self):
        """None routes the row to COALESCE(…, gloss_macula, gloss), which renders
        the raw brackets. Empty string is the only safe 'show nothing'."""
        for raw in ("[the]", "[which]", "I.[am]", "[]", "[ ]", "..", "[.]"):
            got = pg.synthesize(raw, "H1886a", "H")
            self.assertIsNotNone(got, "raw %r returned None" % raw)

    def test_no_bracket_survives_any_fixture_gloss(self):
        for _key, group in self.slots.items():
            for r in group:
                got = pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                self.assertNotIn("[", got or "",
                                 "%r → %r" % (r["gloss_macula"], got))
                self.assertNotIn("]", got or "",
                                 "%r → %r" % (r["gloss_macula"], got))

    def test_bracket_spans_split_across_tokens(self):
        """Macula splits a bracketed span across tokens, so per row the bracket is
        unbalanced and stage 2's `\\[.*?\\]` cannot match. Real values with their
        live counts: [those 329, [will 227, [who 175, the.[one 164, be] 38,
        who].touches 19."""
        for raw, expect in (("[those", "those"), ("[will", "will"),
                            ("[who", "who"), ("the.[one", "the one"),
                            ("(the).[one", "(the) one"), ("be]", "be"),
                            ("who].touches", "who touches"),
                            ("were].dwelling", "were dwelling"),
                            ("who].hate.me", "who hate me")):
            self.assertEqual(pg.synthesize(raw, "H1886a", "H"), expect,
                             "raw %r" % raw)

    def test_round_parens_are_left_alone(self):
        """Only square brackets are editorial notation here. Macula's round
        parens carry sense — "of.rest(s)", "(the).living" — and must survive."""
        self.assertEqual(pg.synthesize("of.rest(s)", "H4496", "H"), "of rest(s)")
        self.assertEqual(pg.synthesize("(the).living", "H1886a", "H"),
                         "(the) living")

    def test_untranslatable_particle_still_wins(self):
        """H853 must stay an em dash — stage 1 runs before stage 7."""
        self.assertEqual(pg.synthesize("[obj]", "H853", "H"), "—")

    def test_greek_untouched_by_stage_7(self):
        self.assertEqual(pg.synthesize("the [word]", "G3056", "G"), "the [word]")

    # ── head-token rule must match the view ───────────────────────────────────

    def test_head_index_matches_the_view_rule(self):
        """Last non-enclitic token; enclitic = lexical_class 'x' or morph 'S…'."""
        for key, group in self.slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            expect = len(toks) - 1
            for i in range(len(toks) - 1, -1, -1):
                if not (toks[i][2] == "x" or (toks[i][1] or "").startswith("S")):
                    expect = i
                    break
            self.assertEqual(pg.head_index(toks), expect, "slot %s" % (key,))

    # ── the live file ─────────────────────────────────────────────────────────

    @unittest.skipUnless(os.path.exists(LIVE), "data/pilot_sample.tsv absent")
    def test_live_sample_shema_and_counts(self):
        rows = read_tsv(LIVE)
        self.assertIn("slot", rows[0],
                      "%s predates the slot rework" % LIVE)
        slots = slots_of(rows)
        reordered, trailing_after = 0, 0
        for _key, group in slots.items():
            toks = [(r["strong"], r["morph"], r["lexical_class"]) for r in group]
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            out = pg.reorder_slot(toks, vals)
            if out != vals:
                reordered += 1
            if trails_possessive(out):
                trailing_after += 1
        self.assertGreaterEqual(reordered, 25,
                                "only %d slots reordered; the measured "
                                "cross-token count was 31" % reordered)
        # Corpus control: the word-level rule this test used to apply flags 159
        # object-pronoun slots as defects. If that ever reaches zero, someone
        # replaced the value-level check with the word-level one again.
        by_word = 0
        for _key, group in slots.items():
            vals = [pg.synthesize(r["gloss_macula"], "H" + r["strong"], "H")
                    for r in group]
            ne = [v.strip() for v in vals if v and v.strip()]
            if len(ne) > 1 and " ".join(ne).split()[-1].lower() in pg.SUFFIX_PRONOUNS:
                by_word += 1
        self.assertGreaterEqual(by_word, trailing_after,
                                "value-level check is stricter than word-level, "
                                "which is backwards")
        self.assertEqual(trailing_after, 0,
                         "%d slot(s) still render a trailing possessive"
                         % trailing_after)


if __name__ == "__main__":
    unittest.main()
