# Збірка sourcebible.db

## Передумови

- **Python ≥ 3.10** — Python 3.9 не підтримує `Path | None` синтаксис (збірка падає з `TypeError`)
  ```bash
  python3 --version   # має бути 3.10+
  # Якщо 3.9 — встанови через brew:
  brew install python@3.12 && python3.12 scripts/build_db.py
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
cd ~/Projects/SourceBible
python3 scripts/build_db.py
```

Очікуваний вивід:
```
[1/6] Importing books...        66 books
[4/6] Importing Strong's...     14,712 entries
[4b] TBESH/TBESG...             ~8,200 H + ~10,800 G rows updated
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

> ⚠️ **`build_db.py` не будує `verse_map`** — обов'язково виконати наступний крок.

### Крок 2: verse_map (обов'язково після build_db.py)

`verse_map` — окремий скрипт, **не вбудований** у `scripts/build_db.py`. Без нього "Оригінал" показує слова не того вірша у 459 розділах (Псалми, RST SNG/ZEC/ROM 16).

```bash
python3 build_verse_map.py sourcebible.db
```

Очікуваний вивід: `✓ Done: 7292 rows across 459 chapters`

## Копіювання в Xcode

```bash
cp sourcebible.db SourceBible/Resources/sourcebible.db
```

Потім у Xcode: **Product → Clean Build Folder** (Shift+Cmd+K), потім Run.

Або одразу повний цикл (всі кроки):
```bash
cd ~/Projects/SourceBible \
  && python3 scripts/build_db.py \
  && python3 build_verse_map.py sourcebible.db \
  && python3 scripts/import_commentaries.py sourcebible.db \
  && cp sourcebible.db SourceBible/Resources/sourcebible.db \
  && echo "✓ DB built and copied to Resources"
```

## Крок 3: Commentaries (Calvin + Henry + Spurgeon + Owen)

Імпортує чотири public-domain коментаторів у таблицю `commentary` (~36 071 вірші).

| Джерело | Файл | Формат | Охоплення | Ліцензія |
|---|---|---|---|---|
| Calvin | `data/CalvinCommentaries.zip` | SWORD zCom | 48 книг, ~11 014 вірші | Public Domain |
| Matthew Henry | `data/matthew_henry.zip` | HTML | 66 книг, ~22 495 вірші | Public Domain |
| Spurgeon | `data/chspurgeon-tod-main.zip` | Markdown | Psalms only, ~2 259 вірші | MIT |
| Owen | `data/OwenHebrews-commentary.cmtx` | SQLite/RTF | Hebrews only, ~303 вірші | ⚠️ див. нижче |

> ⚠️ **Owen — ліцензійне обмеження:** текст публічного домену, але датасет отримано під умовою **не продавати і не включати в комерційні пакети**. Якщо в майбутньому вводиться платна/підписна модель — замінити `OwenHebrews-commentary.cmtx` на інше видання (наприклад, CCEL.org) до релізу платного тиру.

```bash
cd ~/Projects/SourceBible
python3 scripts/import_commentaries.py sourcebible.db
cp sourcebible.db SourceBible/Resources/sourcebible.db
# Xcode: ⇧⌘K → Run
```

Очікуваний вивід:
```
→ Importing Calvin (SWORD zCom)...
   Calvin:   11014 verses
→ Importing Matthew Henry (HTML)...
   Henry:    22495 verses
→ Importing Spurgeon — Treasury of David (Markdown)...
   Spurgeon:  2259 verses
→ Importing Owen — Exposition of Hebrews (SQLite/RTF)...
   Owen:       303 verses
✓ Done: 36071 total commentary entries in sourcebible.db
```

Схема таблиці:
```sql
commentary(source TEXT, book_id TEXT, chapter INT, verse INT, text TEXT,
           PRIMARY KEY(source, book_id, chapter, verse))
