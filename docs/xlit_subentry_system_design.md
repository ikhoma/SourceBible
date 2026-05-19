# Системний дизайн: xlit sub-entry bug та pipeline збірки sourcebible.db

## Проблема

Strong's номери мають sub-entries з суфіксними літерами: H871a, H871b, H1886d, H2050b тощо.

При міграції TBESH → `strongs` таблиця скрипт `migrate_tbesh_to_strongs.py` заповнював
`transliteration` для sub-entries, відрізаючи суфікс і беручи xlit від базового номера:

```
H871  = אֲתָרוֹת  'a.ta.rim'   ← місто Атарот
H871a = בְּ       'a.ta.rim'   ← НЕПРАВИЛЬНО: прийменник בְּ отримав xlit від міста
H871b = כְּ       'a.ta.rim'   ← НЕПРАВИЛЬНО: прийменник כְּ отримав xlit від міста

H1886  = דֹּתָן   'do.tan'     ← місто Дотан
H1886d = הָ       'do.tan'     ← НЕПРАВИЛЬНО: означений артикль הָ отримав xlit від міста

H2050  = הָתַת    'ha.tat'     ← дієслово "нападати"
H2050b = וְ       'ha.tat'     ← НЕПРАВИЛЬНО: сполучник וְ отримав xlit від дієслова
H2050c = הוּא     'ha.tat'     ← НЕПРАВИЛЬНО: займенник
H2050d = וְ       'ha.tat'     ← НЕПРАВИЛЬНО: сполучник
```

Базовий номер і sub-entry в Strong's — це **абсолютно різні слова**. Граматичні частки
(сполучники, прийменники, артиклі, суфіксні займенники) отримали xlit від несумісних лексем.

---

## Корінь причини

```python
# migrate_tbesh_to_strongs.py (помилкова логіка):
base_id = re.sub(r'[a-z]$', '', strongs_id)  # H871a → H871
xlit = tbesh_data[base_id]['transliteration']  # бере xlit від H871 (Атарот)
cursor.execute("INSERT INTO strongs ... transliteration=?", (xlit,))
# ↑ H871a отримує 'a.ta.rim' замість NULL або правильного xlit
```

---

## Архітектура pipeline (3 рівні захисту)

```
┌─────────────────────────────────────────────────────────────┐
│  build_db.py  (єдиний точка входу, без окремих міграцій)    │
│                                                             │
│  Step 1: create_schema()                                    │
│    └─ word table: + gloss_macula, syntax_role, greek,       │
│                     greek_strong                            │
│                                                             │
│  Step 2: import_translations()  [без змін]                  │
│                                                             │
│  Step 3: import_macula_hebrew()  [TSV → base columns]       │
│    └─ populate: surface, lemma, strongs_id, morph           │
│                                                             │
│  Step 4: enrich_macula_from_xml()  [NEW — з lowfat XML]     │
│    └─ populate: xlit, gloss_macula, syntax_role,            │
│                 greek, greek_strong                         │
│                                                             │
│  Step 5: import_stepbible_lexicons()  [EXACT MATCH ONLY]    │
│    └─ UPDATE strongs SET ... WHERE id = ?  ← вже є         │
│                                                             │
│  Step 6: verify_xlit_integrity()  ← NEW (fail-fast)         │
│    └─ SQL check: sub-entry xlit = base xlit + різний        │
│                  original → ABORT if count > 0              │
│                                                             │
│  Step 7: copy → SourceBible/Resources/sourcebible.db        │
└─────────────────────────────────────────────────────────────┘
```

---

## Рівень 1: Нові колонки в схемі (Step 1)

Додати до `CREATE TABLE word`:

```sql
gloss_macula TEXT,   -- Macula contextual gloss ("he walked")
syntax_role  TEXT,   -- синтаксична роль (Subj, Obj, Pred, …)
greek        TEXT,   -- LXX еквівалент (грецьке слово)
greek_strong TEXT    -- Strong's G номер LXX еквіваленту
```

---

