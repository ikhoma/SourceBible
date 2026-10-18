#!/usr/bin/env python3
"""
Strip one licensed translation (default: NASB) out of a COPY of sourcebible.db.

Why: the App Store build must not carry NASB (no licence) — not hidden, ABSENT from the
bundle. TestFlight (Release) keeps the full DB. Run by the "Strip NASB (AppStore only)"
build phase against the DB that Copy Bundle Resources already put into the .app;
can also be run by hand.

    python3 scripts/strip_licensed_translation.py SRC.db DST.db [--translation NASB]

SRC is opened read-only and never modified. DST is written atomically (tmp + rename).

What is removed (measured 2026-10-16 on the shipped DB):
  translation 1 · verse 31 102 · verse_org 31 169 · book_name 66 rows,
  the FTS5 index over verse (rebuilt from the remaining rows),
  search_terms['en'] (rebuilt — 3 254 terms existed ONLY because of NASB),
  sqlite_stat4 samples with NASB keys (re-ANALYZEd), freed pages (VACUUM).

Exits non-zero, and leaves NO DST, if any check fails — including a raw byte scan
of the finished file for the translation id and for sample verse texts.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import os
import time
import sqlite3
import sys
from pathlib import Path

if sys.version_info < (3, 10):
    sys.exit(f"✗ Python ≥ 3.10 required, got {sys.version.split()[0]} ({sys.executable})")

sys.path.insert(0, str(Path(__file__).resolve().parent))
# One implementation of the dictionary builder — never a copy (see rebuild_search_terms.py).
# build_db prints "WARNING: requests not installed…" at import time; inside an Xcode build
# phase any line starting with "warning:" becomes a build warning, so the import is muted.
with contextlib.redirect_stdout(io.StringIO()):
    from build_db import build_search_terms, verify_search_terms  # noqa: E402

# Tables that reference a translation by id. A NEW table with such a column must be added
# here — `check_no_references` scans every TEXT column of every table, so a forgotten one
# fails the build instead of shipping.
DELETES = [
    ("verse", "translation"),
    ("verse_org", "translation"),
    ("book_name", "translation_id"),
    ("translation", "id"),
]
SKIP_SCAN = {"sqlite_sequence", "sqlite_stat1", "sqlite_stat4"}
N_TEXT_SAMPLES = 25


def fail(msg: str) -> None:
    raise SystemExit(f"✗ {msg}")


def counts_by_translation(cur) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    for table, col in DELETES[:-1]:
        out[table] = dict(cur.execute(f'SELECT "{col}", COUNT(*) FROM "{table}" GROUP BY 1'))
    return out


def unique_text_samples(cur, tid: str) -> list[str]:
    """Verse texts of `tid` that occur in no other translation — the raw byte scan
    looks for them after VACUUM. Long ones only, so a hit cannot be a coincidence.

    One pass + a Python set, NOT a correlated `NOT EXISTS` subquery: text_clean has no
    index, and when SQLite drives that query through idx_verse_loc it evaluates the
    subquery for every row before ORDER BY/LIMIT — 31k × 155k comparisons. Measured
    2026-10-16: seconds in the Linux sandbox, a hang of 15+ min in the Xcode build phase."""
    others = {t for (t,) in cur.execute(
        "SELECT text_clean FROM verse WHERE translation <> ?", (tid,))}
    out = []
    for (t,) in cur.execute(
            "SELECT text_clean FROM verse WHERE translation = ? ORDER BY rowid", (tid,)):
        if len(t) > 60 and t not in others:
            out.append(t)
            if len(out) == N_TEXT_SAMPLES:
                break
    return out


_T0 = time.monotonic()


def step(msg: str) -> None:
    """Timestamped progress — in an Xcode build log this is the only way to see
    which stage a slow run is in."""
    print(f"  [{time.monotonic() - _T0:6.1f}s] {msg}", flush=True)


def check_no_references(cur, tid: str) -> list[str]:
    bad = []
    for (table,) in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'").fetchall():
        if table in SKIP_SCAN or table.startswith("verse_fts"):
            continue
        for _, col, typ, *_ in cur.execute(f'PRAGMA table_info("{table}")').fetchall():
            if typ.upper() not in ("TEXT", ""):
                continue
            n = cur.execute(f'SELECT COUNT(*) FROM "{table}" WHERE "{col}" = ? '
                            f'OR "{col}" LIKE ?', (tid, f"{tid}|%")).fetchone()[0]
            if n:
                bad.append(f"{table}.{col}: {n} rows still reference {tid}")
    return bad


def strip(src: Path, dst: Path, tid: str) -> int:
    if not src.exists():
        fail(f"source not found: {src}")
    tmp = dst.with_name(dst.name + ".strip-tmp")
    for p in (tmp, Path(str(tmp) + "-journal"), Path(str(tmp) + "-wal"), Path(str(tmp) + "-shm")):
        p.unlink(missing_ok=True)

    # Backup API instead of cp: consistent snapshot even if SRC is in WAL mode, and SRC
    # is opened read-only — no -wal/-shm is created next to it.
    step(f"copy {src.name} → {tmp.name}")
    with sqlite3.connect(f"file:{src}?mode=ro", uri=True) as s, sqlite3.connect(tmp) as d:
        s.backup(d)

    try:
        con = sqlite3.connect(tmp)
        cur = con.cursor()
        present = {r[0] for r in cur.execute("SELECT id FROM translation")}
        if tid not in present:
            fail(f"{tid} is not in {src} (translations: {sorted(present)}) — wrong DB?")

        before = counts_by_translation(cur)
        step("pick byte-scan samples")
        samples = unique_text_samples(cur, tid)
        if len(samples) < 5:
            fail(f"only {len(samples)} unique {tid} verse texts found for the byte scan")
        print(f"Stripping {tid}: " + ", ".join(
            f"{t} {before[t].get(tid, 0):,}" for t in before))

        step("delete rows")
        cur.execute("PRAGMA journal_mode=DELETE")       # no -wal next to a bundled file
        for table, col in DELETES:
            cur.execute(f'DELETE FROM "{table}" WHERE "{col}" = ?', (tid,))
        # External-content FTS5: deleting from `verse` does NOT touch the index.
        step("rebuild FTS")
        cur.execute("INSERT INTO verse_fts(verse_fts) VALUES('rebuild')")
        cur.execute("INSERT INTO verse_fts(verse_fts) VALUES('integrity-check')")
        con.commit()

        step("rebuild search_terms")
        with contextlib.redirect_stdout(io.StringIO()):   # its ✓/WARNING lines → not Xcode warnings
            build_search_terms(cur, con)                # per-language, from what is left
        failures = verify_search_terms(cur)

        # stat4 holds index-key SAMPLES (e.g. 'NASB|GEN|1|1'). Clear first so that an
        # SQLite built without STAT4 cannot leave the old samples behind.
        if cur.execute("SELECT 1 FROM sqlite_master WHERE name='sqlite_stat4'").fetchone():
            cur.execute("DELETE FROM sqlite_stat4")
        con.commit()
        step("ANALYZE")
        cur.execute("ANALYZE")
        con.commit()

        # ── checks before VACUUM ────────────────────────────────────────────────
        after = counts_by_translation(cur)
        for table in before:
            for t, n in before[table].items():
                want = 0 if t == tid else n
                got = after[table].get(t, 0)
                if got != want:
                    failures.append(f"{table}[{t}]: expected {want:,}, got {got:,}")
        failures += check_no_references(cur, tid)
        fts_docs = cur.execute("SELECT COUNT(*) FROM verse_fts_docsize").fetchone()[0]
        n_verse = cur.execute("SELECT COUNT(*) FROM verse").fetchone()[0]
        if fts_docs != n_verse:
            failures.append(f"verse_fts has {fts_docs:,} docs, verse has {n_verse:,} rows")
        if failures:
            fail("verification failed:\n    • " + "\n    • ".join(failures))

        step("VACUUM")
        cur.execute("VACUUM")                           # freed pages still hold NASB text
        con.close()

        # ── raw byte scan of the finished file ─────────────────────────────────
        step("byte scan")
        blob = tmp.read_bytes()
        needles = [f"{tid}|".encode(), f"'{tid}'".encode()] + [s.encode() for s in samples]
        hits = [n[:50] for n in needles if n in blob]
        if hits:
            fail(f"{len(hits)} {tid} byte patterns survive in the file, e.g. {hits[:3]}")

        os.replace(tmp, dst)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise

    print(f"✓ {dst} — {tid} absent ({len(samples)} text samples + id byte-scanned), "
          f"{os.path.getsize(src)/1e6:.0f} MB → {os.path.getsize(dst)/1e6:.0f} MB")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("src", type=Path)
    ap.add_argument("dst", type=Path)
    ap.add_argument("--translation", default="NASB")
    a = ap.parse_args()
    if a.src.resolve() == a.dst.resolve():
        fail("SRC and DST must differ — the source DB is never modified")
    return strip(a.src, a.dst, a.translation)


if __name__ == "__main__":
    raise SystemExit(main())
