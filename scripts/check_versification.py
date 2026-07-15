#!/usr/bin/env python3
"""
check_versification.py — звірка verse_map з КАНОНІЧНИМ довідником версифікації.

READ-ONLY. Нічого не змінює. Пише один звіт: data/versification_audit.tsv

⛔ Запускати тільки на Mac — sourcebible.db це APFS sparse file, у Linux-sandbox
   він не читається (SQLITE_CORRUPT). Див. CLAUDE.md.

Використання:
    python3 scripts/check_versification.py [path/to/sourcebible.db]

──────────────────────────────────────────────────────────────────────────────
ЩО ЦЕ РОБИТЬ

Поточний verse_map будується евристикою (build_verse_map.py → align_chapter):
жадібний матчинг за перетином Strong's У МЕЖАХ ОДНІЄЇ ГЛАВИ. Два дефекти:

  1. Межа глави. Кандидати беруться лише з тієї ж глави Macula. Для KJV 1CH 6:5
     правильна відповідь — MT 5:31 — навіть не входить у набір кандидатів.
     Схема verse_map(translation, book_id, chapter, trans_verse, macula_verse)
     теж не має macula_chapter, тож записати таке нікуди.

  2. Немає порога. `best_overlap = -1`, тому будь-який вірш з перетином 0
     перемагає identity-фолбек. Коли збігу нема — алгоритм не відступає,
     а впевнено призначає перший вільний вірш.

Емпірично: застосунок для KJV 1CH 6:5 показує іврит Macula 6:36 (за 31 вірш).

Замість евристики є курований довідник — Paratext/UBS .vrs у JSON:
  eng.json  ENG → ORG   (KJV/ASV/BSB)
  rso.json  RSO → ORG   (синодальний = RST)
  org.json  сама ORG    (BHS = Macula)
MIT, Copenhagen Alliance.

Цей скрипт НІЧОГО не переписує. Він лише міряє, наскільки поточний verse_map
розходиться з довідником, щоб рішення про перебудову спиралось на цифру.

──────────────────────────────────────────────────────────────────────────────
ТРИ ПЕРЕВІРКИ

  A. VERSE-COUNT INVARIANT — кількість віршів у кожній главі БД проти maxVerses
     з довідника. Це формалізований масоретський підрахунок. Якщо не сходиться,
     то текст у БД не тієї версифікації, за яку ми його маємо, і все інше
     втрачає сенс. Перевіряється ДО мапінгу.

  B. MAPPING AGREEMENT — кожен рядок verse_map проти канонічного ENG→ORG:
       AGREE       збігається
       CONTRADICT  довідник каже інше  ← показує чужий вірш у застосунку
       SPURIOUS    довідник каже, що мапити не треба (identity)
       MISSING     довідник вимагає мапінг, а рядка нема
       UNREPRESENTABLE  правильна ціль в ІНШІЙ главі — схема це записати не може

  C. CROSS-CHAPTER SCOPE — скільки віршів узагалі потребують macula_chapter.
"""

import json
import os
import re
import sqlite3
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VRS_DIR = os.path.join(REPO, "data", "versification")
REPORT = os.path.join(REPO, "data", "versification_audit.tsv")

# translation id в БД -> файл довідника
TRANSLATION_SCHEME = {
    "KJV": "eng.json",
    "ASV": "eng.json",
    "NASB": "eng.json",
    "RST": "rso.json",
}

OT_BOOKS = {
    "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA",
    "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO",
    "ECC", "SNG", "ISA", "JER", "LAM", "EZK", "DAN", "HOS", "JOL", "AMO",
    "OBA", "JON", "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL",
}

REF_RE = re.compile(r"^([A-Z0-9]{3})\s+(\d+):(\d+)(?:-(\d+))?$")


def parse_ref_range(ref):
    """'1CH 6:1-15' -> ('1CH', 6, [1..15]);  'GEN 31:55' -> ('GEN', 31, [55])"""
    m = REF_RE.match(ref.strip())
    if not m:
        return None
    book, ch, v1 = m.group(1), int(m.group(2)), int(m.group(3))
    v2 = int(m.group(4)) if m.group(4) else v1
    return book, ch, list(range(v1, v2 + 1))


