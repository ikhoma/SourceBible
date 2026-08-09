#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Invariants for the pilot gold-set draw in scripts/build_pilot_sample.py.

Why this file exists
--------------------
The first version of the gold draw looked stratified and was not. Its stratified
pass had a hard ceiling of 3 tiers x 8 books = 24 picks; the `while len(gold) <
args.gold` top-up then filled the remaining 28 of 50 straight off the top of
`rows`, which begin at 1CH and DEU. The gold set came out DEU 23 + 1CH 9 of 50 —
32 rows from two books — with tail = 8, where one error moves the number 12.5 pp.
Nothing failed. The file looked fine.

`test_legacy_algorithm_is_caught` reproduces that exact algorithm and asserts the
invariant checker rejects it, so this suite would have failed before the fix.

Data
----
Runs on real Macula rows, never on invented ones. Two sources:

  * fixtures/pilot_slots_slice.tsv — a verbatim slice of
    data/pilot_sample_slots.tsv, tracked in git. Real columns, real Hebrew, real
    Strong's/morph/gloss/tier, real multi-token slots. The two long verse-text
    columns are blanked because they carry copyrighted translation text and this
    fixture, unlike data/, is tracked; the selector never reads them.
  * data/pilot_sample_slots.tsv — the live 259-row file, when present. data/ is
    gitignored, so its absence skips those cases instead of failing them.

THE UNIT IS THE DISPLAY SLOT, not the token. The gold set is drawn from slot rows
because that is what the app renders (`VerseTabContent.displayWords`) and what a
reviewer edits. Drawing it from token rows hands the reviewer half a word.

No network, no database. `sourcebible.db` is never opened — the APFS sparse-file
rule in CLAUDE.md applies and nothing here needs it.

    python3 -m unittest discover scripts/tests
