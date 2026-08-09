#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Інваріанти збирача чернетки LOG (scripts/harvest_log.py).

Чому цей скрипт існує
---------------------
Заміряно 2026-08-07: за 18 днів після запровадження LOG протокол виконано приблизно
наполовину. Сировина при цьому вже була — середній сабджект коміту несе 58 символів
осмисленого тексту. Бракувало містка між «що змінилось» (git) і «чому так» (LOG).

Найгостріший тест — `test_candidate_markers_match_real_subjects`: він годується
СПРАВЖНІМИ сабджектами з історії проєкту, а не вигаданими. Урок 2026-08-04: тест,
який годують вигаданими даними, перевіряє припущення автора, а не код.

Контрольні випадки (ловлять протилежну помилку — детектор, що позначає все підряд):
`test_plain_subjects_are_not_candidates` і `test_commit_without_trailer_has_no_decisions`.
Детектор, який кричить на кожен коміт, пройшов би кожен позитивний тест і не вартий
нічого — а на 28 комітах за три дні саме він і зробив би LOG другим git-ом.

Запуск без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

import harvest_log  # noqa: E402


# Справжні сабджекти з git-історії SourceBible (серпень 2026).
REAL_DECISIONS = [
    "Висота смуги фільтрів = заміряний нав-бар, а не арифметика падінгів",
    "Чипи пошуку 1:1 з пікерами рідера; сегментований відкочено",
    "Одна резолюція мови замість п'яти дефолтів",
    "Прибрано перехід із «Вживання» на вірш-приклад",
    "Лексикон: порода цієї форми першою, злитий заголовок прибрано (ADR-033)",
]

REAL_PLAIN = [
    "Показ консент-шіта відкладено на наступний тік",
    "Провідні роздільники не входять у підсвітку слова",
    "Складені слова: розбір голови слота + склад слова словами",
    "Шапка Пошуку збігається з нав-баром рідера піксель-у-піксель",
    "Консент-шіт: показ чекає на замір висоти (гонка)",
]


class CandidateDetectorTests(unittest.TestCase):
    def _c(self, subject):
        return harvest_log.Commit(sha="abc123456", date="2026-08-03", subject=subject)

    def test_candidate_markers_match_real_subjects(self):
        for s in REAL_DECISIONS:
            with self.subTest(s=s):
                self.assertTrue(self._c(s).is_candidate, f"мало бути кандидатом: {s}")

    def test_plain_subjects_are_not_candidates(self):
        """Контроль: детектор, що позначає все, робить LOG другим git-ом."""
        for s in REAL_PLAIN:
            with self.subTest(s=s):
                self.assertFalse(self._c(s).is_candidate, f"НЕ мало бути кандидатом: {s}")

    def test_case_insensitive(self):
        self.assertTrue(self._c("Сегментований ВІДКОЧЕНО").is_candidate)

    def test_english_markers(self):
        self.assertTrue(self._c("Use verse_org instead of heuristics").is_candidate)


class TrailerParsingTests(unittest.TestCase):
    def _parse(self, body):
        c = harvest_log.Commit(sha="a" * 9, date="2026-08-08", subject="s")
        for kind, val in harvest_log.TRAILER_RE.findall(body):
            (c.refs if kind.lower() == "refs" else c.decisions).append(val)
        return c

    def test_decision_and_refs(self):
        c = self._parse("Тіло.\n\nDecision: хаптика на call-site, не на спільному шляху\nRefs: ADR-032\n")
        self.assertEqual(c.decisions, ["хаптика на call-site, не на спільному шляху"])
        self.assertEqual(c.refs, ["ADR-032"])

    def test_ukrainian_keyword(self):
        c = self._parse("Рішення: text_clean — єдине джерело плоского тексту\n")
        self.assertEqual(c.decisions, ["text_clean — єдине джерело плоского тексту"])

    def test_multiple_decisions(self):
        c = self._parse("Decision: перше\nDecision: друге\n")
        self.assertEqual(len(c.decisions), 2)

    def test_commit_without_trailer_has_no_decisions(self):
        """Контроль: звичайне тіло коміту не має ставати рішенням."""
        c = self._parse("Виправлено гонку при показі шіта.\nБез трейлерів.\n")
        self.assertEqual(c.decisions, [])
        self.assertEqual(c.refs, [])

    def test_word_decision_in_prose_is_not_a_trailer(self):
        """«Decision» посеред речення — не трейлер; трейлер стоїть НА ПОЧАТКУ рядка."""
        c = self._parse("This Decision: was discussed but not taken.\n")
        self.assertEqual(c.decisions, [])


