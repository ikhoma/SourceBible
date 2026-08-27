#!/usr/bin/env python3
"""
audit_versification.py — незалежний аудит таблиці verse_org (ADR-028).

Навіщо окремо від build_versification.py: там поле `verified` ставить ТОЙ САМИЙ
код, що будує мапінг. Самозвіт не є доказом. Цей скрипт читає ГОТОВУ verse_org і
перевіряє її ззовні, нічого не знаючи про схеми й довідники.

⛔ READ-ONLY. Відкриває базу в режимі ro+immutable. Нічого не пише.
⛔ Python: без синтаксису 3.10+ (сумісність із rebuild.sh).

Оракули
───────
A1 TARGET-MISSING   мапінг вказує на org-вірш, якого в Macula не існує.
                    Легітимний випадок — вірші Textus Receptus, відсутні в
                    критичному тексті (MRK 9:44, ACT 8:37…). Легалізуються
                    рядком `org_* = "-"` в overrides.tsv, після чого org_verse
                    у базі NULL і A1 більше не спрацьовує.

A2 NEIGHBOUR-BETTER сусідній org-вірш (±3 у тій самій главі) дає СУТТЄВО кращий
                    перетин Strong's, ніж призначена ціль → мапінг зсунуто.
                    Рахуємо ТІЛЬКИ по рідкісних Strong's: збіг по בן/ילד/את
                    у генеалогіях нічого не доводить (та сама сліпа пляма, що
                    описана в шапці build_versification.py).

A3 UBIO-vs-RST      UBIO не має тегів Стронга взагалі → A2 для нього неможливий.
                    Проксі: у главах з ІДЕНТИЧНОЮ кількістю віршів мапінги UBIO і RST
                    зазвичай збігаються, тож розбіжність варта погляду.

                    ⚠️ КАЛІБРУВАННЯ 2026-08-26: точність проксі поки НУЛЬОВА — 10
                    спрацювань, 10 хибних. Пс 89:2-6 (UBIO обʼєднує надписання з
                    першим рядком, RST ні) і EST 1:7 / MAT 21:29-30 / PHP 1:16-17 /
                    REV 20:7-8, де Огієнко йде за КРИТИЧНИМ текстом, а Синодальний
                    за Textus Receptus. «Спільна текстова традиція» виявилась
                    хибним припущенням саме в НЗ.

                    Тому A3 — це ПИТАННЯ, а не звинувачення: розбіжність вимагає
                    пояснення, і майже завжди пояснення знаходиться в тексті UBIO.
                    Перевіряти послівно проти оригіналу, НЕ переносити рішення з RST.

Покриття теж друкується: скільки віршів узагалі не має жодного оракула.
Це не помилка, це чесно названа сліпа пляма.

Exit 0 — чисто. Exit 1 — є знахідки (годиться як гейт у rebuild.sh).

Usage:
    python3 scripts/audit_versification.py [path/to/sourcebible.db] [--tsv out.tsv]
"""

import os
import re
import sqlite3
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Ті самі константи, що в build_versification.py. Свідомо продубльовані, а не
# імпортовані: аудит має лишатись робочим, навіть якщо білдер зламано.
OT_BOOKS = set("""GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST
JOB PSA PRO ECC SNG ISA JER LAM EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL""".split())

COMMON_STRONGS = {
    "H1121", "H3205", "H853", "H1", "H559", "H1961", "H3068", "H430",
    "H3478", "H4428", "H3605", "H5921",
    "G2532", "G3588", "G846", "G1722", "G1519", "G3004", "G2316", "G2424",
    "G1161", "G3956", "G2962", "G5100",
}

# Скільки рідкісних тегів мінімально потрібно, щоб висновок щось означав.
MIN_RARE = 2
# Наскільки сусід має бути кращим, щоб це був сигнал, а не шум.
MARGIN = 0.25
# Нижче цього перетину призначена ціль вважається слабкою.
WEAK = 0.50
# Радіус пошуку сусіда всередині глави.
RADIUS = 3

TAG_RE = re.compile(r"<S>\s*[GH]?\s*(\d+[a-z]?)\s*</S>", re.IGNORECASE)

OVERRIDES = os.path.join(REPO, "data", "versification", "overrides.tsv")


def load_signed():
    """Ключі з overrides.tsv = місця, які людина вже подивилась і підписала.

    Підпис буває двох видів і обидва легальні:
      • виправлення  — рядок вказує ІНШУ ціль;
      • «лишаємо»    — рядок вказує ТУ САМУ ціль з поясненням, чому оракул
                       помиляється (тег-дрейф модуля, надто короткий оригінал,
                       вірш перекладу накриває два оригінали…).
    В обох випадках аудит більше не піднімає це місце: рішення вже ухвалене.
    """
    signed = set()
    if not os.path.exists(OVERRIDES):
        return signed
    fh = open(OVERRIDES, encoding="utf-8")
    for ln in fh:
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#") or ln.lower().startswith("translation\t"):
            continue
        p = ln.split("\t")
        if len(p) < 7:
            continue
        try:
            signed.add((p[0], p[1], int(p[2]), int(p[3])))
        except ValueError:
            continue
    fh.close()
    return signed


