"""Вибір варіанта й рядка TBESH для Strong's-id Macula (bug-057).

ЧОМУ ЦЕ ІСНУЄ
-------------
TBESH і Macula нумерують омоніми різними схемами суфіксів (bug-046):

    TBESH:   H3581a = «reptile»   H3581b = «strength»   голого H3581 немає
    Macula:  H3581  = сила (125)  H3581a = ящірка (1)

Імпорт брав для голого id ПЕРШИЙ суфіксований варіант у файлі — і H3581 «сила»
показував «reptile», H1004 «дім» — «place», H5892 «місто» — «excitement».
Літера суфікса нічого не означає між джерелами: правило «зсунути суфікс» на
корпусі виграло 82, програло 41, а в 265 із 388 сигналу не було (bug-046).

СИГНАЛ — глоси самої Macula (`word.gloss`) для цього id: яка частка вживань
має глосу, що перетинається зі словником варіанта TBESH. Два словники:
  G  — лише глоси рядків TBESH (колонка Gloss);
  GF — глоси + текст Meaning.
Кожен окремо помиляється по-своєму (заміряно 2026-10-05 на всіх 414 id групи
ризику проти ручної розмітки):
  G  — 231 спрацювання, 2 хибні, обидва частотні (H2896 «good», H6635 «hosts»);
  GF — 349 спрацювань, 8 хибних, здебільшого імена (Meaning згадує інші імена).
AGREE — рішення приймається, лише коли G і GF не суперечать: 270 спрацювань,
0 хибних. Решта — НЕ вгадується: лишається поточний (перший) варіант, id
потрапляє у звіт, а людина вирішує в tbesh_variant_overrides.tsv.

РЯДОК усередині варіанта: TBESH кладе першим рядок-ім'я (H7704a «Sirion» для
שָׂדֶה «поле», H5483b «Horse (Gate)» для סוּס). Якщо Macula не тегує слово як
ім'я, береться перший рядок, що не є ім'ям. short_def і long_def — з ОДНОГО
рядка (раніше long_def брався з ОСТАННЬОГО рядка групи: «king» → «King's
(Valley)», bug-059).

⛔ Не послаблювати пороги й не вмикати рішення за одним із сигналів: кожен
окремо дає хибні рішення на частотних словах. Модуль чистий (без бази) —
тести в scripts/tests/test_tbesh_select.py.
"""
from __future__ import annotations

import re
from collections import Counter

HI = 0.40          # мінімальне покриття найкращого варіанта
MARGIN = 0.20      # відрив від найкращого НЕеквівалентного конкурента
EQUIV = 0.50       # частка покритого конкурентом, що покрита й лідером → «еквівалентні»

STOP = set("""a an the of to in on at by for from with and or but not no is be was were are been being
as that this these those which who whom whose it its he she they them his her their my your our
you we i me us him one ones thing things do does did have has had shall will would may can
up out off into over under about upon than then so very also all any some such own""".split())


def _clean(text: str) -> str:
    t = re.sub(r"<[^>]+>", " ", text or "")
    t = t.lower().replace("’", "'").replace("'s", "")
    return re.sub(r"[^a-z]+", " ", t)


def stem(w: str) -> str:
    """Грубий англійський стемер: houses/house → hous, cities/city → city, horsemen → horseman."""
    if w.endswith("men") and len(w) > 4:
        w = w[:-3] + "man"
    if len(w) == 4 and w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    if len(w) > 4:
        for suf, rep in (("iness", "y"), ("ness", ""), ("ies", "y"), ("ings", ""), ("ing", ""),
                         ("edly", ""), ("ed", ""), ("ly", ""), ("es", ""), ("s", "")):
            if w.endswith(suf) and len(w) - len(suf) >= 3:
                w = w[: -len(suf)] + rep
                break
    if len(w) > 3 and w.endswith("e"):
        w = w[:-1]
    return w


def vocab(text: str, keep_stop: bool = False) -> set[str]:
    """Змістові основи тексту. keep_stop: якщо змістових немає — службові ("from", "you")."""
    toks = _clean(text).split()
    v = {stem(w) for w in toks if w not in STOP and len(w) > 1}
    if not v and keep_stop:
        v = {stem(w) for w in toks}
    return v


