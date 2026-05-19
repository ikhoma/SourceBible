#!/bin/bash
set -e
SRC="$HOME/Documents/Claude/Projects/Bible App/sourcebible.db"
DST="$HOME/Projects/SourceBible/SourceBible/Resources/sourcebible.db"

echo "Copying $SRC"
echo "     to $DST"
cp "$SRC" "$DST"
echo "Done. $(du -sh "$DST" | cut -f1) written."
echo "Press any key to close..."
read -n1
