# Збірка sourcebible.db

## Передумови

- **Python ≥ 3.10.** `rebuild.sh` перевіряє це першим кроком і виходить із ненульовим
  кодом, друкуючи, який саме `python3` підхопився — вручну перевіряти не треба.
  Поріг існує через `build_db.py:1844` (`dict[str, int]`); на 3.9 збірка вмирала б
  через ~10 хвилин, уже після імпорту Macula.
  Заміряно 2026-08-05: `python3` = **3.14.5** (`/usr/local/bin`, інсталятор python.org),
  а `/usr/bin/python3` = 3.9.6 (системний Apple) і **не використовується**. Homebrew на
  цій машині немає. Деталі — `CLAUDE.md` → розділ про Python.
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
| `UBIO'88.zip` | MyBible модуль (Огієнко 1962/1988) | **CC BY-SA 3.0** — прямий дозвіл УБТ на видання Огієнка **до 1991**, включно з ювілейним 1988 (ADR-029, блокер знято 2026-07-31). Дозволяє похідні й **комерційне** використання за атрибуції (Menu → About) + SA на похідні від самого тексту. Межа «до 1991»: пізніші редакції УБТ НЕ покриті |
| `versification/{org,eng,rso}.json` | [Copenhagen-Alliance/versification-specification](https://github.com/Copenhagen-Alliance/versification-specification) → `standard-mappings/` | MIT |
| `versification/overrides.tsv` | Курований (ADR-028) — рішення виведені й O2-перевірені вручну | — |

Cross-references завантажуються автоматично з OpenBible.info (CC BY 4.0) і кешуються у `scripts/.cache/`.

**`data/versification/` трекається в git** (виняток у `.gitignore`, решта `data/` — ні):
`.vrs` малі й MIT, а `overrides.tsv` — курований build-input, який не можна втратити.
Використовується кроком `scripts/build_versification.py` (verse_org, ADR-028).

## Збірка

**Канонічний шлях — `./rebuild.sh` у корені проєкту, і він же єдине джерело правди про
порядок кроків.** Не переліковуй команди тут: виконуваний скрипт не може розійтися з
реальністю так, як розійшовся цей документ (див. «Історія розходження» в кінці).

Що робить `rebuild.sh`, для орієнтації — деталі читай у самому скрипті:

1. `scripts/build_db.py` — ядро: `word`, `verse`, `strongs`, FTS (~10 хв)
2. `scripts/build_versification.py` — `verse_org` (ADR-028). Падає з ненульовим кодом на
   невирішеному CONFLICT, і `set -e` аборти **ДО** `cp` — бита версифікація не потрапляє
   в бандл
3. `CREATE INDEX idx_verse_org_rev` — зворотний хоп (оригінал → переклад) для крос-рефів
   і конкордансу. Навмисно поза замороженим `build_versification.py`
4. `scripts/import_commentaries.py` — ~36 071 вірші
5. `scripts/process_glosses.py` — `word.gloss_display`. **Без цього кроку вкладка
   «Оригінал» показує сиру крапкову нотацію** (`he.makes.me.lie.down`), бо `COALESCE`
   падає на `gloss_macula`. Див. «Три колонки глос» нижче
6. `cp sourcebible.db SourceBible/Resources/` → в Xcode ⇧⌘K → Run

Очікуваний вивід `build_db.py`:
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

> ⚠️ **`build_db.py` не будує `verse_org`** — це крок 2 у `rebuild.sh`
> (`scripts/build_versification.py`). Без нього «Оригінал», крос-рефи й конкорданс падають
> в identity-fallback у зсунутих главах. Очікуваний розмір `verse_org` — **155 621 рядок**
> (5 перекладів × ~31k); суттєво менше = щось пішло не так.

## Три колонки глос — не переплутати

Джерело правди про runtime — `docs/original-tab.md`. Тут лише те, що стосується збірки:

| колонка | заповнює | вигляд | де в UI |
|---|---|---|---|
| `word.gloss` | `build_db.py:410`, TSV `english` | по-токенна, без крапок (`conceived`, `me`) | останній fallback |
| `word.gloss_macula` | `build_db.py:579`, XML lowfat `gloss` | **фраза рівня слота, порізана по токенах** (`she` + `conceived.me`) | середній fallback |
| `word.gloss_display` | `process_glosses.py:74` | нормалізована: крапки прибрані, конструкт розвернутий | **те, що видно** |

`DatabaseService.loadWords` читає `COALESCE(w.gloss_display, w.gloss_macula, w.gloss)`.
Тобто пропущений крок 5 у `rebuild.sh` = крапки на екрані.

## Коментарі — датасети й ліцензії

`scripts/import_commentaries.py` (крок 4 у `rebuild.sh`) імпортує чотири
public-domain коментаторів у таблицю `commentary` (~36 071 вірші).

| Джерело | Файл | Формат | Охоплення | Ліцензія |
|---|---|---|---|---|
| Calvin | `data/CalvinCommentaries.zip` | SWORD zCom | 48 книг, ~11 014 вірші | Public Domain |
| Matthew Henry | `data/matthew_henry.zip` | HTML | 66 книг, ~22 495 вірші | Public Domain |
| Spurgeon | `data/chspurgeon-tod-main.zip` | Markdown | Psalms only, ~2 259 вірші | MIT |
| Owen | `data/OwenHebrews-commentary.cmtx` | SQLite/RTF | Hebrews only, ~303 вірші | ⚠️ див. нижче |

> ⚠️ **Owen — ліцензійне обмеження:** текст публічного домену, але датасет отримано під умовою **не продавати і не включати в комерційні пакети**. Якщо в майбутньому вводиться платна/підписна модель — замінити `OwenHebrews-commentary.cmtx` на інше видання (наприклад, CCEL.org) до релізу платного тиру.

Окремо запускати не потрібно — крок 4 у `rebuild.sh`. Очікуваний вивід:
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

### ❌ Python 3.9: `TypeError: unsupported operand type(s) for |` / `SyntaxError`

**Причина:** `Path | None` і `dict[str, int]` — синтаксис 3.10+. Системний
`/usr/bin/python3` на macOS — 3.9.6, і в PATH він другий; помилка означає, що
підхопився саме він.

**Рішення:** не запускати `/usr/bin/python3`. `rebuild.sh` перевіряє версію першим
кроком і сам друкує, який інтерпретатор узявся.

**Статус у коді (уточнено 2026-08-05):** `-> Type | None` у `build_db.py` дійсно немає,
але **сумісності з 3.9 немає** — лишився `dict[str, int]` у рядку 1844. Це не баг і не
«виправити»: поріг конвеєра тепер 3.10, а на машині `python3` = 3.14.5.

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

### ❌ `verse_org` відсутня або неповна → "Оригінал" показує слова не того вірша

Симптом старий, причина й лікування змінились у ADR-028 фаза 2 (2026-07).

**Причина:** різні традиції нумерації. Псалми в MT (Macula) мають заголовок як вірш 1 —
KJV і RST його пропускають. Без маппінгу KJV Пс. 3:1 тягне Macula вірш 1 (заголовок).

**Рішення:** таблиця `verse_org` — тотальний курований маппінг «вірш перекладу ⇄ вірш
оригіналу» (UBS `.vrs` + O2-верифікація через Strong's; розбіжність = білд падає).
Обслуговує «Оригінал», крос-рефи і конкорданс. Крос-глава, N:M і «немає оригіналу»
(`org_*` NULL) — першокласні випадки, не винятки.

**Якщо таблиці немає або в ній мало рядків:** перезбирати через `./rebuild.sh` — крок 2
(`scripts/build_versification.py`) плюс крок 3 (`idx_verse_org_rev`). Скрипт вимагає
`data/versification/{org,eng,rso}.json` + `overrides.tsv`; ці файли трекаються в git,
`overrides.tsv` — курований, **НЕ регенерувати наосліп**.

**Перевірка в UI:** RST або KJV, Псалом 3 вірш 1 → «Оригінал» має показувати слова
першого текстового вірша, не заголовку.

**Swift реалізація:** `DatabaseService.loadOriginalWords` (форвард-хоп) +
`orgRef`/`translationRef` (зворотний). Три випадки й гілки — у `docs/original-tab.md`.

⛔ **Стара евристична `verse_map` (7 292 рядки, 57% хибних) видалена разом із
`build_verse_map.py` і `ReaderViewModel.findBestMaculaVerse()`.** Не відроджувати;
маппінг не виводити наново евристикою.

---

### ❌ OpenBible cross-references не завантажуються

Скрипт продовжує без них (WARN, не ERROR). Cross-refs кешуються у `scripts/.cache/openbible_xref.zip` — якщо файл є, завантаження пропускається. Можна завантажити вручну і покласти туди.

---

## Версифікація — `verse_org`

Схема, інваріанти й гілки — в `ADR-028` і `docs/original-tab.md`, тут не дублюються.
Для збірки достатньо трьох фактів: будує `scripts/build_versification.py` (крок 2),
індекс зворотного хопу створює `rebuild.sh` (крок 3), очікуваний розмір — 155 621 рядок.

⛔ Схема `verse_map` була тут до ADR-028 фази 2 і видалена разом із таблицею.

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
    gloss        TEXT,              -- TSV `english` — ПО-ТОКЕННА, без крапок ("conceived", "me")
    language     TEXT,              -- 'hbo' (Hebrew) | 'grc' (Greek)
    xlit         TEXT,              -- occurrence-specific xlit з Macula TSV ← для contextSection
    gloss_macula TEXT,              -- XML lowfat `gloss` — ФРАЗА РІВНЯ СЛОТА, порізана по
                                    -- токенах ("she" + "conceived.me"). Не по-морфемна!
    syntax_role  TEXT,              -- синтаксична роль: v=predicate, s=subject, o=object
    greek        TEXT,              -- LXX грецький еквівалент (поверхнева форма); лише іврит
    greek_strong TEXT,              -- LXX Strong's G номер (e.g. "G4198"); лише іврит
    after_char   TEXT,              -- trailing char з Macula XML: маqаф ־, соф пасук ׃
    lexical_class TEXT,             -- Macula TSV `class`; АВТОРИТЕТНІШЕ за morph для POS
                                    -- (H835a: morph='Ncmpc' іменник, але class='ij' вигук)
    slot         INTEGER,           -- Macula !N дослівно. Кілька токенів з однаковим slot =
                                    -- ОДНЕ display-слово. NULL для греки
    xlit_slot    TEXT,              -- BibleHub комбінована транслітерація на слот (ADR-020);
                                    -- лише іврит, лише не-helper токени
    gloss_display TEXT              -- синтез process_glosses.py ← ЦЕ ВИДНО В UI
);
```

**Одиниця відображення — `slot`, не рядок.** 46.4% івритських слотів багатотокенні, це
65.2% усіх токенів. Групування живе в `VerseTabContent.displayWords`, головний токен —
останній не-енклітичний. Деталі: `docs/original-tab.md`.

⚠️ `gloss_display` додається `process_glosses.py` через `ALTER TABLE`, тому в `SCHEMA`
у `build_db.py` його немає — колонка з'являється після кроку 5.

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
verify_xlit_integrity       ← auto-null, НЕ abort. ⚠️ docstring і комментар у коді
                               обіцяють SystemExit — код його не піднімає. Білд цією
                               перевіркою НЕ захищений (див. docs/original-tab.md)
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

# ── Окремі кроки після build_db.py — усі в rebuild.sh ──
build_versification.py  ← verse_org (ADR-028); падає на CONFLICT, set -e аборти до cp
idx_verse_org_rev       ← індекс зворотного хопу; створює rebuild.sh, НЕ скрипт
import_commentaries.py  ← commentary, ~36 071 вірші
process_glosses.py      ← ALTER TABLE + word.gloss_display; без нього крапки в UI
cp → SourceBible/Resources/sourcebible.db
```

---

## Історія розходження (щоб не повторилось)

`rebuild.sh` змінили 2026-07-16 о 12:25 у комміті `86f2a79` «drop verse_map (ADR-028
phase 2)». Цей документ чіпали того ж дня о 15:10 (`f32a884`) — і та правка додала один
рядок про ліцензію UBIO, а сім згадок `build_verse_map` лишились жити. Ще 31 комміт по
репо документ не бачив, хоч `scripts/` за той час змінювали лише двічі.

Висновок, який тут і закріплюється: **процедура належить `rebuild.sh`, а не тексту.**
Цей файл тримає те, чого немає більше ніде — походження й ліцензії датасетів, схеми,
і реєстр відомих пасток. Щойно тут знову з'явиться перелік команд — він знову збреше.
