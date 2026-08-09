# Fable Run-Brief — ALL verse_map consumers → verse_org (ADR-028 Phase 2)

**Status:** Done — прогін виконано (заміряно 2026-08-07: `verse_map` у базі немає, `verse_org` = 155 621 рядок)
**Date:** 2026-07-15 (розширено з «крос-рефи» на ВСІ споживачі verse_map)
**Реалізує:** ADR-028 (verse_org) — фаза 2: мігрувати ВСІ споживачі verse_map, потім DROP
**Гілка:** окремий worktree/branch (CLAUDE.md autonomous mode) — НЕ прямо в `work`

## ⚠️ SCOPE РОЗШИРЕНО: не лише крос-рефи

`verse_map` має **ТРИ** SQL-споживачі в Swift, усі биті однаково (57% хибні + 0 рядків
для UBIO, бо verse_map будується через Strong's-overlap, а UBIO без Strong's). Мігрувати
треба ВСІ, інакше half-migrated стан і DROP неможливий:

| функція (`DatabaseService.swift`) | що резолвить | симптом |
|---|---|---|
| `loadConcordance` (~403) | плоский конкорданс | зсунуті вірші / fallback |
| `loadBookUsageGroups` (~536) | per-book Word→Usage | **UBIO Псалми показують англ. (KJV fallback)** |
| `loadCrossReferences`+`convertVerse` (~732) | крос-рефи | чужий вірш + «Text unavailable» |

Усі три роблять reverse-lookup `verse_map` (Macula MT → номер перекладу) через
`COALESCE(vm.trans_verse, w.verse)` + fallback-переклад. Замінити на reverse `verse_org`
(`idx_verse_org_rev`: org_book/ch/vs → translation verse), який ПРАВИЛЬНИЙ і МАЄ UBIO.

---

## Навіщо (bug fix, не лише cleanup)

Фаза 1 (готово, змерджено): «Оригінал» тепер через `verse_org` (`loadOriginalWords`),
`findBestMaculaVerse` видалено. Але **крос-рефи досі маршрутизуються через `verse_map`**
(`convertVerse` + JOIN у `loadCrossReferences`), а `verse_map` **57% хибний** (виміряно,
ADR-028). Отже в зсунутих главах (RST Псалтир = Heb+1, 1Хр 6, Дан 6, Іс 64) крос-рефи
показують/лінкують **не ті вірші** — той самий баг, що «Оригінал» мав до фази 1.

Мета: перевести крос-рефи на `verse_org`, тоді прибрати `verse_map` / `convertVerse` /
`build_verse_map.py` як мертві.

---

## Поточний механізм (щоб не виводити наново)

- `cross_reference` таблиця **KJV-нумерована** (`from_verse`/`to_verse`).
  `DatabaseService.crossRefVersification = "KJV"`.
- `loadCrossReferences(bookId,chapter,verse,translation,…)`:
  1. **SOURCE:** `convertVerse(from: translation, to: "KJV")` — вірш читача → KJV, щоб
     знайти `cross_reference.from_verse`. `convertVerse` іде translation→MT→KJV через
     `verse_map` (2 хопи, `findMaculaVerse`/`findTranslationVerse`).
  2. **TARGET:** SQL із двома `verse_map` JOIN — `vm_x` (KJV→MT), `vm_t` (MT→translation)
     — щоб `xr.to_verse` (KJV) показати/лінкувати в нумерації читача; `v_fb` fallback-JOIN
     лишається на сирому `xr.to_verse` (fallback-переклад = crossRefVersification = KJV).
- `convertVerse` вживається **лише** крос-рефами (Original tab уже не вживає).

## Ключова складність (design hint)

Теперішній SQL припускає, що `to_book`/`to_chapter` фіксовані, змінюється лише verse.
**`verse_org` цього припущення не тримає**: `org_book_id`/`org_chapter` можуть відрізнятись
(крос-глава, тестамент), і мапінг N:M. Тому JOIN «той самий book+chapter, інший verse»
ламається. Найпевніше правильний підхід — **резолвити display-ref у Swift** (через
forward+reverse `verse_org` lookup на рядок), а не одним великим SQL JOIN. `verse_org` має
`idx_verse_org_rev (org_book_id, org_chapter, org_verse)` саме для reverse-хопу.

## Маршрутизація на verse_org

- reader-verse → **ORG**: forward `verse_org` (translation=reader).
- **ORG** → KJV (для пошуку `from_verse`): reverse `verse_org` (translation='KJV').
- `xr.to_verse` (KJV) → **ORG**: forward `verse_org` (translation='KJV').
- **ORG** → reader (display/tap): reverse `verse_org` (translation=reader).

Пильнувати: N:M (кілька ORG на вірш — брати перший/узгоджено), «немає оригіналу»
(org=NULL → крос-реф лишається на сирому KJV-числі, не падати), крос-глава (org_chapter
змінюється — display має вести на правильну главу).

