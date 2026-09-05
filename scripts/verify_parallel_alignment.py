#!/usr/bin/env python3
"""Гейт вирівнювання паралельних перекладів (ADR-028, bug-036).

Панель «Переклади» — крос-трансляційна поверхня: номер вірша, який бачить читач,
НЕ є ключем у перекладі з іншою схемою версифікації. Правильний шлях — два хопи
через `verse_org` (вірш перекладу → оригінал → вірш іншого перекладу), і саме цей
шлях перевіряє цей скрипт: на еталонах, на контролях протилежної помилки і на
структурних інваріантах.

Запуск (на Mac, база тільки для читання):
    python3 scripts/verify_parallel_alignment.py [sourcebible.db]
    python3 scripts/verify_parallel_alignment.py --print-baseline   # перезняти матрицю

Ненульовий код виходу = не вирівняно. Друкує очікуване поруч з отриманим, щоб було
видно, хто помиляється — скрипт чи еталон (урок 2026-08-04, CLAUDE.md).
"""

from __future__ import annotations

import sqlite3
import sys

DB_DEFAULT = "sourcebible.db"

# ── Еталони ───────────────────────────────────────────────────────────────────
# (переклад читача, книга, глава, вірш) → {цільовий переклад: (глава, вірш) | None}
# None = рядка НЕ має бути: у цільовому перекладі немає вірша для цього оригіналу
# (напр. надпис псалма, який KJV вливає у вірш 1). Порожній рядок чесніший за чужий
# текст — саме це відрізняє фікс від старого identity-пошуку.
ANCHORS: list[tuple[str, str, int, int, dict[str, tuple[int, int] | None]]] = [
    # Пісн 1: Синодальний нумерує надпис, тож зсунутий на −1; Огієнко — ні.
    ("KJV", "SNG", 1, 15, {"RST": (1, 14), "UBIO": (1, 15)}),
    # Псалтир: RST І UBIO обидва в LXX-нумерації → зсув на ГЛАВУ.
    ("KJV", "PSA", 51, 1, {"RST": (50, 3), "UBIO": (50, 3)}),
    ("RST", "PSA", 50, 1, {"UBIO": (50, 1), "KJV": None}),
    ("UBIO", "PSA", 51, 1, {"RST": (51, 1), "KJV": None}),
    # Межа глави зсунута всередині книги.
    ("KJV", "ECC", 5, 1, {"RST": (4, 17), "UBIO": (4, 17)}),
    ("KJV", "DAN", 4, 1, {"RST": (3, 31), "UBIO": (3, 31)}),
    ("KJV", "HOS", 13, 16, {"RST": (14, 1), "UBIO": (14, 1)}),
    ("UBIO", "1CH", 5, 27, {"KJV": (6, 1), "RST": (6, 1)}),
    # НЗ теж зсувається: RST переставляє 2Кор 11:32–33.
    ("KJV", "2CO", 11, 33, {"RST": (11, 32), "UBIO": (11, 33)}),
    # ── Контролі протилежної помилки: тут зсуву БУТИ НЕ МОЖЕ ──
    # Скрипт/мапінг, що «вирівнює» все підряд, впаде саме тут.
    ("KJV", "GEN", 1, 1, {"RST": (1, 1), "UBIO": (1, 1), "ASV": (1, 1)}),
    ("KJV", "JHN", 3, 16, {"RST": (3, 16), "UBIO": (3, 16), "ASV": (3, 16)}),
    ("UBIO", "JHN", 3, 16, {"RST": (3, 16), "KJV": (3, 16)}),
]

