#!/bin/zsh
set -e

cd "$(dirname "$0")"

echo "▸ Building database..."
python3 scripts/build_db.py

echo "\n▸ Building verse map..."
python3 build_verse_map.py sourcebible.db

echo "\n▸ Importing commentaries..."
python3 scripts/import_commentaries.py sourcebible.db

echo "\n▸ Synthesizing glosses..."
python3 scripts/process_glosses.py sourcebible.db

echo "\n▸ Copying to app bundle..."
cp sourcebible.db SourceBible/Resources/sourcebible.db

echo "\n✓ Done. Open Xcode and do ⇧⌘K → Run."
