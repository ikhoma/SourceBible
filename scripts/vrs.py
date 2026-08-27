#!/usr/bin/env python3
"""Парсер файлів версифікації Paratext `.vrs` (bug-050).

НАВІЩО ОКРЕМИЙ ПАРСЕР
---------------------
Мапінги брались із `standard-mappings/*.json` (Copenhagen Alliance). Там
`mappedVerses` — ОБ'ЄКТ, а `.vrs` виражає злиття «один вірш перекладу = два
оригінальні» ПОВТОРЕННЯМ лівої частини:

    2CO 11:32 = 2CO 11:32
    2CO 11:32 = 2CO 11:33

Повторений ключ у JSON затирається, і ліва половина зникає мовчки. Заміряно
2026-08-21: 21 втрачений рядок → 17 зачеплених віршів; у `verse_org` НУЛЬ віршів
із кількома org-таргетами, тобто гілка ADR-028 «N:M → конкатенація» не виконувалась
жодного разу.

Тому парсер віддає СПИСОК таргетів на ключ, а не одне значення.

ФОРМАТ (перевірено на org/eng/rso 2026-08-25)
---------------------------------------------
- `# …` — коментар. Злиття продубльовані там у людському вигляді
  (`# 2CO 11:32 = 2CO 11:32-33`) — зручно для звірки, але джерело істини — рядки.
- `GEN 1:31 2:25 …` — кількість віршів у кожній главі книги.
- `LEV 6:1-7 = LEV 5:20-26` — мапінг; діапазони розгортаються попарно.
  ⚠️ Діапазон НІКОЛИ не перетинає межу глави в реальних рядках (перевірено:
  збігів нуль) — міжглавові злиття виражені повтором, як REV 13:1.

Джерело: sillsdev/libpalaso, `SIL.Scripture/Resources/*.vrs.txt`, ліцензія MIT.
"""
from __future__ import annotations

import re
from collections import defaultdict

REF_RE = re.compile(r"^([A-Z0-9]{3})\s+(\d+):(\d+)(?:-(\d+))?$")
MAX_LINE_RE = re.compile(r"^([A-Z0-9]{3})\s+(\d+:\d+(?:\s+\d+:\d+)*)\s*$")


class VrsScheme:
    """Розібрана схема версифікації."""

    def __init__(self, name: str):
        self.name = name
        # (book, ch, vs) -> [(org_ch, org_vs), …] — порядок джерела збережений
        self.mappings: dict[tuple[str, int, int], list[tuple[int, int]]] = defaultdict(list)
        # book -> [к-сть віршів у главі 1, 2, …]
        self.max_verses: dict[str, list[int]] = {}
        # рядки, які довідник змапити НАМІРЯВСЯ, але його кодування некоректне
        self.unequal_ranges: list[tuple[str, str]] = []
        # мапінги між РІЗНИМИ книгами — поза межами цієї моделі
        self.cross_book: list[tuple[str, str]] = []

    @property
    def merged_sources(self) -> list[tuple[str, int, int]]:
        """Ключі, що мають БІЛЬШЕ ОДНОГО таргета — те, що втрачав JSON."""
        return sorted(k for k, v in self.mappings.items() if len(v) > 1)

    def __repr__(self):
        return (f"<VrsScheme {self.name}: {len(self.mappings)} ключів, "
                f"{sum(len(v) for v in self.mappings.values())} таргетів, "
                f"{len(self.merged_sources)} злиттів>")


def _expand(ref: str):
    """'LEV 6:1-7' -> ('LEV', 6, [1..7]); None якщо форма чужа."""
    m = REF_RE.match((ref or "").strip())
    if not m:
        return None
    book, ch, v1 = m.group(1), int(m.group(2)), int(m.group(3))
    v2 = int(m.group(4)) if m.group(4) else v1
    if v2 < v1:
        return None
    return book, ch, list(range(v1, v2 + 1))


def parse_vrs(path: str, name: str | None = None) -> VrsScheme:
    scheme = VrsScheme(name or path)
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue

            if "=" in line:
                src, dst = (p.strip() for p in line.split("=", 1))
                s, d = _expand(src), _expand(dst)
                if not s or not d:
                    continue
                sb, sc, svs = s
                db_, dc, dvs = d
                if sb != db_:
                    scheme.cross_book.append((src, dst))
                    continue
                if len(svs) != len(dvs):
                    # Довідник сам собі суперечить — напр. rso `PSA 89:2-6 = 90:1-6`.
                    # НЕ вгадуємо: віддаємо нагору, хай вирішує конвеєр.
                    scheme.unequal_ranges.append((src, dst))
                    continue
                for sv, dv in zip(svs, dvs):
                    # Вірш 0 = слот надписання псалма в оригінальній нумерації
                    # (`PSA 9:22 = PSA 10:0`, `PSA 10:0-7 = PSA 11:0-7`) — у
                    # наших `verse`/`verse_org` рядка з verse=0 не існує
                    # ЖОДНОГО. Нормалізація формату, не виняток (план §8):
                    # без цього фільтра одна и та сама пара (напр. PSA 9:22)
                    # отримує ДРУГИЙ, ніколи не задовольнюваний таргет від
                    # сусіднього рядка (`PSA 9:22-39 = PSA 10:1-18` дає
                    # (10,1) для того самого ключа) — фантомне злиття, яке
                    # verify_versification_completeness.py вважав би вічно
                    # "втраченим". Заміряно 2026-08-27: без фільтра PSA 9:22 і
                    # PSA 113:9 (RST/UBIO) — фантомні 2-таргетні злиття.
                    if sv == 0 or dv == 0:
                        continue
                    tgt = (dc, dv)
                    if tgt not in scheme.mappings[(sb, sc, sv)]:
                        scheme.mappings[(sb, sc, sv)].append(tgt)
                continue

            m = MAX_LINE_RE.match(line)
            if m:
                book = m.group(1)
                counts = []
                for pair in m.group(2).split():
                    ch, vs = pair.split(":")
                    idx = int(ch) - 1
                    while len(counts) <= idx:
                        counts.append(0)
                    counts[idx] = int(vs)
                scheme.max_verses[book] = counts
    scheme.mappings = dict(scheme.mappings)
    return scheme
