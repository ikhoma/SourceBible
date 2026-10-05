#!/usr/bin/env python3
"""Виправляє зсув тегів Strong's в ASV (крок rebuild.sh після build_versification).

ПРОБЛЕМА (заміряно 2026-10-04)
------------------------------
У джерельному файлі ASV тег часто стоїть не після свого слова, а в кінці
ПОПЕРЕДНЬОЇ фрази, перед розділовим знаком:

    ASV  …reigned<S>4427</S> in his stead<S>8034</S>; and the name of his city…
    KJV  …reigned<S>4427</S> in his stead: and the name<S>8034</S> of his city…
    ASV  saying<S>3107</S>, Blessed are they whose…          (Рим 4:7)

Через це тап у читанці на «stead» відкриває שֵׁם «ім'я», «name» не відкриває
нічого, а «Translated as» показує «saying» для μακάριος. ~8 тис. місць в ASV
(у KJV та сама перевірка дає ~200 — шум, KJV не чіпаємо).

ПРАВИЛО
-------
Тег (одиночний) змістового слова оригіналу (`lexical_class` noun/verb/adj) з
однослівною глосою Macula переноситься, якщо:
  * у його нинішньому сегменті глоси немає, а
  * у тексті ДО наступного тегу вона є, і це не останнє слово перед ним
    (останнє — найімовірніше, слово наступного тегу).
Тег ставиться одразу після знайденого слова. Порядок тегів не змінюється, тож
парування слово↔сегмент (`verseWordSegmentPairs`) для решти вірша те саме.
Ланцюжки (перенос одного тегу відкриває сусідній) проходяться до нерухомої точки,
тож повторний прогін скрипта нічого не змінює.

⛔ ПИШЕ в базу (verse.text для ASV) — запускати ТІЛЬКИ на Mac, як решту rebuild.sh.

    python3 scripts/fix_asv_tag_drift.py sourcebible.db [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_word_rendering import STOP_EN, pair_words, parse_segments  # noqa: E402

TRANSLATION = "ASV"
CONTENT = {"noun", "verb", "adj"}
GROUP_RE = re.compile(r"(?:<S>[^<]*</S>\s*)*<S>[^<]*</S>")
WORD_RE = re.compile(r"[A-Za-z]+")

GOLDEN = [
    # (book num, ch, v, фрагмент, який мусить бути у виправленому тексті)
    (45, 4, 7, "Blessed<S>3107</S>"),
    (13, 1, 46, "name<S>8034</S>"),
]


def _words_outside_tags(s: str):
    """(start, end, word) для слів поза <...>."""
    out, i = [], 0
    for m in re.finditer(r"<[^>]*>", s):
        out += [(i + w.start(), i + w.end(), w.group(0)) for w in WORD_RE.finditer(s[i:m.start()])]
        i = m.end()
    out += [(i + w.start(), i + w.end(), w.group(0)) for w in WORD_RE.finditer(s[i:])]
    return out


def fix_verse(text: str, words, info) -> tuple[str, int]:
    segs = parse_segments(text)
    groups = list(GROUP_RE.finditer(text))
    if len(groups) != sum(1 for s in segs if s.strongs):
        return text, 0                       # нестандартна розмітка — не чіпаємо
    wid_by_ord = {o: wid for wid, _, o, _ in pair_words(words, segs)}
    moves = []                               # (group, insert_at)
    for o, g in enumerate(groups):
        if g.group(0).count("<S>") != 1 or o not in wid_by_ord:
            continue
        lc, gloss = info[wid_by_ord[o]]
        if lc not in CONTENT:
            continue
        gw = [w for w in WORD_RE.findall(gloss.lower()) if w not in STOP_EN]
        if len(gw) != 1:
            continue
        stem = gw[0][:4]
        own_from = groups[o - 1].end() if o else 0
        if any(w.lower().startswith(stem) for _, _, w in _words_outside_tags(text[own_from:g.start()])):
            continue
        t_end = groups[o + 1].start() if o + 1 < len(groups) else len(text)
        tw = _words_outside_tags(text[g.end():t_end])
        hit = next((k for k, (_, _, w) in enumerate(tw)
                    if w.lower().startswith(stem) and len(w) - len(gw[0]) <= 4), None)
        if hit is None or (o + 1 < len(groups) and hit == len(tw) - 1):
            continue
        moves.append((g, g.end() + tw[hit][1]))
    for g, at in reversed(moves):            # з кінця — зсуви не ламаються
        tag = g.group(0).strip()
        text = text[:at] + tag + text[at:]
        text = text[:g.start()] + text[g.end():]
    return text, len(moves)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default="sourcebible.db")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    conn = sqlite3.connect(args.db)
    words_by_verse = defaultdict(list)
    info = {}
    for wid, b, c, v, sid, lc, gl in conn.execute(
            "SELECT id, book_id, chapter, verse, strongs_id, lexical_class, gloss FROM word "
            "ORDER BY book_id, chapter, verse, position"):
        words_by_verse[(b, c, v)].append((wid, sid))
        info[wid] = (lc, gl or "")
    org = defaultdict(list)
    for b, c, v, ob, oc, ov in conn.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation = ? ORDER BY book_id, chapter, verse, org_chapter, org_verse", (TRANSLATION,)):
        org[(b, c, v)].append((ob, oc, ov) if ob is not None else None)

    updates, moved = [], 0
    for b, c, v, text in conn.execute(
            "SELECT book_id, chapter, verse, text FROM verse WHERE translation = ?", (TRANSLATION,)).fetchall():
        key = (b, c, v)
        words = sum((words_by_verse.get(r, []) for r in org[key] if r), []) if key in org \
            else words_by_verse.get(key, [])
        if not words or not text:
            continue
        new, n = text, 0
        for _ in range(4):                   # ланцюжок зсувів: перенос відкриває наступний
            new, k = fix_verse(new, words, info)
            n += k
            if not k:
                break
        if n:
            updates.append((new, TRANSLATION, b, c, v))
            moved += n
    print(f"  ASV: перенесено тегів {moved} у {len(updates)} віршах")
    if args.dry_run:
        return 0
    conn.executemany("UPDATE verse SET text = ? WHERE translation = ? AND book_id = ? AND chapter = ? AND verse = ?",
                     updates)
    bad = []
    for bnum, c, v, frag in GOLDEN:
        t = conn.execute("SELECT v.text FROM verse v JOIN book b ON b.id = v.book_id "
                         "WHERE v.translation = ? AND b.num = ? AND v.chapter = ? AND v.verse = ?",
                         (TRANSLATION, bnum, c, v)).fetchone()
        if not t or frag not in t[0]:
            bad.append(f"{bnum} {c}:{v} — немає «{frag}»")
    if bad:
        conn.rollback()
        sys.stderr.write("\n✗ Еталони переносу тегів ASV розійшлися:\n  " + "\n  ".join(bad) + "\n\n")
        return 1
    conn.commit()
    print("  ✓ еталони: Рим 4:7 «Blessed», 1 Хр 1:46 «name»")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
