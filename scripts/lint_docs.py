#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lint_docs.py — перевірка здоров'я пам'яті проєкту (операція LINT з docs/WIKI.md).

Python 3.10+ (мінімум проєкту, CLAUDE.md). READ-ONLY: нічого не пише, лише звітує.
Виходить з НЕНУЛЬОВИМ кодом, якщо знайшов розходження.

    python3 scripts/lint_docs.py            # усі перевірки
    python3 scripts/lint_docs.py --check status   # одна перевірка

Навіщо
------
Аудит 2026-08-07 знайшов **7 документів із 34**, чий заявлений статус розходився з
кодом і базою. Найдорожчий — ADR-028 стояв `Proposed`, тоді як на ньому трималася
вся версифікація застосунку (`verse_org` = 155 621 рядок у базі, `verse_map`
видалена, `findBestMaculaVerse` видалений).

Розходження не випадкові, а СИСТЕМАТИЧНІ: статус живе у двох місцях — шапка файлу
і рядок `docs/INDEX.md` — і синхронізується вручну. Ручна звірка провалилась 7 разів
із 34. За правилом CLAUDE.md «перевірки — у код, не в очі» вона переїхала сюди.

Що перевіряється
----------------
  C1  STATUS    Статус у шапці документа != статус у рядку INDEX.
                Порівнюються НОРМАЛІЗОВАНІ ключові слова (Accepted / Proposed / …),
                не сирі рядки: «Accepted (реалізовано 2026-06)» і «Accepted» — те саме.

  C2  ORPHAN    Документ у architecture/ features/ product decisions/ без рядка в INDEX.
                Сирота невидима для агента, який чесно читає INDEX першим.

  C3  BROKEN    Рядок INDEX посилається на файл, якого немає — АБО на неіснуючий
                документ посилається `CLAUDE.md` чи `.gitignore`.
                Ці два файли — «законодавчі»: перший читається на старті кожного чату,
                другий вирішує, що взагалі потрапить у git. `.gitignore` двічі відсилав
                по датасети до `docs/BUILD.md`, якого не існувало, — шлях відтворення
                проєкту на новій машині не був записаний ніде (заведено 2026-08-08).

  C4  LOG       Коміт із трейлером `Decision:` є, а запису в docs/LOG.md за цю дату
                немає. Заміряно: за 18 днів після запровадження LOG протокол виконано
                приблизно наполовину — пишеться, коли чат закінчується документом,
                і не пишеться, коли закінчується кодом.

                ⚠️ Поріг навмисно вузький — НЕ «будь-який день із комітами». За три
                серпневі дні було 28 комітів, більшість із них полірування; лінтер,
                що кричить на кожен такий день, навчає себе ігнорувати. Трейлер ставить
                людина, тож сигнал завжди справжній: ви самі сказали «це рішення».
                Чернетки й кандидатів на пропущені трейлери шукає `harvest_log.py`.

                ⚠️ Ловить лише ЗАКОМІЧЕНЕ. Рішення, ухвалене в чаті й реалізоване
                у Swift без документа, ця перевірка не побачить — там працює правило
                кінця сесії в CLAUDE.md.

  C5  SYNC      `docs/project-memory.md` оновлено пізніше, ніж його копію перенесли
                в knowledge claude.ai-Проєкту.

                Снапшот живе у ДВОХ місцях: файл у репо (читається, лише коли агент
                під'єднав папку) і копія в knowledge Проєкту (вантажиться автоматично
                в КОЖЕН чат, без мосту, з будь-якої машини). Git у knowledge не
                пушить — перенос ручний.

                Заміряно 2026-08-10: репо було від 10.08, хмара — від 20.07. Три тижні
                розриву, і сесія, що чесно стартувала з автозавантаженого снапшота,
                бачила Огієнка «BLOCKED», Python 3.9 і Phase B «відкладено» — усе
                неправдиве. Це та сама хвороба, що C1 (одна правда у двох місцях),
                але з гіршою асиметрією: копію, якої скрипт НЕ бачить, читають усі
                й завжди.

                ⚠️ Скрипт не має доступу до knowledge claude.ai і не може подивитись,
                що там лежить. Він порівнює два рядки В САМОМУ файлі: «Останнє
                оновлення» проти «Перенесено в knowledge Проєкту». Другий оновлює той,
                хто справді зробив перенос. Це маркер чесності, а не доказ — але він
                робить розрив ВИДИМИМ, а невидимий розрив і був причиною.