class BugClosureTests(unittest.TestCase):
    def test_rename_into_done_detected(self):
        names = "R100\tdocs/bugs/new/bug-035.md\tdocs/bugs/done/bug-035.md\n"
        self.assertEqual(
            [Path(m).stem for m in harvest_log.BUG_DONE_RE.findall(names)], ["bug-035"]
        )

    def test_rename_from_in_progress(self):
        names = "R98\tdocs/bugs/in-progress/bug-030.md\tdocs/bugs/done/bug-030.md\n"
        self.assertEqual(
            [Path(m).stem for m in harvest_log.BUG_DONE_RE.findall(names)], ["bug-030"]
        )

    def test_added_straight_to_done(self):
        self.assertEqual(
            harvest_log.BUG_ADD_RE.findall("A\tdocs/bugs/done/bug-041.md\n"), ["bug-041"]
        )

    def test_move_out_of_done_is_not_a_closure(self):
        """Контроль: повернення бага з done/ у new/ — не закриття."""
        names = "R100\tdocs/bugs/done/bug-017.md\tdocs/bugs/new/bug-017.md\n"
        self.assertEqual(harvest_log.BUG_DONE_RE.findall(names), [])

    def test_unrelated_rename_ignored(self):
        names = "R100\tdocs/features/spec-a.md\tdocs/features/spec-b.md\n"
        self.assertEqual(harvest_log.BUG_DONE_RE.findall(names), [])
        self.assertEqual(harvest_log.BUG_ADD_RE.findall(names), [])


class CollectAgainstRealGitTests(unittest.TestCase):
    """`collect()` проти СПРАВЖНЬОГО git-репо — решта тестів годується структурами.

    Цей клас заведено після реального бага 2026-08-08: з `--name-status` git друкує
    список файлів ПІСЛЯ відформатованого рядка, тож роздільник запису в кінці
    формату приклеював файли коміта N до запису N+1. Усі 22 тести, що були на той
    момент, проходили однаково до й після — вони перевіряли розбір готових структур,
    а не те, що git реально віддає. `test_files_attach_to_their_own_commit` падає
    на старій реалізації.
    """

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self._saved = P_REPO = harvest_log.REPO
        harvest_log.REPO = self.root
        self.addCleanup(lambda: setattr(harvest_log, "REPO", P_REPO))
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "t@t.t")
        self._git("config", "user.name", "t")

    def _git(self, *a):
        subprocess.run(["git", *a], cwd=self.root, check=True, capture_output=True)

    def _commit(self, path, text, msg):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        self._git("add", "-A")
        self._git("commit", "-qm", msg)

    def test_files_attach_to_their_own_commit(self):
        """Баг роздільника: файли коміта N не мають потрапляти в запис N+1."""
        self._commit("docs/bugs/new/bug-500.md", "x", "заводжу баг")
        (self.root / "docs/bugs/done").mkdir(parents=True, exist_ok=True)
        self._git("mv", "docs/bugs/new/bug-500.md", "docs/bugs/done/bug-500.md")
        self._git("commit", "-qm", "закриваю баг")
        self._commit("README.md", "y", "нічого спільного з багами")

        by_subject = {c.subject: c for c in harvest_log.collect(None)}
        self.assertEqual(by_subject["закриваю баг"].bugs_closed, ["bug-500"])
        self.assertEqual(by_subject["нічого спільного з багами"].bugs_closed, [])
        self.assertEqual(by_subject["заводжу баг"].bugs_closed, [])

    def test_trailer_read_from_real_commit_body(self):
        self._commit("a.txt", "a", "тема\n\nDecision: одне джерело правди\nRefs: ADR-034")
        c = harvest_log.collect(None)[0]
        self.assertEqual(c.decisions, ["одне джерело правди"])
        self.assertEqual(c.refs, ["ADR-034"])

    def test_commit_count_matches_git(self):
        for i in range(4):
            self._commit(f"f{i}.txt", str(i), f"коміт {i}")
        n = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=self.root,
                           capture_output=True, text=True).stdout.strip()
        self.assertEqual(len(harvest_log.collect(None)), int(n))

    def test_multiline_body_does_not_break_parsing(self):
        """Тіло з переносами й порожніми рядками не має ламати розбір полів."""
        self._commit("b.txt", "b", "тема\n\nабзац один\n\nабзац два\n\nDecision: вижило")
        c = harvest_log.collect(None)[0]
        self.assertEqual(c.subject, "тема")
        self.assertEqual(c.decisions, ["вижило"])


class DraftTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._saved = harvest_log.LOG
        harvest_log.LOG = self.tmp / "LOG.md"
        harvest_log.LOG.write_text("# LOG\n\n> Шапка.\n\n---\n\n## [2026-08-06] ingest | Старе\n\nТекст.\n",
                                   encoding="utf-8")
        self.addCleanup(self._restore)

    def _restore(self):
        harvest_log.LOG = self._saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _commit(self, **kw):
        base = dict(sha="a" * 9, date="2026-08-08", subject="Тема")
        base.update(kw)
        return harvest_log.Commit(**base)

    def test_last_log_date_reads_max(self):
        self.assertEqual(harvest_log.last_log_date(), "2026-08-06")

    def test_decision_becomes_entry(self):
        out = harvest_log.draft([self._commit(decisions=["одне джерело правди"], refs=["ADR-034"])])
        self.assertIn("## [2026-08-08] decision |", out)
        self.assertIn("одне джерело правди", out)
        self.assertIn("ADR-034", out)

    def test_bugs_grouped_by_date_not_sprint(self):
        """Одиниця — дата: два коміти одного дня дають ОДИН рядок про баги."""
        out = harvest_log.draft([
            self._commit(sha="a" * 9, bugs_closed=["bug-031"]),
            self._commit(sha="b" * 9, bugs_closed=["bug-032"]),
        ])
        self.assertEqual(out.count("] fix | Закрито:"), 1)
        self.assertIn("bug-031, bug-032", out)

    def test_existing_date_is_flagged_not_skipped(self):
        out = harvest_log.draft([self._commit(date="2026-08-06", decisions=["щось"])])
        self.assertIn("ВЖЕ Є", out)

    def test_candidates_listed_separately_from_entries(self):
        out = harvest_log.draft([self._commit(subject="Сегментований відкочено")])
        self.assertIn("перевірити", out)
        self.assertNotIn("] decision |", out)

    def test_commit_with_trailer_is_not_also_a_candidate(self):
        """Позначене рішення не має дублюватись у блоці кандидатів."""
        out = harvest_log.draft([
            self._commit(subject="Сегментований відкочено", decisions=["чипи 1:1 з рідером"])
        ])
        self.assertIn("] decision |", out)
        self.assertNotIn("перевірити", out)

    def test_empty_when_nothing_notable(self):
        self.assertEqual(harvest_log.draft([self._commit(subject="Дрібне полірування")]).strip(), "")

    def test_insert_puts_draft_below_header(self):
        harvest_log.insert("## [2026-08-08] decision | Нове\n\nТекст.")
        content = harvest_log.LOG.read_text(encoding="utf-8")
        self.assertLess(content.index("2026-08-08"), content.index("2026-08-06"))
        self.assertIn("> Шапка.", content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
