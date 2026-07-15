#!/bin/zsh
set -e

cd "$(dirname "$0")"

echo "▸ Building database..."
python3 scripts/build_db.py

echo "\n▸ Building verse map (cross-references)..."
python3 build_verse_map.py sourcebible.db

echo "\n▸ Building verse_org (Original-tab versification, ADR-028)..."
# Curated + O2-verified mapping of each translation verse → Macula (Hebrew/Greek).
# Exits non-zero on an unresolved CONFLICT; `set -e` then aborts BEFORE the cp
# below, so a bad mapping never reaches the app bundle.
python3 scripts/build_versification.py sourcebible.db

echo "\n▸ Importing commentaries..."
python3 scripts/import_commentaries.py sourcebible.db

echo "\n▸ Synthesizing glosses..."
python3 scripts/process_glosses.py sourcebible.db

echo "\n▸ Copying to app bundle..."
cp sourcebible.db SourceBible/Resources/sourcebible.db

echo "\n✓ Done. Open Xcode and do ⇧⌘K → Run."
