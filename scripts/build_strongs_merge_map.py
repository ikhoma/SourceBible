#!/usr/bin/env python3
"""Генерує похідні факти про Strong's-підзаписи: мапу злиття (bug-045) і
список підзаписів із НЕДОСТОВІРНИМ визначенням (bug-046).

ЧОМУ ЦЕ ІСНУЄ
-------------
Суфікс у Strong's-id — частина ідентичності лексеми, а не декорація:
H2617 (hesed I «вірна любов», 245) і H2617a (hesed II «ганьба», 2) — РІЗНІ слова.
Тому конкорданс зіставляє id ТОЧНО (bug-045).

Але Macula подекуди ділить ОДНЕ слово між базою й підзаписом: H835 (1 вживання)
і H835a (44) — це той самий אַשְׁרֵי. Точне зіставлення дало б там список з одного
вірша. Ця мапа перелічує такі — і лише такі — групи, які конкорданс має об'єднувати.

ПРАВИЛО (кошики A+B, рішення Івана 2026-08-19)
----------------------------------------------
Зливати базу й підзапис тоді й лише тоді, коли ОБИДВІ умови:
  1. набори `word.lemma` ІДЕНТИЧНІ — не перетинаються, а збігаються;
  2. набори `word.gloss` ПЕРЕТИНАЮТЬСЯ хоча б в одному значенні.

Умова 1 відсікає різні слова (H871 אֲתָרִים «Атарот» ⟷ H871a בְּ прийменник),
а також варіанти написання імен (Єремія коротка/довга форма) — вони лишаються
розділеними СВІДОМО: два правильних списки краще за один зі сміттям, бо саме
в цьому кошику сидять помилки розмітки (H5892 עִיר «місто» ⟷ H5892b לְ).

Умова 2 відсікає омоніми з тією самою лемою — рівно випадок hesed.

⛔ НЕ послаблювати до «лема перетинається» або «однакове визначення». Визначення
підзаписів ненадійні (bug-046: 558 з 1008 несуть визначення базового номера), тож
правило на них мовчки зіллє hesed назад.

Джерело сигналу — `word.lemma` і `word.gloss`, тобто дані Macula по токенах.
Лексикон TBESH тут НЕ використовується навмисно: він отруєний bug-046.

ВИКОРИСТАННЯ
------------
    python3 scripts/build_strongs_merge_map.py [sourcebible.db] [--dry-run]

Читає sourcebible.db у режимі ro. Пише Swift-файл (див. OUT). Базу не змінює.
Падає з ненульовим кодом, якщо еталонні випадки розійшлися з очікуванням.
"""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from collections import defaultdict

DB = "sourcebible.db"
OUT = "SourceBible/Generated/StrongsMergeMap.swift"
OUT_TRUST = "SourceBible/Generated/StrongsDefinitionTrust.swift"

SUB_RE = re.compile(r"^([HG]\d+)([a-z]+)$")

# Еталони: (id_a, id_b, чи_мають_злитися). Позитивні І негативні — негативні
# ловлять протилежну помилку (правило, що зливає все).
GOLDEN = [
    ("H835",  "H835a",  True,  "אַשְׁרֵי — одне слово, розбите розміткою"),
    ("H2617", "H2617a", False, "hesed I «вірна любов» проти hesed II «ганьба» — омоніми"),
    ("H871",  "H871a",  False, "Атарот (місто) проти прийменника בְּ"),
    ("H5892", "H5892b", False, "עִיר «місто» проти леми לְ — помилка розмітки"),
    ("H7969", "H7969a", False, "שָׁלֹשׁ «три» проти леми מִן — помилка розмітки"),
    ("H3414", "H3414a", False, "Єремія: коротка й довга форма імені — свідомо НЕ зливаємо"),
]


