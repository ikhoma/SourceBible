#!/usr/bin/env python3
"""Гейти ADR-042, яким потрібна Macula (тому не в конвертері, який її не читає).

Запуск (база лише для читання; після build_db.py):
    python3 scripts/verify_asv_alignment.py [sourcebible.db]

1. ГОЛОВНИЙ ТОКЕН = ГОЛОВА СЛОТА. Кожен івритський токен OpenBible, який конвертер обрав
   головним (тег іде на нього), мусить бути головою свого слота Macula за правилом
   `headToken` (BibleModels.swift: останній не-енклітичний; енклітика = class 'x' або
   morph S…). Арамейський емфатичний -א (Td після іменника) рахуємо енклітикою — це
   окремий дефект «Оригіналу» (bug-060), а не конвертера. Поріг: ≥ 99%.
2. МЕЖІ СЛІВ. Слово OpenBible (за правилом конвертера) = слот Macula. Поріг: ≥ 99%.
3. НЕЗІСТАВЛЕНІ. Частка токенів OpenBible (без нульових морфем «[הַ]» і варіантів .vNNN),
   для яких не знайшлося слова в `word`. Іврит — за поверхнею в порядку вірша, грека — за
   послідовністю базових Strong's (SBLGNT ≠ Nestle 1904). Поріг: ≤ 3%.
Еталон-контроль: Бут 22:8 — голова слота «בְּנִי» = בֵּן (H1121), не суфікс; Бут 1:5 «לָאוֹר» → H216.

Ненульовий код виходу на провал; друкує приклади розбіжностей.
Заміряно 2026-10-07 на коміті b6580247: 99,98% / 99,97% / 1,85%.
"""
from __future__ import annotations

import collections
import difflib
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_asv_module import SRC_DIR, PROCLITIC, _cls, hebrew_words, head_of, parse_original  # noqa: E402

MIN_HEAD = 0.99
MIN_BOUND = 0.99
MAX_UNMATCHED = 0.03
VARIANT_RE = re.compile(r"\.v\d+")


def src_verse(tok: dict) -> tuple[str, int, int]:
    m = re.match(r"(?:WLC|SBLGNT)\.(\w+)\.(\d+)\.(\d+)\.\d+$", tok["x-id"])
    src = tok.get("x-source-ref")
    b, c, v = src.split(".") if src else (m.group(1), m.group(2), m.group(3))
    return b, int(c), int(v)


def base(s: str | None) -> str:
    return re.sub(r"[a-z]$", "", s or "")


def mac_head(rows: list[tuple]) -> tuple:
    """BibleModels.headToken + арамейський -א як енклітика. rows: (id, morph, class, …)."""
    cand = [r for i, r in enumerate(rows)
            if not (r[2] == "x" or (r[1] or "").startswith("S")
                    or (r[1] == "Td" and i > 0 and _cls(rows[i - 1][1]) not in PROCLITIC))]
    return (cand or rows)[-1]


