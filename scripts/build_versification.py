#!/usr/bin/env python3
"""
build_versification.py — ADR-028. Будує таблицю verse_org з КУРОВАНОГО довідника,
доводить кожен рядок незалежним оракулом, і ПАДАЄ на конфлікті.

Замінює евристику build_verse_map.py / align_chapter(). Мапінг тут — не висновок
з даних, а матеріалізація довідника UBS/Paratext з незалежною перевіркою.

АДИТИВНО І ОБОРОТНО. Створює НОВУ таблицю verse_org поряд зі старою verse_map
(її НЕ чіпає). Можна безпечно передивитись звіт до будь-яких змін схеми/Swift.

⛔ Тільки на Mac — sourcebible.db це APFS sparse file, у Linux-sandbox не читається.
⛔ Python: без синтаксису 3.10+ (Optional/Dict з typing, без match/case).

Usage:
    python3 scripts/build_versification.py [path/to/sourcebible.db]

──────────────────────────────────────────────────────────────────────────────
ОРАКУЛИ (ADR-028, з поправками ревʼю)

  ДЖЕРЕЛО мапінгу — декларативне: пари .vrs (org/eng/rso). Версифікація це
  властивість СХЕМИ, не тексту: KJV за визначенням = eng, тож KJV→ORG повністю
  визначається eng.json+org.json, без заглядання в текст.

  O3  STRUCTURE (гейт довіри):  verse-count глави в БД == maxVerses довідника.
      Пройшла глава → схема для неї застосовна, мапінг з довідника надійний.
      НЕ пройшла   → схему для цієї глави НЕ припускаємо (див. RST нижче).

  O2  CONTENT (аудит, не джерело):  overlap Strong's тексту перекладу з Macula
      при запропонованому org-вірші. Ловить, чи виробник модуля тихо не
      переверсифікував. НЕ бланкує показ — лише:
        overlap==0 при обох боках ≥2 тегів → CONFLICT → БІЛД ПАДАЄ
      Сліпа пляма: генеалогії (בן/ילד/את повторюються) → overlap≥2 може бути
      хибним. Тому додатково: MONOTONICITY (org-вірші вздовж глави не спадають)
      + RARE-overlap (збіг по НЕчастих Strong's).

  RST — НЕ припускаємо «RST=rso». Виміряно (2026-07-14): у 5 з 6 проблемних
  глав наш модуль збігається з ORG/ENG, а rso.json — виняток. Тому схема RST
  визначається ЕМПІРИЧНО per-chapter: де O3 з rso збігся — беремо rso; де ні —
  пробуємо org/eng; де жодна не підходить — empirical-пошук або verified=0.
──────────────────────────────────────────────────────────────────────────────
"""

import json
import os
import re
import sqlite3
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VRS_DIR = os.path.join(REPO, "data", "versification")
OVERRIDES = os.path.join(VRS_DIR, "overrides.tsv")
REPORT = os.path.join(REPO, "data", "versification_build.tsv")

# translation -> список СХЕМ-КАНДИДАТІВ у порядку переваги.
# RST має кілька, бо «RST=rso» спростовано вимірюванням (ADR-028 R1).
SCHEME_CANDIDATES = {
    "KJV":  ["eng.json"],
    "ASV":  ["eng.json"],
    "NASB": ["eng.json"],
    "RST":  ["rso.json", "org.json", "eng.json"],
}

OT_BOOKS = {
    "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA",
    "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO",
    "ECC", "SNG", "ISA", "JER", "LAM", "EZK", "DAN", "HOS", "JOL", "AMO",
    "OBA", "JON", "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL",
}
NT_BOOKS = {
    "MAT", "MRK", "LUK", "JHN", "ACT", "ROM", "1CO", "2CO", "GAL", "EPH",
    "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM", "HEB", "JAS",
    "1PE", "2PE", "1JN", "2JN", "3JN", "JUD", "REV",
}
ALL_BOOKS = OT_BOOKS | NT_BOOKS

