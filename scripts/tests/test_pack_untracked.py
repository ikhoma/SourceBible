#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Інваріанти пакувальника untracked-файлів (scripts/pack_untracked.py).

Що він робить
-------------
Заміряно 2026-08-08: поза git лишається 2.37 GB у 33 794 файлах — база, датасети
й секрети. Із чистого клону застосунок не збирається, тож переїзд на іншу машину
вимагає перенести саме цей набір.

Найважливіший інваріант — `test_take_set_comes_from_git_not_from_a_hardcoded_list`:
перелік того, що не в git, береться з `git ls-files --others --ignored`, тобто з
самого `.gitignore`. Список, зашитий у скрипт, розійшовся б із `.gitignore` рівно
так, як сьогодні розійшлись статуси ADR із кодом. Тест ставить у fixture файл, про
який скрипт нічого не знає, і вимагає, щоб той опинився в архіві.

Контрольні випадки (ловлять протилежну помилку — пакувальник, що бере все підряд
або мовчки викидає потрібне): `test_nothing_is_dropped_without_a_reason`,
`test_tracked_files_are_never_packed`, `test_db_duplicate_skipped_but_original_kept`.

Фікстура — СПРАВЖНІЙ git-репозиторій у tmp зі справжнім `.gitignore`. Синтетичний
список шляхів перевіряв би припущення автора, а не поведінку git (урок 2026-08-04).

Запуск без мережі й без бази:
    python3 -m unittest discover scripts/tests
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

import pack_untracked as P  # noqa: E402


GITIGNORE = """\
sourcebible.db
SourceBible/Resources/sourcebible.db
data/*
!data/versification/
!data/versification/**
__pycache__/
*.log
Config/Secrets.xcconfig
backups/
"""


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


