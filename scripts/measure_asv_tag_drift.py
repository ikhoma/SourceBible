#!/usr/bin/env python3
"""Міряє дрейф тегів Стронга в модулі ASV (bug-047).

ЩО САМЕ МІРЯЄМО
---------------
Гіпотеза, підтверджена емпірично Іваном: у модулі ASV тег `<S>` часто повішений на
англійське СЛУЖБОВЕ слово (he, them, thee, in, of), тоді як змістовне слово, якому цей
номер належить, лишається поза тегом. Наслідок: у конкордансі підсвічується хибне
слово, а в рідері клікабельним стає не те.

МЕТОД — структурний з ОБОХ боків, без глос
------------------------------------------
Для кожного тега:
  1. беремо англійське слово, до якого він причеплений;
  2. дивимось `word.lexical_class` того Macula-токена, що несе цей номер у цьому вірші;
  3. якщо номер належить ЗМІСТОВНОМУ слову (noun/verb/adj/num), а тег висить на
     англійській частці — це дрейф.

⛔ Свідомо НЕ використовуються глоси. Попередня версія цього скрипта звіряла англійське
слово з глосою Macula й тонула в шумі: KJV і NASB, обидва зі справними тегами, не
сходяться між собою на 41% — бо перекладачі просто добирають різні слова. Синоніми
(«field» / «country», «towns» / «villages») зараховувались як промахи. Клас частини мови
такого шуму не має.

⛔ Тільки англомовні переклади: RST і UBIO цим методом не міряються.

ДВА КОНТРОЛІ
------------
Один переклад можна списати на випадковість модуля; два з різних традицій — ні.

Заміряно 2026-08-19:
    NASB : 77 з 159 588 → 0.05%
    KJV  : 783 з 205 005 → 0.38%
    ASV  : 9 063 з 204 108 → 4.44%
    → ASV у 92× гірший за NASB і в 11.6× за KJV.

Нечисленні випадки KJV здебільшого ЗАКОННІ: майже всі — «in» ← H935 (בוא), де
англійська передає значення прийменником («brought in»). В ASV натомість
«were» ← H441 (noun), «him» ← H4191 (verb), «them» ← H7079 (Кенат).

ВИКОРИСТАННЯ
------------
    python3 scripts/measure_asv_tag_drift.py [sourcebible.db]

Читає базу в mode=ro. Замір, не гейт: порогу «скільки дрейфу прийнятно» ніхто не
встановлював, тож ненульового коду виходу не повертає.
"""
from __future__ import annotations

import re
import sqlite3
import sys
from collections import defaultdict

DB = "sourcebible.db"
SUBJECT = "ASV"
CONTROLS = ["NASB", "KJV"]

CONTENT_CLASSES = {"noun", "verb", "adj", "num"}

# Англійські службові слова. Список навмисно широкий: хибне спрацювання тут
# симетричне для всіх трьох перекладів, тож на РОЗРИВ між ними воно не впливає.
FUNCTION_WORDS = {
    "he", "she", "it", "they", "them", "thee", "thou", "you", "him", "her", "his",
    "its", "their", "my", "our", "not", "and", "the", "that", "which", "unto",
    "was", "were", "is", "are", "be", "of", "to", "in", "for", "with", "but",
}

TAG_RE = re.compile(r"([A-Za-z'’-]+)\s*<S>(\d+)</S>")


def strongs_classes(conn):
    """(книга, глава, вірш) -> {базовий номер: lexical_class}."""
    out = defaultdict(dict)
    sql = ("SELECT book_id, chapter, verse, strongs_id, lexical_class FROM word "
           "WHERE strongs_id IS NOT NULL AND lexical_class IS NOT NULL")
    for bk, ch, vs, sid, lc in conn.execute(sql):
        num = re.sub(r"[a-z]+$", "", sid)
        # Номер може трапитись у вірші і як змістовний, і як службовий токен —
        # у такому разі вважаємо змістовним, щоб не занизити чисельник.
        if out[(bk, ch, vs)].get(num) not in CONTENT_CLASSES:
            out[(bk, ch, vs)][num] = lc
    return out


def measure(conn, classes, translation):
    total = drifted = 0
    samples = []
    for bk, ch, vs, txt in conn.execute(
            "SELECT book_id, chapter, verse, text FROM verse WHERE translation = ?",
            (translation,)):
        verse_cls = classes.get((bk, ch, vs))
        if not verse_cls:
            continue
        for m in TAG_RE.finditer(txt or ""):
            word, num = m.group(1).lower(), "H" + m.group(2)
            if verse_cls.get(num) not in CONTENT_CLASSES:
                continue
            total += 1
            if word in FUNCTION_WORDS:
                drifted += 1
                if len(samples) < 8:
                    samples.append((bk, ch, vs, word, num, verse_cls[num]))
    return total, drifted, samples


def main() -> int:
    db = sys.argv[1] if len(sys.argv) > 1 else DB
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    classes = strongs_classes(conn)

    rates = {}
    print(f"{'':6}{'тегів на змістовних':>21}{'на англ. частці':>18}{'%':>8}")
    for tr in CONTROLS + [SUBJECT]:
        total, drifted, samples = measure(conn, classes, tr)
        rates[tr] = (drifted / total) if total else 0.0
        print(f"{tr:6}{total:21}{drifted:18}{100 * rates[tr]:8.2f}")
        if tr == SUBJECT:
            print("\nприклади дрейфу:")
            for bk, ch, vs, w, n, lc in samples:
                print(f"   {bk} {ch}:{vs}  «{w}» ← {n} ({lc})")

    print()
    for tr in CONTROLS:
        ratio = rates[SUBJECT] / rates[tr] if rates[tr] else float("inf")
        print(f"РОЗРИВ {SUBJECT} / {tr}: {ratio:.1f}×")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
