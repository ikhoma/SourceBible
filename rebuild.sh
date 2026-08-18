#!/bin/zsh
set -e

cd "$(dirname "$0")"

# ── Python version floor ──────────────────────────────────────────────────────
# build_db.py uses 3.10+ syntax (dict[str, int] at :1844), so a 3.9 interpreter
# dies ~10 minutes in, after the Macula import. Fail here instead, in a second,
# and print WHICH python3 was picked up — /usr/bin/python3 is Apple's 3.9.6 and
# sits second in PATH, so a broken PATH is the likely cause, not a missing build.
python3 - <<'PY'
import sys
need = (3, 10)
got = sys.version.split()[0]
if sys.version_info < need:
    sys.stderr.write(
        "\n✗ python3 is %s at %s\n"
        "  this build needs >= %d.%d (build_db.py uses 3.10+ syntax)\n"
        "  /usr/bin/python3 is Apple's 3.9 — put a newer python3 first in PATH\n\n"
        % (got, sys.executable, need[0], need[1]))
    raise SystemExit(1)
print("▸ python3 %s at %s" % (got, sys.executable))
PY

echo "\n▸ Building database..."
python3 scripts/build_db.py

echo "\n▸ Building verse_org (versification: Original tab + cross-references, ADR-028)..."
# Curated + O2-verified mapping of each translation verse → Macula (Hebrew/Greek).
# Exits non-zero on an unresolved CONFLICT; `set -e` then aborts BEFORE the cp
# below, so a bad mapping never reaches the app bundle.
# NOTE: the old verse_map build step (build_verse_map.py) is gone — cross-refs and
# concordance display now resolve through verse_org (ADR-028 phase 2).
python3 scripts/build_versification.py sourcebible.db

echo "\n▸ Indexing verse_org reverse hop (original → translation)..."
# Used by cross-refs and concordance display; kept out of the frozen
# build_versification.py on purpose (additive, no row data touched).
sqlite3 sourcebible.db "CREATE INDEX IF NOT EXISTS idx_verse_org_rev ON verse_org(translation, org_book_id, org_chapter, org_verse);"

echo "\n▸ Verifying parallel-translation alignment (ADR-028, bug-036)..."
# Панель «Переклади» читає вірш ІНШОГО перекладу, тож мусить іти через verse_org, а не
# через той самий номер. Гейт перевіряє еталони (Пісн 1:15, Пс 51, Еккл 5:1, Дан 4:1,
# Ос 13:16, 2Кор 11:33, 1Хр 5:27), контролі, де зсуву бути НЕ може, покриття мапінгу
# і матрицю розходжень проти замороженої базової. `set -e` спиняє білд ДО cp у бандл.
python3 scripts/verify_parallel_alignment.py sourcebible.db

echo "\n▸ Importing commentaries..."
python3 scripts/import_commentaries.py sourcebible.db

echo "\n▸ Synthesizing glosses..."
python3 scripts/process_glosses.py sourcebible.db

echo "\n▸ Copying to app bundle..."
cp sourcebible.db SourceBible/Resources/sourcebible.db

echo "\n✓ Done. Open Xcode and do ⇧⌘K → Run."