```

---

## Відомі проблеми та рішення

### ❌ Python 3.9: `TypeError: unsupported operand type(s) for |`

**Причина:** Синтаксис `Path | None` доданий у Python 3.10. На macOS системний Python часто 3.9.

**Рішення:**
```bash
brew install python@3.12
python3.12 scripts/build_db.py
```

**Статус у коді:** Всі `-> Type | None` анотації у `build_db.py` видалені — сумісно з 3.9+.

---

### ❌ `long_def` порожній для більшості слів → лексичні дані не відображаються в UI

**Причина (виявлена у травні 2026):** `import_strongs()` заповнює `long_def` із `kjv_def` openscriptures JSON — це короткий список ключових слів через кому (наприклад `"blessed, happy"`). Потім `import_stepbible_lexicons()` намагається записати повне BDB-визначення, але умова `CASE WHEN long_def = '' ...` не спрацьовує бо поле вже непорожнє.

Наслідок: `LexiconParser` очікує BDB-формат (`1) визначення<br>1a) ...`), а отримує `"blessed, happy"` → парсинг не знаходить нічого → `ЛЕКСИЧНЕ ЗНАЧЕННЯ` порожнє для більшості слів.

**Рішення в `build_db.py`:** Умова змінена на `CASE WHEN ? != '' THEN ?` — TBESH завжди перезаписує `kjv_def`.

**Якщо БД вже зібрана (без повної перезбірки):**
```bash
python3 scripts/patch_long_def.py
cp sourcebible.db SourceBible/Resources/sourcebible.db
```
Скрипт оновлює лише `strongs.long_def` з TBESH/TBESG (~10 секунд).

---

### ❌ `long_def` використовує `\n`, але `LexiconParser` очікував `<br>`

**Причина (виявлена у травні 2026):** `_clean_stepbible_html()` конвертує HTML `<br>` → `\n` при збереженні в БД. `LexiconParser` у Swift ділив рядок по `"<br>"` — отримував один великий рядок, regex не знаходив нумеровані пункти.

Наслідок: навіть якщо `long_def` містив правильне BDB-визначення, парсер бачив лише перший пункт (або нічого, якщо рядок починався з `": keyword"`).

**Рішення у `LexiconParser` (Swift):** Нормалізація перед розбивкою:
```swift
let normalized = raw.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
let lines = normalized.components(separatedBy: "\n")
```
**Дана проблема — тільки у Swift, не в БД.**

---

### ❌ Sub-entry IDs (H835a, H871a, H3887a) мають порожній `long_def`

**Причина:** TBESH зберігає власні sub-entries (H835a, H3887a тощо) для слів де базовий номер і sub-entry — це пов'язані лексеми. **Але** парсер `_parse_stepbible_file()` у старих версіях скіпав ці рядки через regex `data_re = r'^[HG]\d{4,5}\t'` (потребує TAB одразу після цифр, без суфікса) — це баг парсера, описаний нижче.

Для H835a/H3887a fix: Swift fallback до базового ID (якщо перша буква збігається) достатній, бо ці sub-entries мають той самий корінь. Дивись "Рішення в DatabaseService" нижче.

Наслідок: клік на перше слово Пс 1:1 (אַשְׁרֵי → H835a) не показував лексичних даних.

**Рішення в `DatabaseService.loadStrongs()` (Swift):** Умовний fallback до базового ID — лише якщо перша буква іврит-лексеми збігається (захист від неправильного fallback, див. наступний пункт).

**Дана проблема — тільки у Swift, не в БД.**

---

### ❌ Sub-entry fallback повертає визначення абсолютно не пов'язаного слова

**Причина (виявлена у травні 2026):** У розширеній нумерації Strong's деякі граматичні частки отримали `a`-suffix ID у тому ж числовому діапазоні, що й абсолютно інші слова. Наївний fallback H1886a → H1886 повертав назву міста замість визначення артикля:

| Sub-entry | Значення | Base ID | Значення base | Зв'язок |
|---|---|---|---|---|
| H1886a | הַ — означений артикль | H1886 | Dothan (місто) | ❌ не пов'язані |
| H871a | בְּ — прийменник "в" | H871 | Atharim (маршрут) | ❌ не пов'язані |
| H835a | אַשְׁרֵי — "blessed are" | H835 | אֶשֶׁר — "happiness" | ✓ пов'язані |
| H3887a | לֵצִים — "scorners" | H3887 | לוּץ — "to scorn" | ✓ пов'язані |

Симптом: H1886a показував "§ Dothan = two wells; a place in northern Palestine", H871a — "This name means perhaps mountain pass or caravan route".

**Рішення в `DatabaseService.loadStrongs()` (Swift):** Fallback виконується тільки якщо **перша літера оригінального слова збігається** між sub-entry і base entry. Різні стартові букви = різні слова = fallback пропускається.

```swift
let sameRoot = subFirst != nil && baseFirst != nil && subFirst == baseFirst
if sameRoot { /* merge base long_def */ }
```

**Дана проблема — тільки у Swift, не в БД.**

---

### ❌ xlit integrity check: `WARNING: N potential sub-entry xlit violation(s)`

Це **не помилка** — check знаходить sub-entries де `transliteration` збігається з базовим Strong's, але `original` відрізняється. Відомі false positives:

| ID | Причина false positive |
|---|---|
| H6924a | Та ж лексема קֶדֶם ("east/ancient"), різна граматична форма |
| H672b/H672c | Ephrathah vs Ephrath — та ж місцевість, різне написання |
| H746a | Той самий власний іменник Arioch |

Build автоматично NULLить `transliteration` для цих entries (`xlit_simple` з TBESH зберігається). Це безпечно — `xlit_simple` має пріоритет у UI.

**Реальна проблема яку check запобігає:** H871a (прийменник בְּ) отримує xlit від H871 (місто Атарот). `import_stepbible_lexicons()` використовує `WHERE id = ?` (exact match only, без propagation).

---

### ❌ TBESH suffixed `eStrong#` entries (H1471a, H6213a) — порожні `short_def`/`long_def` для ~542 слів