def covered(glosses: Counter, voc: set[str]) -> tuple[float, frozenset[str]]:
    """Частка вживань (зважено), чия глоса перетинається з voc; і які саме глоси."""
    tot = hit_n = 0
    hit: set[str] = set()
    for g, n in glosses.items():
        v = vocab(g, keep_stop=True)
        if not v:
            continue
        tot += n
        if v & voc:
            hit_n += n
            hit.add(g)
    return (hit_n / tot if tot else 0.0), frozenset(hit)


def variant_vocab(rows: list[dict], with_meaning: bool) -> set[str]:
    s: set[str] = set()
    for r in rows:
        s |= vocab(r.get("gloss", ""), keep_stop=True)
        if with_meaning:
            s |= vocab(r.get("meaning", ""))
    return s


def decide_one(glosses: Counter, variants: dict[str, list[dict]], order: list[str],
               with_meaning: bool) -> tuple[str, str | None, dict[str, float]]:
    """('AUTO'|'CURATE'|'NO_SIGNAL', обраний варіант або None, покриття по варіантах)."""
    sc = {v: covered(glosses, variant_vocab(variants[v], with_meaning)) for v in order}
    rk = sorted(order, key=lambda v: (-sc[v][0], order.index(v)))
    best = rk[0]
    bc, bhit = sc[best]

    def equiv(v: str) -> bool:
        c, hit = sc[v]
        if not hit:
            return False
        w = sum(glosses[g] for g in hit)
        return sum(glosses[g] for g in hit & bhit) / w >= EQUIV

    comp = max((sc[v][0] for v in rk[1:] if not equiv(v)), default=0.0)
    cov = {v: round(sc[v][0], 3) for v in order}
    if bc >= HI and bc - comp >= MARGIN:
        return "AUTO", best, cov
    if bc < 0.10:
        return "NO_SIGNAL", None, cov
    return "CURATE", best, cov


def decide_variant(glosses: Counter, variants: dict[str, list[dict]], order: list[str]):
    """AGREE: рішення лише коли G і GF не суперечать. Повертає (рішення, варіант|None, деталі)."""
    dg, pg, cg = decide_one(glosses, variants, order, False)
    df, pf, cf = decide_one(glosses, variants, order, True)
    info = {"G": (dg, pg, cg), "GF": (df, pf, cf)}
    if dg == "AUTO" and df == "AUTO":
        return ("AUTO", pg, info) if pg == pf else ("CURATE", None, info)
    if dg == "AUTO" and pf == pg:
        return "AUTO", pg, info
    if df == "AUTO" and pg == pf:
        return "AUTO", pf, info
    if dg == "NO_SIGNAL" and df == "NO_SIGNAL":
        return "NO_SIGNAL", None, info
    return "CURATE", None, info


def is_name_row(row: dict) -> bool:
    """Рядок-ім'я TBESH: морфологія N:…; зв'язок dStrong «a Name of» / «a Part of» (H5553G «rock» =
    «The Rock / Sela» — глоса з малої!); або глоса з великої літери / дужки / лапки («Sirion», «(Mount) Ebal»)."""
    g = (row.get("gloss") or "").strip()
    rel = (row.get("relation") or "").strip()
    return (row.get("morph", "").startswith("N:")
            or rel.startswith(("a Name of", "a Part of"))
            or (bool(g) and (g[0].isupper() or g[0] in "(`")))


def pick_row(rows: list[dict], macula_classes: Counter) -> dict:
    """Рядок для short_def І long_def. Ім'я в Macula (Np/Ng) — перший рядок; інакше — перший не-ім'я."""
    top = macula_classes.most_common(1)[0][0] if macula_classes else "?"
    if top not in ("Np", "Ng"):
        for r in rows:
            if not is_name_row(r):
                return r
    return rows[0]


def macula_class(morph: str | None) -> str:
    """OSHB-морфологія Macula → клас: Nc/Np/Ng (іменник/ім'я/етнонім), V, A, R, C, P, T, …"""
    if not morph:
        return "?"
    return morph[:2] if morph[0] == "N" else morph[0]