## Рівень 2: Integrity check після TBESH import (Step 6)

```python
def verify_xlit_integrity(db):
    """
    Fail the build if any sub-entry inherited xlit from an unrelated base entry.
    Safe sub-entries (same original word, e.g. H7927 / H7927a = Shechem) are excluded.
    """
    rows = db.execute("""
        SELECT sub.id, sub.transliteration, base.transliteration,
               sub.original, base.original
        FROM   strongs sub
        JOIN   strongs base
               ON base.id = RTRIM(sub.id, 'abcdefghijklmnopqrstuvwxyz')
        WHERE  base.id != sub.id
          AND  sub.transliteration IS NOT NULL
          AND  sub.transliteration != ''
          AND  sub.transliteration = base.transliteration
          AND  sub.original != base.original  -- різні слова → помилка
    """).fetchall()

    if rows:
        for r in rows:
            print(f"  XLIT BUG: {r[0]} '{r[3]}' got xlit '{r[1]}' from {r[4]}")
        raise SystemExit(f"BUILD FAILED: {len(rows)} sub-entry xlit violations.")

    print(f"  ✓ xlit integrity: 0 violations")
```

Якщо виникне — збірка впаде з чіткою діагностикою. Не треба перевіряти вручну.

Ручна перевірка після збірки (має повернути 0 рядків):

```sql
SELECT sub.id, sub.transliteration, base.transliteration AS base_xlit,
       sub.original, base.original AS base_original
FROM   strongs sub
JOIN   strongs base ON base.id = RTRIM(sub.id, 'abcdefghijklmnopqrstuvwxyz')
WHERE  base.id != sub.id
  AND  sub.transliteration = base.transliteration
  AND  sub.original != base.original;
```

---

## Рівень 3: Swift UI — пріоритет xlit (WordMeaningView)

Навіть якщо DB містить неправильний xlit, UI пріоритизує контекстуальний xlit з Macula:

```swift
// WordMeaningView / headerSection
let xlit: String = {
    // 1. Macula contextual xlit — завжди правильний для конкретної словоформи в тексті
    if let ctx = vm.selectedWord?.xlit, !ctx.isEmpty { return ctx }
    // 2. TBESH lemma xlit — правильний після DB-фіксу
    if !entry.xlitSimple.isEmpty { return entry.xlitSimple }
    // 3. Academic transliteration — fallback
    return entry.transliteration
}()
```

---

## Що НЕ чіпати: безпечний concordance fallback

`loadConcordance()` GLOB search — **безпечний**:

```sql
WHERE w.strongs_id = ?
   OR (w.strongs_id GLOB ? || '[a-z]' AND length(w.strongs_id) = length(?) + 1)
-- H835 → знаходить і H835 і H835a, H835b тощо
```

Це OK бо ми йдемо від **базового до sub-entries** (розширення пошуку),
а НЕ від sub-entry до базового (що дало б неправильні lexical дані).

Небезпечний напрямок — `H871a → H871` (strip suffix) для отримання xlit/definition.

---

## Trade-offs

| Рішення | Альтернатива | Чому обрано |
|---|---|---|
| Fail-fast у build скрипті | SQL патч після збірки | Помилка не може потрапити в prod |
| Exact-only TBESH match | Fallback chain | Wrong data > missing data для xlit |
| XML lowfat для xlit колонки | TSV | XML має per-word xlit (TSV — лише lemma) |
| Єдиний `build_db.py` | Окремі міграції | Неможливо запустити міграції в неправильному порядку |

---

## Файли

| Файл | Зміна |
|---|---|
| `scripts/build_db.py` | Схема + `enrich_macula_from_xml()` + `verify_xlit_integrity()` |
| `scripts/migrate_tbesh_to_strongs.py` | Deprecated — логіка перенесена в `build_db.py` |
| `SourceBible/Resources/sourcebible.db` | Rebuild з нуля |
| `SourceBible/Views/BottomSheet/WordTabContent.swift` | `headerSection` — пріоритет `word.xlit` |