def load(conn: sqlite3.Connection) -> tuple[dict[str, set[str]], dict[str, set[str]], dict[str, int]]:
    lemmas: dict[str, set[str]] = defaultdict(set)
    glosses: dict[str, set[str]] = defaultdict(set)
    counts: dict[str, int] = defaultdict(int)
    sql = "SELECT strongs_id, lemma, gloss FROM word WHERE strongs_id IS NOT NULL"
    for sid, lemma, gloss in conn.execute(sql):
        counts[sid] += 1
        if lemma:
            lemmas[sid].add(lemma.strip())
        if gloss:
            glosses[sid].add(gloss.strip().lower())
    return lemmas, glosses, counts


def should_merge(a: str, b: str, lemmas, glosses) -> bool:
    la, lb = lemmas.get(a, set()), lemmas.get(b, set())
    ga, gb = glosses.get(a, set()), glosses.get(b, set())
    if not la or not lb:
        return False
    return la == lb and bool(ga & gb)


def build_groups(lemmas, glosses, counts) -> dict[str, list[str]]:
    groups: dict[str, set[str]] = {}
    for sid in counts:
        m = SUB_RE.match(sid)
        if not m:
            continue
        base = m.group(1)
        if counts.get(base, 0) == 0:
            continue  # база в тексті не вживається — зливати нема з чим
        if should_merge(sid, base, lemmas, glosses):
            groups.setdefault(base, {base}).add(sid)
    # розгорнути: кожен член групи вказує на повний склад
    out: dict[str, list[str]] = {}
    for members in groups.values():
        ordered = sorted(members)
        for m_ in ordered:
            out[m_] = ordered
    return out


def verify(lemmas, glosses) -> list[str]:
    failures = []
    for a, b, expected, why in GOLDEN:
        actual = should_merge(b, a, lemmas, glosses) if SUB_RE.match(b) else should_merge(a, b, lemmas, glosses)
        if actual != expected:
            failures.append(
                f"  {a} ⟷ {b}: очікували {'ЗЛИТИ' if expected else 'РОЗДІЛИТИ'}, "
                f"отримали {'ЗЛИТИ' if actual else 'РОЗДІЛИТИ'}  ({why})\n"
                f"      лема  {a}={sorted(lemmas.get(a,set()))}  {b}={sorted(lemmas.get(b,set()))}\n"
                f"      глоси {a}={sorted(glosses.get(a,set()))[:4]}  {b}={sorted(glosses.get(b,set()))[:4]}"
            )
    return failures


def render(groups: dict[str, list[str]]) -> str:
    uniq = {tuple(v) for v in groups.values()}
    lines = [
        "// ЗГЕНЕРОВАНО scripts/build_strongs_merge_map.py — НЕ РЕДАГУВАТИ ВРУЧНУ.",
        "//",
        "// Групи Strong's-id, які конкорданс має вважати ОДНИМ словом (bug-045).",
        "// Правило: набори word.lemma ідентичні І набори word.gloss перетинаються.",
        "// Все, чого тут немає, зіставляється ТОЧНО за strongs_id.",
        "//",
        f"// Груп: {len(uniq)}   id у мапі: {len(groups)}",
        "",
        "enum StrongsMergeMap {",
        "    /// id → усі id його групи (включно з ним самим). Відсутній ключ = точне зіставлення.",
        "    static let groups: [String: [String]] = [",
    ]
    for key in sorted(groups):
        members = ", ".join(f'"{m}"' for m in groups[key])
        lines.append(f'        "{key}": [{members}],')
    lines += [
        "    ]",
        "",
        "    /// Усі id, за якими треба шукати вживання цього слова.",
        "    static func expand(_ strongsId: String) -> [String] {",
        "        groups[strongsId] ?? [strongsId]",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines)