**Виявлено:** червень 2026. Симптом: вкладка "Значення" для слів Псалма 1 показувала порожні gloss і BDB-визначення (H1471 גּוֹי, H5034 נָבֵל, H6213 עָשָׂה, H6743 צָלַח та інші).

**Причина — баг regex у `_parse_stepbible_file()`:**
```python
# БАГ: потребує TAB одразу після цифр, скіпає рядки з суфіксом
data_re = re.compile(r'^[HG]\d{4,5}\t')

# ВИПРАВЛЕННЯ: дозволити опціональний суфікс перед TAB
data_re = re.compile(r'^[HG]\d{4,5}[a-z]?\t')
```

TBESH містить рядки де `eStrong#` — це `H1471a`, `H6213a`, `H6743b` тощо. Для **542 Strong's IDs** у TBESH взагалі немає bare-number рядка — є тільки suffixed-entry. Старий regex мовчки скіпав 1 424 рядки (з 11 682 data rows), залишаючи `short_def`/`long_def` = NULL.

Macula при цьому тегує ці самі слова як `H1471`, `H6213` (без суфікса) — тому запис у таблиці `strongs` існує, але порожній.

**Масштаб:** ~542 Strong's IDs з порожніми визначеннями. Помітно на: גּוֹי (H1471), עָשָׂה (H6213), צָלַח (H6743), נָבֵל (H5034), plus hundreds of others across the OT.

**Де баг присутній:**
- `scripts/build_db.py` — функція `_parse_stepbible_file()`, рядок ~904
- `scripts/fix_strongs_tbesh.py` — та сама функція (copy-paste)

**Повне виправлення потребує також:** після зміни regex, в import-циклі додати UPDATE базового ID (H1471) коли TBESH-рядок suffixed (H1471a):
```python
m_base = re.match(r'^([HG]\d+)[a-z]$', sid)
if m_base:
    base_sid = m_base.group(1)
    cur.execute("""
        UPDATE strongs SET
            xlit_simple = CASE WHEN (xlit_simple IS NULL OR xlit_simple = '') AND ? != '' THEN ? ELSE xlit_simple END,
            short_def   = CASE WHEN (short_def   IS NULL OR short_def   = '') AND ? != '' THEN ? ELSE short_def   END,
            long_def    = CASE WHEN (long_def    IS NULL OR long_def    = '') AND ? != '' THEN ? ELSE long_def    END
        WHERE id = ?
    """, (xlit_simple, xlit_simple, short_def, short_def, long_def, long_def, base_sid))
```