def testament_prefix(book):
    return "H" if book in OT_BOOKS else "G"


def basenum(sid):
    if not sid:
        return ""
    return re.sub(r"[a-z]+$", "", "".join(ch for ch in sid if ch.isdigit()))


def tags_of(raw_text, prefix):
    out = set()
    for n in TAG_RE.findall(raw_text or ""):
        bn = basenum(n)
        if bn:
            out.add(prefix + bn)
    return out


def load_macula(con):
    """(book, chapter, verse) -> set префіксованих Strong's."""
    macula = defaultdict(set)
    rows = con.execute(
        "SELECT book_id, chapter, verse, strongs_id FROM word WHERE strongs_id IS NOT NULL"
    ).fetchall()
    for b, c, v, sid in rows:
        bn = basenum(sid)
        if bn:
            macula[(b, c, v)].add(testament_prefix(b) + bn)
    return macula


def coverage(t_rare, org_key, macula):
    """Частка рідкісних тегів перекладу, покритих оригінальним віршем."""
    o = macula.get(org_key)
    if not o:
        return 0.0
    return len(t_rare & (o - COMMON_STRONGS)) / float(len(t_rare))


class Finding(object):
    def __init__(self, kind, tr, ref, mapped, detail):
        self.kind = kind
        self.tr = tr
        self.ref = ref
        self.mapped = mapped
        self.detail = detail

    def row(self):
        return "\t".join([self.kind, self.tr, self.ref, self.mapped, self.detail])


def audit_translation(con, tr, macula, signed):
    findings = []
    stats = defaultdict(int)
    claimed = set()
    for ob_, oc_, ov_ in con.execute(
            "SELECT org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation = ? AND org_verse IS NOT NULL", (tr,)).fetchall():
        claimed.add((ob_, oc_, ov_))

    rows = con.execute(
        "SELECT v.book_id, v.chapter, v.verse, v.text, "
        "       o.org_book_id, o.org_chapter, o.org_verse, o.source "
        "FROM verse v JOIN verse_org o "
        "  ON o.translation = v.translation AND o.book_id = v.book_id "
        " AND o.chapter = v.chapter AND o.verse = v.verse "
        "WHERE v.translation = ?", (tr,)
    ).fetchall()

    for b, c, v, text, ob, oc, ov, source in rows:
        ref = "%s %d:%d" % (b, c, v)
        stats["total"] += 1

        if (tr, b, c, v) in signed:
            stats["підписано в overrides.tsv"] += 1
            continue

        # Явно задекларована відсутність оригіналу — рішення людини, не помилка.
        if ov is None or oc is None or ob is None:
            stats["no-original (свідомо)"] += 1
            continue

        # A1 — ціль не існує в Macula.
        if (ob, oc, ov) not in macula:
            stats["A1"] += 1
            findings.append(Finding(
                "A1-TARGET-MISSING", tr, ref, "%s %d:%d" % (ob, oc, ov),
                "цілі немає в Macula; якщо це вірш TR — легалізуй рядком org_*='-'"))
            continue

        tags = tags_of(text, testament_prefix(ob))
        rare = tags - COMMON_STRONGS
        if len(rare) < MIN_RARE:
            stats["без оракула (мало рідкісних тегів)"] += 1
            continue

        base = coverage(rare, (ob, oc, ov), macula)
        best_score, best_v = base, ov
        for d in range(-RADIUS, RADIUS + 1):
            if d == 0:
                continue
            sc = coverage(rare, (ob, oc, ov + d), macula)
            if sc > best_score:
                best_score, best_v = sc, ov + d

        stats["перевірено O2"] += 1
        if best_v != ov and (best_score - base) >= MARGIN and base < WEAK:
            stats["A2"] += 1
            union = coverage(rare, (ob, oc, ov), macula)  # плейсхолдер, перерахуємо нижче
            o1 = macula.get((ob, oc, ov), set()) - COMMON_STRONGS
            o2 = macula.get((ob, oc, best_v), set()) - COMMON_STRONGS
            union = len(rare & (o1 | o2)) / float(len(rare))
            kind = "ЗСУВ" if (ob, oc, best_v) in claimed else "НАКРИВАЄ-ДВА"
            findings.append(Finding(
                "A2-NEIGHBOUR-BETTER", tr, ref, "%s %d:%d" % (ob, oc, ov),
                "%s: перетин %.2f, %s %d:%d дає %.2f, разом %.2f (source=%s)"
                % (kind, base, ob, oc, best_v, best_score, union, source)))
        elif base >= 0.70:
            stats["збіг >=70%"] += 1
        elif base >= 0.40:
            stats["збіг 40-70%"] += 1
        else:
            stats["збіг <40% (сусід не кращий)"] += 1

    return findings, stats