---

## Scope

**ALLOW (можна чіпати):**
- `DatabaseService.swift`: `loadCrossReferences`, `convertVerse` (замінити на verse_org-логіку
  або видалити), `findMaculaVerse`/`findTranslationVerse` (видалити, якщо стануть мертві),
  **`loadConcordance` та `loadBookUsageGroups`** (замінити verse_map reverse-JOIN на verse_org
  reverse-lookup). Спільний helper для org→translation reverse-lookup — бажано.
- `rebuild.sh`: прибрати крок `build_verse_map.py` ПІСЛЯ того, як ніщо не вживає verse_map.
- `build_db.py`/схема: `DROP verse_map` (або просто перестати будувати) — лише коли Swift
  більше на неї не спирається.
- Нова reverse-`verse_org` helper-функція в `DatabaseService`, якщо потрібно.

**DENY (не чіпати):**
- `loadOriginalWords` / вкладка «Оригінал» / `verseWordSegmentPairs` (фаза 1, готово).
- Схема `verse_org` і `scripts/build_versification.py` / `overrides.tsv` (заморожені, доведені).
- Будь-що, не пов'язане з крос-рефами.
- `cross_reference` таблиця та її побудова (KJV-нумерація лишається — конвертуємо на льоту).

---

## Acceptance criteria

1. Крос-рефи резолвляться через `verse_org`; `verse_map`/`convertVerse`/`findMaculaVerse`/
   `findTranslationVerse`/`build_verse_map.py` **видалені** (або verse_map не будується і не
   читається ніде — `grep` по кодовій базі порожній).
2. **On-device QA (обов'язково) — зсунуті глави, де старий verse_map брехав:**
   - RST **Пс 50** (=Heb 51): крос-рефи ведуть на правильні вірші (не зсунуті).
   - RST **1Хр 6:5**, **Дан 6**, **Іс 64** — крос-рефи коректні.
   - **UBIO Пс 89** (=Heb 90, Молитва Мойсея) — **НАЙВАЖЛИВІШИЙ кейс.** UBIO БЕЗ
     Strong's → `build_verse_map.py` дає йому 0 рядків (align_chapter через Strong's-
     overlap). Тому зараз крос-рефи для UBIO Пс 89 подвійно биті: (а) identity бере
     KJV Пс 89 замість 90 → рефи чужого псалма; (б) ціль не конвертується → «Text
     unavailable». verse_org МАЄ UBIO → міграція має це виправити: рефи Пс 89(UBIO)
     мусять бути для Heb/KJV 90 і показувати укр. текст. Перевір обовʼязково.
   - НЗ контрольний (напр. Мт 5) — не зламано.
   - **UBIO Word→Usage у Псалмах** — конкорданс має показувати УКРАЇНСЬКИЙ текст
     (UBIO), а не англійський KJV-fallback. Зараз verse_map порожній для UBIO → MT-
     номер не резолвиться в синодальну UBIO → англ. fallback. verse_org має UBIO →
     має показувати укр. (тап слово в «Оригіналі» UBIO → Word → Usage → Псалми).
   - **Конкорданс у зсунутих главах** (RST/UBIO Псалми) — приклади ведуть на
     правильні вірші, не зсунуті.
3. **Регресія:** у НЕзсунутих главах (переважна більшість) крос-рефи **не змінились** —
   before/after на кількох reference-віршах (напр. Ів 3:16, Бут 1:1).
4. `fallback`-гілка (crossRefVersification) працює, коли переклад не має вірша.
5. Build зелений: Debug + **Archive** (Release); Swift 6 strict concurrency чисто.
6. Повна перезбірка `./rebuild.sh` проходить без `build_verse_map.py`; `verse_org` не
   зачеплено (byte-identical до поточної — звірити `.dump verse_org`).

## Огорожа (CLAUDE.md autonomous mode)

- Окремий worktree/branch, НЕ `work` напряму. Merge — Іван.
- iOS 26-only API під `#available(iOS 26)` + iOS 18 fallback.
- Жодних незворотних дій (не ламати робочу базу, не force-push). `verse_map` DROP —
  оборотний (регенерується `build_verse_map.py` з git-історії), але робити лише після
  проходження QA.
- Не виходити за scope; якщо треба — зупинитись і спитати.
- Фінал: повний diff + звіт змін на ревʼю Івану.

## Ризик-нотатка

`loadCrossReferences` — інтрикатний working SQL. Найбезпечніше: спершу reverse/forward
`verse_org` helper-и + unit-перевірка на кількох відомих зсувах (RST Пс 50 → Heb 51),
потім переписати резолвінг, і **обов'язково** before/after на незсунутих главах, щоб не
зламати 96% робочих крос-рефів заради виправлення зсунутих.
