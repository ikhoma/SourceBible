#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pack_untracked.py — зібрати архів усього, що НЕ їде в git, для переїзду на іншу машину.

Python 3.10+ (мінімум проєкту, CLAUDE.md).
За замовчуванням НІЧОГО не пише — друкує план і розміри. Архів створює лише `--write`.

    python3 scripts/pack_untracked.py                      # план, профіль essential
    python3 scripts/pack_untracked.py --profile db
    python3 scripts/pack_untracked.py --profile full --write
    python3 scripts/pack_untracked.py --write --out ~/Desktop/sb.zip

Навіщо
------
Заміряно 2026-08-08: поза git лишається **2.37 GB у 33 794 файлах** — `sourcebible.db`
(357 MB), `data/` (1.6 GB) і `Config/Secrets.xcconfig`. З чистого клону застосунок не
збирається (`docs/BUILD.md`). Збирати цей список руками — гарантовано забути щось.

⛔ **Перелік не хардкодиться.** Джерело правди —
`git ls-files --others --ignored --exclude-standard`, тобто сам `.gitignore`. Список,
записаний у скрипті, розійшовся б із `.gitignore` рівно так, як сьогодні розійшлись
статуси ADR із кодом. Тут розійтися нема чому.

Що НЕ береться і чому
---------------------
Із ignored-набору віднімається те, що відновлюється саме або є шумом. Кожен виняток
друкується в плані з причиною — мовчазне викидання даних гірше за зайвий гігабайт.

  bh_cache*            кеш HTTP-скрейпу BibleHub, 654 MB у 31 тис. файлів — качається заново
  *.bak.*, _snapshot_* локальні знімки перед правками, цінності на новій машині не мають
  backups/             копії бази ~150–190 MB кожна
  Resources/*.db       ДУБЛІКАТ кореневої бази; `restore.sh` покладе її туди сам
  __pycache__, .DS_Store, *.log, DerivedData, xcuserdata   похідне й машинозалежне

⚠️ **Архів містить `Config/Secrets.xcconfig` із живими токенами Mixpanel.**
Переносити диском або зашифрованим каналом; у публічну хмару не класти; після
розпакування видалити. Скрипт друкує це попередження й перед створенням архіву теж.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from fnmatch import fnmatch
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (глоб, причина) — застосовується до шляху відносно кореня репо.
ALWAYS_SKIP: list[tuple[str, str]] = [
    ("SourceBible/Resources/sourcebible.db", "дублікат кореневої бази — restore.sh покладе сам"),
    ("sourcebible.db-wal", "журнал SQLite, не переносити"),
    ("sourcebible.db-shm", "журнал SQLite, не переносити"),
    ("sourcebible-backup.db", "локальна резервна копія"),
    ("SourceBible/Resources/sourcebible-backup.db", "локальна резервна копія"),
    ("sb_baseline.db*", "локальний базлайн для порівнянь"),
    ("backups/*", "копії бази, 150–190 MB кожна"),
    ("*/__pycache__/*", "похідне від Python"),
    ("__pycache__/*", "похідне від Python"),
    ("*.pyc", "похідне від Python"),
    ("*.DS_Store", "сміття macOS"),
    ("*.log", "логи прогонів"),
    ("DerivedData/*", "кеш Xcode"),
    ("*/xcuserdata/*", "машинозалежні налаштування Xcode"),
    ("scripts/_to_delete/*", "зламані копії, чекають на видалення"),
    (".venv/*", "віртуальне оточення — створюється заново"),
    ("*.fuse_hidden*", "артефакт FUSE"),
]

# Профілі: що ще відкидається понад ALWAYS_SKIP.
PROFILES: dict[str, list[tuple[str, str]]] = {
    "db": [
        ("data/*", "профіль db: датасети не потрібні, поки не міняєш конвеєр збірки"),
        ("scripts/.cache/*", "профіль db: кеш крос-рефів"),
    ],
    "essential": [
        ("data/bh_cache*", "кеш HTTP-скрейпу BibleHub — качається заново"),
        ("data/bh_cache_hebrew/*", "кеш HTTP-скрейпу BibleHub — качається заново"),
        ("data/bh_cache/*", "кеш HTTP-скрейпу BibleHub — качається заново"),
        ("data/*.bak.*", "локальні знімки перед правками"),
        ("data/_snapshot_*", "локальний знімок перед правками"),
        ("data/_snapshot_*/*", "локальний знімок перед правками"),
        ("scripts/.cache/*", "кеш крос-рефів OpenBible — качається заново"),
    ],
    "full": [],
}

SECRET_PATHS = ["Config/Secrets.xcconfig"]


def git(*args: str) -> str:
    r = subprocess.run(["git", *args], cwd=REPO, capture_output=True, timeout=180)
    if r.returncode != 0:
        sys.exit(f"✗ git {' '.join(args)}: {r.stderr.decode('utf-8', 'replace').strip()}")
    return r.stdout.decode("utf-8", "replace")