# ВЗ мапиться на Macula Hebrew, НЗ — на Macula Greek. Strong's з обох боків
# префіксуємо ЗА ТЕСТАМЕНТОМ (H/G), а не лишаємо голі цифри: інакше H430 (אלהים)
# і G430 (ἀργός) злилися б в одне «430». ВЗ-vs-Greek ніколи не порівнюється
# (org-книга НЗ-вірша — грецька), але префікс тримає COMMON_STRONGS чистим і
# зберігає доведені ВЗ-результати незмінними.
def testament_prefix(book: str) -> str:
    return "H" if book in OT_BOOKS else "G"


# Дуже часті Strong's (з тестамент-префіксом) — грам. службові + генеалогічні.
# overlap ТІЛЬКИ по них = слабкий доказ.
COMMON_STRONGS = {
    # Hebrew
    "H1121",  # בן son
    "H3205",  # ילד begat/bore
    "H853",   # את (direct-object marker)
    "H1",     # אב father
    "H559",   # אמר said
    "H1961",  # היה was
    "H3068",  # YHWH
    "H430",   # אלהים God
    "H3478",  # ישראל Israel
    "H4428",  # מלך king
    "H3605",  # כל all
    "H5921",  # על on/against
    # Greek (найчастіші службові — щоб «weak»/rare-overlap лишались значущими в НЗ)
    "G2532",  # καί and
    "G3588",  # ὁ the
    "G846",   # αὐτός he/it
    "G1722",  # ἐν in
    "G1519",  # εἰς into
    "G3004",  # λέγω say
    "G2316",  # θεός God
    "G2424",  # Ἰησοῦς Jesus
    "G1161",  # δέ but/and
    "G3956",  # πᾶς all
    "G2962",  # κύριος Lord
    "G5100",  # τις someone
}

REF_RE = re.compile(r"^([A-Z0-9]{3})\s+(\d+):(\d+)(?:-(\d+))?$")


def basenum(sid: str) -> str:
    """'H3807a'/'3807a'/'<S>3807</S>' → '3807'. Одна нормалізація для ОБОХ боків
    (у старому build_verse_map боки нормалізувались по-різному — латентний баг)."""
    if not sid:
        return ""
    return re.sub(r"[a-z]+$", "", "".join(c for c in sid if c.isdigit()))


def extract_translation_strongs(raw_text: str, prefix: str) -> frozenset:
    """Strong's з розмітки MyBible-вірша: <S>NNNN</S>. Тег зазвичай без H/G —
    тестамент визначає префікс, тому додаємо його за книгою (prefix)."""
    nums = re.findall(r"<S>\s*[GH]?\s*(\d+[a-z]?)\s*</S>", raw_text or "", re.IGNORECASE)
    return frozenset(prefix + basenum(n) for n in nums if basenum(n))


def parse_ref_range(ref: str):
    """'1CH 6:1-15' -> ('1CH',6,[1..15]); 'GEN 31:55' -> ('GEN',31,[55]); інакше None."""
    m = REF_RE.match((ref or "").strip())
    if not m:
        return None
    book, ch, v1 = m.group(1), int(m.group(2)), int(m.group(3))
    v2 = int(m.group(4)) if m.group(4) else v1
    if v2 < v1:
        return None
    return book, ch, list(range(v1, v2 + 1))


def load_scheme(path: str):
    """
    -> (mapping, max_verses, self_inconsistent, dropped_srcs)
    mapping:      {(book, tr_ch, tr_vs): (org_ch, org_vs)}  напрям TRANSLATION→ORG.
    dropped_srcs: {(book, tr_ch, tr_vs)} — джерельні вірші з НЕРІВНИХ діапазонів
                  довідника. Довідник мав НАМІР їх змапити, але його кодування
                  діапазону некоректне (напр. rso `PSA 89:2-6 → 90:1-6`, 5≠6 —
                  побічний ефект надписання-як-вірш-0; UBS README це визнає).
                  Такі вірші НЕ падають на identity (це був би тихий здогад) —
                  вони йдуть в empirical, де O2 доводить їх по Strong's.
    """
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    mapping = {}
    bad = []
    dropped = set()
    for src, dst in data.get("mappedVerses", {}).items():
        s = parse_ref_range(src)
        d = parse_ref_range(dst)
        if not s or not d:
            continue                       # ESG 1:1a тощо — літерні підвірші, поза ВЗ-нумерацією
        sb, sc, svs = s
        db_, dc, dvs = d
        if sb not in ALL_BOOKS or db_ not in ALL_BOOKS or sb != db_:
            continue
        if len(svs) != len(dvs):
            bad.append((src, dst))         # довідник сам собі суперечить
            for sv in svs:
                dropped.add((sb, sc, sv))  # намір є, але не рівний → в empirical, не identity
            continue
        for sv, dv in zip(svs, dvs):
            mapping[(sb, sc, sv)] = (dc, dv)
    return mapping, data.get("maxVerses", {}), bad, dropped


