#!/usr/bin/env python3
"""
check_gloss_coverage.py — гейт покриття глосами (bug-051).

⛔ READ-ONLY.

Рахує ДИСПЛЕЙНІ СЛОВА (слоти), а не токени. Це не педантизм:
`VerseTabContent.displayWords` зливає токени одного слота і склеює лише непорожні
глоси, тож слот із одним порожнім токеном на екрані виглядає нормально.
Виміряно 2026-08-26: 3 247 порожніх токенів (0.535%) дають лише 307 порожніх
слотів (0.069%) — токенна метрика перебільшує шкоду в 10 разів і показала б
«регресію» там, де користувач нічого не помітить.

Дві перевірки:
  1. БЮДЖЕТ   — слотів без глоса не більше за BUDGET.
  2. ПАСТКА H853 — суфіксне אֹתָם (H853 + займенниковий суфікс) мусить лишатись
     «them», а не стати «— them». У process_glosses.py ранній вихід
     `if not raw: return None` стоїть ПЕРЕД стадією 1 (H853 → «—»), і це
     виглядає як недосяжний код, який хочеться «полагодити». Не можна:
     перевірено, що всі 1 673 такі токени сидять у слоті разом зі значущим
     суфіксом, і «фікс» зіпсував би 1 673 правильні слова.

Usage: python3 scripts/check_gloss_coverage.py [path/to/sourcebible.db]
"""

import os
import sqlite3
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Стан на 2026-08-26 після курації 4 грецьких віршів: 307 − 147 = 160.
BUDGET = 160

G = ("COALESCE(NULLIF(TRIM(gloss_display),''),"
     "NULLIF(TRIM(gloss_macula),''),NULLIF(TRIM(gloss),''))")

TRAPS = [
    ("GEN", 1, 17, 2, "them", "суфіксне אֹתָם — H853 не має додавати «—»"),
    ("GEN", 1, 27, 9, "it",   "суфіксне אֹתוֹ"),
    ("GEN", 1, 27, 13, "them", "суфіксне אֹתָם"),
    ("GEN", 1, 1, 4, "—",     "ОКРЕМЕ אֵת — тут «—» правильне"),
]


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "sourcebible.db")
    if not os.path.exists(db):
        sys.stderr.write("✗ немає бази: %s\n" % db)
        return 2
    con = sqlite3.connect("file:%s?mode=ro&immutable=1" % db, uri=True)

    total = con.execute(
        "SELECT COUNT(*) FROM (SELECT book_id,chapter,verse,slot FROM word GROUP BY 1,2,3,4)"
    ).fetchone()[0]
    empty = con.execute(
        "SELECT COUNT(*) FROM (SELECT book_id,chapter,verse,slot FROM word GROUP BY 1,2,3,4 "
        "HAVING SUM(CASE WHEN %s IS NOT NULL THEN 1 ELSE 0 END)=0)" % G
    ).fetchone()[0]

    print("=" * 66)
    print("ПОКРИТТЯ ГЛОСАМИ — дисплейні слова (слоти)")
    print("=" * 66)
    print("  слотів усього : %d" % total)
    print("  без глоса     : %d (%.3f%%)   бюджет: %d" % (empty, 100.0 * empty / total, BUDGET))

    worst = con.execute(
        "SELECT book_id,chapter,verse,COUNT(*) FROM (SELECT book_id,chapter,verse,slot FROM word "
        "GROUP BY 1,2,3,4 HAVING SUM(CASE WHEN %s IS NOT NULL THEN 1 ELSE 0 END)=0) "
        "GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 5" % G
    ).fetchall()
    if worst:
        print("\n  найгірші вірші:")
        for b, c, v, n in worst:
            print("     %s %d:%d — %d слів" % (b, c, v, n))

    print("\n  пастка H853 (суфіксні форми не мають отримати «—»):")
    trap_fail = []
    for b, c, v, slot, want, why in TRAPS:
        r = con.execute(
            "SELECT GROUP_CONCAT(%s,' ') FROM word WHERE book_id=? AND chapter=? "
            "AND verse=? AND slot=?" % G, (b, c, v, slot)).fetchone()
        got = (r[0] or "").strip()
        ok = got == want
        print("     %s %d:%d слот %-2d  «%s»  %s" % (b, c, v, slot, got, "✓" if ok else "✗ мало бути «%s» — %s" % (want, why)))
        if not ok:
            trap_fail.append((b, c, v, slot, want, got, why))

    con.close()
    print("=" * 66)
    if trap_fail:
        print("✗ ПАСТКА СПРАЦЮВАЛА — %d слотів змінили значення." % len(trap_fail))
        print("  Найімовірніша причина: стадію 1 (H853 → «—») підняли вище за")
        print("  ранній вихід у synthesize(). Див. bug-051, розділ «не баг».")
        return 1
    if empty > BUDGET:
        print("✗ ПОКРИТТЯ ПРОСІЛО: %d слотів без глоса проти бюджету %d." % (empty, BUDGET))
        print("  Або курація загубилась, або джерело змінилось.")
        return 1
    if empty < BUDGET:
        print("✓ Краще за бюджет (%d < %d). Опусти BUDGET у цьому файлі." % (empty, BUDGET))
        return 0
    print("✓ Покриття в межах бюджету, пастки цілі.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
