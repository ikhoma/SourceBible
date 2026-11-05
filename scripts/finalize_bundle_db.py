#!/usr/bin/env python3
"""finalize_bundle_db.py — зібрана база → схудла копія для бандла застосунку.

Повна база (корінь репо) лишається недоторканою: її читають скрипти конвеєра
(process_glosses, build_strongs_merge_map, …) і старі утиліти, а також
дослідження. У бандл іде лише копія без того, чого застосунок не читає.
Той самий принцип, що в strip_licensed_translation.py: джерело не змінюється.

  --kind core        (sourcebible.db)
      • word.gloss, word.gloss_macula → NULL. Колонки ЛИШАЮТЬСЯ: Swift читає
        COALESCE(gloss_display, gloss_macula, gloss) (DatabaseService.swift), і
        без колонки запит не підготувався б — «Оригінал» мовчки спорожнів би.
        Обнулення безпечне, бо запасні гілки COALESCE не спрацьовують ніде:
        скрипт це ПЕРЕВІРЯЄ (рядки з порожньою gloss_display і непорожньою
        запасною глосою = провал) і звіряє хеш показаної глоси до/після.
      • word.lemma, word.language — видалити (Swift їх не читає).
      • індекс idx_word_verse — видалити: префікс idx_word_slot, планувальник
        бере саме idx_word_slot (EXPLAIN QUERY PLAN, 2026-11-05).
  --kind commentary  (commentaries-en.db)
      • comments_fts — видалити: застосунок його не читає, пошуку по коментарях
        немає і не заплановано (рішення Івана 2026-11-05, ADR-027 Amendment).

Пише в тимчасовий файл поруч із DST і перейменовує лише після всіх перевірок.
Ненульовий код виходу на будь-який провал.

    python3 scripts/finalize_bundle_db.py --kind core SRC.db DST.db
    python3 scripts/finalize_bundle_db.py --kind commentary SRC.db DST.db
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sqlite3
import sys
from pathlib import Path

CORE_NULL_COLUMNS = ("gloss", "gloss_macula")
CORE_DROP_COLUMNS = ("lemma", "language")
CORE_DROP_INDEXES = ("idx_word_verse",)
DISPLAY_GLOSS_SQL = ("SELECT COALESCE(gloss_display, gloss_macula, gloss) "
                     "FROM word ORDER BY rowid")
COMMENTARY_DROP_TABLES = ("comments_fts",)
COMMENTARY_KEEP_COUNTS = ("comments", "comment_verses", "module_info")


class FinalizeError(Exception):
    pass


def _columns(cur, table: str) -> set[str]:
    return {r[1] for r in cur.execute(f'PRAGMA table_info("{table}")')}


def _display_gloss_digest(cur) -> tuple[str, int]:
    h = hashlib.sha256()
    n = 0
    for (g,) in cur.execute(DISPLAY_GLOSS_SQL):
        h.update(b"\x00" if g is None else b"\x01" + g.encode())
        n += 1
    return h.hexdigest(), n


def finalize_core(cur) -> list[str]:
    log: list[str] = []
    cols = _columns(cur, "word")
    missing = {"gloss_display", *CORE_NULL_COLUMNS} - cols
    if missing:
        raise FinalizeError(f"word: немає колонок {sorted(missing)} — стара/інша схема?")

    bad = cur.execute(
        "SELECT id, gloss_macula, gloss FROM word WHERE gloss_display IS NULL "
        "AND (gloss_macula IS NOT NULL OR gloss IS NOT NULL) LIMIT 5").fetchall()
    if bad:
        n = cur.execute(
            "SELECT COUNT(*) FROM word WHERE gloss_display IS NULL "
            "AND (gloss_macula IS NOT NULL OR gloss IS NOT NULL)").fetchone()[0]
        raise FinalizeError(
            f"{n} слів показують запасну глосу (gloss_display порожня, а gloss_macula/"
            f"gloss ні) — обнулення змінило б показ. Приклади (id, gloss_macula, gloss): "
            f"{bad}. Виправ process_glosses або прибери обнулення.")

    before = _display_gloss_digest(cur)
    cur.execute("UPDATE word SET " + ", ".join(f"{c} = NULL" for c in CORE_NULL_COLUMNS))
    log.append(f"word.{'/'.join(CORE_NULL_COLUMNS)} → NULL ({before[1]:,} рядків)")
    for c in CORE_DROP_COLUMNS:
        if c in cols:
            cur.execute(f'ALTER TABLE word DROP COLUMN "{c}"')
            log.append(f"word.{c} видалено")
    for ix in CORE_DROP_INDEXES:
        if cur.execute("SELECT 1 FROM sqlite_schema WHERE type='index' AND name=?",
                       (ix,)).fetchone():
            cur.execute(f'DROP INDEX "{ix}"')
            log.append(f"індекс {ix} видалено")
    after = _display_gloss_digest(cur)
    if after != before:
        raise FinalizeError(f"показана глоса змінилась: {before} → {after}")
    log.append("показана глоса незмінна (sha256 збігся)")
    return log


def finalize_commentary(cur) -> list[str]:
    log: list[str] = []
    before = {t: cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
              for t in COMMENTARY_KEEP_COUNTS}
    for t in COMMENTARY_DROP_TABLES:
        if cur.execute("SELECT 1 FROM sqlite_schema WHERE name=?", (t,)).fetchone():
            cur.execute(f'DROP TABLE "{t}"')
            log.append(f"{t} видалено")
    after = {t: cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
             for t in COMMENTARY_KEEP_COUNTS}
    if after != before:
        raise FinalizeError(f"кількість рядків змінилась: {before} → {after}")
    log.append("comments/comment_verses/module_info незмінні: "
               + ", ".join(f"{k}={v:,}" for k, v in after.items()))
    return log


def run(kind: str, src: Path, dst: Path) -> list[str]:
    if src.resolve() == dst.resolve():
        raise FinalizeError("SRC і DST — один файл; джерело змінювати не можна")
    if not src.exists():
        raise FinalizeError(f"{src}: файлу немає")
    tmp = dst.with_name(dst.name + ".finalize-tmp")
    for p in (tmp, Path(str(tmp) + "-wal"), Path(str(tmp) + "-shm")):
        if p.exists():
            p.unlink()
    with sqlite3.connect(f"file:{src}?mode=ro&immutable=1", uri=True) as s, \
            sqlite3.connect(tmp) as d:
        s.backup(d)
    s.close()
    d.close()
    try:
        con = sqlite3.connect(tmp)
        cur = con.cursor()
        log = finalize_core(cur) if kind == "core" else finalize_commentary(cur)
        con.commit()
        cur.execute("VACUUM")
        ok = cur.execute("PRAGMA quick_check").fetchone()[0]
        if ok != "ok":
            raise FinalizeError(f"quick_check: {ok}")
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        con.close()
        for side in ("-wal", "-shm"):
            p = Path(str(tmp) + side)
            if p.exists() and p.stat().st_size == 0:
                p.unlink()
        os.replace(tmp, dst)
    except BaseException:
        try:
            con.close()
        except Exception:
            pass
        if tmp.exists():
            tmp.unlink()
        raise
    log.append(f"{src.stat().st_size / 1e6:.1f} МБ → {dst.stat().st_size / 1e6:.1f} МБ")
    return log


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--kind", choices=("core", "commentary"), required=True)
    ap.add_argument("src", type=Path)
    ap.add_argument("dst", type=Path)
    args = ap.parse_args(argv)
    try:
        log = run(args.kind, args.src, args.dst)
    except FinalizeError as e:
        print(f"✗ finalize ({args.kind}): {e}", file=sys.stderr)
        return 1
    for line in log:
        print(f"  {line}")
    print(f"✓ {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