Кожен провал друкує ОЧІКУВАНЕ ПОРУЧ З ОТРИМАНИМ — бо еталон теж буває хибним
(урок 2026-08-04: два з сімнадцяти якорів були записані перевернутими, і скрипт
«падав» на власній правильній поведінці).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOCS = REPO / "docs"
INDEX = DOCS / "INDEX.md"
LOG = DOCS / "LOG.md"

# Теки, документи яких МУСЯТЬ бути в INDEX.
INDEXED_DIRS = ["architecture", "features", "product decisions"]

# Ці файли навмисно поза перевіркою статусу/сирітства.
EXEMPT = {
    "INDEX.md",
    "INDEX-amendments.md",
    "LOG.md",
    "WIKI.md",
    "TEMPLATE.md",
    "README.md",
    "project-memory.md",
}

# Контрольований словник статусів. Порядок важливий: довші/специфічніші —
# ПЕРШИМИ, інакше «Superseded by ADR-012» зматчиться як щось інше.
# (Урок ADR-034: `S>\d*[a-z]?` перед загальним `<[^>]+>` робить із `</S>`
#  невиліковне `</` — порядок альтернатив у розборі це не косметика.)
STATUS_VOCAB = [
    "superseded",
    "implemented",
    "reverted",
    "deferred",
    "accepted",
    "proposed",
    "blocked",
    "amended",
    "draft",
    "ready",
    "done",
]

STATUS_HEADER_RE = re.compile(
    r"^\s*\*\*(?:Status|Статус)\:?\*\*\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE
)


@dataclass
class Failure:
    check: str
    subject: str
    expected: str
    actual: str
    hint: str = ""


@dataclass
class Report:
    failures: list[Failure] = field(default_factory=list)
    checked: int = 0

    def fail(self, *a, **kw) -> None:
        self.failures.append(Failure(*a, **kw))


def normalize_status(raw: str | None) -> str | None:
    """Сирий текст статусу -> одне ключове слово зі словника, або None.

    'Accepted (реалізовано 2026-06; статус виправлено lint-ом)' -> 'accepted'
    '**Proposed** (2026-08-07)'                                 -> 'proposed'
    'Superseded by ADR-012'                                     -> 'superseded'
    """
    if not raw:
        return None
    low = raw.lower()
    hits = [(low.index(w), w) for w in STATUS_VOCAB if w in low]
    if not hits:
        return None
    # Перше ключове слово за позицією в тексті — воно і є заявленим статусом;
    # решта зазвичай історія («Accepted … (було: BLOCKED …)»).
    hits.sort()
    return hits[0][1]


def header_status(path: Path) -> tuple[str | None, str | None]:
    """-> (нормалізований, сирий) статус із шапки документа."""
    try:
        head = path.read_text(encoding="utf-8")[:4000]
    except OSError:
        return None, None
    m = STATUS_HEADER_RE.search(head)
    raw = m.group(1).strip() if m else None
    return normalize_status(raw), raw


def parse_index() -> dict[str, dict]:
    """-> {basename.md: {'status_raw', 'status', 'line'}} з таблиць INDEX."""
    rows: dict[str, dict] = {}
    if not INDEX.exists():
        return rows
    for n, line in enumerate(INDEX.read_text(encoding="utf-8").splitlines(), 1):
        if not line.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not cells:
            continue
        m = re.match(r"^`([^`]+\.md)`$", cells[0])
        if not m:
            continue
        name = Path(m.group(1)).name
        status_raw = cells[2] if len(cells) >= 4 else None
        rows[name] = {
            "status_raw": status_raw,
            "status": normalize_status(status_raw),
            "line": n,
            "ref": m.group(1),
        }
    return rows


def indexed_docs() -> list[Path]:
    out = []
    for d in INDEXED_DIRS:
        p = DOCS / d
        if p.is_dir():
            out += [f for f in sorted(p.glob("*.md")) if f.name not in EXEMPT]
    return out


