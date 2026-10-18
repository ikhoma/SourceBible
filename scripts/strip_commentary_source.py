#!/usr/bin/env python3
"""
Strip one commentary source (default: Spurgeon-VE) out of a COPY of commentaries-en.db.

Why: Spurgeon's "Verse Expositions" in the shipped module is the Grace-eBooks.com 2011
compilation, "© Grace-eBooks.com 2011" (legal/commentaries-provenance-2026-10-17.md).
Spurgeon's words are PD, the compilation claims copyright → the App Store build ships
without it. TestFlight (Release) keeps the full module. Spurgeon's Treasury of David
(source 'Spurgeon-TOD', CC0, Psalms only) stays.

Run by the "Strip … (AppStore only)" build phase against the module that Copy Bundle
Resources put into the .app; can also be run by hand.

    python3 scripts/strip_commentary_source.py SRC.db DST.db [--source Spurgeon-VE]

SRC is opened read-only and never modified. DST is written atomically (tmp + rename).

What is removed (measured 2026-10-18 on the shipped module):
  comments 1 362 · comment_verses 23 923 (joined by key) · comments_fts (rebuilt from
  what is left) · the source's entries in module_info.sources / book_versions ·
  freed pages (VACUUM).

Exits non-zero, and leaves NO DST, if any check fails — including a raw byte scan of the
finished file for the source id and for text samples unique to that source.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

if sys.version_info < (3, 10):
    sys.exit(f"✗ Python ≥ 3.10 required, got {sys.version.split()[0]} ({sys.executable})")

N_TEXT_SAMPLES = 25
SAMPLE_LEN = 90
_T0 = time.monotonic()


def step(msg: str) -> None:
    print(f"  [{time.monotonic() - _T0:6.1f}s] {msg}", flush=True)


def fail(msg: str) -> None:
    raise SystemExit(f"✗ {msg}")


def counts(cur) -> tuple[dict[str, int], dict[str, int]]:
    comments = dict(cur.execute("SELECT source, COUNT(*) FROM comments GROUP BY 1"))
    verses = dict(cur.execute(
        "SELECT c.source, COUNT(*) FROM comment_verses v JOIN comments c ON c.key = v.key "
        "GROUP BY 1"))
    return comments, verses


def unique_text_samples(cur, source: str) -> list[str]:
    """Substrings of the source's comments that occur in no other source — the raw byte
    scan looks for them after VACUUM. Taken from the body (offset SAMPLE_LEN), not the
    first line: comments open with the quoted Bible verse, which other authors quote too."""
    out: list[str] = []
    rows = cur.execute("SELECT text FROM comments WHERE source = ? ORDER BY rowid",
                       (source,)).fetchall()
    for (text,) in rows:
        frag = text[SAMPLE_LEN:SAMPLE_LEN * 2]
        if len(frag) < SAMPLE_LEN or "\n" in frag:
            continue
        hit = cur.execute("SELECT 1 FROM comments WHERE source <> ? AND instr(text, ?) > 0 "
                          "LIMIT 1", (source, frag)).fetchone()
        if not hit:
            out.append(frag)
            if len(out) == N_TEXT_SAMPLES:
                break
    return out


def strip_module_info(cur, source: str) -> None:
    row = cur.execute("SELECT value FROM module_info WHERE name = 'sources'").fetchone()
    if row:
        sources = [s for s in json.loads(row[0]) if s.get("source") != source]
        cur.execute("UPDATE module_info SET value = ? WHERE name = 'sources'",
                    (json.dumps(sources, ensure_ascii=False),))
    row = cur.execute("SELECT value FROM module_info WHERE name = 'book_versions'").fetchone()
    if row:
        bv = json.loads(row[0])
        bv.pop(source, None)
        cur.execute("UPDATE module_info SET value = ? WHERE name = 'book_versions'",
                    (json.dumps(bv, ensure_ascii=False, sort_keys=True),))


def strip(src: Path, dst: Path, source: str) -> int:
    if not src.exists():
        fail(f"source not found: {src}")
    tmp = dst.with_name(dst.name + ".strip-tmp")
    for p in (tmp, Path(f"{tmp}-journal"), Path(f"{tmp}-wal"), Path(f"{tmp}-shm")):
        p.unlink(missing_ok=True)

    step(f"copy {src.name} → {tmp.name}")
    with sqlite3.connect(f"file:{src}?mode=ro", uri=True) as s, sqlite3.connect(tmp) as d:
        s.backup(d)

    try:
        con = sqlite3.connect(tmp)
        cur = con.cursor()
        before_c, before_v = counts(cur)
        if source not in before_c:
            fail(f"{source} is not in {src} (sources: {sorted(before_c)}) — wrong module?")
        step("pick byte-scan samples")
        samples = unique_text_samples(cur, source)
        if len(samples) < 5:
            fail(f"only {len(samples)} unique {source} text samples found for the byte scan")
        print(f"Stripping {source}: comments {before_c[source]:,}, "
              f"comment_verses {before_v.get(source, 0):,}", flush=True)

        step("delete rows")
        cur.execute("PRAGMA journal_mode=DELETE")       # no -wal next to a bundled file
        cur.execute("DELETE FROM comment_verses WHERE key IN "
                    "(SELECT key FROM comments WHERE source = ?)", (source,))
        cur.execute("DELETE FROM comments WHERE source = ?", (source,))
        strip_module_info(cur, source)
        # External-content FTS5: deleting from `comments` does NOT touch the index.
        step("rebuild FTS")
        cur.execute("INSERT INTO comments_fts(comments_fts) VALUES('rebuild')")
        cur.execute("INSERT INTO comments_fts(comments_fts) VALUES('integrity-check')")
        con.commit()

        # ── checks before VACUUM ────────────────────────────────────────────────
        failures: list[str] = []
        after_c, after_v = counts(cur)
        for name, before, after in (("comments", before_c, after_c),
                                    ("comment_verses", before_v, after_v)):
            for s, n in before.items():
                want = 0 if s == source else n
                if after.get(s, 0) != want:
                    failures.append(f"{name}[{s}]: expected {want:,}, got {after.get(s, 0):,}")
        orphans = cur.execute("SELECT COUNT(*) FROM comment_verses v LEFT JOIN comments c "
                              "ON c.key = v.key WHERE c.key IS NULL").fetchone()[0]
        if orphans:
            failures.append(f"comment_verses: {orphans:,} rows point at no comment")
        fts = cur.execute("SELECT COUNT(*) FROM comments_fts_docsize").fetchone()[0]
        n_comments = cur.execute("SELECT COUNT(*) FROM comments").fetchone()[0]
        if fts != n_comments:
            failures.append(f"comments_fts has {fts:,} docs, comments has {n_comments:,}")
        leftover = cur.execute("SELECT name FROM module_info WHERE instr(value, ?) > 0",
                               (source,)).fetchall()
        if leftover:
            failures.append(f"module_info still mentions {source}: {[r[0] for r in leftover]}")
        if failures:
            fail("verification failed:\n    • " + "\n    • ".join(failures))

        step("VACUUM")
        cur.execute("VACUUM")                           # freed pages still hold the text
        con.close()

        step("byte scan")
        blob = tmp.read_bytes()
        needles = [source.encode()] + [s.encode() for s in samples]
        hits = [n[:50] for n in needles if n in blob]
        if hits:
            fail(f"{len(hits)} {source} byte patterns survive in the file, e.g. {hits[:3]}")

        os.replace(tmp, dst)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise

    print(f"✓ {dst} — {source} absent ({len(samples)} text samples + id byte-scanned), "
          f"{os.path.getsize(src) / 1e6:.0f} MB → {os.path.getsize(dst) / 1e6:.0f} MB")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("src", type=Path)
    ap.add_argument("dst", type=Path)
    ap.add_argument("--source", default="Spurgeon-VE")
    a = ap.parse_args()
    if a.src.resolve() == a.dst.resolve():
        fail("SRC and DST must differ — the source module is never modified")
    return strip(a.src, a.dst, a.source)


if __name__ == "__main__":
    raise SystemExit(main())