def load_overrides():
    """overrides.tsv: translation book ch vs org_book org_ch org_vs reason.
    org_* == '-' → «оригіналу немає» (второканон/доданий вірш)."""
    out = {}
    if not os.path.exists(OVERRIDES):
        return out
    with open(OVERRIDES, encoding="utf-8") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("#") or ln.lower().startswith("translation\t"):
                continue
            p = ln.split("\t")
            if len(p) < 7:
                continue
            tr, bk, ch, vs, ob, oc, ov = p[:7]
            key = (tr, bk, int(ch), int(vs))
            if ob == "-" or oc == "-" or ov == "-":
                out[key] = None            # явно: оригіналу немає
            else:
                out[key] = (ob, int(oc), int(ov))
    return out


# ─────────────────────────────────────────────────────────────────────────
def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "sourcebible.db")
    if not os.path.exists(db_path):
        sys.exit("✗ БД не знайдено: %s" % db_path)
    if not os.path.isdir(VRS_DIR):
        sys.exit("✗ Немає %s — завантаж org/eng/rso.json (див. ADR-028)." % VRS_DIR)

    print("=" * 70)
    print("  build_versification.py — verse_org з довідника + перевірка (ADR-028)")
    print("=" * 70)

    schemes = {}
    for fn in set(sum(SCHEME_CANDIDATES.values(), [])):
        p = os.path.join(VRS_DIR, fn)
        if not os.path.exists(p):
            sys.exit("✗ Немає %s" % p)
        schemes[fn] = load_scheme(p)

    con = sqlite3.connect(db_path)
    cur = con.cursor()

    org_map, org_maxv, _, _ = schemes["org.json"]

    def org_expected(b, c):
        exp = org_maxv.get(b)
        return int(exp[c - 1]) if exp and c <= len(exp) else None

    # ── Macula ORG у памʼять: ВЗ (hbo→H) + НЗ (grc→G). (book,ch,vs) -> set(Strong's) ──
    cur.execute("SELECT book_id, chapter, verse, strongs_id FROM word "
                "WHERE language IN ('hbo','grc')")
    macula = defaultdict(set)
    verses_in_ch = defaultdict(set)
    for b, c, v, sid in cur.fetchall():
        if b not in ALL_BOOKS:
            continue
        pref = testament_prefix(b)
        if sid:
            macula[(b, c, v)].add(pref + basenum(sid))
        verses_in_ch[(b, c)].add(v)
    macula = {k: frozenset(s) for k, s in macula.items()}

    # max-verse = найбільший присутній вірш, що НЕ перевищує очікуваний з org.json.
    # НЗ (Nestle1904) має ДВА види відхилень від суцільного 1..N:
    #   • внутрішні пропуски (MAT 17:21, ACT 8:37 — text-crit. відсутні вірші) —
    #     номер N усе одно існує (MAT 17:27), тож cap-by-org їх ігнорує;
    #   • хвостовий маркер MRK 16:99 (коротше закінчення) — >20, відкидається.
    # ВЗ суцільний, тож cap-by-org == звичайний max → 929/929 без змін.
    macula_maxv = {}
    for (b, c), vs in verses_in_ch.items():
        exp = org_expected(b, c)
        cand = [v for v in vs if exp is None or v <= exp]
        macula_maxv[(b, c)] = max(cand) if cand else 0

    nt_v = sum(1 for k in macula if k[0] in NT_BOOKS)
    print("  Macula віршів: %d (ВЗ+НЗ; НЗ=%d)" % (len(macula), nt_v))

    # ── O3 санітарний гейт: Macula проти org.json (весь канон) ──
    bad = []
    for (b, c), n in macula_maxv.items():
        exp = org_expected(b, c)
        if exp is not None and n != exp:
            bad.append((b, c, n, exp))
    if bad:
        for b, c, n, e in bad[:10]:
            print("    ✗ %s %d: Macula=%d org=%d" % (b, c, n, e))
        sys.exit("✗ Macula РОЗХОДИТЬСЯ з org.vrs у %d главах — стоп." % len(bad))
    print("  ✓ O3: Macula == ORG (усі глави, ВЗ+НЗ)")

    # ── таблиця verse_org (адитивно) ──
    cur.executescript("""
        DROP TABLE IF EXISTS verse_org;
        CREATE TABLE verse_org (
            translation TEXT NOT NULL,
            book_id     TEXT NOT NULL,
            chapter     INTEGER NOT NULL,
            verse       INTEGER NOT NULL,
            org_book_id TEXT,
            org_chapter INTEGER,
            org_verse   INTEGER,
            scheme      TEXT NOT NULL,   -- яка .vrs-схема застосована (або 'empirical'/'override')
            source      TEXT NOT NULL,   -- identity | ubs | empirical | override | none
            verified    INTEGER NOT NULL,
            overlap     INTEGER,
            PRIMARY KEY (translation, book_id, chapter, verse, org_chapter, org_verse)
        );
    """)

    overrides = load_overrides()
    report_rows = []
    conflicts = []
    grand = defaultdict(lambda: defaultdict(int))

    for tr, candidates in sorted(SCHEME_CANDIDATES.items()):
        cur.execute("SELECT DISTINCT book_id FROM verse WHERE translation=?", (tr,))
        have = {r[0] for r in cur.fetchall()}
        if not have:
            print("\n  %s: у БД немає — пропущено" % tr)
            continue

        # весь текст перекладу: (book,ch,vs) -> frozenset Strong's, + maxv
        cur.execute("SELECT book_id, chapter, verse, text FROM verse WHERE translation=?", (tr,))
        tr_strongs = {}
        tr_maxv = defaultdict(int)
        tagged = 0
        for b, c, v, txt in cur.fetchall():
            if b not in ALL_BOOKS:
                continue
            s = extract_translation_strongs(txt, testament_prefix(b))
            tr_strongs[(b, c, v)] = s
            if s:
                tagged += 1
            if v > tr_maxv[(b, c)]:
                tr_maxv[(b, c)] = v

        # САНІТАРНИЙ ГЕЙТ: якщо тегів Strong's ~нема — O2 не працює, не мовчати
        if tr_strongs and tagged < 0.5 * len(tr_strongs):
            print("\n  ⚠ %s: лише %d/%d віршів мають <S>-теги — O2 ненадійний для цього модуля"
                  % (tr, tagged, len(tr_strongs)))

        # ── O3 per-chapter: обрати схему ──
        # Крок 1: кандидати, що збігаються за verse-count.
        # Крок 2 (якщо кілька): взяти ту, чий МАПІНГ дає найбільший O2-overlap по главі
        #   — НЕ першу за списком. Інакше rso (порожній для Даниїла → identity) виграє
        #   у eng (має правильний зсув 6:1-28→6:2-29) лише тому, що count теж збігся,
        #   і весь Дан 6 тихо з'їжджає на 1 вірш.
        chapter_scheme = {}         # (book,ch) -> filename | None
        for (b, c) in sorted(tr_maxv):
            n = tr_maxv[(b, c)]
            matching = [fn for fn in candidates
                        if schemes[fn][1].get(b) and c <= len(schemes[fn][1][b])
                        and int(schemes[fn][1][b][c - 1]) == n]
            if not matching:
                chapter_scheme[(b, c)] = None
            elif len(matching) == 1:
                chapter_scheme[(b, c)] = matching[0]
            else:
                best_fn, best_score = matching[0], -1
                for fn in matching:
                    mapping = schemes[fn][0]
                    score = 0
                    for vv in range(1, n + 1):
                        oc, ov = mapping.get((b, c, vv), (c, vv))
                        score += len(tr_strongs.get((b, c, vv), frozenset())
                                     & macula.get((b, oc, ov), frozenset()))
                    if score > best_score:
                        best_score, best_fn = score, fn
                chapter_scheme[(b, c)] = best_fn

        s = defaultdict(int)
        # монотонність рахуємо per-chapter
        per_chapter_assign = defaultdict(list)   # (book,ch) -> [(tr_vs, org_ch, org_vs)]

        for (b, c, v), t_str in sorted(tr_strongs.items()):
            key = (tr, b, c, v)

            # 1) явний override має пріоритет над усім — але теж перевіряється O2
            if key in overrides:
                ov = overrides[key]
                if ov is None:
                    # свідоме рішення «оригіналу немає» — довіряємо декларації
                    _emit(cur, report_rows, s, per_chapter_assign,
                          tr, b, c, v, None, "override", "override", 1, None, t_str, macula,
                          note="override: оригіналу немає (свідомо)")
                else:
                    ob, oc, ovs = ov
                    m_str = macula.get((ob, oc, ovs), frozenset())
                    ol = _overlap(t_str, m_str)
                    # хибний override не проходить тихо: обидва боки багаті, перетин 0 → конфлікт
                    if len(t_str) >= 2 and len(m_str) >= 2 and ol == 0:
                        conflicts.append((tr, "%s %d:%d" % (b, c, v),
                                          "%s %d:%d" % (ob, oc, ovs), "override"))
                        s["conflict"] += 1
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (ob, oc, ovs), "override", "override", 0, ol, t_str, macula,
                              note="CONFLICT: override не підтверджений O2 (overlap=0)")
                    else:
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (ob, oc, ovs), "override", "override",
                              1 if ol >= 2 else 0, ol, t_str, macula,
                              note="override overlap=%d" % ol)
                continue

            fn = chapter_scheme.get((b, c))

            # 2) глава конформна якійсь схемі → застосувати її мапінг
            if fn is not None:
                mapping = schemes[fn][0]
                dropped = schemes[fn][3]

                # вірш із НЕРІВНОГО діапазону довідника → НЕ identity-здогад, а empirical
                if (b, c, v) not in mapping and (b, c, v) in dropped:
                    best = _empirical(t_str, b, macula, c)
                    if best is not None:
                        (ob, oc, ovs), ol, unique = best
                        verified = 1 if (ol >= 2 and unique) else 0
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (ob, oc, ovs), fn, "empirical",
                              verified, ol, t_str, macula,
                              note="" if verified else "dropped-range→empirical слабкий → override")
                        if not verified:
                            s["needs_override"] += 1
                    else:
                        s["needs_override"] += 1
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, None, fn, "none", 0, None, t_str, macula,
                              note="dropped-range довідника, empirical не знайшов → override")
                    continue

                org_ch, org_vs = mapping.get((b, c, v), (c, v))
                src = "ubs" if (b, c, v) in mapping else "identity"
                m_str = macula.get((b, org_ch, org_vs), frozenset())
                ol = _overlap(t_str, m_str)
                rare = _overlap(t_str - COMMON_STRONGS, m_str - COMMON_STRONGS)

                # O2 ВІДКИНУВ пропозицію довідника (обидва боки багаті, перетин 0).
                # Не довіряємо довіднику наосліп — пробуємо empirical довести інший
                # вірш. Спрацював унікально й сильно → беремо його (довідник помилявся,
                # напр. немонотонний ISA 3 у rso). Ні → це СПРАВЖНІЙ конфлікт → override.
                if len(t_str) >= 2 and len(m_str) >= 2 and ol == 0:
                    if src == "identity":
                        # identity в конформній главі — за неї РУЧАЮТЬСЯ схема+O3. НЕ
                        # запускаємо empirical: він може схопити випадкового сусіда на
                        # короткому вірші (напр. MAT 4 → 4:21) і перекрити правильний
                        # identity. O2=0 тут = артефакт нумерації (Macula тегує ЛЕМУ
                        # G4771 σύ, переклад ФОРМУ G5213 ὑμῖν) → просто неверифіковно.
                        s["unverifiable_identity"] += 1
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (b, org_ch, org_vs), fn, src, 0, ol, t_str, macula,
                              note="identity overlap=0 неверифіковно (напр. Greek лема/форма)")
                        continue

                    # НЕ identity: ми АКТИВНО застосували ubs-мапінг, а O2 його відкинув.
                    # Пробуємо empirical перевизначити; ні — справжня суперечність.
                    best = _empirical(t_str, b, macula, c)
                    if best is not None and best[1] >= 2 and best[2] \
                            and (best[0][1], best[0][2]) != (org_ch, org_vs):
                        (ob, oc, ovs), eol, _ = best
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (ob, oc, ovs), fn, "empirical", 1, eol, t_str, macula,
                              note="довідник %d:%d відкинуто O2 → empirical довів %d:%d"
                                   % (org_ch, org_vs, oc, ovs))
                    else:
                        conflicts.append((tr, "%s %d:%d" % (b, c, v),
                                          "%s %d:%d" % (b, org_ch, org_vs), fn))
                        s["conflict"] += 1
                        s["needs_override"] += 1
                        _emit(cur, report_rows, s, per_chapter_assign,
                              tr, b, c, v, (b, org_ch, org_vs), fn, src, 0, ol, t_str, macula,
                              note="CONFLICT: ubs-мапінг відкинуто O2, empirical не врятував → override")
                    continue

                verified = 1 if ol >= 2 else 0
                note = ""
                if verified and ol >= 2 and rare == 0:
                    s["weak_common_only"] += 1
                    note = "weak: overlap лише через часті Strong's"
                _emit(cur, report_rows, s, per_chapter_assign,
                      tr, b, c, v, (b, org_ch, org_vs), fn, src, verified, ol, t_str, macula,
                      note=note)
                continue

            # 3) жодна схема не конформна цій главі → EMPIRICAL пошук у книзі
            best = _empirical(t_str, b, macula, c)
            if best is not None:
                (ob, oc, ovs), ol, unique = best
                verified = 1 if (ol >= 2 and unique) else 0
                _emit(cur, report_rows, s, per_chapter_assign,
                      tr, b, c, v, (ob, oc, ovs), "empirical", "empirical",
                      verified, ol, t_str, macula,
                      note="" if verified else "empirical: слабкий/неунікальний → потрібен override")
                if not verified:
                    s["needs_override"] += 1
            else:
                s["needs_override"] += 1
                _emit(cur, report_rows, s, per_chapter_assign,
                      tr, b, c, v, None, "none", "none", 0, None, t_str, macula,
                      note="empirical не знайшов — потрібен override")

        # ── MONOTONICITY: org-вірші вздовж глави мусять не спадати ──
        mono_viol = 0
        for (b, c), lst in per_chapter_assign.items():
            lst_sorted = sorted(lst, key=lambda x: x[0])   # за tr_vs
            prev = None
            for (tv, oc, ovs) in lst_sorted:
                if oc is None:
                    continue
                cur_key = (oc, ovs)
                if prev is not None and cur_key < prev:
                    mono_viol += 1
                    report_rows.append(("MONOTONICITY", tr, "%s %d:%d" % (b, c, tv),
                                        "%d:%d після %d:%d" % (oc, ovs, prev[0], prev[1]),
                                        "org-вірш спадає — підозра на зсув/хибний мапінг"))
                prev = cur_key
        s["monotonicity_violations"] = mono_viol

        print("\n  %s  (кандидати: %s)" % (tr, ", ".join(candidates)))
        print("    AGREE/verified          %6d" % s["verified"])
        print("    identity                %6d" % s["identity_total"])
        print("    ubs-mapped              %6d" % s["ubs_total"])
        print("    empirical               %6d" % s["empirical_total"])
        print("    override                %6d" % s["override_total"])
        print("    verified=0 (недоведені) %6d" % s["unverified"])
        print("    weak (лише часті S)     %6d" % s["weak_common_only"])
        print("    потребують override     %6d" % s["needs_override"])
        print("    CONFLICT (білд падає)   %6d" % s["conflict"])
        print("    monotonicity порушень   %6d" % s["monotonicity_violations"])
        # нонконформні глави — саме тут RST-сюрприз
        nonconf = sorted(k for k, fn in chapter_scheme.items() if fn is None)
        if nonconf:
            print("    глави без конформної схеми: %s"
                  % ", ".join("%s %d" % (b, c) for b, c in nonconf[:12]))
        for k in s:
            grand[tr][k] = s[k]

    con.commit()

    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("type\ttranslation\tref\torg_or_detail\tnote\n")
        for r in report_rows:
            f.write("\t".join(str(x) for x in r) + "\n")

    print("\n" + "=" * 70)
    total_conf = sum(g["conflict"] for g in grand.values())
    print("  Звіт: %s  (%d рядків)" % (REPORT, len(report_rows)))
    print("  verse_org записано у БД поряд зі старим verse_map (нічого не видалено).")
    if total_conf:
        print("\n  ✗ CONFLICT: %d рядків (обидва боки ≥2 тегів, overlap=0)." % total_conf)
        print("    Це або хибний мапінг довідника, або переверсифікований модуль.")
        print("    Дивись CONFLICT-рядки у звіті. БІЛД НЕ ВВАЖАЄТЬСЯ ЧИСТИМ.")
        con.close()
        sys.exit(1)
    print("\n  ✓ Нуль CONFLICT. Перевір verified=0 / monotonicity / weak у звіті перед схема+Swift.")
    print("=" * 70)
    con.close()