def check_status(rows: dict[str, dict], rep: Report) -> None:
    for doc in indexed_docs():
        row = rows.get(doc.name)
        if row is None or row["status"] is None:
            continue  # сирітство ловить C2; рядок без колонки статусу — не помилка
        file_status, file_raw = header_status(doc)
        rep.checked += 1
        if file_status is None:
            rep.fail(
                "STATUS",
                doc.relative_to(REPO).as_posix(),
                expected=f"шапка зі '**Status:** …' ({row['status']} за INDEX)",
                actual="шапки зі статусом немає або статус не зі словника",
                hint="Додай рядок '**Status:** Accepted (реалізовано РРРР-ММ-ДД)'",
            )
        elif file_status != row["status"]:
            rep.fail(
                "STATUS",
                doc.relative_to(REPO).as_posix(),
                expected=f"{row['status']}   ← INDEX.md:{row['line']}  «{row['status_raw']}»",
                actual=f"{file_status}   ← шапка файлу  «{file_raw}»",
                hint="Правий зазвичай той, що ближче до коду. Звір із реальним станом, не з пам'яті.",
            )


def check_orphans(rows: dict[str, dict], rep: Report) -> None:
    for doc in indexed_docs():
        rep.checked += 1
        if doc.name not in rows:
            rep.fail(
                "ORPHAN",
                doc.relative_to(REPO).as_posix(),
                expected="рядок у docs/INDEX.md",
                actual="документа в INDEX немає",
                hint="Сирота невидима для агента, який читає INDEX першим (WIKI.md, крок 5 INGEST).",
            )


# Файли-«закони»: перший читається на старті кожного чату, другий вирішує, що
# потрапить у git. Посилання з них на неіснуючий документ — тиха діра.
LAW_FILES = ["CLAUDE.md", ".gitignore"]
DOC_REF_RE = re.compile(r"docs/[A-Za-z0-9_/.-]+\.md")


def check_broken(rows: dict[str, dict], rep: Report) -> None:
    known = {p.name for p in DOCS.rglob("*.md")}
    for name, row in rows.items():
        rep.checked += 1
        if name not in known:
            rep.fail(
                "BROKEN",
                f"INDEX.md:{row['line']}",
                expected=f"файл {row['ref']} існує",
                actual="файла немає в docs/",
                hint="Перейменований або видалений — онови рядок або прибери його.",
            )

    for law in LAW_FILES:
        p = REPO / law
        if not p.exists():
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for ref in set(DOC_REF_RE.findall(line)):
                rep.checked += 1
                if not (REPO / ref).exists():
                    rep.fail(
                        "BROKEN",
                        f"{law}:{n}",
                        expected=f"документ {ref} існує",
                        actual="файла немає — посилання веде в нікуди",
                        hint="Або створи документ, або прибери посилання. Мовчазна діра "
                             "в законодавчому файлі коштує дорожче за биту таблицю.",
                    )


DECISION_TRAILER_RE = re.compile(r"^(?:Decision|Рішення)\s*:", re.IGNORECASE | re.MULTILINE)