# ── Базова матриця розходжень ────────────────────────────────────────────────
# Заміряно 2026-09-05 на повному прогоні ./rebuild.sh (build_db.py коміт 2b6028d
# + ADR-034 item#2 punctuation-фікс — уперше повний пайплайн пройшов ці зміни
# end-to-end; попередній baseline був заморожений 2026-08-16, ДО них).
# Звірено вручну (не наосліп): усі 10 розходжень з попереднім baseline —
# документовані реальні відмінності нумерації віршів між перекладами
# (2CO 13:13-14, ACT 19:40-41, ISA 63:19/64:1, MAT 21:29-30 — відомий
# текстологічний варіант порядку відповідей синів, NEH 7:68-69, PHP 1:16-17,
# PSA 13:5-6) або вже відомі "глави без конформної схеми" для UBIO
# (JER 5, PSA 141 — саме ті, що позначає сам build_versification.py).
# shifted = вірш цілі має ІНШИЙ номер; absent = у цілі немає вірша для цього оригіналу.
# Обидва числа стережуть з двох боків: обвал у нуль = мапінг загубився і панель
# знову показує чужий вірш; вибух = мапінг поїхав.
BASELINE: dict[tuple[str, str], tuple[int, int]] = {
    ("ASV", "KJV"):  (8, 0),     ("ASV", "NASB"):  (7, 0),    ("ASV", "RST"):  (2705, 7),  ("ASV", "UBIO"): (3341, 31),
    ("KJV", "ASV"):  (8, 17),    ("KJV", "NASB"):  (9, 0),    ("KJV", "RST"):  (2703, 9),  ("KJV", "UBIO"): (3343, 31),
    ("NASB", "ASV"): (6, 18),    ("NASB", "KJV"):  (8, 1),    ("NASB", "RST"): (2703, 10), ("NASB", "UBIO"): (3338, 31),
    ("RST", "ASV"):  (2705, 83), ("RST", "KJV"):   (2703, 68), ("RST", "NASB"): (2703, 68), ("RST", "UBIO"): (898, 31),
    ("UBIO", "ASV"): (3339, 90), ("UBIO", "KJV"):  (3341, 73), ("UBIO", "NASB"): (3336, 72), ("UBIO", "RST"): (896, 14),
}
TOLERANCE = 0.02   # ±2% — ребілд мапінгу може ворухнути хвіст, але не порядок

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"  ✗ {msg}")


def load(db: sqlite3.Connection) -> tuple[dict, dict, set]:
    """fwd: вірш → перший непорожній оригінал; rev: оригінал → перший вірш; have: наявні вірші."""
    fwd: dict = {}
    rev: dict = {}
    sql = """SELECT translation, book_id, chapter, verse, org_book_id, org_chapter, org_verse
             FROM verse_org
             ORDER BY translation, book_id, chapter, verse, org_chapter, org_verse"""
    for t, b, ch, v, ob, oc, ov in db.execute(sql):
        fwd.setdefault((t, b, ch, v), (ob, oc, ov) if ob is not None else None)
        if ob is not None:
            rev.setdefault((t, ob, oc, ov), (b, ch, v))
    have = {row for row in db.execute("SELECT translation, book_id, chapter, verse FROM verse")}
    return fwd, rev, have


def resolve(fwd: dict, rev: dict, source: str, book: str, ch: int, v: int, target: str):
    """Те саме, що `DatabaseService.loadParallelVerseTexts` — два хопи + фолбек на identity."""
    key = (source, book, ch, v)
    if key not in fwd:                      # рядка немає → база до ADR-028 → identity
        return (book, ch, v)
    org = fwd[key]
    if org is None:                         # «немає оригіналу» → identity (як у Swift)
        return (book, ch, v)
    if target == source:
        return (book, ch, v)
    return rev.get((target, *org))          # None = у цілі немає вірша