def load_mapping(path):
    """
    -> {(book, trans_chapter, trans_verse): (macula_chapter, macula_verse)}

    mappedVerses у довіднику: ключ = вірш ЦІЄЇ версифікації (напр. ENG),
    значення = вірш ORG. Діапазони розгортаються поелементно, по порядку.
    """
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    out = {}
    bad_ranges = []
    for src, dst in data.get("mappedVerses", {}).items():
        s = parse_ref_range(src)
        d = parse_ref_range(dst)
        if not s or not d:
            continue                       # напр. ESG 1:1a — літерні підвірші, не наш кейс
        sb, sc, svs = s
        db_, dc, dvs = d
        if sb not in OT_BOOKS or db_ not in OT_BOOKS:
            continue
        if len(svs) != len(dvs):
            bad_ranges.append((src, dst))  # довідник сам собі суперечить — не вгадуємо
            continue
        for sv, dv in zip(svs, dvs):
            out[(sb, sc, sv)] = (dc, dv)

    return out, data.get("maxVerses", {}), bad_ranges


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "sourcebible.db")
    if not os.path.exists(db_path):
        sys.exit("✗ БД не знайдено: %s" % db_path)
    if not os.path.isdir(VRS_DIR):
        sys.exit("✗ Немає %s\n  Завантаж eng.json / org.json / rso.json (див. docstring)."
                 % VRS_DIR)

    print("=" * 68)
    print("  Версифікація — звірка verse_map з канонічним довідником (UBS/Paratext)")
    print("=" * 68)

    con = sqlite3.connect(db_path)
    cur = con.cursor()
    rows = []

    # ─────────────────────────────────────────────────────────────────────
    # A. VERSE-COUNT INVARIANT
    # ─────────────────────────────────────────────────────────────────────
    print("\n[A] VERSE-COUNT INVARIANT (масоретський підрахунок як assert)")

    org_path = os.path.join(VRS_DIR, "org.json")
    if not os.path.exists(org_path):
        sys.exit("✗ Немає org.json")
    _, org_max, _ = load_mapping(org_path)

    cur.execute("""
        SELECT book_id, chapter, MAX(verse) FROM word
        WHERE language IN ('hbo') GROUP BY book_id, chapter
    """)
    macula_counts = {(r[0], r[1]): r[2] for r in cur.fetchall()}

    ok = bad = 0
    for (book, ch), n in sorted(macula_counts.items()):
        exp = org_max.get(book)
        if not exp or ch > len(exp):
            continue
        expected = int(exp[ch - 1])
        if n == expected:
            ok += 1
        else:
            bad += 1
            rows.append(("VERSE_COUNT", "MACULA", "%s %d" % (book, ch), "",
                         "у БД %d віршів, за org.vrs має бути %d" % (n, expected)))
    print("    Macula проти org.vrs:  %d глав збігаються, %d РОЗХОДЯТЬСЯ" % (ok, bad))
    if bad == 0:
        print("    ✓ Macula справді у версифікації ORG — можна довіряти як базі.")

    for tr, scheme in sorted(TRANSLATION_SCHEME.items()):
        p = os.path.join(VRS_DIR, scheme)
        if not os.path.exists(p):
            continue
        _, tmax, _ = load_mapping(p)
        cur.execute("""
            SELECT book_id, chapter, MAX(verse) FROM verse
            WHERE translation=? GROUP BY book_id, chapter
        """, (tr,))
        t_ok = t_bad = 0
        for book, ch, n in cur.fetchall():
            if book not in OT_BOOKS:
                continue
            exp = tmax.get(book)
            if not exp or ch > len(exp):
                continue
            expected = int(exp[ch - 1])
            if n == expected:
                t_ok += 1
            else:
                t_bad += 1
                rows.append(("VERSE_COUNT", tr, "%s %d" % (book, ch), "",
                             "у БД %d віршів, за %s має бути %d" % (n, scheme, expected)))
        flag = "✓" if t_bad == 0 else "⚠"
        print("    %s %-5s проти %-9s %d глав ок, %d розходяться"
              % (flag, tr, scheme, t_ok, t_bad))

    # ─────────────────────────────────────────────────────────────────────
    # B + C. MAPPING
    # ─────────────────────────────────────────────────────────────────────
    print("\n[B] MAPPING — поточний verse_map проти довідника")

    try:
        cur.execute("SELECT translation, book_id, chapter, trans_verse, macula_verse "
                    "FROM verse_map")
        vm_rows = cur.fetchall()
    except sqlite3.OperationalError:
        sys.exit("✗ Немає таблиці verse_map. Спершу: python3 build_verse_map.py sourcebible.db")

    current = {}
    for tr, book, ch, tv, mv in vm_rows:
        current[(tr, book, ch, tv)] = mv

    grand = defaultdict(int)
    for tr, scheme in sorted(TRANSLATION_SCHEME.items()):
        p = os.path.join(VRS_DIR, scheme)
        if not os.path.exists(p):
            continue
        canon, _, bad_ranges = load_mapping(p)
        for src, dst in bad_ranges:
            rows.append(("VRS_SELF_INCONSISTENT", tr, src, dst,
                         "довідник: довжини діапазонів не збігаються — пропущено"))

        cur.execute("SELECT DISTINCT book_id FROM verse WHERE translation=?", (tr,))
        have_books = {r[0] for r in cur.fetchall()}

        s = defaultdict(int)

        # чого вимагає довідник
        for (book, ch, tv), (mc, mv) in canon.items():
            if book not in have_books:
                continue
            cur_mv = current.get((tr, book, ch, tv))
            if mc != ch:
                s["unrepresentable"] += 1
                rows.append(("UNREPRESENTABLE", tr, "%s %d:%d" % (book, ch, tv),
                             "%s %d:%d" % (book, mc, mv),
                             "ціль в ІНШІЙ главі — схема verse_map не має macula_chapter"
                             + ("; зараз у БД -> вірш %s" % cur_mv if cur_mv else "; рядка нема")))
                continue
            if cur_mv is None:
                s["missing"] += 1
                rows.append(("MISSING", tr, "%s %d:%d" % (book, ch, tv),
                             "%s %d:%d" % (book, mc, mv), "довідник вимагає мапінг, рядка нема"))
            elif cur_mv == mv:
                s["agree"] += 1
            else:
                s["contradict"] += 1
                rows.append(("CONTRADICT", tr, "%s %d:%d" % (book, ch, tv),
                             "%s %d:%d" % (book, mc, mv),
                             "у БД -> вірш %d, довідник -> вірш %d" % (cur_mv, mv)))

        # що є в БД, чого довідник не просив
        for (t, book, ch, tv), mv in current.items():
            if t != tr or book not in OT_BOOKS:
                continue
            if (book, ch, tv) not in canon:
                s["spurious"] += 1
                rows.append(("SPURIOUS", tr, "%s %d:%d" % (book, ch, tv), "",
                             "у БД -> вірш %d, довідник мапінгу не вимагає (має бути identity)" % mv))

        tot_bad = s["contradict"] + s["spurious"] + s["missing"] + s["unrepresentable"]
        print("\n    %s (%s)" % (tr, scheme))
        print("      AGREE            %6d" % s["agree"])
        print("      CONTRADICT       %6d   ← показує ЧУЖИЙ вірш" % s["contradict"])
        print("      SPURIOUS         %6d   ← мапить те, що мапити не треба" % s["spurious"])
        print("      MISSING          %6d   ← мапінг потрібен, але його нема" % s["missing"])
        print("      UNREPRESENTABLE  %6d   ← інша глава: схему треба міняти" % s["unrepresentable"])
        print("      ─ разом хибних:  %6d" % tot_bad)
        for k in s:
            grand[k] += s[k]

    print("\n[C] ПІДСУМОК")
    print("    рядків verse_map у БД:       %6d" % len(vm_rows))
    print("    підтверджено довідником:     %6d" % grand["agree"])
    print("    ХИБНИХ (усі переклади):      %6d"
          % (grand["contradict"] + grand["spurious"] + grand["missing"] + grand["unrepresentable"]))
    print("    з них потребують macula_chapter: %6d" % grand["unrepresentable"])

    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("type\ttranslation\tref\tcanonical\tdetail\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")
    print("\n    Звіт: %s  (%d рядків)" % (REPORT, len(rows)))
    print("=" * 68)

    con.close()


if __name__ == "__main__":
    main()