def ignored_files() -> list[str]:
    """Джерело правди — .gitignore очима самого git, не список у цьому файлі."""
    out = subprocess.run(
        ["git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
        cwd=REPO, capture_output=True, timeout=300,
    )
    if out.returncode != 0:
        sys.exit("✗ git ls-files не спрацював — це git-репозиторій?")
    return [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]


def skip_reason(rel: str, rules: list[tuple[str, str]]) -> str | None:
    """Перше правило, що збіглося, — його причина й друкується в плані.

    Два способи збігу навмисно: `fnmatch` не переходить меж каталогів так, як
    очікує людина (`data/*` не ловить `data/a/b`), тож глоб із хвостовою зіркою
    додатково трактується як префікс шляху.
    """
    for pat, why in rules:
        if fnmatch(rel, pat):
            return why
        if pat.endswith("*") and rel.startswith(pat[:-1]):
            return why
    return None


@dataclass
class Plan:
    take: list[tuple[str, int]] = field(default_factory=list)   # (шлях, розмір)
    skipped: dict[str, tuple[int, int]] = field(default_factory=dict)  # причина -> (к-сть, байти)
    missing: int = 0
    links: list[str] = field(default_factory=list)


def build_plan(rules: list[tuple[str, str]]) -> Plan:
    """Що піде в архів, що ні і чому — ОДНА реалізація на всіх споживачів.

    Раніше цей розбір жив тілом `main()`, а тест мав власну копію — і копія не
    знала про симлінки, тож правило існувало, а перевірка його не бачила. Це той
    самий дефект, що в ADR-034: одне правило, дві реалізації, тиха розбіжність.
    """
    plan = Plan()
    for rel in ignored_files():
        p = REPO / rel
        # Симлінк перевіряємо ПЕРШИМ: `stat()` іде за посиланням, і биті симлінки
        # інакше потрапили б у «зникли», а живі — в архів вмістом цілі.
        if p.is_symlink():
            plan.links.append(rel)
            continue
        try:
            size = p.stat().st_size
        except OSError:
            plan.missing += 1
            continue
        why = skip_reason(rel, rules)
        if why:
            n, s = plan.skipped.get(why, (0, 0))
            plan.skipped[why] = (n + 1, s + size)
        else:
            plan.take.append((rel, size))
    return plan


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n:.0f} B"
        n /= 1024
    return f"{n:.1f} GB"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


