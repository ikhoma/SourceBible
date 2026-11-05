#!/usr/bin/env python3
"""check_bundle_db.py — гейт складу і розміру баз, що їдуть у бандл.

Навіщо. Після ADR-027 коментарі живуть лише в commentaries-en.db, але rebuild.sh ще
два місяці викликав import_commentaries.py і щоразу заново писав у sourcebible.db
таблиці `comments`/`comment_verses` (~101 МБ), яких застосунок уже не читав. Жоден
гейт цього не бачив: перевірки дивились на вміст таблиць, а не на те, чи таблиця
взагалі повинна там бути. Звідси 600+ МБ у App Store (2026-11-05).

Що перевіряє (--kind core | commentary):
  1. Склад: кожна таблиця бази — в allow-list (або службова SQLite). Нова таблиця =
     свідоме рішення: додай її сюди тим самим комітом, що й код, який її читає.
  2. Повноту: кожна таблиця з allow-list присутня.
  3. core: те, що finalize_bundle_db.py прибирає з бандла, справді прибрано
     (word.lemma/language, порожні word.gloss/gloss_macula, idx_word_verse).
  4. Розмір: файл не більший за --max-mb.
  5. --app-dir: у теці застосунку немає побічних файлів, які синхронізована
     група Xcode могла б потягти в бандл (*.bak, -wal/-shm, .fuse_hidden*).

Читає базу лише в mode=ro&immutable=1 (без -shm/-wal поруч). Ненульовий код виходу.

    python3 scripts/check_bundle_db.py [--kind core] sourcebible.db [--app-dir SourceBible]
    python3 scripts/check_bundle_db.py --kind commentary commentaries-en.db
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import sqlite3
import sys

# Службові таблиці SQLite: можуть бути або не бути залежно від схеми і ANALYZE.
OPTIONAL_TABLES = frozenset({"sqlite_sequence", "sqlite_stat1", "sqlite_stat4"})

PROFILES = {
    "core": {
        # Таблиці, які читає застосунок (і FTS5-тіньові таблиці verse_fts).
        "allowed": frozenset({
            "book", "book_name", "cross_reference", "footnote", "rendering",
            "rendering_example", "search_terms", "strongs", "translation", "verse",
            "verse_fts", "verse_fts_config", "verse_fts_data", "verse_fts_docsize",
            "verse_fts_idx", "verse_org", "word", "word_rendering",
        }),
        # finalize_bundle_db.py --kind core
        "forbidden_columns": {"word": ("lemma", "language")},
        "must_be_null": {"word": ("gloss", "gloss_macula")},
        "forbidden_indexes": ("idx_word_verse",),
        # Повна (TestFlight) база після finalize заміряна 2026-11-05: 298 МБ.
        # Запас ~7%. Перевищення — привід подивитись, що виросло, а не підняти поріг.
        "max_mb": 320,
    },
    "commentary": {
        # comments_fts свідомо відсутня: пошуку по коментарях немає (ADR-027 Amendment
        # 2026-11-05). Повернеться разом із фічею — тоді й сюди.
        "allowed": frozenset({"comments", "comment_verses", "module_info"}),
        "forbidden_columns": {},
        "must_be_null": {},
        "forbidden_indexes": (),
        # Після finalize заміряно 125.5 МБ (з Spurgeon-VE; App Store вирізає його далі).
        "max_mb": 135,
    },
}

STRAY_PATTERNS = ("*.bak", "*.db-wal", "*.db-shm", "*.db-journal", ".fuse_hidden*",
                  "*.finalize-tmp")


def check(db_path: str, max_mb: float | None = None, kind: str = "core") -> list[str]:
    """Повертає список проблем; порожній список = база придатна для бандла."""
    prof = PROFILES[kind]
    if max_mb is None:
        max_mb = prof["max_mb"]
    problems: list[str] = []
    con = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
    try:
        tables = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_schema WHERE type = 'table'")}
        indexes = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_schema WHERE type = 'index'")}

        extra = sorted(tables - prof["allowed"] - OPTIONAL_TABLES)
        missing = sorted(prof["allowed"] - tables)
        if extra:
            problems.append(
                "зайві таблиці (застосунок їх не читає, або їх не внесено в "
                "allow-list): " + ", ".join(extra))
        if missing:
            problems.append("відсутні таблиці: " + ", ".join(missing))

        for table, cols in prof["forbidden_columns"].items():
            if table in tables:
                present = {r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
                bad = [c for c in cols if c in present]
                if bad:
                    problems.append(f"{table}: колонки {bad} мають бути прибрані "
                                    "(finalize_bundle_db.py не запускався?)")
        for table, cols in prof["must_be_null"].items():
            if table in tables:
                present = {r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
                for c in cols:
                    if c in present:
                        n = con.execute(f'SELECT COUNT(*) FROM "{table}" '
                                        f'WHERE "{c}" IS NOT NULL').fetchone()[0]
                        if n:
                            problems.append(f"{table}.{c}: {n:,} непорожніх значень, "
                                            "у бандлі має бути NULL")
        bad_ix = sorted(set(prof["forbidden_indexes"]) & indexes)
        if bad_ix:
            problems.append("зайві індекси: " + ", ".join(bad_ix))
    finally:
        con.close()

    size_mb = os.path.getsize(db_path) / 1_000_000
    if size_mb > max_mb:
        problems.append(f"розмір {size_mb:.1f} МБ > ліміту {max_mb:g} МБ")
    return problems


def stray_files(app_dir: str) -> list[str]:
    found = []
    for root, _dirs, files in os.walk(app_dir):
        for f in files:
            if any(fnmatch.fnmatch(f, p) for p in STRAY_PATTERNS):
                found.append(os.path.join(root, f))
    return sorted(found)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("db")
    ap.add_argument("--kind", choices=sorted(PROFILES), default="core")
    ap.add_argument("--max-mb", type=float, default=None)
    ap.add_argument("--app-dir", help="тека застосунку для пошуку побічних файлів")
    args = ap.parse_args(argv)

    if not os.path.exists(args.db):
        print(f"✗ {args.db}: файлу немає", file=sys.stderr)
        return 1
    problems = check(args.db, args.max_mb, args.kind)
    if args.app_dir:
        stray = stray_files(args.app_dir)
        if stray:
            problems.append("побічні файли в теці застосунку (потраплять у бандл): "
                            + ", ".join(stray))
    if problems:
        for p in problems:
            print(f"✗ {args.db}: {p}", file=sys.stderr)
        return 1
    size_mb = os.path.getsize(args.db) / 1_000_000
    limit = args.max_mb if args.max_mb is not None else PROFILES[args.kind]["max_mb"]
    print(f"✓ {args.db} ({args.kind}): склад OK, {size_mb:.1f} МБ ≤ {limit:g} МБ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
