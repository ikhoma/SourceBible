#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""harvest_log.py — зібрати чернетку записів `docs/LOG.md` із git-історії.

Python 3.10+ (мінімум проєкту, CLAUDE.md). За замовчуванням НІЧОГО не пише —
друкує чернетку, яку ви вичитуєте. Запис у файл — лише за явним `--write`.

    python3 scripts/harvest_log.py                 # чернетка від останньої дати в LOG
    python3 scripts/harvest_log.py --since 2026-08-01
    python3 scripts/harvest_log.py --write         # вставити чернетку у LOG.md

Навіщо
------
Заміряно 2026-08-07: за 18 днів після запровадження LOG протокол виконано приблизно
наполовину. Пишеться, коли чат закінчується документом, і не пишеться, коли чат
закінчується кодом — а саме рішення в коді потім найважче відновити.

При цьому сировина вже є: середній сабджект коміту — 58 символів осмисленого тексту
(«Висота смуги фільтрів = заміряний нав-бар, а не арифметика падінгів» — це вже
рішення), чверть уже посилається на ADR або баг. Бракувало не дисципліни, а МІСТКА:
git пише «що», LOG хоче «чому», і між ними не було нічого, крім людської пам'яті
наприкінці сесії.

Три джерела
-----------
  1. ТРЕЙЛЕРИ  `Decision:` / `Refs:` у тілі коміту — явно позначене рішення.
                Це єдине, на чому падає `lint_docs.py`: сигнал завжди справжній,
                бо його поставила людина.

  2. ЗАКРИТІ БАГИ  перейменування `docs/bugs/*/bug-N.md` → `docs/bugs/done/`.
                Не потребує оголошувати «спринт закінчено»: одиниця — ДАТА, а не
                спринт. Запис за день росте, поки баги закриваються.

  3. КАНДИДАТИ  сабджекти з маркерами відкинутої альтернативи («а не», «замість»,
                «відкочено», «відхилено», «натомість», «прибрано»). Це підказка,
                НЕ факт: рішення закриває альтернативу, і ваша власна мова це
                вже позначає. Виводяться окремим блоком «перевірити».

⛔ Чернетка — не запис. Формулювання «чому» лишається за людиною; скрипт лише не дає
   дню зникнути безслідно.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOG = REPO / "docs" / "LOG.md"

SEP_REC, SEP_FLD = "\x1e", "\x1f"

# Маркери відкинутої альтернативи у ваших власних сабджектах.
CANDIDATE_MARKERS = [
    "а не", "замість", "відкочено", "відхилено", "натомість",
    "прибрано", "більше не", "скасовано", "instead of", "rejected",
]