def untrusted_definitions(conn: sqlite3.Connection, groups: dict[str, list[str]]) -> list[str]:
    """Підзаписи, чиє визначення насправді належить БАЗОВОМУ номеру (bug-046).

    Критерій: `short_def` збігається з базовим І пара НЕ визнана однією лексемою
    мапою злиття (bug-045). Якщо мапа каже «те саме слово» — спільне визначення
    законне, і ховати його не треба.

    ⛔ Не намагатись «полагодити» ці записи зсувом суфіксів Macula→TBESH.
    Перевірено 2026-08-19 на корпусі: зсув виграє 82 випадки, програє 41, а в 265
    із 388 сигналу немає. Це евристика, а евристичне зіставлення цей проєкт уже
    купив один раз (ADR-028, verse_map, 57% хибних рядків). Правильні дані в TBESH
    існують (H2617b = «shame»), але їх зіставлення — куроване рішення, не формула.
    """
    defs = dict(conn.execute("SELECT id, short_def FROM strongs"))
    out = []
    for sid in defs:
        m = SUB_RE.match(sid)
        if not m:
            continue
        base = m.group(1)
        if base not in defs or defs[sid] is None or defs[sid] != defs[base]:
            continue
        if base in groups.get(sid, []):
            continue          # та сама лексема — спільне визначення законне
        out.append(sid)
    return sorted(out)


def render_trust(ids: list[str]) -> str:
    lines = [
        "// ЗГЕНЕРОВАНО scripts/build_strongs_merge_map.py — НЕ РЕДАГУВАТИ ВРУЧНУ.",
        "//",
        "// Strong's-підзаписи, чиє визначення в базі насправді належить БАЗОВОМУ",
        "// номеру, а не їм (bug-046). Найгостріший приклад: H2617a — це חֶסֶד II",
        "// «ганьба» (Лев 20:17), а показувалося «kindness», тобто протилежне.",
        "//",
        "// Для них визначення НЕ показується взагалі. Порожньо чесніше за",
        "// правдоподібний хибний текст: користувач бачить, що даних немає, замість",
        "// того щоб прочитати чуже значення як факт.",
        "//",
        f"// Записів: {len(ids)}",
        "",
        "enum StrongsDefinitionTrust {",
        "    /// id, для яких short_def / long_def з бази показувати НЕ можна.",
        "    static let untrusted: Set<String> = [",
    ]
    for i in range(0, len(ids), 6):
        lines.append("        " + ", ".join(f'"{x}"' for x in ids[i:i + 6]) + ",")
    lines += [
        "    ]",
        "",
        "    /// true — визначення для цього id недостовірне й має бути приховане.",
        "    static func isUntrusted(_ strongsId: String) -> Bool {",
        "        untrusted.contains(strongsId)",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default=DB, help=f"шлях до бази (типово {DB})")
    ap.add_argument("--dry-run", action="store_true", help="нічого не писати, лише звіт")
    args = ap.parse_args()

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    lemmas, glosses, counts = load(conn)

    failures = verify(lemmas, glosses)
    if failures:
        print("⛔ ЕТАЛОННІ ВИПАДКИ НЕ ЗІЙШЛИСЬ:\n" + "\n".join(failures), file=sys.stderr)
        return 1

    groups = build_groups(lemmas, glosses, counts)
    uniq = {tuple(v) for v in groups.values()}
    merged_occ = sum(min(counts.get(m, 0) for m in g) for g in uniq)

    print(f"еталонів пройдено: {len(GOLDEN)}")
    print(f"груп злиття:       {len(uniq)}")
    print(f"id у мапі:         {len(groups)}")
    print(f"вживань, повернутих у списки: {merged_occ}")
    print("\nнайбільші групи:")
    for g in sorted(uniq, key=lambda t: -sum(counts.get(m, 0) for m in t))[:10]:
        parts = "  ".join(f"{m}={counts.get(m,0)}" for m in g)
        print(f"    {parts}")

    untrusted = untrusted_definitions(conn, groups)
    print(f"\nнедостовірних визначень (bug-046): {len(untrusted)}")

    if args.dry_run:
        print(f"--dry-run: {OUT} і {OUT_TRUST} не змінено")
        return 0

    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(render(groups))
    with open(OUT_TRUST, "w", encoding="utf-8") as fh:
        fh.write(render_trust(untrusted))
    print(f"записано {OUT}")
    print(f"записано {OUT_TRUST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