"""

import csv
import os
import sys
import unittest
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
REPO = os.path.dirname(SCRIPTS)
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

import build_pilot_sample as bps  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "pilot_slots_slice.tsv")
LIVE = os.path.join(REPO, "data", "pilot_sample_slots.tsv")
LIVE_TOKENS = os.path.join(REPO, "data", "pilot_sample.tsv")


def read_tsv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def legacy_pick(rows, n):
    """The algorithm as it stood before the fix, verbatim. Kept so the defect
    stays reproducible: a regression test that only asserts the new behaviour
    cannot tell you the old behaviour was actually wrong."""
    books = sorted({r["osis"] for r in rows})
    seen, gold = set(), []
    for tier in ("head", "mid", "tail"):
        for osis in books:
            for r in rows:
                if len(gold) >= n:
                    break
                k = (r["strong"], r["morph"], r["gloss_macula"])
                if r["osis"] == osis and r["tier"] == tier and k not in seen:
                    seen.add(k)
                    gold.append(r)
                    break
    i = 0
    while len(gold) < n and i < len(rows):
        k = (rows[i]["strong"], rows[i]["morph"], rows[i]["gloss_macula"])
        if k not in seen:
            seen.add(k)
            gold.append(rows[i])
        i += 1
    return gold


class GoldDrawTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.rows = read_tsv(FIXTURE)
        cls.n = 60

    def draw(self, rows=None, n=None):
        return bps.pick_gold(rows if rows is not None else self.rows,
                             n if n is not None else self.n)

    # ── the defect ────────────────────────────────────────────────────────────

    def test_legacy_algorithm_is_caught(self):
        """The pre-fix draw must be rejected, and rejected for the right reason."""
        legacy = legacy_pick(self.rows, self.n)
        self.assertEqual(len(legacy), self.n)  # it did produce a full-looking file
        with self.assertRaises(bps.GoldError) as ctx:
            bps.check_gold(legacy, self.rows, self.n)
        self.assertIn("book share", str(ctx.exception))

    def test_legacy_concentrates_in_two_books(self):
        """Names the failure in numbers, so a future refactor cannot 'fix' the
        test by loosening the cap and calling it done."""
        legacy = legacy_pick(self.rows, self.n)
        top = Counter(r["osis"] for r in legacy).most_common(2)
        share = sum(c for _b, c in top) / float(len(legacy))
        self.assertGreater(share, 0.45,
                           "legacy draw was expected to pile up in two books; "
                           "got %s" % top)

    # ── the fix ───────────────────────────────────────────────────────────────

    def test_no_book_dominates(self):
        gold, _ = self.draw()
        books = Counter(r["osis"] for r in gold)
        cap = max(1, int(bps.MAX_BOOK_SHARE * len(gold)))
        worst = books.most_common(1)[0]
        self.assertLessEqual(worst[1], cap,
                            "%s carries %d of %d rows (cap %d)"
                            % (worst[0], worst[1], len(gold), cap))

    def test_tier_quotas_put_precision_in_the_tail(self):
        """The tail must not be the smallest stratum: it is the one that breaks,
        and the plan forbids merging it into the head number."""
        gold, _ = self.draw()
        got = Counter(r["tier"] for r in gold)
        self.assertGreater(got["tail"], got["head"],
                           "tail=%d head=%d — tail must be the largest stratum"
                           % (got["tail"], got["head"]))
        self.assertGreaterEqual(got["tail"], 20,
                                "tail=%d: one error moves the number %.1f pp"
                                % (got["tail"], 100.0 / max(1, got["tail"])))

    def test_every_supplied_cell_is_represented(self):
        gold, _ = self.draw()
        uniq = bps.first_by_triple(self.rows)
        supplied = {(r["tier"], r["osis"]) for r in uniq.values()}
        drawn = {(r["tier"], r["osis"]) for r in gold}
        quotas, _notes = bps.tier_quotas(self.n, Counter(
            r["tier"] for r in uniq.values()))
        for tier, want in quotas.items():
            books = sorted({o for (t, o) in supplied if t == tier})
            if want >= len(books):
                for b in books:
                    self.assertIn((tier, b), drawn,
                                  "tier %s misses %s though quota %d covers "
                                  "%d books" % (tier, b, want, len(books)))

    def test_empty_cells_are_data_not_failure(self):
        """1CH (genealogy) has no head and no tail triples in the real sample.
        The draw must not invent coverage there, and must not crash on it."""
        uniq = bps.first_by_triple(self.rows)
        cells = set((r["tier"], r["osis"]) for r in uniq.values())
        self.assertNotIn(("head", "1CH"), cells)
        self.assertNotIn(("tail", "1CH"), cells)
        gold, _ = self.draw()
        drawn_1ch = set(r["tier"] for r in gold if r["osis"] == "1CH")
        self.assertEqual(drawn_1ch, {"mid"})

    def test_no_duplicate_triples(self):
        gold, _ = self.draw()
        triples = [bps.triple_of(r) for r in gold]
        self.assertEqual(len(triples), len(set(triples)))

    def test_gold_is_a_subset_of_the_sample(self):
        gold, _ = self.draw()
        sample = {bps.triple_of(r) for r in self.rows}
        for t in (bps.triple_of(r) for r in gold):
            self.assertIn(t, sample)

    def test_uk_column_ships_empty(self):
        """A gold file that arrives pre-filled is not a blind gold file."""
        gold, _ = self.draw()
        self.assertEqual([r for r in gold if (r.get("uk") or "").strip()], [])

    def test_deterministic(self):
        a, _ = self.draw()
        b, _ = self.draw()
        self.assertEqual([bps.triple_of(r) for r in a],
                         [bps.triple_of(r) for r in b])

    def test_row_shape_is_preserved(self):
        """Gold rows must carry every SLOT column — the reviewer reads context
        (merged surface, head xlit, composed morph, both Ukrainian verses) off
        this file. Asserting bps.COLS here would test the token unit."""
        gold, _ = self.draw()
        for col in bps.SLOT_COLS:
            self.assertIn(col, gold[0], "gold row lost column %r" % col)


    def test_unit_is_the_display_slot(self):
        """Guards the whole point of the rework: multi-token slots must survive
        into the gold set as single units. If this drops to zero, someone pointed
        the draw back at the token file and every downstream count is wrong."""
        gold, _ = self.draw()
        multi = [r for r in gold if int(r["n_tokens"]) > 1]
        self.assertGreater(len(multi), 0, "no multi-token slot in the gold set")
        for r in multi:
            self.assertIn("·", r["morph"],
                          "multi-token slot %s has no composed morph" % r["slot"])
            self.assertIn("+", r["strong"],
                          "multi-token slot %s has no composed Strong's" % r["slot"])

    def test_no_slot_is_split(self):
        """A slot is atomic. Its identity must never be a bare single-token key
        when the slot actually holds more tokens."""
        gold, _ = self.draw()
        for r in gold:
            n = int(r["n_tokens"])
            self.assertEqual(len(r["strong"].split("+")), n,
                             "slot %s: n_tokens=%d but %d Strong's ids"
                             % (r["slot"], n, len(r["strong"].split("+"))))

    @unittest.skipUnless(os.path.exists(LIVE) and os.path.exists(LIVE_TOKENS),
                         "pilot data absent")
    def test_live_two_levels_agree(self):
        """Token file and slot file must describe the same grouping — same slot
        count, same token count per slot. They are written from one grouping pass,
        so disagreement means someone edited one path and not the other."""
        toks = read_tsv(LIVE_TOKENS)
        slots = read_tsv(LIVE)
        self.assertIn("slot", toks[0],
                      "%s has no `slot` column — it predates the slot rework, so "
                      "the display unit cannot be derived from it at all"
                      % LIVE_TOKENS)
        per = Counter((r["osis"], r["chapter"], r["verse"], r["slot"]) for r in toks)
        self.assertEqual(len(per), len(slots))
        for s in slots:
            k = (s["osis"], s["chapter"], s["verse"], s["slot"])
            self.assertEqual(per[k], int(s["n_tokens"]), "slot %s" % (k,))

    # ── quota arithmetic ──────────────────────────────────────────────────────

    def test_quotas_sum_to_n(self):
        uniq = bps.first_by_triple(self.rows)
        supply = Counter(r["tier"] for r in uniq.values())
        for n in (30, 50, 60, 72, 90):
            quotas, _notes = bps.tier_quotas(n, supply)
            if sum(supply.values()) >= n:
                self.assertEqual(sum(quotas.values()), n, "n=%d" % n)

    def test_quota_clamp_is_reported_not_silent(self):
        """When a tier cannot supply its share the clamp must be named, because a
        silent clamp is how the head quietly eats the tail's rows."""
        supply = Counter({"head": 100, "mid": 100, "tail": 2})
        quotas, notes = bps.tier_quotas(60, supply)
        self.assertEqual(quotas["tail"], 2)
        self.assertTrue(any("tail" in s for s in notes), notes)

    def test_asking_for_more_than_the_sample_holds_fails_loudly(self):
        uniq = bps.first_by_triple(self.rows)
        with self.assertRaises(bps.GoldError):
            bps.pick_gold(self.rows, len(uniq) + 1)

    # ── the live file ─────────────────────────────────────────────────────────

    @unittest.skipUnless(os.path.exists(LIVE), "data/pilot_sample.tsv absent")
    def test_live_sample_passes_every_invariant(self):
        rows = read_tsv(LIVE)
        gold, _report = bps.pick_gold(rows, self.n)
        uniq = bps.first_by_triple(rows)
        quotas, _notes = bps.tier_quotas(
            self.n, Counter(r["tier"] for r in uniq.values()))
        bps.check_gold(gold, rows, self.n, quotas)

    @unittest.skipUnless(os.path.exists(LIVE), "data/pilot_sample.tsv absent")
    def test_live_tail_supply_supports_the_policy(self):
        """The tail quota must be satisfiable from real data, or the design
        number is fiction."""
        rows = read_tsv(LIVE)
        uniq = bps.first_by_triple(rows)
        supply = Counter(r["tier"] for r in uniq.values())
        quotas, _notes = bps.tier_quotas(self.n, supply)
        self.assertLessEqual(quotas["tail"], supply["tail"])
        self.assertGreaterEqual(
            supply["tail"], 24,
            "only %d tail triples in the sample — widen the sample before "
            "quoting a tail accuracy number" % supply["tail"])


if __name__ == "__main__":
    unittest.main()
