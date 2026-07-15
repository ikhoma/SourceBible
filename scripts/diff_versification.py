#!/usr/bin/env python3
"""
diff_versification.py — ADR-028 крок 5 (regression). READ-ONLY.

Порівнює НОВУ verse_org зі СТАРОЮ verse_map: скільки віршів змінюють показаний
іврит, якого типу ці зміни, і — головне — чи не ламається жоден з тих, що зараз
показуються ПРАВИЛЬНО.

Нічого не змінює. Пише data/versification_regression.tsv.

⛔ Тільки на Mac (APFS sparse). Обидві таблиці вже в БД (build_versification.py
   додав verse_org поряд, verse_map не чіпав).

Usage:
    python3 scripts/diff_versification.py [path/to/sourcebible.db]

──────────────────────────────────────────────────────────────────────────────
МОДЕЛЬ СТАРОЇ ПОВЕДІНКИ

  findBestMaculaVerse (ReaderViewModel) рівень 1 читав verse_map → macula_verse
  у ТІЙ САМІЙ главі; якщо рядка немає → identity (той самий номер, та сама глава).
  Рівні 2-3 — рантайм-евристика (Strong's-перевірка + перебір ±2), у БД не
  зберігаються; рівень 2 переважно лише підтверджує identity. Тому старий
  ЕФЕКТИВНИЙ показ добре наближається як:

      old_org = (chapter, verse_map[(tr,b,c,v)]  or  v)     # завжди та сама глава

  Крос-главний показ старій системі недоступний У ПРИНЦИПІ (повертала Int).

КАТЕГОРІЇ ЗМІН
  SAME                 old == new — без змін
  FIX_VERSE            та сама глава, інший вірш — виправлення номера
  FIX_CROSS_CHAPTER    інша глава — те, чого стара система НЕ вміла (1CH 6, RST псалми)
  NOW_NONE             new каже «оригіналу немає» (override) — old показував щось
  MERGED               new дає кілька org-віршів (N:M) — old показував один
  RISK_UNVERIFIED      зміна, але new verified=0 — єдина категорія на ручний огляд
"""

import os
import sqlite3
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = os.path.join(REPO, "data", "versification_regression.tsv")


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "sourcebible.db")
    if not os.path.exists(db_path):
        sys.exit("✗ БД не знайдено: %s" % db_path)

    con = sqlite3.connect(db_path)
    cur = con.cursor()

    # стара verse_map: (tr,book,ch,trans_verse) -> macula_verse (та сама глава)
    old = {}
    try:
        cur.execute("SELECT translation, book_id, chapter, trans_verse, macula_verse FROM verse_map")
        for tr, b, c, tv, mv in cur.fetchall():
            old[(tr, b, c, tv)] = mv
    except sqlite3.OperationalError:
        print("  (verse_map немає — стара система вважається чистою identity)")

    # нова verse_org, згрупована (N:M) → список org-рефів на кожен вірш перекладу
    cur.execute("""SELECT translation, book_id, chapter, verse,
                          org_book_id, org_chapter, org_verse, source, verified
                   FROM verse_org""")
    new = defaultdict(list)
    for tr, b, c, v, ob, oc, ov, src, ver in cur.fetchall():
        new[(tr, b, c, v)].append((ob, oc, ov, src, ver))

    print("=" * 66)
    print("  Regression diff: verse_org (нова) проти verse_map (стара)")
    print("=" * 66)

    rows = []
    per_tr = defaultdict(lambda: defaultdict(int))

    for key in sorted(new):
        tr, b, c, v = key
        refs = new[key]

        # НОВИЙ показ
        if len(refs) > 1:
            cat_multi = True
            # монотонно за org_verse
            new_disp = sorted((oc, ov) for (ob, oc, ov, s, ver) in refs if oc is not None)
            new_verified = all(ver for (_, _, _, _, ver) in refs)
            new_none = all(oc is None for (_, oc, _, _, _) in refs)
        else:
            cat_multi = False
            ob, oc, ov, s, ver = refs[0]
            new_disp = [] if oc is None else [(oc, ov)]
            new_verified = bool(ver)
            new_none = oc is None

        # СТАРИЙ показ: та сама глава, verse_map або identity
        old_mv = old.get(key, v)
        old_disp = (c, old_mv)

        # класифікація
        if new_none:
            cat = "NOW_NONE"
        elif cat_multi:
            cat = "MERGED"
        elif new_disp and new_disp[0] == old_disp:
            cat = "SAME"
        elif new_disp and new_disp[0][0] != old_disp[0]:
            cat = "FIX_CROSS_CHAPTER"
        elif new_disp:
            cat = "FIX_VERSE"
        else:
            cat = "SAME"

        # ризик: показ ЗМІНИВСЯ, а новий недоведений
        changed = (cat != "SAME")
        if changed and not new_verified and cat != "NOW_NONE":
            cat = "RISK_UNVERIFIED"

        per_tr[tr][cat] += 1

        if cat in ("FIX_CROSS_CHAPTER", "NOW_NONE", "MERGED", "RISK_UNVERIFIED"):
            new_str = "—" if new_none else " ".join("%d:%d" % (oc, ov) for oc, ov in new_disp)
            rows.append((cat, tr, "%s %d:%d" % (b, c, v),
                         "old %d:%d" % old_disp, "new %s" % new_str))

    order = ["SAME", "FIX_VERSE", "FIX_CROSS_CHAPTER", "MERGED", "NOW_NONE", "RISK_UNVERIFIED"]
    for tr in sorted(per_tr):
        d = per_tr[tr]
        total = sum(d.values())
        changed = total - d["SAME"]
        print("\n  %s   (%d віршів, %d змінюються)" % (tr, total, changed))
        for cat in order:
            if d[cat]:
                mark = "  ← НА ОГЛЯД" if cat == "RISK_UNVERIFIED" else ""
                print("    %-18s %6d%s" % (cat, d[cat], mark))

    # глобальний підсумок
    g = defaultdict(int)
    for tr in per_tr:
        for cat, n in per_tr[tr].items():
            g[cat] += n
    print("\n" + "─" * 66)
    print("  РАЗОМ по всіх перекладах:")
    print("    без змін (SAME):        %6d" % g["SAME"])
    print("    виправлень вірша:       %6d" % g["FIX_VERSE"])
    print("    виправлень КРОС-ГЛАВА:  %6d   ← стара система не вміла" % g["FIX_CROSS_CHAPTER"])
    print("    merged (N:M):           %6d" % g["MERGED"])
    print("    now-none:               %6d" % g["NOW_NONE"])
    print("    RISK_UNVERIFIED:        %6d   ← єдине, що на ручний огляд" % g["RISK_UNVERIFIED"])

    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("category\ttranslation\tref\told\tnew\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")
    print("\n  Звіт (усі зміни крос-глава / none / merged / risk): %s  (%d рядків)"
          % (REPORT, len(rows)))
    print("=" * 66)
    con.close()


if __name__ == "__main__":
    main()