def dates_with_decision_trailers() -> dict[str, list[str]]:
    """-> {дата: [сабджекти комітів, що несуть трейлер `Decision:`]}.

    Поза git-репо або на помилці git повертає порожньо: лінтер не вигадує провалів
    там, де не має даних (контрольний тест `test_log_with_entries_passes_when_no_git`).
    """
    try:
        out = subprocess.run(
            ["git", "log", "--format=%ad\x1f%s\x1f%b\x1e", "--date=short"],
            cwd=REPO, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if out.returncode != 0:
        return {}
    found: dict[str, list[str]] = {}
    for rec in out.stdout.split("\x1e"):
        if not rec.strip():
            continue
        parts = rec.strip("\n").split("\x1f")
        if len(parts) < 3:
            continue
        date, subject, body = parts[0], parts[1], parts[2]
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            continue
        if DECISION_TRAILER_RE.search(body):
            found.setdefault(date, []).append(subject)
    return found


def check_log(rep: Report) -> None:
    if not LOG.exists():
        rep.fail("LOG", "docs/LOG.md", expected="файл існує", actual="файла немає")
        return
    text = LOG.read_text(encoding="utf-8")
    logged = set(re.findall(r"^##\s*\[(\d{4}-\d{2}-\d{2})\]", text, re.MULTILINE))
    if not logged:
        rep.fail("LOG", "docs/LOG.md", expected="записи '## [РРРР-ММ-ДД]'", actual="жодного")
        return
    for date, subjects in sorted(dates_with_decision_trailers().items()):
        rep.checked += 1
        if date not in logged:
            head = subjects[0][:60] + ("…" if len(subjects[0]) > 60 else "")
            more = f" (+{len(subjects) - 1})" if len(subjects) > 1 else ""
            rep.fail(
                "LOG",
                date,
                expected=f"запис '## [{date}] decision | …' у docs/LOG.md",
                actual=f"коміт із трейлером `Decision:` є, хронологія мовчить: «{head}»{more}",
                hint="`python3 scripts/harvest_log.py` збере чернетку з тих самих трейлерів.",
            )


SNAPSHOT = DOCS / "project-memory.md"
UPDATED_RE = re.compile(r"Останнє оновлення:\s*\*\*(\d{4}-\d{2}-\d{2})\*\*")
SYNCED_RE = re.compile(r"Перенесено в knowledge Проєкту:\s*\*\*(\d{4}-\d{2}-\d{2})\*\*")

SYNC_HINT = (
    "Перенос робить агент у чаті Проєкту (project_write на claude/project-memory.md), "
    "після чого оновлює тут рядок «Перенесено в knowledge Проєкту». "
    "Крок входить в операцію LINT — див. docs/WIKI.md."
)


def check_sync(rep: Report) -> None:
    if not SNAPSHOT.exists():
        rep.fail("SYNC", "docs/project-memory.md",
                 expected="файл існує", actual="файла немає")
        return

    text = SNAPSHOT.read_text(encoding="utf-8")
    upd, syn = UPDATED_RE.search(text), SYNCED_RE.search(text)
    rep.checked += 1

    if not upd:
        rep.fail("SYNC", "docs/project-memory.md",
                 expected="рядок «Останнє оновлення: **РРРР-ММ-ДД**»",
                 actual="рядка немає або дата не у форматі",
                 hint="Без дати оновлення розрив із хмарою не обчислити.")
        return

    if not syn:
        rep.fail("SYNC", "docs/project-memory.md",
                 expected="рядок «Перенесено в knowledge Проєкту: **РРРР-ММ-ДД**»",
                 actual=f"рядка немає; оновлено {upd.group(1)}, дата переносу невідома",
                 hint=SYNC_HINT)
        return

    # ISO-дати порівнюються лексикографічно.
    if syn.group(1) < upd.group(1):
        rep.fail("SYNC", "docs/project-memory.md",
                 expected=f"перенос не старіший за оновлення ({upd.group(1)})",
                 actual=f"оновлено {upd.group(1)}, перенесено {syn.group(1)} — "
                        "у хмарі стара картина, і саме її читає кожен новий чат",
                 hint=SYNC_HINT)


CHECKS = {
    "status": check_status,
    "orphan": check_orphans,
    "broken": check_broken,
    "log": check_log,
    "sync": check_sync,
}

# Перевірки, яким не потрібні рядки INDEX.
NO_ROWS = {"log", "sync"}


def main() -> int:
    ap = argparse.ArgumentParser(description="Лінтер пам'яті проєкту SourceBible")
    ap.add_argument("--check", choices=sorted(CHECKS), action="append",
                    help="запустити лише вказані перевірки (можна кілька разів)")
    args = ap.parse_args()

    rows = parse_index()
    rep = Report()
    wanted = args.check or sorted(CHECKS)

    for name in wanted:
        fn = CHECKS[name]
        fn(rep) if name in NO_ROWS else fn(rows, rep)

    print("=" * 72)
    print("  LINT пам'яті — docs/ проти коду й самих себе")
    print("=" * 72)
    print(f"  INDEX рядків:      {len(rows)}")
    print(f"  Документів:        {len(indexed_docs())}")
    print(f"  Перевірок:         {rep.checked}")
    print(f"  Перевірки:         {', '.join(wanted)}\n")

    if not rep.failures:
        print("  ✓ Розходжень немає.\n")
        return 0

    by_check: dict[str, list[Failure]] = {}
    for f in rep.failures:
        by_check.setdefault(f.check, []).append(f)

    for check, items in by_check.items():
        print(f"  ─── {check} ({len(items)}) " + "─" * (44 - len(check)))
        for f in items:
            print(f"\n  ✗ {f.subject}")
            print(f"      очікувано: {f.expected}")
            print(f"      отримано:  {f.actual}")
            if f.hint:
                print(f"      → {f.hint}")
        print()

    print("=" * 72)
    print(f"  ✗ Розходжень: {len(rep.failures)}")
    print("=" * 72)
    return 1


if __name__ == "__main__":
    sys.exit(main())