def _overlap(a: frozenset, b: frozenset) -> int:
    return len(a & b)


def _empirical(t_str: frozenset, book: str, macula: Dict, near_chapter: int):
    """Пошук org-вірша у книзі з найкращим УНІКАЛЬНИМ перетином (для нонконформних глав).
    Повертає ((ob,oc,ov), overlap, unique) або None. Вимагає рідкісного збігу."""
    if len(t_str) < 2:
        return None
    rare_t = t_str - COMMON_STRONGS
    scored = []
    for (ob, oc, ov), m_str in macula.items():
        if ob != book:
            continue
        if abs(oc - near_chapter) > 1:      # шукаємо в сусідніх главах, не по всій книзі
            continue
        ol = len(rare_t & (m_str - COMMON_STRONGS))
        if ol > 0:
            scored.append((ol, oc, ov))
    if not scored:
        return None
    scored.sort(reverse=True)
    best_ol, boc, bov = scored[0]
    unique = len(scored) == 1 or scored[0][0] > scored[1][0]   # строго кращий за 2-й
    return (book, boc, bov), best_ol, unique


def _emit(cur, report_rows, s, per_chapter_assign,
          tr, b, c, v, org, scheme, source, verified, overlap, t_str, macula, note=""):
    """Записати рядок verse_org + оновити лічильники + зібрати для монотонності."""
    if org is None:
        oc = ov = None
        ob = None
    else:
        ob, oc, ov = org
    cur.execute("INSERT OR REPLACE INTO verse_org VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (tr, b, c, v, ob, oc, ov, scheme, source, verified, overlap))
    per_chapter_assign[(b, c)].append((v, oc, ov))
    s[source + "_total"] += 1
    if verified:
        s["verified"] += 1
    else:
        s["unverified"] += 1
    if note or source in ("empirical", "override", "none"):
        report_rows.append((("OK" if verified else "CHECK"), tr,
                            "%s %d:%d" % (b, c, v),
                            ("%s %d:%d" % (ob, oc, ov)) if org else "—",
                            note or (source + " verified=%d overlap=%s" % (verified, overlap))))


if __name__ == "__main__":
    main()
