# strip_commentary fixture

Real schema (`schema.sql`, verbatim from `sqlite_master` of the shipped
`commentaries-en.db`, 2026-10-18) and real rows (`rows.json`: up to 3 comments per
source (6 for Spurgeon-VE — the byte scan needs ≥5 samples) from GEN/PSA/JHN, text cut to 700 chars, with all their `comment_verses`;
`module_info` with `sources`/`book_versions` rewritten for this subset) for
`test_strip_commentary_source.py`. Regenerate only if the module schema changes.