def main() -> int:
    print_baseline = "--print-baseline" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else DB_DEFAULT

    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    fwd, rev, have = load(db)
    translations = [r[0] for r in db.execute("SELECT id FROM translation ORDER BY id")]
    print(f"▸ {path}: {len(fwd)} рядків verse_org, {len(have)} віршів, переклади {translations}")

    # ── 1. Покриття: без рядка verse_org фікс тихо падає в identity ──────────
    print("\n▸ Покриття verse_org")
    missing = sorted(have - set(fwd))
    if missing:
        fail(f"{len(missing)} віршів без рядка verse_org (фолбек в identity = знову чужий вірш), "
             f"перший: {missing[0]}")
    else:
        print(f"  ✓ всі {len(have)} віршів мають мапінг")

    # ── 2. Цілісність зворотного хопа: він мусить вести на наявний вірш ──────
    print("\n▸ Цілісність зворотного хопа")
    dangling = [(t, *ref) for (t, *_), ref in rev.items() if (t, *ref) not in have]
    if dangling:
        fail(f"{len(dangling)} зворотних хопів ведуть на відсутній вірш, перший: {dangling[0]}")
    else:
        print(f"  ✓ всі {len(rev)} зворотних хопів ведуть на наявний вірш")

    # ── 3. Еталони ──────────────────────────────────────────────────────────
    print("\n▸ Еталонні вірші")
    for source, book, ch, v, expected in ANCHORS:
        for target, want in expected.items():
            got_ref = resolve(fwd, rev, source, book, ch, v, target)
            got = None if got_ref is None else (got_ref[1], got_ref[2])
            mark = "✓" if got == want else "✗"
            line = (f"{source} {book} {ch}:{v} → {target}: "
                    f"очікувано {want or 'рядка немає'}, отримано {got or 'рядка немає'}")
            if got != want:
                fail(line)
            else:
                print(f"  {mark} {line}")
            # текст мусить існувати там, куди привів хоп
            if got_ref is not None and (target, *got_ref) not in have:
                fail(f"{source} {book} {ch}:{v} → {target} {got_ref}: вірша немає в таблиці verse")

    # ── 4. Матриця розходжень проти замороженої базової ──────────────────────
    print("\n▸ Матриця розходжень (shifted / absent)")
    measured: dict[tuple[str, str], tuple[int, int]] = {}
    for source in translations:
        verses = [k for k in fwd if k[0] == source]
        for target in translations:
            if target == source:
                continue
            shifted = absent = 0
            for (_, book, ch, v) in verses:
                ref = resolve(fwd, rev, source, book, ch, v, target)
                if ref is None:
                    absent += 1
                elif ref != (book, ch, v):
                    shifted += 1
            measured[(source, target)] = (shifted, absent)

    if print_baseline:
        print("  BASELINE = {")
        for k, val in measured.items():
            print(f'      ("{k[0]}", "{k[1]}"): {val},')
        print("  }")
        return 0

    for key, want in BASELINE.items():
        got = measured.get(key)
        if got is None:
            fail(f"{key[0]}→{key[1]}: пари немає в базі (перекладу більше немає?)")
            continue
        for i, label in enumerate(("shifted", "absent")):
            lo = want[i] * (1 - TOLERANCE) - 1
            hi = want[i] * (1 + TOLERANCE) + 1
            if not lo <= got[i] <= hi:
                fail(f"{key[0]}→{key[1]} {label}: очікувано ~{want[i]} (±{TOLERANCE:.0%}), "
                     f"отримано {got[i]}")
    for key, got in measured.items():
        if key not in BASELINE:
            fail(f"{key[0]}→{key[1]}: нової пари немає в BASELINE — перезнiми --print-baseline")
    if not failures:
        for key in sorted(measured):
            s, a = measured[key]
            print(f"  ✓ {key[0]}→{key[1]}: shifted {s}, absent {a}")

    # ── 5. Контроль протилежної помилки: більшість віршів МУСИТЬ бути identity ──
    print("\n▸ Частка identity (мапінг, що зсуває все, — теж баг)")
    for key, (shifted, absent) in measured.items():
        total = sum(1 for k in fwd if k[0] == key[0])
        share = 1 - (shifted + absent) / total
        if share < 0.85:
            fail(f"{key[0]}→{key[1]}: identity лише {share:.1%} — мапінг зсуває надто багато")
        else:
            print(f"  ✓ {key[0]}→{key[1]}: identity {share:.1%}")

    print()
    if failures:
        print(f"✗ Провалів: {len(failures)}")
        return 1
    print("✓ Паралельні переклади вирівняні")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
