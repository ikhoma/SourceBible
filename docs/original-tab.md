# Вкладка «Оригінал» — як вона працює

**Тип:** reference. Читати перед будь-якою задачею, що торкається оригінальних мов,
глос, транслітерації, слотів або морфології.
**Дата:** 2026-08-05
**Пов'язане:** ADR-020 (транслітерація per-slot), ADR-028 (версифікація), ADR-016
(clickability), `PDR-Lexicon-Language`, `docs/db_build.md`, `plan-uk-interlinear-glosses.md`

---

## Кому це і чому існує

Цей документ існує тому, що агенти в кожному новому чаті переоткривали через
багатогодинні дослідження те, що вже давно вирішено й лежить у коді. Найдорожчий
приклад: **одиниця відображення — слот, а не рядок таблиці `word`**. Це реалізовано в
`VerseTabContent.displayWords` ще до цього документа, але щоб це побачити, треба знати,
що дивитись у `VerseTabContent.swift`, а не в `WordTabContent.swift` (назва обманює).

Далі — карта конвеєра з іменами функцій і рядками. Читай розділ «Що зазвичай розуміють
неправильно» першим, якщо мало часу.

---

## Що зазвичай розуміють неправильно

| Хибне припущення | Насправді |
|---|---|
| Одиниця = рядок `word` | Одиниця екрана = **слот** (`word.slot`). 46.4% слотів івриту містять >1 токен, це 65.2% усіх токенів. Групування: `VerseTabContent.displayWords:280` |
| Глоса під словом — це `word.gloss` | Показується `COALESCE(gloss_display, gloss_macula, gloss)` — `DatabaseService.swift:229`. Тобто в нормі це **`gloss_display`**, синтезований `process_glosses.py` |
| `gloss_macula` — це колонка `gloss` із TSV | `gloss_macula` заповнюється з **XML lowfat** атрибута `gloss` (`build_db.py:579`). Колонка `word.gloss` — це TSV `english` (`build_db.py:410`) |
| Крапки в глосі (`he.makes.me.lie.down`) — сира проблема, яку треба вирішувати | `process_glosses.py:74` уже нормалізує їх у `gloss_display`: знімає займенниковий префікс підмета, розвертає конструктний ланцюжок, крапки → пробіли |
| Транслітерація одна | Їх чотири джерела з жорстким приоритетом. `BibleWord.bestXlit:172` = `xlitSlot ?? xlit ?? xlitSimple`; лексиконний хедер має **свій, інший** ланцюжок |
| Головний токен слота — перший | **Останній не-енклітичний** (`headToken:269`). «Перший не-helper» була стара евристика, вона помилялась на ~8.5% івритських слів |
| Вкладка недоступна для перекладів без Strong's | Доступна завжди. Clickability має «cheat mode» — `clickableWordIDs:401` |
| Версифікація = identity | Тільки якщо в `verse_org` **немає рядка взагалі**. Див. три різні випадки нижче |
| `findBestMaculaVerse` / `verse_map` десь ще є | Видалені (ADR-028 фаза 2). Живуть лише як згадки в комментарях і в застарілому `db_build.md` |

---

## Конвеєр цілком

```
Macula TSV ─┐
Macula XML ─┼─► build_db.py ──► word ──┐
BibleHub   ─┘                          │
                                       ├─► DatabaseService.loadWords (SQL)
verse_org ─────────────────────────────┘         ▲
                                                 │ loadOriginalWords (версифікація)
                                                 │
                              ReaderViewModel.loadWordsForSelectedVerse
                                                 │
                                       BibleVerse.words  ([BibleWord])
                                                 │
                              VerseTabContent.displayWords  ◄── ГРУПУВАННЯ ПО СЛОТАХ
                                                 │
                                  OriginalWordsView → WordRow
                                                 │ tap
                                  ReaderViewModel.tapWord → WordTabContent
```

---

## 1. Дані: Macula → `word`

`scripts/build_db.py`. Два проходи.

**Прохід TSV** — `parse_macula_tsv:379`, викликається з `import_macula_hebrew` (іврит,
`WLC/tsv/macula-hebrew.tsv`) і `import_macula_greek` (грека, `Nestle1904/tsv/…`).

| Колонка TSV | → `word` | де |
|---|---|---|
| `ref` (розібраний) | `book_id`, `chapter`, `verse`, `slot` | `:397–401` |
| `text` | `surface` | `:403` |
| `lemma`, `morph` | `lemma`, `morph` | `:408–409` |
| `english` (fallback `gloss`) | **`gloss`** | `:410` |
| `strongnumberx` (Heb) / `strong` (Grk) | `strongs_id` (нормалізований) | `:412` |
| `transliteration` / `normalized` | `xlit` | `:415–423` |
| `class` | `lexical_class` | `:427` |
| лічильник у межах вірша | `position` | `:429` |

