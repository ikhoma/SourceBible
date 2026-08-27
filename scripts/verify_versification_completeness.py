#!/usr/bin/env python3
"""Гейт ПОВНОТИ версифікації: кожен мапінг із .vrs має бути в `verse_org` (bug-050).

ЧОМУ ЦЬОГО НЕ ЛОВИВ ЖОДЕН НАЯВНИЙ ГЕЙТ
--------------------------------------
`verify_parallel_alignment.py` і оракули O2/O3 у `build_versification.py`
перевіряють, що НАЯВНИЙ мапінг ПРАВИЛЬНИЙ. Питання «чи всі мапінги наявні» ніхто
не ставив — а це інша перевірка, і дешевою вона бути не могла, бо вимагає
незалежного джерела істини. Тепер воно є: `.vrs`.

Симптом, який гейт ловить: переклад зливає два оригінальні вірші в один, а ми
показуємо лише другий. RST 2Кор 11:32 містить грецькі 11:32 І 11:33; ми давали
тільки 11:33, тож 13 грецьких слів про правителя Арети були недосяжні з RST узагалі.

ЩО САМЕ ПЕРЕВІРЯЄМО — І ЧОМУ НЕ БІЛЬШЕ
--------------------------------------
Перевіряються ЛИШЕ злиття (ключі з кількома таргетами) і лише там, де ключ у
`verse_org` УЖЕ Є. Наявність ключа доводить, що конвеєр застосував цю схему до
цього вірша; отже брак таргета — справжня втрата, а не незастосовний мапінг.

⛔ Перша версія гейта перевіряла ПОВНЕ покриття всіх мапінгів .vrs і дала 888
«відсутніх ключів» — хибні спрацювання. Конвеєр обирає схему ПО ГЛАВІ за збігом
кількості віршів (`build_versification.py`, вибір за `maxVerses`), тож частина
мапінгів rso до нашого RST просто незастосовна: напр. `PRO 13:15-21` наш модуль
не поділяє. Гейт, що виє вовком на 888 рядків, ніхто не триматиме зеленим.

⛔ ЧЕРВОНИЙ, доки джерело мапінгів не переведене з JSON на .vrs. Червоний із
відомої причини — це працюючий гейт, а не зламаний.

ВИКОРИСТАННЯ
------------
    python3 scripts/verify_versification_completeness.py [sourcebible.db]

Читає базу в mode=ro. Ненульовий код виходу на будь-яке розходження.
"""
from __future__ import annotations

import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vrs import parse_vrs  # noqa: E402

DB = "sourcebible.db"
VRS_DIR = "data/versification"

# Яка схема застосовна до якого перекладу — дзеркалить SCHEMES у build_versification.py.
SCHEME_FOR = {
    "KJV": "eng", "ASV": "eng", "NASB": "eng",
    "RST": "rso", "UBIO": "rso",
}

# Еталони: ці вірші МУСЯТЬ мати рівно два org-таргети після фіксу.
GOLDEN_MERGES = [
    ("RST", "2CO", 11, 32, 2, "грец. 11:32 (правитель Арети) + 11:33 (кошик)"),
    ("RST", "LEV", 14, 55, 2, "два оригінальні вірші в одному російському"),
    ("RST", "REV", 13, 1, 2, "злиття через межу глави: 12:18 + 13:1"),
]


def load_expected():
    """(translation, book, ch, vs) -> [(org_ch, org_vs), …] з .vrs."""
    schemes = {}
    for name in set(SCHEME_FOR.values()):
        path = os.path.join(VRS_DIR, f"{name}.vrs.txt")
        if not os.path.exists(path):
            sys.exit(f"✗ Немає {path} — завантаж .vrs зі sillsdev/libpalaso (MIT). Див. bug-050.")
        schemes[name] = parse_vrs(path, name)
    out = {}
    for tr, scheme in SCHEME_FOR.items():
        for key, targets in schemes[scheme].mappings.items():
            out[(tr,) + key] = targets
    return out, schemes


