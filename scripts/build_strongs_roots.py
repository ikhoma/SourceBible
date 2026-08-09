#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_strongs_roots.py  (ADR-030)

Обчислює root_id (первинний корінь) для кожного Strong's-номера з поля
`derivation` словників OpenScriptures і записує його в таблицю `strongs`.

Запускати НА MAC (база — APFS sparse-файл; у Linux-пісочниці не читати/не писати).
Python 3.10+ (project minimum, see CLAUDE.md — the old "write for 3.9" rule was
withdrawn 2026-08-05; `rebuild.sh` gates the version with a non-zero exit).

Використання:
    python3 scripts/build_strongs_roots.py sourcebible.db
    python3 scripts/build_strongs_roots.py sourcebible.db \
        --hebrew data/strongs-hebrew-dictionary.js \
        --greek  data/strongs-greek-dictionary.js

Без --hebrew/--greek словники тягнуться з OpenScriptures (public domain; потрібна мережа).
"""
import argparse
import json
import re
import sqlite3
import sys
from typing import Dict, List, Optional

HEB_URL = "https://raw.githubusercontent.com/openscriptures/strongs/master/hebrew/strongs-hebrew-dictionary.js"
GRK_URL = "https://raw.githubusercontent.com/openscriptures/strongs/master/greek/strongs-greek-dictionary.js"

REF_RE = re.compile(r'\b([HG]\d{1,5})\b')
PRIMITIVE_RE = re.compile(r'primitive root', re.I)

# Acceptance (ADR-030) — на темі «Божий характер». Розбіжність = білд падає.
ACCEPTANCE = {
    "H7349": "H7355", "H7356": "H7355", "H7358": "H7355",   # r-ch-m
    "H2587": "H2603", "H2580": "H2603",                     # ch-n-n
    "H571": "H539",  "H530": "H539",                        # aman
    "H2617": "H2616",                                       # hesed <- chasad
    "H5375": "H5375", "H5352": "H5352",                     # primitive roots
}


def load_js_dict(text: str) -> Dict[str, dict]:
    """Файли мають вигляд:  var strongs...Dictionary = { ... };"""
    start = text.index("{")
    end = text.rindex("}")
    return json.loads(text[start:end + 1])


def fetch(url: str) -> str:
    import urllib.request
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode("utf-8")


def get_dict(path: Optional[str], url: str) -> Dict[str, dict]:
    if path:
        with open(path, encoding="utf-8") as f:
            return load_js_dict(f.read())
    return load_js_dict(fetch(url))


def parents_of(entry: dict) -> List[str]:
    d = entry.get("derivation") or ""
    if PRIMITIVE_RE.search(d):
        return []
    return REF_RE.findall(d)


def build_roots(entries: Dict[str, dict]):
    cache: Dict[str, str] = {}
    dangling: List[str] = []

    def resolve(sid: str, stack) -> str:
        if sid in cache:
            return cache[sid]
        entry = entries.get(sid)
        if entry is None:
            dangling.append(sid)
            cache[sid] = sid
            return sid
        for p in parents_of(entry):
            if p in stack or p not in entries:
                continue
            root = resolve(p, stack | {sid})
            cache[sid] = root
            return root
        cache[sid] = sid          # primitive root / без валідних батьків
        return sid

    for sid in entries:
        resolve(sid, set())
    return cache, dangling


def base_id(sid: str) -> str:
    """H1471a -> H1471 (extended Strong's, ADR-019)."""
    m = re.match(r'^([HG]\d{1,5})[a-z]?$', sid)
    return m.group(1) if m else sid


def main() -> None:
    ap = argparse.ArgumentParser(description="ADR-030: root_id для strongs")
    ap.add_argument("db")
    ap.add_argument("--hebrew")
    ap.add_argument("--greek")
    args = ap.parse_args()

    entries: Dict[str, dict] = {}
    entries.update(get_dict(args.hebrew, HEB_URL))
    entries.update(get_dict(args.greek, GRK_URL))
    roots, dangling = build_roots(entries)

    con = sqlite3.connect(args.db)
    cur = con.cursor()
    cols = [r[1] for r in cur.execute("PRAGMA table_info(strongs)")]
    if "root_id" not in cols:
        cur.execute("ALTER TABLE strongs ADD COLUMN root_id TEXT")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_strongs_root ON strongs(root_id)")

    updated = self_root = missing = 0
    for (sid,) in cur.execute("SELECT id FROM strongs").fetchall():
        root = roots.get(sid) or roots.get(base_id(sid))
        if root is None:
            root, missing = sid, missing + 1     # безпечний дефолт = сам собі
        if root == sid:
            self_root += 1
        cur.execute("UPDATE strongs SET root_id=? WHERE id=?", (root, sid))
        updated += 1
    con.commit()

    fails = []
    print("Acceptance (ADR-030):")
    for sid, expected in ACCEPTANCE.items():
        row = cur.execute("SELECT root_id FROM strongs WHERE id=?", (sid,)).fetchone()
        got = row[0] if row else None
        ok = got == expected
        if not ok:
            fails.append((sid, expected, got))
        print("  %-6s -> %-6s (очікувано %s) %s" % (sid, got, expected, "ok" if ok else "FAIL"))

    print("Оновлено: %d | самокорінь: %d | без словника: %d | dangling: %d"
          % (updated, self_root, missing, len(dangling)))
    con.close()
    if fails:
        print("ACCEPTANCE FAILED:", fails, file=sys.stderr)
        sys.exit(1)
    print("OK — root_id заповнено, acceptance пройдено.")


if __name__ == "__main__":
    main()
