#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Інваріанти лінтера пам'яті (scripts/lint_docs.py).

Що зловив лінтер
----------------
Аудит 2026-08-07: 7 документів із 34 мали заявлений статус, що розходився з кодом
і базою. Найдорожчий — ADR-028 стояв `Proposed`, тоді як `verse_org` (155 621 рядок)
уже обслуговував усю версифікацію застосунку, `verse_map` була видалена, а
`findBestMaculaVerse` не існував. Агент, який чесно читав INDEX першим, бачив
фундамент системи як нерозглянуту пропозицію.

Найгостріший тест тут — `test_status_keyword_wins_over_history`. Реальні шапки
несуть історію в дужках: «Accepted — ліцензія підтверджена (було: BLOCKED on
licence)». Наївне порівняння підрядків знайшло б у ній і `accepted`, і `blocked`
і мовчки обрало б алфавітно перше. Тому нормалізація бере ключове слово за
ПОЗИЦІЄЮ в тексті, і цей тест падає на будь-якій реалізації, що цього не робить.

Контрольні випадки (обов'язкові за CLAUDE.md, «Перевірки — у код, не в очі»):
`test_matching_status_does_not_fire` і `test_orphan_check_ignores_exempt` ловлять
ПРОТИЛЕЖНУ помилку — лінтер, що кричить на все підряд, проходить кожен позитивний
тест і не вартий нічого.

Дані
----
Тимчасові теки з РЕАЛЬНОЮ формою рядка INDEX (`| \\`file.md\\` | Title | Status |
Summary |`) і реальною формою шапки (`**Status:** …  ` з двома пробілами в кінці —
markdown hard break, який справді стоїть у файлах). Урок 2026-08-04: фікстура,
що не відтворює справжню форму, перевіряє припущення автора, а не код.

Запуск без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

import lint_docs  # noqa: E402


class NormalizeStatusTests(unittest.TestCase):
    """Сирий текст статусу -> одне ключове слово."""

    def test_plain(self):
        self.assertEqual(lint_docs.normalize_status("Accepted"), "accepted")
        self.assertEqual(lint_docs.normalize_status("Proposed"), "proposed")

    def test_bold_and_date(self):
        self.assertEqual(lint_docs.normalize_status("**Proposed** (2026-08-07)"), "proposed")

    def test_parenthetical_detail_ignored(self):
        self.assertEqual(
            lint_docs.normalize_status("Accepted (реалізовано 2026-06; статус виправлено lint-ом)"),
            "accepted",
        )

    def test_status_keyword_wins_over_history(self):
        """Шапка ADR-029: чинний статус попереду, скасований — у дужках позаду.

        Падає на будь-якій реалізації, що бере ключові слова в алфавітному
        порядку або через `any()`, а не за позицією в тексті.
        """
        raw = "**Accepted** — ліцензія (CC BY-SA 3.0) підтверджена 2026-07-31 (було: BLOCKED on licence)"
        self.assertEqual(lint_docs.normalize_status(raw), "accepted")

    def test_superseded_not_confused_with_target(self):
        self.assertEqual(lint_docs.normalize_status("Superseded by ADR-012"), "superseded")

    def test_unknown_and_empty(self):
        self.assertIsNone(lint_docs.normalize_status("Витає в повітрі"))
        self.assertIsNone(lint_docs.normalize_status(""))
        self.assertIsNone(lint_docs.normalize_status(None))

    def test_case_insensitive(self):
        self.assertEqual(lint_docs.normalize_status("ACCEPTED"), "accepted")
        self.assertEqual(lint_docs.normalize_status("accepted"), "accepted")


class FakeRepo:
    """Тимчасовий docs/ реальної форми; лінтер перенаправляється на нього."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp())
        self.docs = self.root / "docs"
        (self.docs / "architecture").mkdir(parents=True)
        (self.docs / "features").mkdir()
        (self.docs / "product decisions").mkdir()
        self._rows: list[str] = []
        self._saved = (lint_docs.REPO, lint_docs.DOCS, lint_docs.INDEX, lint_docs.LOG)
        lint_docs.REPO, lint_docs.DOCS = self.root, self.docs
        lint_docs.INDEX, lint_docs.LOG = self.docs / "INDEX.md", self.docs / "LOG.md"

    def adr(self, name: str, status: str | None):
        body = f"# {name}\n\n"
        if status is not None:
            body += f"**Status:** {status}  \n"       # два пробіли = markdown hard break
        body += "**Date:** 2026-08-07  \n\n---\n\nТекст.\n"
        (self.docs / "architecture" / name).write_text(body, encoding="utf-8")

    def row(self, name: str, status: str):
        self._rows.append(f"| `{name}` | Заголовок | {status} | Короткий опис |")

    def write_index(self):
        head = "# SourceBible — docs index\n\n| File | Title | Status | Summary |\n|---|---|---|---|\n"
        lint_docs.INDEX.write_text(head + "\n".join(self._rows) + "\n", encoding="utf-8")

    def close(self):
        lint_docs.REPO, lint_docs.DOCS, lint_docs.INDEX, lint_docs.LOG = self._saved
        shutil.rmtree(self.root, ignore_errors=True)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.repo = FakeRepo()
        self.addCleanup(self.repo.close)

    def _run(self, check):
        rows = lint_docs.parse_index()
        rep = lint_docs.Report()
        check(rows, rep)
        return rep

    # ── STATUS ───────────────────────────────────────────────────────────
    def test_status_mismatch_fires(self):
        """Точний сценарій ADR-028: реалізовано в коді, «Proposed» у карті."""
        self.repo.adr("ADR-028-versification.md", "Accepted — фази 1 і 2 реалізовані")
        self.repo.row("ADR-028-versification.md", "**Proposed**")
        self.repo.write_index()
        rep = self._run(lint_docs.check_status)
        self.assertEqual(len(rep.failures), 1)
        f = rep.failures[0]
        self.assertEqual(f.check, "STATUS")
        # Провал друкує очікуване ПОРУЧ з отриманим — еталон теж буває хибним.
        self.assertIn("proposed", f.expected)
        self.assertIn("accepted", f.actual)

    def test_matching_status_does_not_fire(self):
        """Контроль: різні формулювання одного статусу — не розходження."""
        self.repo.adr("ADR-001-platform-stack.md", "Accepted (amended 2026-07-31)")
        self.repo.row("ADR-001-platform-stack.md", "Accepted")
        self.repo.write_index()
        self.assertEqual(self._run(lint_docs.check_status).failures, [])

    def test_missing_header_fires(self):
        self.repo.adr("ADR-099-no-header.md", None)
        self.repo.row("ADR-099-no-header.md", "Accepted")
        self.repo.write_index()
        rep = self._run(lint_docs.check_status)
        self.assertEqual(len(rep.failures), 1)
        self.assertIn("Status", rep.failures[0].expected)

    def test_index_row_without_status_column_is_not_a_failure(self):
        """Довідкові таблиці мають лише File | Summary — це не привід падати."""
        self.repo.adr("ADR-050-ref.md", "Accepted")
        self.repo._rows.append("| `ADR-050-ref.md` | Тільки опис |")
        self.repo.write_index()
        self.assertEqual(self._run(lint_docs.check_status).failures, [])

    # ── ORPHAN ───────────────────────────────────────────────────────────
    def test_orphan_fires(self):
        self.repo.adr("ADR-777-orphan.md", "Draft")
        self.repo.write_index()                      # рядка немає навмисно
        rep = self._run(lint_docs.check_orphans)
        self.assertEqual([f.check for f in rep.failures], ["ORPHAN"])

    def test_orphan_check_ignores_exempt(self):
        """Контроль: TEMPLATE/README не є сиротами."""
        (self.repo.docs / "features" / "TEMPLATE.md").write_text("# T\n", encoding="utf-8")
        (self.repo.docs / "features" / "README.md").write_text("# R\n", encoding="utf-8")
        self.repo.write_index()
        self.assertEqual(self._run(lint_docs.check_orphans).failures, [])

    # ── BROKEN ───────────────────────────────────────────────────────────
    def test_broken_link_fires(self):
        self.repo.row("ADR-404-gone.md", "Accepted")
        self.repo.write_index()
        rep = self._run(lint_docs.check_broken)
        self.assertEqual([f.check for f in rep.failures], ["BROKEN"])

    def test_existing_link_does_not_fire(self):
        self.repo.adr("ADR-002-here.md", "Accepted")
        self.repo.row("ADR-002-here.md", "Accepted")
        self.repo.write_index()
        self.assertEqual(self._run(lint_docs.check_broken).failures, [])

    def test_law_file_pointing_at_missing_doc_fires(self):
        """Реальний випадок: .gitignore двічі відсилав до неіснуючого docs/BUILD.md."""
        self.repo.write_index()
        (self.repo.root / ".gitignore").write_text(
            "data/*\n# download instructions: docs/BUILD.md\n", encoding="utf-8"
        )
        rep = self._run(lint_docs.check_broken)
        self.assertEqual([f.check for f in rep.failures], ["BROKEN"])
        self.assertIn("docs/BUILD.md", rep.failures[0].expected)
        self.assertIn(".gitignore:2", rep.failures[0].subject)

    def test_law_file_pointing_at_existing_doc_does_not_fire(self):
        """Контроль: чинне посилання не має падати."""
        self.repo.write_index()
        (self.repo.docs / "BUILD.md").write_text("# Build\n", encoding="utf-8")
        (self.repo.root / "CLAUDE.md").write_text("Дивись docs/BUILD.md\n", encoding="utf-8")
        self.assertEqual(self._run(lint_docs.check_broken).failures, [])

    def test_same_ref_twice_on_one_line_counted_once(self):
        self.repo.write_index()
        (self.repo.root / "CLAUDE.md").write_text("docs/X.md і ще раз docs/X.md\n", encoding="utf-8")
        self.assertEqual(len(self._run(lint_docs.check_broken).failures), 1)

    # ── LOG ──────────────────────────────────────────────────────────────
    def test_log_missing_file_fires(self):
        self.repo.write_index()
        rep = lint_docs.Report()
        lint_docs.check_log(rep)
        self.assertEqual([f.check for f in rep.failures], ["LOG"])

    def test_log_with_entries_passes_when_no_git(self):
        """Поза git-репо дат комітів немає — лінтер не має вигадувати провали."""
        self.repo.write_index()
        lint_docs.LOG.write_text(
            "# LOG\n\n## [2026-08-07] lint | Аудит\n\nТекст.\n", encoding="utf-8"
        )
        rep = lint_docs.Report()
        lint_docs.check_log(rep)
        self.assertEqual(rep.failures, [])


class ParseIndexTests(unittest.TestCase):
    def setUp(self):
        self.repo = FakeRepo()
        self.addCleanup(self.repo.close)

    def test_reads_status_column(self):
        self.repo.row("ADR-008-search-architecture.md", "Accepted (amended 2026-08-07)")
        self.repo.write_index()
        rows = lint_docs.parse_index()
        self.assertIn("ADR-008-search-architecture.md", rows)
        self.assertEqual(rows["ADR-008-search-architecture.md"]["status"], "accepted")

    def test_ignores_non_table_lines_and_headers(self):
        self.repo.row("ADR-003-file-modularity.md", "Accepted")
        self.repo.write_index()
        self.assertEqual(len(lint_docs.parse_index()), 1)  # не рахує |---|---| і заголовок

    def test_path_prefixed_reference_keyed_by_basename(self):
        """INDEX посилається і як `ux/feature-requests.md` — ключ має бути basename."""
        self.repo._rows.append("| `ux/feature-requests.md` | Беклог | Draft | Опис |")
        self.repo.write_index()
        self.assertIn("feature-requests.md", lint_docs.parse_index())


if __name__ == "__main__":
    unittest.main(verbosity=2)
