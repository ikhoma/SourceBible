# Збірка sourcebible.db

## Передумови

- **Python ≥ 3.10** (3.9 не підтримує `Path | None` синтаксис — збірка падає з `TypeError: unsupported operand type(s) for |`)
  ```bash
  python3 --version   # має бути 3.10+
  # Якщо 3.9 — встанови через brew: brew install python@3.12
  python3.12 scripts/build_db.py
  ```
- `pip3 install requests` (для завантаження cross-references з OpenBible)

## Необхідні датасети

Поклади у `data/` (не комітяться в git — занадто великі та ліцензійні):

| Файл | Звідки | Ліцензія |
|---|---|---|
| `macula-hebrew-main.zip` | [Clear-Bible/macula-hebrew](https://github.com/Clear-Bible/macula-hebrew) → Code → Download ZIP | MIT |
| `macula-greek-main.zip` | [Clear-Bible/macula-greek](https://github.com/Clear-Bible/macula-greek) → Code → Download ZIP | MIT |
| `strongsHebrew.json` | [openscriptures/strongs](https://github.com/openscriptures/strongs/blob/master/hebrew/strongsHebrew.json) | Public domain |
| `strongsGreek.json` | [openscriptures/strongs](https://github.com/openscriptures/strongs/blob/master/greek/strongsGreek.json) | Public domain |
| `TBESH*.txt` | [STEPBible-Data/Lexicons](https://github.com/STEPBible/STEPBible-Data/tree/master/Lexicons) | CC BY 4.0 |
| `TBESG*.txt` | [STEPBible-Data/Lexicons](https://github.com/STEPBible/STEPBible-Data/tree/master/Lexicons) | CC BY 4.0 |
| `KJV+.zip` | MyBible модуль | Public domain |
| `ASV+.zip` | MyBible модуль | Public domain |
| `NASB+.zip` | MyBible модуль | Licensed — не розповсюджувати |
| `RST+.zip` | MyBible модуль | Public domain |

Cross-references завантажуються автоматично з OpenBible.info (CC BY 4.0) і кешуються у `scripts/.cache/`.

## Збірка

```bash
cd /Users/ivan.khoma/Projects/SourceBible
python3 scripts/build_db.py
```

Очікуваний вивід:
```
[1/6] Importing books...        66 books
[4/6] Importing Strong's...     14,712 entries
[4b] TBESH/TBESG...             15,425 updated
[4c] xlit fallback...           ~1,391 entries
[4d] xlit integrity check...    ✓ 0 violations (або WARNING з auto-null для false positives)
[2/6] Macula Hebrew TSV...      ~430K words
[3b] Macula XML enrichment...   ~430K words (gloss_macula, syntax_role, greek, greek_strong)
[3/6] Macula Greek TSV...       ~140K words
[5/6] Translations...           KJV, ASV, NASB, RST
[6/7] Footnotes...
[6/6] Cross-references...
Finalizing...
✓ Done: sourcebible.db  (~149 MB)
```

## Копіювання в Xcode

```bash
cp sourcebible.db SourceBible/Resources/sourcebible.db
```

Потім у Xcode: **Product → Clean Build Folder** (Shift+Cmd+K), потім Run.

Або одразу:
```bash
cd /Users/ivan.khoma/Projects/SourceBible && python3 scripts/build_db.py && cp sourcebible.db SourceBible/Resources/sourcebible.db && echo "✓ DB copied to Resources"
```

## Відомі проблеми та рішення

### Python 3.9: `TypeError: unsupported operand type(s) for |`
Синтаксис `Path | None` доданий у Python 3.10. На macOS з системним Python 3.9 збірка падає.
```bash
# Діагностика
python3 --version
# Рішення
brew install python@3.12
python3.12 scripts/build_db.py
```
Всі `def func(...) -> Type | None:` у `build_db.py` замінено на `def func(...):` (без анотації) — сумісно з 3.9+.

### xlit integrity check: `WARNING: N potential sub-entry xlit violation(s)`
Це **не помилка** — check знаходить sub-entries де `transliteration` співпадає з базовим Strong's і `original` відрізняється. Відомі false positives:
- **H6924a** — та ж лексема קֶדֶם ("east/ancient"), різна граматична форма
- **H672b/H672c** — Ephrathah vs Ephrath, та ж місцевість різного написання
- **H746a** — той самий власний іменник Arioch

Build автоматично NULLить `transliteration` для цих entries (xlit_simple з TBESH зберігається). Це безпечно — `xlit_simple` має пріоритет у UI.

**Реальна проблема яку check запобігає:** H871a (прийменник בְּ) отримує xlit від H871 (місто Атарот) — це заблоковано: `import_stepbible_lexicons()` використовує `WHERE id = ?` (exact match only, без propagation).

### `sourcebible.db` відсутній у Xcode після збірки
```
no such column: w.gloss_macula
```
Старий bundled DB у `SourceBible/Resources/`. Виконай `cp` вище і Clean Build.

### OpenBible cross-references не завантажуються
Скрипт продовжує без них (WARN, не ERROR). Cross-refs кешуються у `scripts/.cache/openbible_xref.zip` — якщо файл є, завантаження пропускається.

## Схема word table (повна)

```sql
CREATE TABLE word (
    id           TEXT PRIMARY KEY,  -- 'GEN|1|1|1'
    book_id      TEXT,
    chapter      INTEGER,
    verse        INTEGER,
    position     INTEGER,
    surface      TEXT,              -- оригінальний текст (з огласовками)
    lemma        TEXT,
    strongs_id   TEXT,              -- 'H835', 'G4198'
    morph        TEXT,              -- код морфології Macula
    gloss        TEXT,              -- контекстуальна глоса з TSV (e.g. "he.walked")
    language     TEXT,              -- 'hbo' (Hebrew) | 'grc' (Greek)
    xlit         TEXT,              -- спрощена транслітерація з TSV (e.g. "ba.reshit")
    gloss_macula TEXT,              -- контекстуальна глоса з XML lowfat (детальніша)
    syntax_role  TEXT,              -- синтаксична роль: v=predicate, s=subject, o=object
    greek        TEXT,              -- LXX грецький еквівалент (поверхнева форма)
    greek_strong TEXT               -- LXX Strong's G номер (e.g. "G4198")
);
```

## Pipeline збірки (порядок важливий)

```
import_books
import_strongs          ← FK для word table
import_stepbible_lexicons (TBESH/TBESG, exact-ID only — без sub-entry propagation!)
_apply_xlit_fallback    ← xlit_simple для entries без TBESH
verify_xlit_integrity   ← fail-safe check (auto-null false positives)
import_macula_hebrew    ← заповнює word table з TSV (xlit з TSV)
enrich_macula_from_xml  ← додає gloss_macula, syntax_role, greek, greek_strong з XML
import_macula_greek
import_translations
import_footnotes
import_cross_references
finalize
```