def load_actual(db: str):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    actual = {}
    sql = ("SELECT translation, book_id, chapter, verse, org_chapter, org_verse "
           "FROM verse_org WHERE org_book_id IS NOT NULL "
           "ORDER BY translation, book_id, chapter, verse, org_chapter, org_verse")
    for tr, bk, ch, vs, oc, ov in conn.execute(sql):
        actual.setdefault((tr, bk, ch, vs), []).append((oc, ov))
    return actual


def load_actual_max_verses(db: str):
    """(translation, book_id, chapter) -> найбільший verse у нашій БД.

    Потрібно, щоб відрізнити СПРАВЖНЮ втрату злиття від того, що конвеєр
    узагалі не застосував цю .vrs-схему до цієї глави — він обирає схему
    ПО ГЛАВІ за збігом кількості віршів (`build_versification.py`, вибір за
    maxVerses). Приклад, знайдений 2026-08-27: rso.vrs заявляє PSA 114 = 8
    віршів, а в RST реально 9 (1:1 до Heb 116:1-9) — конвеєр коректно НЕ
    застосовує тут rso-мапінг PSA 114:8→[116:8,116:9]. `have` при цьому НЕ
    None (у RST є якийсь рядок для 114:8), тож без цього гейту ключ падав у
    "втрачені" НАЗАВЖДИ, навіть після повного і коректного фіксу конвеєра.
    """
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    out = {}
    sql = ("SELECT translation, book_id, chapter, MAX(verse) "
           "FROM verse GROUP BY translation, book_id, chapter")
    for tr, bk, ch, mx in conn.execute(sql):
        out[(tr, bk, ch)] = mx
    return out


def main() -> int:
    db = sys.argv[1] if len(sys.argv) > 1 else DB
    expected, schemes = load_expected()
    actual = load_actual(db)
    actual_max_verses = load_actual_max_verses(db)

    for name, sc in sorted(schemes.items()):
        print(f"  {name}.vrs: {len(sc.mappings)} ключів, {len(sc.merged_sources)} злиттів, "
              f"{len(sc.unequal_ranges)} нерівних діапазонів")

    complete, lost, not_applicable = [], [], []
    for tr, scheme_name in sorted(SCHEME_FOR.items()):
        sc = schemes[scheme_name]
        for key in sc.merged_sources:
            book, ch, vs = key
            want = sc.mappings[key]
            have = actual.get((tr,) + key)

            # Гейт на збіг maxVerses глави (план §9) — див. load_actual_max_verses.
            declared = sc.max_verses.get(book, [])
            declared_max = declared[ch - 1] if 0 < ch <= len(declared) else None
            actual_max = actual_max_verses.get((tr, book, ch))
            if declared_max is not None and actual_max is not None and declared_max != actual_max:
                not_applicable.append((tr, key))           # схема з іншою к-стю віршів у главі — не застосовна
                continue

            if have is None:
                not_applicable.append((tr, key))          # схему до цього вірша не застосовували
            elif len(have) >= len(want):
                complete.append((tr, key))
            else:
                lost.append((tr, key, want, have))

    print(f"\nзлиття з .vrs, застосовні до наших перекладів: {len(complete) + len(lost)}")
    print(f"  ПОВНІ:     {len(complete)}")
    print(f"  ВТРАЧЕНІ:  {len(lost)}")
    print(f"  (схема до вірша не застосовується — не рахуємо: {len(not_applicable)})")

    print("\n=== еталонні злиття ===")
    golden_bad = []
    for tr, bk, ch, vs, want_n, why in GOLDEN_MERGES:
        have = actual.get((tr, bk, ch, vs), [])
        ok = len(have) == want_n
        if not ok:
            golden_bad.append((tr, bk, ch, vs))
        print(f"  {'✓' if ok else '✗'} {tr} {bk} {ch}:{vs} — очікувано {want_n}, "
              f"є {len(have)} {have}   ({why})")

    if lost:
        print("\n=== втрачені злиття ===")
        for tr, key, want, have in lost:
            print(f"  {tr} {key[0]} {key[1]}:{key[2]} — треба {want}, є {have}")

    if lost or golden_bad:
        print(f"\n✗ ПОВНОТА ПОРУШЕНА: {len(lost)} злиттів втрачено, "
              f"{len(golden_bad)} еталонів не зійшлись.")
        return 1
    print("\n✓ Повнота: кожне застосовне злиття присутнє в verse_org повністю.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