**Прохід XML lowfat** — `enrich_macula_from_xml:522` (іврит) і
`enrich_macula_greek_from_xml` (грека).

| Атрибут XML | → `word` | примітка |
|---|---|---|
| `gloss` | **`gloss_macula`** | лише іврит, `:579` |
| `role` | `syntax_role` | лише іврит |
| `greek`, `greekstrong` | `greek`, `greek_strong` | лише іврит — це LXX-відповідник, не НЗ |
| `after` | `after_char` | і іврит, і грека |

### `slot` — найважливіша колонка

`ref` має форму `PSA 51:7!5`. `parse_macula_ref:286` бере `!N` **дослівно**, без
перенумерації; за відсутності `!N` ставить `1`. Це і є `slot`.

`position` — **інший** лічильник, послідовний у межах вірша, з нього будується `word.id`
(`"GEN|1|1|1"`). Саме тому кілька токенів одного слота не втрачаються.

Приклад із реальних даних, Пс. 51:7 (МТ):

| ref | strongs | morph | `gloss` (TSV english) | `gloss_macula` (XML) |
|---|---|---|---|---|
| `PSA 51:7!5` | 3179 | Vpp3fs | conceived | `she` |
| `PSA 51:7!5` | 5204a | Sp1cs | me | `conceived.me` |
| `PSA 51:7!6` | 0517 | Ncfsc | mother | `mother` |
| `PSA 51:7!6` | 2967a | Sp1cs | my | `my` |

Читай уважно: `gloss_macula` — це **фраза рівня слота, порізана по токенах**, і різана
не морфема-в-морфему. Дієслівний токен несе `she`, а суфікс несе `conceived.me`. Це не
баг Macula й не баг імпорту — це властивість колонки. Колонка `gloss` (TSV `english`)
натомість по-токенна й вирівняна правильно.

### `xlit_slot` (ADR-020)

`_apply_bh_hebrew_translit:1910`, джерело `data/hebrew_translit.json` (BibleHub),
**лише іврит**; для грецьких рядків завжди NULL.

