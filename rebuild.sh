#!/bin/zsh
set -e

cd "$(dirname "$0")"

echo "▸ Building database..."
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

echo "\n▸ Importing commentaries..."
python3 scripts/import_commentaries.py sourcebible.db

echo "\n▸ Synthesizing glosses..."
python3 scripts/process_glosses.py sourcebible.db

echo "\n▸ Copying to app bundle..."
cp sourcebible.db SourceBible/Resources/sourcebible.db

echo "\n✓ Done. Open Xcode and do ⇧⌘K → Run."