class FakeRepo:
    """Справжній git-репозиторій у tmp — щоб перевіряти поведінку git, а не здогадки."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp())
        run("git", "init", "-q", "-b", "main", cwd=self.root)
        run("git", "config", "user.email", "t@t.t", cwd=self.root)
        run("git", "config", "user.name", "t", cwd=self.root)

        self.write(".gitignore", GITIGNORE)
        self.write("CLAUDE.md", "# rules\n")
        self.write("data/versification/org.json", "{}")          # трекається (виняток)
        run("git", "add", "-A", cwd=self.root)
        run("git", "commit", "-qm", "init", cwd=self.root)

        # ignored-but-present
        self.write("sourcebible.db", "x" * 4096)
        self.write("SourceBible/Resources/sourcebible.db", "x" * 4096)
        self.write("Config/Secrets.xcconfig", "MIXPANEL_TOKEN = live-token\n")
        self.write("data/macula.zip", "z" * 2048)
        self.write("data/bh_cache/a.html", "<html/>")
        self.write("data/hebrew.json.bak.20260804-224536", "b" * 512)
        self.write("data/brand_new_dataset.tsv", "n" * 256)      # скрипт про нього НЕ знає
        self.write("build.log", "noise")
        self.write("__pycache__/x.pyc", "c")
        self.write("backups/db.sqlite", "b" * 1024)

        self._saved = P.REPO
        P.REPO = self.root

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def plan(self, profile="essential", extra=()):
        """Викликає ТУ САМУ `build_plan`, що й `main()` — власної копії правил тут немає.

        Копія була, і саме вона не знала про симлінки: правило існувало, а тест
        його не бачив. Тепер розбіжності нема звідки взятися.
        """
        rules = P.ALWAYS_SKIP + P.PROFILES[profile] + [(g, "cli") for g in extra]
        plan = P.build_plan(rules)
        skipped = {why: n for why, (n, _) in plan.skipped.items()}
        return {rel for rel, _ in plan.take}, skipped

    def close(self):
        P.REPO = self._saved
        shutil.rmtree(self.root, ignore_errors=True)


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.repo = FakeRepo()
        self.addCleanup(self.repo.close)

    def test_take_set_comes_from_git_not_from_a_hardcoded_list(self):
        """Файл, про який скрипт нічого не знає, все одно має поїхати."""
        take, _ = self.repo.plan()
        self.assertIn("data/brand_new_dataset.tsv", take)

    def test_tracked_files_are_never_packed(self):
        """Контроль: те, що вже в git, дублювати в архіві безглуздо."""
        take, _ = self.repo.plan("full")
        self.assertNotIn("CLAUDE.md", take)
        self.assertNotIn("data/versification/org.json", take)
        self.assertNotIn(".gitignore", take)

    def test_db_duplicate_skipped_but_original_kept(self):
        take, skipped = self.repo.plan()
        self.assertIn("sourcebible.db", take)
        self.assertNotIn("SourceBible/Resources/sourcebible.db", take)
        self.assertTrue(any("дублікат" in w for w in skipped))

    def test_secrets_are_included(self):
        """Секрети — саме те, що треба перенести; попередження друкується окремо."""
        take, _ = self.repo.plan()
        self.assertIn("Config/Secrets.xcconfig", take)

    def test_nothing_is_dropped_without_a_reason(self):
        """Контроль: кожен ignored-файл або їде, або має друковану причину, або симлінк.

        Мовчазне зникнення даних гірше за зайвий гігабайт — цей тест перевіряє,
        що баланс сходиться до одного файла.
        """
        rules = P.ALWAYS_SKIP + P.PROFILES["essential"]
        plan = P.build_plan(rules)
        total = len(plan.take) + sum(n for n, _ in plan.skipped.values()) \
            + len(plan.links) + plan.missing
        self.assertEqual(total, len(P.ignored_files()), "баланс не сходиться")
        for why, (n, _) in plan.skipped.items():
            self.assertTrue(why and why.strip(), f"{n} файлів пропущено без причини")

    def test_noise_skipped_in_every_profile(self):
        for prof in ("db", "essential", "full"):
            with self.subTest(profile=prof):
                take, _ = self.repo.plan(prof)
                self.assertNotIn("build.log", take)
                self.assertNotIn("__pycache__/x.pyc", take)
                self.assertNotIn("backups/db.sqlite", take)

    def test_profile_db_drops_datasets_keeps_db_and_secrets(self):
        take, _ = self.repo.plan("db")
        self.assertEqual(take, {"sourcebible.db", "Config/Secrets.xcconfig"})

    def test_profile_essential_drops_cache_and_backups_keeps_datasets(self):
        take, _ = self.repo.plan("essential")
        self.assertIn("data/macula.zip", take)
        self.assertNotIn("data/bh_cache/a.html", take)
        self.assertNotIn("data/hebrew.json.bak.20260804-224536", take)

    def test_profile_full_keeps_cache(self):
        take, _ = self.repo.plan("full")
        self.assertIn("data/bh_cache/a.html", take)
        self.assertIn("data/hebrew.json.bak.20260804-224536", take)

    def test_cli_exclude_applies(self):
        take, _ = self.repo.plan("essential", extra=["data/macula.zip"])
        self.assertNotIn("data/macula.zip", take)


class SkipReasonTests(unittest.TestCase):
    def test_trailing_star_crosses_directories(self):
        """`data/*` має ловити і `data/a/b.txt` — fnmatch сам по собі цього не робить."""
        self.assertIsNotNone(P.skip_reason("data/a/b.txt", [("data/*", "r")]))

    def test_exact_path_rule(self):
        rules = [("sourcebible.db-wal", "журнал")]
        self.assertEqual(P.skip_reason("sourcebible.db-wal", rules), "журнал")
        self.assertIsNone(P.skip_reason("sourcebible.db", rules))

    def test_first_matching_rule_wins(self):
        rules = [("data/*", "перша"), ("data/x", "друга")]
        self.assertEqual(P.skip_reason("data/x", rules), "перша")

    def test_unmatched_returns_none(self):
        self.assertIsNone(P.skip_reason("SourceBible/App.swift", [("data/*", "r")]))


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.repo = FakeRepo()
        self.addCleanup(self.repo.close)
        self.out = self.repo.root / "out.zip"

    def _pack(self, profile="db"):
        argv = sys.argv
        sys.argv = ["pack_untracked.py", "--profile", profile, "--write", "--out", str(self.out)]
        try:
            return P.main()
        finally:
            sys.argv = argv

    def test_archive_contains_files_manifest_and_restore(self):
        self.assertEqual(self._pack(), 0)
        with zipfile.ZipFile(self.out) as z:
            names = set(z.namelist())
            self.assertIn("sourcebible.db", names)
            self.assertIn("MANIFEST.json", names)
            self.assertIn("RESTORE.md", names)
            self.assertIn("restore.sh", names)
            manifest = json.loads(z.read("MANIFEST.json"))
        self.assertEqual(manifest["profile"], "db")
        self.assertEqual(manifest["contains_secrets"], ["Config/Secrets.xcconfig"])
        self.assertEqual(len(manifest["source_commit"]), 40)

    def test_manifest_db_hash_matches_file(self):
        """Приймальна сторона звіряє sha256 — він мусить бути від СПРАВЖНЬОЇ бази."""
        self._pack()
        with zipfile.ZipFile(self.out) as z:
            manifest = json.loads(z.read("MANIFEST.json"))
        self.assertEqual(manifest["db_sha256"], P.sha256(self.repo.root / "sourcebible.db"))

    def test_restore_script_is_executable_in_archive(self):
        self._pack()
        with zipfile.ZipFile(self.out) as z:
            mode = z.getinfo("restore.sh").external_attr >> 16
        self.assertTrue(mode & 0o111, "restore.sh має бути виконуваним")

    def test_refuses_to_overwrite_without_force(self):
        """Профіль essential збирається хвилинами — мовчки затирати його не можна."""
        self._pack()
        before = self.out.stat().st_mtime_ns
        with self.assertRaises(SystemExit):
            self._pack()
        self.assertEqual(self.out.stat().st_mtime_ns, before, "архів усе-таки перезаписано")

    def test_force_overwrites(self):
        self._pack()
        argv = sys.argv
        sys.argv = ["pack_untracked.py", "--profile", "db", "--write", "--force",
                    "--out", str(self.out)]
        try:
            self.assertEqual(P.main(), 0)
        finally:
            sys.argv = argv

    def test_symlinks_are_reported_not_packed(self):
        """Контроль: zip поклав би ВМІСТ цілі, тож симлінк беззвучно брати не можна."""
        (self.repo.root / "data").mkdir(exist_ok=True)
        (self.repo.root / "data" / "link.zip").symlink_to(self.repo.root / "sourcebible.db")
        take, _ = self.repo.plan("full")
        self.assertNotIn("data/link.zip", take)   # у план симлінк не потрапляє
        self._pack("full")
        with zipfile.ZipFile(self.out) as z:
            self.assertNotIn("data/link.zip", z.namelist())

    def test_restore_doc_renders_secrets_as_prose(self):
        """У RESTORE.md не має бути Python-репру списку."""
        self._pack()
        with zipfile.ZipFile(self.out) as z:
            doc = z.read("RESTORE.md").decode("utf-8")
        self.assertIn("`Config/Secrets.xcconfig`", doc)
        self.assertNotIn("['Config/Secrets.xcconfig']", doc)

    def test_plan_mode_writes_nothing(self):
        """Контроль: без --write на диску не з'являється нічого."""
        argv = sys.argv
        sys.argv = ["pack_untracked.py", "--profile", "db"]
        try:
            self.assertEqual(P.main(), 0)
        finally:
            sys.argv = argv
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