**Workaround без rebuild:** повний `scripts/build_db.py` rebuild (~10 хв) після патча обох файлів — виправляє проблему повністю.

**Це не повязано** з sub-entry fallback у Swift — там інша проблема (H835a → H835 lookup). Тут проблема в тому, що база взагалі не містить даних для H1471 тощо.

---

### ❌ Старий bundled DB у Xcode після збірки

**Симптом:** `no such column: w.gloss_macula` або лексичні дані не оновились.

**Причина:** Xcode продовжує використовувати кешований старий `sourcebible.db`.

**Рішення:**
```bash
cp sourcebible.db SourceBible/Resources/sourcebible.db
# Потім в Xcode: Product → Clean Build Folder (⇧⌘K) → Run
```

---

### ❌ `verse_map` відсутня → "Оригінал" показує слова не того вірша

**Причина:** У Біблії різні традиції нумерації. Псалми в MT (Macula) мають заголовок як вірш 1 — KJV і RST його пропускають. Результат: KJV вірш 1 Псалма 3 → код завантажує Macula вірш 1 (заголовок), а не текст.

**Масштаб:** 459 розділів зі зсувом (з ~1 189), 7 292 non-identity mappings. Найбільше — Псалми (62 розділи), також RST SNG, ZEC, ROM 16.

**Рішення:** Таблиця `verse_map` з pre-computed маппінгом. Будується алгоритмом Strong's overlap greedy alignment.

**Якщо `verse_map` відсутня в DB (наприклад після часткового відновлення):**
```bash
cd ~/Projects/SourceBible
python3 build_verse_map.py   # standalone скрипт, не чіпає інші таблиці
```
Очікуваний результат: `✓ Done: 7292 rows across 459 chapters`

**Якщо збираєш DB з нуля через `scripts/build_db.py`:** `verse_map` **не будується автоматично** — після `build_db.py` обов'язково запусти `python3 build_verse_map.py sourcebible.db` (div. розділ "Збірка" вище).

**Перевірка в UI:** відкрий Псалом 3, вірш 1 у RST або KJV → вкладка "Оригінал" має показувати слова першого текстового вірша (не заголовку).

**Swift реалізація** — три рівні пошуку в `ReaderViewModel.findBestMaculaVerse()`:
1. O(1) lookup у `verse_map` (точний маппінг)
2. Identity перевірка через Strong's overlap (≥2 збіги)
3. Heuristic fallback ±2 вірші по Strong's overlap

---

### ❌ OpenBible cross-references не завантажуються

Скрипт продовжує без них (WARN, не ERROR). Cross-refs кешуються у `scripts/.cache/openbible_xref.zip` — якщо файл є, завантаження пропускається. Можна завантажити вручну і покласти туди.

---

## Схема `verse_map` table

```sql
CREATE TABLE verse_map (
    translation  TEXT    NOT NULL,  -- ID перекладу ('KJV', 'RST', 'ASV', ...)
    book_id      TEXT    NOT NULL,  -- 'PSA', 'ROM', 'SNG', 'ZEC'
    chapter      INTEGER NOT NULL,
    trans_verse  INTEGER NOT NULL,  -- номер вірша у перекладі
    macula_verse INTEGER NOT NULL,  -- відповідний вірш у Macula (word table, MT нумерація)
    PRIMARY KEY (translation, book_id, chapter, trans_verse)
);

CREATE INDEX idx_verse_map ON verse_map(translation, book_id, chapter);
```

**Ключові принципи:**
- Зберігаємо **тільки non-identity** рядки (`trans_verse != macula_verse`). Відсутній рядок = identity mapping (вірш однаковий в обох схемах).
- Таблиця завжди мапить → MT (Macula). Зворотний напрямок (MT → переклад) потребує окремого рядка або reverse lookup.
- Будується один раз при зміні перекладів. Standalone скрипт: `build_verse_map.py` у корені проекту.

---

## Схема `strongs` table