TRAILER_RE = re.compile(r"^(Decision|Refs|Рішення)\s*:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
BUG_DONE_RE = re.compile(r"^R\d*\t\S*?(bug-[\w-]+\.md)\tdocs/bugs/done/\1$", re.MULTILINE)
BUG_ADD_RE = re.compile(r"^A\tdocs/bugs/done/(bug-[\w-]+)\.md$", re.MULTILINE)


@dataclass
class Commit:
    sha: str
    date: str
    subject: str
    decisions: list[str] = field(default_factory=list)
    refs: list[str] = field(default_factory=list)
    bugs_closed: list[str] = field(default_factory=list)

    @property
    def is_candidate(self) -> bool:
        low = self.subject.lower()
        return any(m in low for m in CANDIDATE_MARKERS)


def git(*args: str) -> str:
    r = subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(f"✗ git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def last_log_date() -> str | None:
    if not LOG.exists():
        return None
    d = re.findall(r"^##\s*\[(\d{4}-\d{2}-\d{2})\]", LOG.read_text(encoding="utf-8"), re.MULTILINE)
    return max(d) if d else None


def logged_dates() -> set[str]:
    if not LOG.exists():
        return set()
    return set(re.findall(r"^##\s*\[(\d{4}-\d{2}-\d{2})\]", LOG.read_text(encoding="utf-8"), re.MULTILINE))


def collect(since: str | None) -> list[Commit]:
    """Один прохід `git log` разом зі списком файлів.

    Раніше тут був `git show --name-status` НА КОЖЕН коміт — 115 спавнів процесу
    на повній історії SourceBible, якщо LOG порожній. `--name-status` просто
    додається до того самого `git log`, тож виклик лишається один.
    """
    # ⛔ Роздільник запису — на ПОЧАТКУ формату, не в кінці. З `--name-status`
    # git друкує список файлів ПІСЛЯ відформатованого рядка, тож роздільник у
    # кінці приклеїв би файли коміта N до запису N+1. Перевірено на живій історії.
    fmt = SEP_REC + SEP_FLD.join(["%H", "%ad", "%s", "%b"])
    args = ["log", f"--format={fmt}", "--date=short", "--name-status", "-M"]
    if since:
        args.append(f"--since={since}")
    out = []
    for rec in git(*args).split(SEP_REC):
        if not rec.strip():
            continue
        parts = rec.split(SEP_FLD)
        if len(parts) < 4:
            continue
        sha, date, subject = parts[0].strip(), parts[1], parts[2]
        tail = SEP_FLD.join(parts[3:])          # тіло коміту + список файлів
        c = Commit(sha=sha[:9], date=date, subject=subject)
        for kind, val in TRAILER_RE.findall(tail):
            (c.refs if kind.lower() == "refs" else c.decisions).append(val)
        c.bugs_closed = [Path(m).stem for m in BUG_DONE_RE.findall(tail)] + BUG_ADD_RE.findall(tail)
        out.append(c)
    return out


def draft_parts(commits: list[Commit]) -> tuple[str, str]:
    """-> (готові записи, блок кандидатів).

    Розділено НА ДЖЕРЕЛІ, а не виріз�анням із відрендереного тексту: попередня
    версія `--write` фільтрувала рядки регулярками вже по готовому виводу, тож
    текст рішення, що почався б із дев'яти hex-символів і двох пробілів, мовчки
    зникав би. Структуру треба ділити структурно.
    """
    by_date: dict[str, list[Commit]] = defaultdict(list)
    for c in commits:
        by_date[c.date].append(c)

    known = logged_dates()
    entries: list[str] = []
    cand_blocks: list[str] = []

    for date in sorted(by_date, reverse=True):
        day = by_date[date]
        decided = [c for c in day if c.decisions]
        bugs = sorted({b for c in day for b in c.bugs_closed})
        cands = [c for c in day if c.is_candidate and not c.decisions]
        if not (decided or bugs or cands):
            continue

        if decided or bugs:
            note = "  ← запис за цю дату ВЖЕ Є, звірте перед вставкою" if date in known else ""
            entries.append(f"{'=' * 72}\n  {date}{note}\n{'=' * 72}")

        for c in decided:
            refs = f" ({', '.join(c.refs)})" if c.refs else ""
            entries.append(f"\n## [{date}] decision | {c.subject}{refs}\n")
            entries.extend(c.decisions)
            entries.append(f"\n_{c.sha} — {c.subject}_\n")

        if bugs:
            entries.append(f"\n## [{date}] fix | Закрито: {', '.join(bugs)}\n")
            entries.append("<!-- одним рядком за ДАТУ, не за спринт: деталі лишаються у теках "
                           "docs/bugs/done/. Допишіть, що з цього було рішенням, а що ремонтом. -->\n")

        if cands:
            cand_blocks.append(f"\n  ─── {date} · перевірити: схоже на рішення, але трейлера немає ───")
            cand_blocks.extend(f"    {c.sha}  {c.subject}" for c in cands)

    return "\n".join(entries), "\n".join(cand_blocks)


def draft(commits: list[Commit]) -> str:
    """Повний вивід для друку — записи плюс блок кандидатів."""
    entries, cands = draft_parts(commits)
    return "\n".join(p for p in (entries, cands) if p)


def insert(text: str) -> None:
    content = LOG.read_text(encoding="utf-8")
    i = content.find("\n---\n")
    if i == -1:
        sys.exit("✗ У LOG.md немає роздільника '---' після шапки — не знаю, куди вставляти.")
    at = i + len("\n---\n")
    LOG.write_text(content[:at] + "\n" + text.rstrip() + "\n" + content[at:], encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Чернетка записів LOG із git-історії")
    ap.add_argument("--since", help="дата РРРР-ММ-ДД (типово — остання дата в LOG)")
    ap.add_argument("--write", action="store_true", help="вставити чернетку у docs/LOG.md")
    args = ap.parse_args()

    since = args.since or last_log_date()
    commits = collect(since)
    entries, candidates = draft_parts(commits)

    print(f"  Комітів переглянуто: {len(commits)}   від: {since or 'початку історії'}\n")
    if not (entries.strip() or candidates.strip()):
        print("  ✓ Нових рішень, закритих багів і кандидатів немає.\n")
        return 0

    if entries:
        print(entries)
    if candidates:
        print(candidates)

    if args.write:
        if not entries.strip():
            print("\n  Записувати нічого: є лише кандидати, а вони — підказка, не запис.")
            print("  Постав трейлер `Decision:` у коміті або допиши рядок вручну.\n")
            return 0
        # Кандидати у файл не йдуть — вони підказка. Розділення зроблено в
        # draft_parts() на джерелі, а не вирізанням рядків із готового тексту.
        keep = "\n".join(l for l in entries.splitlines() if not l.startswith("="))
        keep = re.sub(r"^  \d{4}-\d{2}-\d{2}.*$", "", keep, flags=re.MULTILINE)
        insert(keep.strip())
        print(f"\n  ✎ Вставлено у {LOG.relative_to(REPO)} — вичитайте перед комітом.")
    else:
        print("\n  Це ЧЕРНЕТКА. Формулювання «чому» — за вами. `--write` вставить у LOG.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