RESTORE_SH = """#!/bin/zsh
# Відновлення на новій машині. Запускати З КОРЕНЯ клону репозиторію:
#     unzip -q <архів>.zip -d /tmp/sb-restore && /tmp/sb-restore/restore.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(pwd)"

if [[ ! -f "$REPO/CLAUDE.md" || ! -d "$REPO/SourceBible" ]]; then
  echo "\\n✗ Схоже, це не корінь клону SourceBible: $REPO"
  echo "  Перейди в теку репозиторію і запусти скрипт звідти.\\n"
  exit 1
fi

echo "→ Копіюю у $REPO"
/usr/bin/rsync -a --exclude restore.sh --exclude MANIFEST.json --exclude RESTORE.md "$HERE"/ "$REPO"/

if [[ -f "$REPO/sourcebible.db" ]]; then
  mkdir -p "$REPO/SourceBible/Resources"
  cp "$REPO/sourcebible.db" "$REPO/SourceBible/Resources/sourcebible.db"
  echo "→ Базу продубльовано в SourceBible/Resources/"
  EXPECTED=$(/usr/bin/python3 -c "import json;print(json.load(open('$HERE/MANIFEST.json')).get('db_sha256') or '')")
  if [[ -n "$EXPECTED" ]]; then
    ACTUAL=$(shasum -a 256 "$REPO/sourcebible.db" | cut -d' ' -f1)
    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
      echo "→ sha256 бази збігається ✓"
    else
      echo "\\n✗ sha256 бази НЕ збігається — архів пошкоджено, не збирай на цій базі\\n"
      exit 1
    fi
  fi
fi

echo "\\n✓ Готово. Далі:"
echo "   1. Config/Secrets.xcconfig — перевір, що на місці (у ньому живі токени)"
echo "   2. python3 scripts/lint_docs.py && python3 -m unittest discover scripts/tests"
echo "   3. Xcode: Clean Build Folder (Shift-Cmd-K) -> Run"
echo "   4. Видали розпакований архів — у ньому секрети\\n"
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Архів усього, що не їде в git")
    ap.add_argument("--profile", choices=sorted(PROFILES), default="essential",
                    help="db = лише база й секрети; essential = + датасети без кешів; full = все")
    ap.add_argument("--out", type=Path, help="шлях архіву (типово ~/Desktop/sourcebible-untracked-ДАТА.zip)")
    ap.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                    help="додатково виключити (можна кілька разів)")
    ap.add_argument("--write", action="store_true", help="справді створити архів")
    ap.add_argument("--force", action="store_true", help="перезаписати наявний архів")
    args = ap.parse_args()

    rules = ALWAYS_SKIP + PROFILES[args.profile] + [(g, "--exclude із командного рядка") for g in args.exclude]

    plan = build_plan(rules)
    take, skipped, missing, links = plan.take, plan.skipped, plan.missing, plan.links
    total = sum(s for _, s in take)
    secrets = [r for r, _ in take if r in SECRET_PATHS]

    print("=" * 72)
    print(f"  Архів untracked-файлів — профіль «{args.profile}»")
    print("=" * 72)
    print(f"  Береться:   {len(take):6d} файлів   {human(total)}")
    if skipped:
        print("\n  Пропущено (з причинами):")
        for why, (n, s) in sorted(skipped.items(), key=lambda kv: -kv[1][1]):
            print(f"    {human(s):>10}  {n:6d} ф.  {why}")
    if missing:
        print(f"\n  ⚠ {missing} файлів зникли між переліком і читанням — пропущено")
    if links:
        print(f"\n  ⚠ {len(links)} симлінків НЕ взято (zip поклав би вміст цілі, не посилання):")
        for rel in links[:5]:
            print(f"      {rel}")
        if len(links) > 5:
            print(f"      … і ще {len(links) - 5}")

    print("\n  Найбільше:")
    for rel, size in sorted(take, key=lambda t: -t[1])[:8]:
        print(f"    {human(size):>10}  {rel}")

    if secrets:
        print("\n  ⚠️  В архіві будуть ЖИВІ ТОКЕНИ: " + ", ".join(secrets))
        print("      Переносити диском або зашифровано. У хмару не класти.")
        print("      Після розпакування архів видалити.")

    if not args.write:
        print("\n  Це ПЛАН. `--write` створить архів.\n")
        return 0

    out = args.out or Path.home() / "Desktop" / f"sourcebible-untracked-{datetime.now():%Y%m%d}.zip"
    out = out.expanduser()
    if out.exists() and not args.force:
        sys.exit(f"\n✗ {out} уже існує ({human(out.stat().st_size)}).\n"
                 f"  Профіль essential збирається хвилинами — мовчки перезаписувати не буду.\n"
                 f"  Або вкажи інший --out, або додай --force.\n")
    out.parent.mkdir(parents=True, exist_ok=True)

    db = REPO / "sourcebible.db"
    manifest = {
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "profile": args.profile,
        "source_commit": git("rev-parse", "HEAD").strip(),
        "source_branch": git("rev-parse", "--abbrev-ref", "HEAD").strip(),
        "file_count": len(take),
        "bytes": total,
        "db_sha256": sha256(db) if db.exists() else None,
        "contains_secrets": secrets,
        "note": "Розпакувати й запустити restore.sh з кореня клону. Див. docs/BUILD.md.",
    }

    print(f"\n  ✎ Пишу {out} …")
    done = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        for rel, size in take:
            z.write(REPO / rel, rel)
            done += size
            pct = 100 * done / total if total else 100
            print(f"\r    {pct:5.1f}%  {human(done)} / {human(total)}", end="", flush=True)
        z.writestr("MANIFEST.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        # `contains_secrets` — список; у документ він має піти реченням, а не
        # Python-репром `['Config/Secrets.xcconfig']` (і не порожнім `[]`).
        z.writestr("RESTORE.md", RESTORE_DOC.format(
            **{**manifest, "contains_secrets": (
                "Архів містить: " + ", ".join(f"`{s}`" for s in secrets)
                if secrets else "Файлів із секретами в цьому архіві немає."
            )}))
        info = zipfile.ZipInfo("restore.sh")
        info.external_attr = 0o755 << 16
        z.writestr(info, RESTORE_SH)
    print()

    with zipfile.ZipFile(out) as z:
        n = len(z.namelist())
    expected = len(take) + 3
    if n != expected:
        sys.exit(f"\n✗ В архіві {n} записів, очікувалось {expected} — не довіряй йому.")

    print(f"\n  ✓ {out}  ({human(out.stat().st_size)}, стиснення "
          f"{100 * out.stat().st_size / total:.0f}% від оригіналу)")
    print(f"  ✓ Цілісність: {n} записів, sha256 бази в MANIFEST.json")
    print("\n  На новій машині: git clone → розпакувати → ./restore.sh з кореня клону.\n")
    return 0


RESTORE_DOC = """# Відновлення untracked-файлів SourceBible

Створено: {created}
Профіль: {profile}
Джерело: гілка `{source_branch}`, коміт `{source_commit}`
Вміст: {file_count} файлів

## Кроки

1. `git clone git@github.com:ikhoma/SourceBible.git && cd SourceBible`
   Звір коміт: цей архів зібрано на `{source_commit}`. Якщо клон новіший — нормально;
   якщо СТАРІШИЙ, спершу `git pull`, інакше база може не відповідати схемі в коді.
2. Розпакувати архів у тимчасову теку.
3. Запустити `restore.sh` **з кореня клону** — він скопіює файли, продублює базу
   в `SourceBible/Resources/` і звірить sha256.
4. Xcode: Clean Build Folder (⇧⌘K) → Run.

## ⚠️ Секрети

{contains_secrets}

Ці файли містять живі токени Mixpanel. Після розпакування видали архів і не клади
його в хмарне сховище.

## Далі

Повний чекліст нової машини — `docs/BUILD.md` у самому репозиторії.
"""

if __name__ == "__main__":
    sys.exit(main())