- «Display slots» = слоти, що містять хоч один не-helper токен (`HELPER_STRONGS` —
  зв'язані морфеми, яким BibleHub не дає власної транслітерації, напр. `H871a`, `H1886a`).
- N-те слово BibleHub кладеться на `display_slots[N-1]`.
- Helper-токени пропускаються навмисно — вони лишаються зі своєю короткою `xlit`.
- Якщо кількість display-слотів не збігається з кількістю слів BibleHub —
  **вірш пропускається цілком** (`COUNT_MISMATCH`), а не псується частково.

⚠️ **Розбіжність, яку треба знати:** `build_db.py` пише `xlit_slot` на той токен, який
**він** вважає коренем, а це провідний прийменник — тобто стара евристика. Погляд
компенсує це, читаючи `xlit_slot` з будь-якого токена слота
(`tokens.compactMap(\.xlitSlot).first`, `VerseTabContent.swift:337`), а НЕ з head-токена.
Довгий комментар там же це фіксує. Якщо чіпаєш одне — перевір інше.

### `gloss_display` — синтез

`scripts/process_glosses.py`, окремий крок конвеєра після `import_commentaries.py`.
`synthesize:74` бере `gloss_macula` (fallback `gloss`) і дає `word.gloss_display`.
Грека повертається як є. Для івриту шість стадій:

1. Неперекладні частки (`UNTRANSLATABLE`, напр. H853) → `—`.
2. Зняти квадратні дужки: `[is].the` → `the`.
3. Зняти крапковий префікс займенника-підмета: `he.created` → `created`.
4. Розвернути конструктний ланцюжок: `heart your` → `your heart`.
5. Решта крапок → пробіли: `let.it.be` → `let it be`.
6. Запобіжник власних назв (`PROPER_NOUNS`): `of david` → `of David`.

Тобто задача «прибрати крапкову нотацію й впорядкувати слова» **вже розв'язана** для
англійської глоси. Будь-яка нова робота над глосами має починатися з цього файла.

### Перевірки цілісності

`verify_xlit_integrity:719` — єдина. Ловить sub-entry, що успадкував академічну
`transliteration` від неспорідненого базового номера (`H1886a` від `H1886`), через
умову «та сама xlit, але інший `original`».

⚠️ **Комментар і docstring брешуть.** Обидва обіцяють `SystemExit` при знахідці.
Код нічого не піднімає: друкує `WARNING`, робить `UPDATE strongs SET transliteration =
NULL` для порушників (зберігаючи `xlit_simple`) і йде далі. Це суперечить правилу
«🧪 Перевірки — у код» із `CLAUDE.md`: тут перевірка не має ненульового коду виходу.
`db_build.md` описує фактичну (не-аварійну) поведінку правильно.

---

## 2. Читання: `DatabaseService`

`SourceBible/Services/DatabaseService.swift`. `final class … @unchecked Sendable`,
синглтон, `nonisolated(unsafe) private var db`, режим
`SQLITE_OPEN_READONLY | URI | NOMUTEX`, `PRAGMA cache_size=-8000`.
Кеша prepared statements немає — `query` готує й фіналізує запит щоразу.
`async`/`await`/`Task` у файлі немає взагалі: читання синхронне, бо «<1ms з кешем»
(обґрунтування в `ReaderViewModel:840`).

**`loadWords:213`** — власне SQL:

```sql
SELECT w.id, w.surface, w.strongs_id, w.morph,
       COALESCE(w.gloss_display, w.gloss_macula, w.gloss) AS display_gloss,
       COALESCE(NULLIF(s.transliteration,''), '') AS xlit_lex,
       w.xlit AS xlit_ctx,
       w.syntax_role, w.greek, w.greek_strong,
       w.after_char, w.lexical_class,
       w.slot, w.xlit_slot
FROM word w
LEFT JOIN strongs s ON w.strongs_id = s.id
WHERE w.book_id = ? AND w.chapter = ? AND w.verse = ?
ORDER BY w.position
```

`ORDER BY w.position` — не `slot`. Групування в погляді розраховує на те, що токени
одного слота йдуть послідовно, і це гарантує саме `position`.

**`loadOriginalWords:689`** — версифікація. Питає `verse_org`, потім кличе `loadWords`
на кожен розв'язаний оригінальний реф. Три випадки, і їх треба розрізняти:

| Стан `verse_org` | Поведінка | Приклад |
|---|---|---|
| Рядка немає взагалі (`!sawRow`) | identity-fallback: `loadWords` на власному рефі — база старіша за `verse_org` | — |
| Рядок є, `org_*` = NULL | повертає `[]` — «оригіналу немає», чесний порожній стан | KJV/NASB Неєм. 7:68, RST Рим. 16:24 |
| Один або кілька рядків | конкатенує слова з **усіх** оригінальних рефів (N:M) | злиті/розділені вірші |

Крос-глава працює сама, бо `org_chapter` у рядку незалежний — жодного припущення «та
сама глава» в коді немає.

Зворотний хоп (оригінал → переклад) для крос-рефів і конкордансу: `orgRef:618` +
`translationRef:643`, а `loadConcordance:382` і `loadBookUsageGroups:473` роблять той
самий хоп **інлайном у SQL** через `LEFT JOIN verse_org`. Індекс `idx_verse_org_rev`
створюється в `rebuild.sh`, не в `build_versification.py`.

**`loadStrongs:267`** — лексикон. `baseId` знімає кінцеві малі літери лише коли перед
ними цифра (`H835a` → `H835`). Fallback на базову статтю дозволений **тільки** якщо
перший Unicode-скаляр `original` у sub-entry і в базі однаковий:

```
H1886 = Дотан (місто),  H1886a = הַ (артикль)   — НЕ споріднені
H871  = Атарім,         H871a  = בְּ (прийменник) — НЕ споріднені
H835  = אֶשֶׁר,            H835a  = אַשְׁרֵי          — споріднені ✓
```

У `loadConcordance` і `loadBookUsageGroups` для **групування** використовується інша,
простіша перевірка суфікса й GLOB `w.strongs_id GLOB ? || '[a-z]'` — там немає перевірки
кореня, бо це зіставлення, а не злиття текстів.

`slot` / `xlit_slot` у цьому файлі лише читаються з БД і кладуться в модель. Жодного
`GROUP BY slot` тут немає.

---

## 3. Стан: `ReaderViewModel`

`@MainActor`, усе синхронно.

```
VerseTextView.Coordinator.handleTap:357 → onVerseTap
  → tapVerse:897        selectedVerse, activeSheet = .verse, loadWordsForSelectedVerse()
  → loadWordsForSelectedVerse:861 → DatabaseService.loadOriginalWords
  → verses[idx].words оновлюється, selectedVerse перепризначається
```

Інші входи в те саме завантаження: `navigateToVerse:774`, `navigateToPreviousVerse:971`,
`navigateToNextVerse:988`, і `tapWord(segment:):914` — останній лише якщо
`verse.words.isEmpty`.

**Кешу оригінальних слів немає.** Повторний тап на той самий вірш = повторний запит.
`pageVersesCache:798` кешує вірші сусідніх сторінок пейджера, але з `words: []` —
`loadChapter` ніколи не тягне Macula-слова, тож префетчу слів немає. Інвалідація —
`pageVersesCache.removeAll()` у `loadChapter:839`.

Індикатора завантаження для слів немає (`isLoading` — про главу, `isLoadingStrongs` —
про лексикон). Скасування `Task` при швидкому перемиканні віршів немає, бо немає
`Task`; єдиний скасовуваний — `positionSaveTask` для збереження позиції читання.

`clickableWordIDs:401`, `verseWordSegmentPairs`, `translationLacksStrongsMapping`,
`wordNavSequence` — **computed**, не збережені. `clickableWordIDs` перебудовує все
відображення при кожному доступі, тому `OriginalWordsView` виносить його в локальний
`let` (інакше O(words²·segments) на рендер).

---

## 4. Погляд: групування по слотах

Файл — **`Views/BottomSheet/VerseTabContent.swift`**, не `WordTabContent.swift`.

`OriginalWordsView:228` — вміст пілюли «Оригінал». Пілюлі: `VersePill:55` =
`.crossRefs, .translations, .original, .commentaries`; за замовчуванням відкривається
`.crossRefs`, тож користувач має тапнути «Оригінал» окремо. Дані на той момент уже
завантажені — **відкриття пілюли не робить запиту до БД**.

`displayWords:280` — ядро:

1. Якщо `words.first?.slot == nil` → повернути як є. Це і є фактична розвилка
   іврит/грека: у греки `slot` завжди NULL, тож кожен рядок = одне слово.
2. Групувати **послідовні** токени з однаковим `slot`.
3. Злити групу в один `BibleWord`:

| Поле | Правило злиття |
|---|---|
| `surface` | конкатенація `displayText` кожного токена (а `displayText` = `text + afterChar`) |
| `gloss` | `joined(separator: " ")` — крапки всередині кожного куска лишаються |
| `morphology` | `joined(separator: "·")` — це `morphemeSeparator` для декодера |
| `strongsId`, `xlit`, `xlitSimple`, `syntaxRole`, `lexicalClass` | від **head**-токена |
| `xlitSlot` | **перший непорожній у групі**, навмисно не від head — див. розбіжність у §1 |
| `afterChar` | `nil` — уже вкладений у `surface`, щоб не додати двічі |

**Head-токен** — `headToken:269`: останній токен, який не є енклітикою.
Енклітика — `lexical_class == "x"` або `morph`, що починається з `S` (займенниковий
суфікс). Попередня евристика «перший не-helper зі списку Strong's» ставила головним
провідний прийменник і помилялась на ~8.5% івритських слів (звірено з BSB, ADR-020).

`displayWords` — computed, без мемоізації: групування рахується на кожен рендер.
Прийнятно, бо це один вірш.

### Транслітерація — два різні ланцюжки

- **Рядок у списку й «форма в контексті»:** `BibleWord.bestXlit:172` =
  `xlitSlot ?? xlit ?? xlitSimple` — BibleHub на слот → Macula на входження →
  TBESH на лему.
- **Хедер лексиконної статті:** `entry.xlitSimple` → `entry.transliteration`, бо там
  показується **лема**, а не поверхнева форма. `word.xlit` туди свідомо не потрапляє.

Не змішуй їх — це різні поверхні з різними джерелами правди.

### Глоса на екрані

`WordRow` виводить `word.gloss` дослівно (`WordTabContent:1348`) — жодного
`replacingOccurrences` чи `split`. Тобто крапки, що дожили до цього місця, видно
користувачу. У нормальній базі їх немає, бо працює `gloss_display`; якщо крапки
з'явились на екрані — не запускали `process_glosses.py`.

### Морфологія

`MorphologyDecoder:790` — stateless enum, два входи: `decode:1128` (коротка форма для
рядка списку) і `decodeFull:949` (повна для картки слова).

- Івритські коди без префікса: `V` + стем + аспект + особа/рід/число; `N` + рід/число/стан.
- Грецькі коди через дефіс (`V-PAI-3S`) — `decodeGreek:1244`.
- Складений код зі слота (`Td·Ncfsa`) розбирається по `morphemeSeparator`;
  `headMorpheme` бере останню не-`S` частину, `composition` дає читабельне
  «артикль + іменник».
- **`lexical_class` авторитетніший за morph і застосовується останнім**: H835a має
  `morph='Ncmpc'` (іменник), але `class='ij'` → «вигук».
- Випадок `"S"`: `decodeFull` розрізняє підтипи (`Sp` займенниковий, `Sd` прямого
  об'єкта), коротка форма `decodeHebrew` навмисно згортає всі `S` в один ярлик.
- **Невідомий тег → `nil` → рядок просто не показується.** Ні заглушки, ні помилки.
- Усі рядки йдуть через `TranslationProvider` з константами з `MorphKey.swift`, ніколи
  не літералами. Назви івритських стемів (Qal, Niphal…) не перекладаються.

### Тап по слову

`WordRow` → `vm.tapWord(word, in: verse):940`: ставить `selectedWord`,
`bottomSheetMode = .word`, `syncSegment(for:)` (підсвітити слово в тексті перекладу),
`loadStrongs(for:)`. Нового аркуша не відкривається — той самий
`VerseBottomSheetView` перемикає сегмент на «Слово».

### Іврит vs грека в розкладці

Власних шрифтів для івриту/греки немає — працює системний плюс Unicode bidi.
`WordRow` не має явного RTL-оверайду. Єдиний явний — `InfoGroup:556`, де рядок
позначений `isValueHebrew` отримує `.environment(\.layoutDirection, .rightToLeft)`;
у грецькій секції це `false`. Заголовок секції обирається за `currentBook.testament`
(`sectionTitleKey:236`), не за самими даними.

`after_char` (маqаф `־`, соф пасук `׃`) додається через `displayText:176` і при злитті
слота вже вкладений у `surface`.

Аналітика: `.onAppear { tracker.recordFeatureUse(.original) }` на `OriginalWordsView`.
Окремої події `analytics.track` для відкриття пілюли немає.

---

## Заміри корпусу (не оцінки)

Порахувано по `macula-hebrew.tsv` 2026-08-05, лише рядки з непорожніми `strongnumberx`
і `gloss`:

| | |
|---|---|
| токенів із глосою | 470 537 |
| display-слотів (`!N`) | 305 349 |
| розміри слотів | 1 → 163 680; 2 → 119 420; 3 → 20 980; 4 → 1 268; 5 → 1 |
| багатотокенних слотів | 46.4% слотів = **65.2% токенів** |
| унікальних `(strongs, morph, gloss_macula)` | 63 487 |
| унікальних **слотових** одиниць | 78 451 |
| токенних трійок для 80% покриття токенів | 5 584 |
| слотових одиниць для 80% покриття слотів | 21 874 |
| дієслівних токенів із глосою-займенником | 4 687 / 72 757 = 6.4% |
| `Sp*` токенів із крапковою глосою | 7 852 / 45 607 = 17.2% |

Два останні рядки — це не дефект, а наслідок того, що `gloss_macula` живе на рівні слота.

---

## Відомі розбіжності й застаріле

1. **`verify_xlit_integrity` не падає**, хоч комментар і docstring обіцяють `SystemExit`.
2. **`build_db.py` пише `xlit_slot` на провідний прийменник**, погляд компенсує читанням
   `compactMap(\.xlitSlot).first`. Два місця з різними правилами головного токена.
3. **`docs/db_build.md` застарілий у двох місцях:** блок схеми `word` не має
   `after_char`, `lexical_class`, `slot`, `xlit_slot`; і документ досі описує `verse_map`
   та `build_verse_map.py` як актуальні, хоч вони видалені в ADR-028 фаза 2.
4. **Кешу оригінальних слів немає**, префетчу для сусідніх віршів немає. Поки читання
   синхронне й <1ms — це свідомий вибір, не недогляд.
5. **`loadOriginalWords` дублює SQL `orgRef`** інлайном замість викликати його.

---

## Якщо ти агент і збираєшся щось тут міняти

- ⛔ Правило #1 у `CLAUDE.md`: не редагуй Swift, скрипти чи базу без явного прохання.
- ⛔ Не читай `sourcebible.db` із Linux-пісочниці — APFS sparse, SQLite впаде з
  `SQLITE_CORRUPT`. Усе потрібне для аналізу є в `data/*.tsv`, `*.json` і зіпах Macula.
- Одиниця — слот. Якщо твоє рішення оперує рядками `word`, спершу перевір, чи не
  розрізає воно display-слово.
- `gloss_display` — не `gloss_macula`. Перед тим як «виправляти крапкову нотацію»,
  прочитай `process_glosses.py`.
- Python — під 3.9 (`Optional[str]`, не `str | None`).
- Будь-яку перевірку пиши кодом із ненульовим кодом виходу; тести для скриптів даних —
  у `scripts/tests/`, годувати реальною формою даних.
