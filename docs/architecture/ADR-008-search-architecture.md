# ADR-008: Search Architecture — MVP

**Status:** Accepted (amended 2026-06-11)  
**Date:** 2026-05-23  
**Deciders:** Ivan

## Context

iOS offline-first Bible app. Потрібен пошук по тексту перекладу, Strong's номерах, леммах і морфології. DB — SQLite bundle (read-only, `immutable=1`). Existing: `word` table (Macula, lemma/morph/strongs_id), `verse` table, `strongs` table.

## Decision

**V1 MVP: FTS5 + SQL joins. Без vector search.**

1. `verse_fts` — FTS5 virtual table (`content='verse'`, `tokenize='unicode61 remove_diacritics 2'`). Будується в `build_db.py` один раз.
2. `search_terms` — deduplicated word list з verse text для autocomplete (GLOB prefix scan).
3. Strong's/lemma/morph — прямі SQL SELECT на `word` table (дані вже є).
4. `SearchViewModel` — debounce 280ms, `Task.detached` для DB queries off main thread.
5. `SearchView` — `.searchable` (нативний iOS API) + `Tab(role: .search)`. Предіктів і результати рендеряться **inline** в основному `List` (Apple Music pattern). **Без `.searchSuggestions`** — див. amendment 2026-06-11.

## Amendment 2026-06-11 — drop `.searchSuggestions`, predictions→results model

**Контекст:** на iOS 26 системний `.searchSuggestions` overlay лягає окремим шаром і стискає `content` у вузьку смугу (зсуви ширини + різний фон у "Searching…"/"Nothing found"). Перша спроба (живі inline-результати під час набору) дала іншу проблему: щільний текст результатів малювався позаду предіктіва й напівпрозорого нижнього бара ("rendering underneath"), а тап по підказці, якої нема в активному перекладі, давав порожній екран.

**Рішення (модель "предіктів → результати"):** прибрати `.searchSuggestions`; розділити дві фази:
- **Набір (uncommitted):** показуємо **тільки** список предіктіва (`predictiveList`) — без результатів під низом. Префікс терміна `.primary`, продовження `.secondary` (Apple Music "**dak**ooka"). Якщо підказок нема — один рядок для пошуку буквального тексту.
- **Коміт** (тап підказки / синій Search / `onSubmit`): `committedQuery` = запит, запускаємо `vm.search`, ховаємо клавіатуру (`resignFirstResponder`), показуємо повноекранну сторінку результатів (`resultsList`); 0 результатів → центрований "Nothing found" (`emptyResultsView`), а не порожнеча.
- Редагування тексту після коміту (`trimmedQuery != committedQuery`) → назад у предіктів. Скасування пошуку (✕) скидає `committedQuery`.

`vm.search` більше **не** викликається на кожне натискання — лише на коміт.

**Не змінюється:** `.searchable` + `Tab(role: .search)` (нижній бар + морф-анімація), FTS5, `search_terms`, `DatabaseService.suggestTerms()`/`searchByText()`, debounce. Зміна суто на рівні презентації UI (`SearchView.swift`).

**Відомий борг (крок B, окремий спринт):** `search_terms` будується з усіх перекладів (`build_db.py` → `build_search_terms`, `SELECT text FROM verse`), а `searchByText` фільтрує по `v.translation`. Тому предіктів може пропонувати слово, якого нема в активному перекладі (напр. "bloodshed" у KJV) → коміт дає "Nothing found". Фікс: зробити `search_terms` по-перекладним (колонка `translation`, `suggestTerms(prefix:translation:)`). Потребує ребілду бази.

## Rejected Options

- **ObjectBox** — міграція ORM без ROI для read-only bundle.
- **GRDB.swift** — не потрібен без sqlite-vec (системний SQLite має FTS5).
- **sqlite-vec + ONNX Runtime Mobile** — V1.5; +2-3 дні складності, якість ембедингів невідома без тестування.
- **Stanza/VESUM лематизація** — defer до V1.5 разом з vector search.

## Trade-offs

| Що маємо | Що відкладаємо |
|---|---|
| Working search за 4 год | Semantic search "смуток → Йов" |
| Zero нових залежностей | Морфологічний стемінг для укр. |
| 100% offline | — |
| Strong's/lemma — точний match | — |

## Upgrade Path (V1.5)

1. `build_db.py`: `build_verse_vectors()` — `sentence-transformers` → ONNX INT8 → `vec0` virtual table (~47MB).
2. iOS: `sqlite-vec` SPM пакет + ONNX Runtime Mobile (~30MB, all-MiniLM-L6-v2 або fine-tuned на cross_reference pairs).
3. `DatabaseService.searchByVector()` → новий метод, existing architecture не змінюється.
4. `SearchMode.semantic` → додається до enum без рефакторингу.

## Files Changed

- `scripts/build_db.py` — `build_verse_fts()`, `build_search_terms()`
- `SourceBible/Models/SearchModels.swift` — новий файл
- `SourceBible/Services/DatabaseService.swift` — `// MARK: - Search` секція
- `SourceBible/ViewModels/SearchViewModel.swift` — новий файл
- `SourceBible/Views/Search/SearchView.swift` — повна реалізація
- `SourceBible/ContentView.swift` — environment objects для SearchView