def audit_ubio_vs_rst(con, signed):
    """A3 — UBIO не має тегів; звіряємо з RST там, де глави однакової довжини."""
    findings = []
    stats = defaultdict(int)

    def counts(tr):
        return dict(((b, c), n) for b, c, n in con.execute(
            "SELECT book_id, chapter, MAX(verse) FROM verse "
            "WHERE translation = ? GROUP BY book_id, chapter", (tr,)).fetchall())

    def mapping(tr):
        return dict(((b, c, v), (ob, oc, ov)) for b, c, v, ob, oc, ov in con.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse "
            "FROM verse_org WHERE translation = ?", (tr,)).fetchall())

    cu, cr = counts("UBIO"), counts("RST")
    mu, mr = mapping("UBIO"), mapping("RST")

    for key, tu in sorted(mu.items()):
        b, c, v = key
        if ("UBIO", b, c, v) in signed:
            stats["підписано в overrides.tsv"] += 1
            continue
        if (b, c) not in cr or cu.get((b, c)) != cr.get((b, c)):
            stats["непорівнянно (різна довжина глави)"] += 1
            continue
        tr_ = mr.get(key)
        if tr_ is None:
            stats["непорівнянно (немає в RST)"] += 1
            continue
        if tu == tr_:
            stats["збіг з RST"] += 1
        else:
            stats["A3"] += 1
            findings.append(Finding(
                "A3-UBIO-DIFFERS-FROM-RST", "UBIO", "%s %d:%d" % (b, c, v),
                "%s" % (tu,), "RST для того самого вірша дає %s" % (tr_,)))
    return findings, stats


def main():
    args = [a for a in sys.argv[1:]]
    tsv_out = None
    if "--tsv" in args:
        i = args.index("--tsv")
        tsv_out = args[i + 1]
        del args[i:i + 2]
    db_path = args[0] if args else os.path.join(REPO, "sourcebible.db")

    if not os.path.exists(db_path):
        sys.stderr.write("✗ немає бази: %s\n" % db_path)
        return 2

    con = sqlite3.connect("file:%s?mode=ro&immutable=1" % db_path, uri=True)
    macula = load_macula(con)
    signed = load_signed()

    print("=" * 74)
    print("АУДИТ ВЕРСИФІКАЦІЇ — verse_org проти Macula (ADR-028)")
    print("база: %s   оригінальних віршів у Macula: %d" % (db_path, len(macula)))
    print("=" * 74)

    all_findings = []
    translations = [r[0] for r in con.execute(
        "SELECT DISTINCT translation FROM verse_org ORDER BY translation").fetchall()]

    for tr in translations:
        f, st = audit_translation(con, tr, macula, signed)
        all_findings.extend(f)
        checked = st.get("перевірено O2", 0)
        print("\n▸ %s — %d віршів" % (tr, st["total"]))
        if checked:
            for k in ("збіг >=70%", "збіг 40-70%", "збіг <40% (сусід не кращий)"):
                print("    %-32s %6d  (%.2f%%)"
                      % (k, st[k], 100.0 * st[k] / checked))
        else:
            print("    O2 неможливий: у цьому перекладі немає тегів Стронга")
        for k in ("без оракула (мало рідкісних тегів)", "no-original (свідомо)",
                  "підписано в overrides.tsv"):
            if st[k]:
                print("    %-32s %6d" % (k, st[k]))
        print("    %-32s %6d" % ("⛔ A1 ціль не існує", st["A1"]))
        print("    %-32s %6d" % ("⛔ A2 сусід явно кращий", st["A2"]))

    f3, st3 = audit_ubio_vs_rst(con, signed)
    all_findings.extend(f3)
    print("\n▸ UBIO ↔ RST (A3)")
    for k in sorted(st3):
        print("    %-32s %6d" % (k, st3[k]))

    con.close()

    print("\n" + "=" * 74)
    if not all_findings:
        print("✓ ЧИСТО — жодної знахідки.")
        print("=" * 74)
        return 0

    by_kind = defaultdict(int)
    for f in all_findings:
        by_kind[f.kind] += 1
    print("⛔ ЗНАХІДОК: %d" % len(all_findings))
    for k in sorted(by_kind):
        print("    %-28s %d" % (k, by_kind[k]))
    print("=" * 74)
    for f in all_findings:
        print("  [%s] %s %-12s → %-14s %s" % (f.kind[:2], f.tr, f.ref, f.mapped, f.detail))

    if tsv_out:
        with open(tsv_out, "w", encoding="utf-8") as fh:
            fh.write("kind\ttranslation\tref\tmapped\tdetail\n")
            for f in all_findings:
                fh.write(f.row() + "\n")
        print("\n→ %s" % tsv_out)

    print("\nКожна знахідка закривається рядком у data/versification/overrides.tsv:")
    print("  • інша ціль            — виправлення;")
    print("  • та сама ціль + reason — «подивився, лишаємо» (оракул помиляється);")
    print("  • org_* = \"-\"          — оригіналу не існує (вірш Textus Receptus).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
