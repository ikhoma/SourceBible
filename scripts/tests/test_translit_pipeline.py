#!/usr/bin/env python3
"""
Regression tests for the Hebrew transliteration pipeline.

    python3 -m unittest discover scripts/tests
    python3 scripts/tests/test_translit_pipeline.py     # same thing, direct

No network, no database, no BSB/Macula files — everything is a fixture. Runs in
well under a second, so there is no excuse for not running it.

EVERY test here corresponds to a defect that actually shipped on 2026-08-04 and
would have been caught by the test had it existed. They are named after the
defect, not after the function, so a failure says what broke rather than where.

The fixtures deliberately reproduce the REAL shapes of the data:
`parse_hebrew_translit()` hands back 3-tuples, not dicts. An earlier round of
hand-written checks used dicts because that is what the author assumed, so they
passed while the live run crashed on the first verse. A fixture that encodes the
same assumption as the code under test verifies nothing.
"""

import importlib.util
import json
import os
import re
import sys
import tempfile
import types
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(name):
    """Import a pipeline script by filename without executing its main()."""
    path = os.path.join(SCRIPTS, name)
    spec = importlib.util.spec_from_file_location(name.replace(".py", ""), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def install_fake_v1(pages):
    """
    Stand in for fetch_biblehub_translit_hebrew (the v1 scraper).

    `pages` maps (book, eng_ch, eng_vs) -> list of Strong's strings. The fake
    parser returns 3-TUPLES, matching the real v1 signature.
    """
    stub = types.ModuleType("fetch_biblehub_translit_hebrew")
    current = {}

    def fake_parse(_html):
        strongs = pages[current["key"]]
        return [("heb%d" % i, "tr%d" % i, s) for i, s in enumerate(strongs, 1)]

    def fake_fetch(url):
        m = re.search(r"/text/([^/]+)/(\d+)-(\d+)\.htm", url)
        book = {"psalms": "PSA", "isaiah": "ISA", "1_samuel": "1SA",
                "genesis": "GEN"}[m.group(1)]
        current["key"] = (book, int(m.group(2)), int(m.group(3)))
        return None if current["key"] not in pages else "<html/>"

    stub.parse_hebrew_translit = fake_parse
    stub.fetch = fake_fetch
    stub.DELAY = 0
    stub.SAVE_EVERY = 10 ** 9
    sys.modules["fetch_biblehub_translit_hebrew"] = stub


MAP_HEADER = ("osis\torg_chapter\torg_verse\tseg\teng_chapter\teng_verse"
              "\tword_offset\tword_len\tscore\tflag\n")


# ─── The matcher ──────────────────────────────────────────────────────────────

class TestMatcher(unittest.TestCase):
    """derive_org_to_eng.map_book — how ORG verses are located in the ENG stream."""

    @classmethod
    def setUpClass(cls):
        cls.d = load("derive_org_to_eng.py")

    def first_segments(self, rows):
        return {(r[1], r[2]): (r[4], r[5], r[6], r[7]) for r in rows if r[3] == 0}

    def test_merged_superscription_is_not_swallowed_as_1to1(self):
        """
        DEFECT: MT 3:1 covered exactly 60% of ENG 3:1, cleared a 0.60 threshold
        as a clean 1:1, took the whole page and orphaned MT 3:2. Accepting the
        first shape that passes is wrong; every shape must be scored and the
        best one chosen.
        """
        mac = {(3, 1): ["4210", "1732", "1272", "6440", "1121", "53"],
               (3, 2): ["3068", "4100", "7231", "6862"],
               (3, 3): ["7227", "559", "5315"]}
        bsb = {(3, 1): ["4210", "1732", "1272", "6440", "1121", "53",
                        "3068", "4100", "7231", "6862"],
               (3, 2): ["7227", "559", "5315"]}
        rows, review, stats = self.d.map_book("PSA", mac, bsb, 25)
        segs = self.first_segments(rows)
        self.assertEqual(stats.get("N:1"), 1, "the merge was not detected")
        self.assertEqual(segs[(3, 1)][:3], (3, 1, 0))
        self.assertEqual(segs[(3, 2)][:3], (3, 1, 6), "MT 3:2 must start where 3:1 ends")
        self.assertEqual(review, [])

    def test_verse_split_across_two_english_verses(self):
        """One MT verse spanning two ENG verses must produce two segments."""
        mac = {(20, 42): ["3212", "7965", "834", "7650"], (21, 1): ["6965", "935"]}
        bsb = {(20, 42): ["3212", "7965"], (21, 1): ["834", "7650"],
               (21, 2): ["6965", "935"]}
        rows, review, stats = self.d.map_book("1SA", mac, bsb, 25)
        spans = [(r[1], r[2], r[3], r[4], r[5]) for r in rows]
        self.assertIn((20, 42, 0, 20, 42), spans)
        self.assertIn((20, 42, 1, 21, 1), spans)
        self.assertEqual(stats.get("1:N"), 1)

    def test_chapter_shift_genesis_32(self):
        """
        DEFECT: 'Genesis has no versification divergence' was asserted from
        memory. MT Gen 32:1 = English 31:55, so the whole chapter runs one ahead
        and 30 verses were corrupt.
        """
        mac = {(32, 1): ["7925", "3837"], (32, 2): ["3290", "1980", "1870"],
               (32, 3): ["559", "3290", "834"]}
        bsb = {(31, 55): ["7925", "3837"], (32, 1): ["3290", "1980", "1870"],
               (32, 2): ["559", "3290", "834"]}
        segs = self.first_segments(self.d.map_book("GEN", mac, bsb, 25)[0])
        self.assertEqual(segs[(32, 2)][:2], (32, 1))
        self.assertEqual(segs[(32, 3)][:2], (32, 2))

    def test_suffix_heavy_verse_still_matches(self):
        """
        DEFECT: Macula splits a pronominal suffix into its own token while BSB
        keeps the word whole, so containment sits below coverage on a correct
        match. Gating on min(coverage, containment) refused Isaiah 53:5 while
        every verse around it matched. Coverage alone is the right gate.
        """
        mac = {(53, 5): ["2490", "6588", "1792", "5771", "4148", "7965",
                         "2250", "7495"]}
        bsb = {(53, 5): ["2490", "6588", "1792", "5771", "4148", "7965"]}
        rows, review, _ = self.d.map_book("ISA", mac, bsb, 25)
        self.assertEqual(review, [], "a suffix-heavy verse must not be refused")
        self.assertEqual(len(rows), 1)

    def test_one_unmatched_verse_does_not_desynchronise_the_book(self):
        """
        DEFECT: on failure only the ORG pointer advanced, leaving the streams a
        verse out of step. One bad verse at the Numbers 30 boundary produced 227
        consecutive failures.
        """
        mac = {(1, 1): ["111"], (1, 2): ["999999"], (1, 3): ["333"], (1, 4): ["444"]}
        bsb = {(1, 1): ["111"], (1, 2): ["222"], (1, 3): ["333"], (1, 4): ["444"]}
        rows, review, _ = self.d.map_book("NUM", mac, bsb, 25)
        segs = self.first_segments(rows)
        self.assertEqual(len(review), 1, "exactly one verse should fail")
        self.assertEqual(segs[(1, 3)][:2], (1, 3), "verses after the gap must stay put")
        self.assertEqual(segs[(1, 4)][:2], (1, 4))

    def test_resync_never_goes_backwards(self):
        """
        DEFECT: resync searched behind the pointer, so a later block re-claimed
        ENG verses an earlier one already held — 16 backward jumps and 33 tiling
        overlaps in the first full run.
        """
        mac = {(1, 1): ["111"], (1, 2): ["222"], (1, 3): ["111"]}
        bsb = {(1, 1): ["111"], (1, 2): ["222"], (1, 3): ["777"]}
        rows, _, _ = self.d.map_book("X", mac, bsb, 25)
        engs = [(r[4], r[5]) for r in rows]
        self.assertEqual(engs, sorted(engs), "the map must be monotone")


class TestSelfCheck(unittest.TestCase):
    """derive_org_to_eng.verify — the gate that stops a bad map reaching the network."""

    @classmethod
    def setUpClass(cls):
        cls.d = load("derive_org_to_eng.py")

    def row(self, osis, oc, ov, ec, ev, off=0, ln=5, seg=0):
        flag = "OK" + ("|SHIFTED" if (oc, ov) != (ec, ev) else "")
        return (osis, oc, ov, seg, ec, ev, off, ln, 1.0, flag)

    def test_tiling_overlap_is_caught(self):
        rows = [self.row("PSA", 3, 1, 3, 1, 0, 6), self.row("PSA", 3, 2, 3, 1, 3, 6)]
        ok, failures = self.d.verify(rows, 2, ["PSA"])
        self.assertFalse(ok)
        self.assertTrue(any("OVERLAP" in f for f in failures))

    def test_tiling_gap_is_caught(self):
        rows = [self.row("PSA", 3, 1, 3, 1, 0, 4), self.row("PSA", 3, 2, 3, 1, 7, 3)]
        ok, failures = self.d.verify(rows, 2, ["PSA"])
        self.assertFalse(ok)
        self.assertTrue(any("GAP" in f for f in failures))

    def test_unshifted_map_fails_the_anchors(self):
        """The whole point of the gate: a map that forgot to shift must not pass."""
        rows = [self.row("JON", 2, 1, 2, 1), self.row("MAL", 3, 19, 3, 19)]
        ok, failures = self.d.verify(rows, 2, ["JON", "MAL"])
        self.assertFalse(ok)
        self.assertTrue(any("ANCHOR" in f for f in failures))


# ─── The scraper ──────────────────────────────────────────────────────────────

class TestScraper(unittest.TestCase):
    """fetch_biblehub_translit_hebrew_v2 — slicing, storing, auditing."""

    def build(self, pages, map_rows, macula, existing=None):
        install_fake_v1(pages)
        m = load("fetch_biblehub_translit_hebrew_v2.py")
        d = tempfile.mkdtemp()
        m.DATA = d
        m.OUT_JSON = os.path.join(d, "translit.json")
        m.OUT_REJECT = os.path.join(d, "rejected.tsv")
        m.MAP_TSV = os.path.join(d, "map.tsv")
        with open(m.MAP_TSV, "w", encoding="utf-8") as f:
            f.write(MAP_HEADER)
            for r in map_rows:
                f.write("\t".join(str(x) for x in r) + "\n")
        m.load_macula_strongs = lambda: macula
        if existing is not None:
            with open(m.OUT_JSON, "w", encoding="utf-8") as f:
                json.dump(existing, f)
        return m

    def run_main(self, m, argv):
        old = sys.argv
        sys.argv = ["fetch"] + argv
        try:
            m.main()
        except SystemExit:
            pass
        finally:
            sys.argv = old
        with open(m.OUT_JSON, encoding="utf-8") as f:
            return json.load(f)

    def strongs(self, store, key):
        n = store.get("%s:count" % key)
        return [store["%s:%d" % (key, p)]["strong"] for p in range(1, (n or 0) + 1)]

    def test_parser_returns_tuples_not_dicts(self):
        """
        DEFECT: v1's parse_hebrew_translit returns 3-tuples. The v2 code assumed
        dicts and crashed on the first live verse — after the author had said
        'tested' three times, because the hand-written fixtures used dicts.
        """
        m = load("fetch_biblehub_translit_hebrew_v2.py")
        self.assertEqual(m.as_word(("heb", "tr", "7225")),
                         {"surface": "heb", "translit": "tr", "strong": "7225"})
        self.assertEqual(m.as_word({"surface": "a", "translit": "b", "strong": "c"}),
                         {"surface": "a", "translit": "b", "strong": "c"})

    def test_shared_page_is_split_between_two_verses(self):
        pages = {("PSA", 3, 1): ["4210", "1732", "1272", "6440", "1121", "53",
                                 "3068", "4100", "7231", "6862"],
                 ("PSA", 3, 2): ["7227", "559", "5315"]}
        rows = [("PSA", 3, 1, 0, 3, 1, 0, 6, 1.0, "OK|N:1"),
                ("PSA", 3, 2, 0, 3, 1, 6, 4, 1.0, "OK|N:1|SHIFTED"),
                ("PSA", 3, 3, 0, 3, 2, 0, 3, 1.0, "OK|SHIFTED")]
        mac = {("PSA", 3, 1): ["4210", "1732", "1272", "6440", "1121", "53"],
               ("PSA", 3, 2): ["3068", "4100", "7231", "6862"],
               ("PSA", 3, 3): ["7227", "559", "5315"]}
        m = self.build(pages, rows, mac)
        store = self.run_main(m, ["--all"])
        self.assertEqual(self.strongs(store, "PSA:3:1"), mac[("PSA", 3, 1)])
        self.assertEqual(self.strongs(store, "PSA:3:2"), mac[("PSA", 3, 2)])

    def test_shared_page_shorter_than_the_map_claims(self):
        """
        DEFECT: slice bounds came from BSB's word counts, but BibleHub tokenises
        a handful of verses differently. On a single-claimant page that produced
        a visible out-of-range error; on a shared page it moved the boundary by
        one word and still scored 0.83, passing the 0.70 guard silently.
        Boundaries must be recomputed from the live page.
        """
        pages = {("PSA", 3, 1): ["4210", "1732", "1272", "6440", "1121",
                                 "3068", "4100", "7231", "6862"]}   # one word fewer
        rows = [("PSA", 3, 1, 0, 3, 1, 0, 6, 1.0, "OK|N:1"),         # map says 6
                ("PSA", 3, 2, 0, 3, 1, 6, 4, 1.0, "OK|N:1|SHIFTED")]
        mac = {("PSA", 3, 1): ["4210", "1732", "1272", "6440", "1121"],
               ("PSA", 3, 2): ["3068", "4100", "7231", "6862"]}
        m = self.build(pages, rows, mac)
        store = self.run_main(m, ["--all"])
        self.assertEqual(self.strongs(store, "PSA:3:1"), mac[("PSA", 3, 1)])
        self.assertEqual(self.strongs(store, "PSA:3:2"), mac[("PSA", 3, 2)])

    def test_repair_targets_only_broken_verses(self):
        """--repair must leave good entries untouched and rebuild the bad one."""
        pages = {("PSA", 57, 1): ["5329", "4210", "1732", "1272",
                                  "2603", "5204", "430"]}
        rows = [("PSA", 57, 1, 0, 57, 1, 0, 4, 1.0, "OK|N:1"),
                ("PSA", 57, 2, 0, 57, 1, 4, 3, 1.0, "OK|N:1|SHIFTED")]
        mac = {("PSA", 57, 1): ["5329", "4210", "1732", "1272"],
               ("PSA", 57, 2): ["2603", "5204", "430"]}
        stale = {"PSA:57:2:count": 3}
        for p, s in enumerate(["7121", "430", "5945"], 1):      # another verse's words
            stale["PSA:57:2:%d" % p] = {"translit": "old", "surface": "x", "strong": s}
        m = self.build(pages, rows, mac, existing=stale)
        store = self.run_main(m, ["--repair"])
        self.assertEqual(self.strongs(store, "PSA:57:2"), mac[("PSA", 57, 2)])

    def test_rejected_page_purges_the_stale_wrong_entry(self):
        """
        DEFECT: when the Strong's guard refused a page, the entry written
        earlier under the wrong verse number stayed. 'Rejected' quietly meant
        'keep showing another verse's transliteration' for nine Psalms verses.
        """
        pages = {("PSA", 9, 1): ["1111", "2222", "3333"]}       # matches nothing
        rows = [("PSA", 9, 1, 0, 9, 1, 0, 3, 1.0, "OK")]
        mac = {("PSA", 9, 1): ["7777", "8888", "9999"]}
        stale = {"PSA:9:1:count": 3}
        for p, s in enumerate(["4444", "5555", "6666"], 1):     # also wrong
            stale["PSA:9:1:%d" % p] = {"translit": "old", "surface": "x", "strong": s}
        m = self.build(pages, rows, mac, existing=stale)
        store = self.run_main(m, ["--repair"])
        self.assertNotIn("PSA:9:1:count", store,
                         "a refused fetch must not leave known-wrong data in place")

    def test_audit_separates_correct_from_wrong_verse(self):
        m = load("fetch_biblehub_translit_hebrew_v2.py")
        m.DATA = tempfile.mkdtemp()
        mac = {("PSA", 51, 7): ["2005", "5771", "2342", "2399", "3179", "517"]}

        def store_for(strongs):
            s = {"PSA:51:7:count": len(strongs)}
            for p, x in enumerate(strongs, 1):
                s["PSA:51:7:%d" % p] = {"translit": "t", "surface": "s", "strong": x}
            return s

        good, _ = m.audit(store_for(mac[("PSA", 51, 7)]), mac)
        self.assertTrue(good)
        # the words of MT 51:9 — the shape the original bug report showed
        bad, failures = m.audit(
            store_for(["2398", "231", "2891", "3526", "7950", "3835"]), mac)
        self.assertFalse(bad)
        self.assertTrue(any("51:7" in f for f in failures))

    def test_marginal_agreement_is_stored_not_discarded(self):
        """
        DEFECT: a flat 0.70 bar refused 30 CORRECT verses. On a three-word verse
        one differing Strong's id is 0.67. Measured on real data, wrong-verse
        pages never scored above 0.17 while right-verse-with-lexeme-variance
        never scored below 0.33 — so the bar belongs in that empty band, and the
        marginal range must be kept rather than thrown away.
        """
        pages = {("GEN", 34, 9): ["2859", "9999", "5414"]}   # middle id differs
        rows = [("GEN", 34, 9, 0, 34, 9, 0, 3, 1.0, "OK")]
        mac = {("GEN", 34, 9): ["2859", "1323", "5414"]}
        m = self.build(pages, rows, mac)
        store = self.run_main(m, ["--all"])
        self.assertIn("GEN:34:9:count", store,
                      "0.67 is a lexeme disagreement, not a different verse")

    def test_clearly_wrong_verse_is_still_refused(self):
        """The relaxed bar must not let an actually-wrong page through."""
        pages = {("GEN", 34, 9): ["1111", "2222", "3333"]}
        rows = [("GEN", 34, 9, 0, 34, 9, 0, 3, 1.0, "OK")]
        mac = {("GEN", 34, 9): ["2859", "1323", "5414"]}
        m = self.build(pages, rows, mac)
        store = self.run_main(m, ["--all"])
        self.assertNotIn("GEN:34:9:count", store)

    def test_audit_counts_verses_that_have_no_entry(self):
        """
        DEFECT: the audit scored only stored verses, so after a repair purged 30
        refused entries it reported "every stored verse agrees" — true, and
        silent about the 30 that were gone. Absence is a coverage hole.
        """
        m = load("fetch_biblehub_translit_hebrew_v2.py")
        m.DATA = tempfile.mkdtemp()
        mac = {("PSA", 1, 1): ["835"], ("PSA", 1, 2): ["3588"]}
        store = {"PSA:1:1:count": 1,
                 "PSA:1:1:1": {"translit": "t", "surface": "s", "strong": "835"}}
        ok, failures = m.audit(store, mac)          # PSA 1:2 has no entry
        self.assertFalse(ok, "a missing verse must not pass as clean")
        self.assertTrue(any("no transliteration" in f for f in failures))


if __name__ == "__main__":
    unittest.main(verbosity=2)