```sql
CREATE TABLE strongs (
    id              TEXT PRIMARY KEY,  -- 'H835', 'H835a', 'G4198'
    language        TEXT,              -- 'H' | 'G'
    original        TEXT,              -- лемма (іврит/грецька)
    transliteration TEXT,              -- академічна транслітерація (openscriptures)
    xlit_simple     TEXT,              -- спрощена xlit (STEPBible TBESH/TBESG) ← основна для UI
    pronunciation   TEXT,
    part_of_speech  TEXT,
    short_def       TEXT,              -- коротке визначення (strongs_def з openscriptures)
    long_def        TEXT               -- повне BDB / Abbott-Smith (STEPBible) ← для LexiconParser
);
```

**Важливо про `long_def`:**
- Заповнюється з TBESH/TBESG у `import_stepbible_lexicons()`
- Формат: нумеровані пункти через `\n`: `"1) визначення\n1a) (Qal)\n1a1) ..."`
- Sub-entries (H835a) не мають власного `long_def` — UI робить fallback до базового ID
- `kjv_def` з openscriptures **не** використовується для `long_def` (лише `short_def`)

## Схема `word` table

```sql
CREATE TABLE word (
    id           TEXT PRIMARY KEY,  -- 'GEN|1|1|1'
    book_id      TEXT,
    chapter      INTEGER,
    verse        INTEGER,
    position     INTEGER,
    surface      TEXT,              -- оригінальний текст (з огласовками) ← показується в UI
    lemma        TEXT,
    strongs_id   TEXT,              -- 'H835', 'G4198'
    morph        TEXT,              -- код морфології Macula
    gloss        TEXT,              -- контекстуальна глоса з TSV (e.g. "he.walked")
    language     TEXT,              -- 'hbo' (Hebrew) | 'grc' (Greek)
    xlit         TEXT,              -- occurrence-specific xlit з Macula TSV ← для contextSection
    gloss_macula TEXT,              -- детальніша глоса з XML lowfat
    syntax_role  TEXT,              -- синтаксична роль: v=predicate, s=subject, o=object
    greek        TEXT,              -- LXX грецький еквівалент (поверхнева форма)
    greek_strong TEXT               -- LXX Strong's G номер (e.g. "G4198")
);
```

**Важливо про `word.xlit`:**
- Occurrence-specific (форма конкретного слова у конкретному вірші)
- Використовується у секції "Форма у Пс 1:1" — **не** у заголовку WordMeaningView
- Заголовок показує лемму → xlit заголовка береться з `strongs.xlit_simple`

## Pipeline збірки (порядок важливий)

```
import_books
import_strongs              ← FK для word table; заповнює short_def з strongs_def,
                               long_def з kjv_def (буде перезаписано TBESH нижче!)
import_stepbible_lexicons   ← TBESH/TBESG: перезаписує long_def BDB-визначенням,
                               заповнює xlit_simple; exact-ID only (без sub-entry propagation)
_apply_xlit_fallback        ← xlit_simple для entries без TBESH (з academic transliteration)
verify_xlit_integrity       ← fail-safe check (auto-null false positives, не abort)
import_macula_hebrew        ← заповнює word table з TSV (surface, morph, gloss, xlit)
enrich_macula_from_xml      ← додає gloss_macula, syntax_role, greek, greek_strong з XML
import_macula_greek
_backfill_strongs_originals ← strongs.original з word.lemma (Macula)
_apply_word_table_xlit_fallback ← 4th fallback: xlit_simple + short_def для ~507 sub-entry
                               stubs (H871a, H1886a, H2050b…) що не є в TBESH/openscriptures;
                               бере найпоширенішу word.xlit / word.gloss для кожного strongs_id
import_translations
import_footnotes
import_cross_references
finalize

# ── Окремий крок після build_db.py ──
build_verse_map.py      ← НЕ вбудований у build_db.py! Запускати вручну:
                           python3 build_verse_map.py sourcebible.db
                           Strong's overlap alignment; 7 292 non-identity rows
                           Псалми (62 розд.), RST SNG/ZEC/ROM — найбільше зсувів
```
