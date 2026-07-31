# LOG — хронологія проєкту

> Append-only. Формат: `## [РРРР-ММ-ДД] <тип> | <заголовок>` (тип: ingest / decision / fix / lint / finding).
> Тільки додавати новий запис знизу. Протокол — `docs/WIKI.md`.

---

## [2026-07-20] fix | Нові чати Проєкту «не пам'ятали» контекст
Причина: custom instructions claude.ai-Проєкту були порожні + Cowork не авто-читає `CLAUDE.md` (на відміну від Claude Code CLI). Пам'ять репо (`CLAUDE.md`+`docs/`) не завантажувалась у Cowork-чати.
Фікс: bootstrap у custom instructions Проєкту (під'єднати `~/Projects/SourceBible` → читати `CLAUDE.md`+`INDEX.md`) + снапшот `project-memory.md` у knowledge Проєкту.

## [2026-07-20] ingest | Завершено патерн пам'яті (LOG + протокол)
Додано `docs/WIKI.md` (операції ingest/query/lint, 3 шари) і `docs/LOG.md` — дві прогалини відносно LLM-Wiki Карпатого.

## [2026-07-20] decision | Search → тематичні добірки (сітка як Apple Music)
Модель — курована подорож 5–9 кроків {назва, уривок, контекст, питання, крос-рефи}. Пілот: «Божий характер».

## [2026-07-20] finding | Звірка кореня для крос-рефів «Божого характеру»
Стрижень Вихід 34:6-7 → 6 атрибутів. Крос-рефи розділено: точний корінь (erekh appayim ×6, hesed ×4, nasa) / той-самий-корінь-інша-форма (r-ch-m, ch-n-n, aman) / лише тематичні (Іс.Нав.23:14, Бут.50:20, salach, avar).

## [2026-07-20] decision | Картка слова: лексичне vs сюжетне посилання
Тап на слово → word study лише з кореневими місцями (лексичне); сюжетні ілюстрації — окремий тип посилання. Мета фічі — драйвити adoption core word-study.

## [2026-07-20] decision | ADR-030 (Proposed) — кореневий конкорданс через Strong's-деривацію
Перевірено: групування за коренем немає в жодному джерелі (strongs/word/TBESH/BSB/Macula); Macula coredomain групує за значенням, не коренем. Рішення: імпорт OpenScriptures Strong's derivation → `root_id` у `strongs`; картка слова отримує рівень «цей корінь». Скрипт — окремо після прийняття ADR.

## [2026-07-20] decision | ADR-030 прийнято (Accepted) + чернетка скрипта
ADR-030 → Accepted. Додано чернетку `scripts/build_strongs_roots.py` (Python 3.9): парсить деривацію OpenScriptures → `root_id` у `strongs`, self-acceptance на 6 темах «Божого характеру». Запуск — на Mac; на ревʼю (не закомічено, не запущено).

---
### Backfill (ключові дати з INDEX, до запровадження LOG)

## [2026-07-15] decision | ADR-029 Огієнко (UBIO) — BLOCKED на ліцензії (UBS ©, не PD)
## [2026-07-14] decision | PDR-Lexicon-Language — лексичні дані EN-only для MVP
## [2026-07-10] decision | ADR-026 chapter paging — IMPLEMENTED (UIPageViewController)
## [2026-07-06] decision | iOS 18 compat Phase A — DONE; Phase B відкладено
## [2026-05-26] lint | docs-audit — перший аудит доків