def main() -> int:
    db = sys.argv[1] if len(sys.argv) > 1 else "sourcebible.db"
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    words = collections.defaultdict(list)
    slots = collections.defaultdict(list)
    for wid, b, c, v, pos, surf, sid, morph, cls, slot, lang in con.execute(
            "SELECT id, book_id, chapter, verse, position, surface, strongs_id, morph, lexical_class, slot, "
            "language FROM word ORDER BY book_id, chapter, verse, position"):
        words[(b, c, v)].append((wid, surf, sid))
        if slot is not None and lang == "hbo":
            slots[(b, c, v, slot)].append((wid, morph, cls))
    slot_of = {r[0]: k for k, rows in slots.items() for r in rows}

    org = {}
    for f in sorted((SRC_DIR / "usx-original-aligned").glob("*.usx")):
        org.update(parse_original(f))
    by_verse = collections.defaultdict(list)
    for t in org.values():
        if VARIANT_RE.search(t["x-id"]) or t["surface"].startswith("["):
            continue
        by_verse[src_verse(t)].append(t)

    mp: dict[str, str] = {}
    tot = {"heb": 0, "grc": 0}
    for sv, toks in by_verse.items():
        toks.sort(key=lambda t: t["x-id"])
        heb = toks[0]["x-id"].startswith("WLC.")
        rows = words.get(sv, [])
        key_o = [t["surface"] if heb else base(t.get("strong")) for t in toks]
        key_w = [r[1] if heb else base(r[2]) for r in rows]
        tot["heb" if heb else "grc"] += len(toks)
        sm = difflib.SequenceMatcher(None, key_o, key_w, autojunk=False)
        for a, b2, n in sm.get_matching_blocks():
            for i in range(n):
                mp[toks[a + i]["x-id"]] = rows[b2 + i][0]
    unmatched = 1 - len(mp) / (tot["heb"] + tot["grc"])

    # слова OpenBible (правило конвертера) у порядку документа
    ws_by_ref = collections.defaultdict(list)
    for t in org.values():
        if t["x-id"].startswith("WLC."):
            ws_by_ref[t["x-id"].rsplit(".", 1)[0]].append(t)
    obi_head_of, obi_set_of = {}, {}
    for toks in ws_by_ref.values():
        toks.sort(key=lambda t: t["x-id"])
        for w in hebrew_words(toks):
            h = mp.get(head_of(w)["x-id"])
            ids = frozenset(mp[t["x-id"]] for t in w if t["x-id"] in mp)
            for t in w:
                if t["x-id"] in mp:
                    obi_head_of[mp[t["x-id"]]] = h
                    obi_set_of[mp[t["x-id"]]] = ids
    st = collections.Counter()
    bad = []
    for k, rows in slots.items():
        if not all(r[0] in obi_head_of for r in rows):
            st["slot_unmapped"] += 1
            continue
        mh = mac_head(rows)[0]
        same_set = {obi_set_of[r[0]] for r in rows} == {frozenset(r[0] for r in rows)}
        st["bound_ok" if same_set else "bound_bad"] += 1
        ok = all(obi_head_of[r[0]] == mh for r in rows)
        st["head_ok" if ok else "head_bad"] += 1
        if not ok and len(bad) < 15:
            bad.append(k)
    n = st["head_ok"] + st["head_bad"]
    head_rate, bound_rate = st["head_ok"] / n, st["bound_ok"] / n

    fails = []
    for ref, exp in ((("GEN", 22, 8, 8), "H1121"), (("GEN", 1, 5, 3), "H216")):
        h = obi_head_of.get(mac_head(slots[ref])[0])
        got = con.execute("SELECT strongs_id FROM word WHERE id = ?", (h,)).fetchone()
        if not got or got[0] != exp:
            fails.append(f"еталон {ref}: голова {exp}, отримано {got}")
    print(f"▸ слотів івриту: {n:,} (незіставлених слотів {st['slot_unmapped']:,})")
    print(f"  головний токен = голова слота: {head_rate:.3%} (поріг {MIN_HEAD:.0%})")
    print(f"  межі слів = слоти:             {bound_rate:.3%} (поріг {MIN_BOUND:.0%})")
    print(f"  незіставлені токени:           {unmatched:.2%} з {tot['heb'] + tot['grc']:,} (поріг ≤ {MAX_UNMATCHED:.0%})")
    if head_rate < MIN_HEAD:
        fails.append(f"головний токен {head_rate:.3%} < {MIN_HEAD:.0%}; приклади: {bad}")
    if bound_rate < MIN_BOUND:
        fails.append(f"межі слів {bound_rate:.3%} < {MIN_BOUND:.0%}")
    if unmatched > MAX_UNMATCHED:
        fails.append(f"незіставлених {unmatched:.2%} > {MAX_UNMATCHED:.0%}")
    for f in fails:
        print("  ✗ " + f)
    print("✓ ASV ↔ Macula узгоджені" if not fails else "✗ ASV ↔ Macula — провал")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
