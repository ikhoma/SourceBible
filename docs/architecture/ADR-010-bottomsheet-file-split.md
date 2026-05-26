# ADR-010: Розбиття VerseBottomSheetView.swift на окремі файли

**Status:** Accepted — implemented 2026-05  
**Date:** 2026-05-11  
**Deciders:** Ivan Khoma

---

## Context

`VerseBottomSheetView.swift` — 801 рядок, містить ~14 структур:

```
VerseBottomSheetView        — головний контейнер (header, tabs, action bar)
├── VerseTabView            — вкладка "Вірш" з pill-навігацією
│   ├── VersePill (enum)
│   ├── CrossReferencesView — паралельні місця (placeholder)
│   ├── TranslationsView    — інші переклади (placeholder)
│   ├── OriginalWordsView   — слова оригіналу → tap переходить у Word mode
│   ├── CommentariesView    — список богословів
│   └── CommentaryDetailView — деталі коментаря (окрема NavigationLink screen)
└── WordTabView             — вкладка "Слово" (Strong's)
    ├── WordSubTab (enum)
    ├── WordMeaningView     — лексика, семантичний діапазон, визначення
    └── WordUsageView       — конкорданс (список входжень)

FlowLayout                  — кастомний Layout для chip-рядків
```

Питання: чи варто і як розбивати?

---

## Decision

**Розбити на 3 файли по логічних групах, не на 4 по компонентах.**  
Зробити це після реалізації ADR-009 (HighlightRepository + BibleRepository), не замість.

```
Views/BottomSheet/
├── VerseBottomSheetView.swift   — контейнер + action bar (~120 рядків)
├── VerseTabContent.swift        — все для вкладки "Вірш" (~320 рядків)
├── WordTabContent.swift         — все для вкладки "Слово" (~230 рядків)
└── (FlowLayout → Views/Components/FlowLayout.swift)
```

---

## Options Considered

### Option A: Не розбивати (status quo)

| Dimension | Assessment |
|-----------|------------|
| Effort | 0 |
| Navigation | Погана — CMD+F по 800 рядках |
| Merge conflicts | Немає ризику (solo) |
| Future growth | CrossRefs + Commentary виростуть ще на ~200–400 рядків кожен |

**Pros:** нульові витрати часу  
**Cons:** файл росте далі — при підключенні реальних даних до CrossRefs, Commentary і Translations кожен блок додасть ще 100–300 рядків. Через 2 місяці буде 1200+ рядків.

---

### Option B: 4 файли (по компонентах — як в запиті)

```
VerseBottomSheetView.swift
VerseTabView.swift          ← VerseTabView + VersePill
CrossReferencesAndMore.swift ← CrossRefs + Translations + OriginalWords + Commentaries
WordTabView.swift           ← WordTabView + WordSubTab + WordMeaning + WordUsage
```

або строго по 4:
```
VerseBottomSheetView.swift
VerseTab.swift
WordTab.swift
WordMeaning.swift  ← окремо від WordTab
```

| Dimension | Assessment |
|-----------|------------|
| Effort | Medium — більше переміщень, більше рішень де що |
| Navigation | Відмінна |
| Granularity | Висока — але WordMeaning без WordTab не відкривається |

**Cons:** `WordMeaningView` і `WordUsageView` ніколи не з'являються окремо від `WordTabView` — виносити їх в окремий файл розриває логічний зв'язок без практичної вигоди. `CrossReferencesView`, `TranslationsView`, `CommentariesView` — теж завжди всередині `VerseTabView`.

---

### Option C: 3 файли по вкладках (обраний)

```
Views/BottomSheet/
├── VerseBottomSheetView.swift   — контейнер (~120 рядків)
├── VerseTabContent.swift        — вкладка Вірш + всі її sub-views (~320 рядків)
└── WordTabContent.swift         — вкладка Слово + WordMeaning + WordUsage (~230 рядків)

Views/Components/
└── FlowLayout.swift             — перевикористовується поза BottomSheet (~45 рядків)
```

| Dimension | Assessment |
|-----------|------------|
| Effort | Low — 30 хвилин механічного переміщення |
| Navigation | Добра — 3 файли замість 1 |
| Cohesion | Висока — всі компоненти вкладки в одному файлі |
| Future growth | VerseTabContent може вирости, але тематично ціле |

---

## Trade-off Analysis

**4 файли vs 3**: `WordMeaningView` і `WordUsageView` — деталі реалізації `WordTabView`, не самостійні компоненти. Виносити їх окремо — штучне дроблення. Те саме для `CrossReferencesView` всередині `VerseTabView`. **Правило**: файл = unit of cohesion, не unit of "один struct".

**3 файли vs не розбивати**: `VerseTabContent.swift` через 2–3 місяці матиме реальний CrossRefs (з API), реальний TranslationsView (з бази), реальний Commentary (з бандлу). Кожен додасть ~150–300 рядків. Краще сформувати структуру поки код ще маленький.

**Коли робити**: після ADR-009. Причина — при підключенні `BibleRepository` у `VerseTabContent` зміняться всі placeholder-и. Розбивати зараз щоб через тиждень знову все рухати — марна трата часу.

---

## Proposed File Structure

```
Views/
├── Reader/
│   ├── ReaderView.swift
│   └── VerseRowView.swift          ← винести з ReaderView (зараз там же)
├── BottomSheet/
│   ├── VerseBottomSheetView.swift  — sheet container, header, mode tabs, action bar
│   ├── VerseTabContent.swift       — VerseTabView, VersePill, CrossRefs, Translations,
│   │                                  OriginalWords, Commentaries, CommentaryDetail
│   └── WordTabContent.swift        — WordTabView, WordSubTab, WordMeaning, WordUsage
├── Navigation/
│   └── BookChapterPickerView.swift
├── Entries/
│   └── EntriesView.swift
└── Components/
    └── FlowLayout.swift            — перевикористовується
```

---

## Consequences

**Стає простіше:**
- Навігація в Xcode — знаєш що CrossRefs лежить у `VerseTabContent`, не шукаєш по 800 рядках
- При додаванні реального API для CrossRefs — редагуєш один цільний файл
- `FlowLayout` перевикористовується якщо з'являться chips в інших місцях

**Стає складніше:**
- Нічого суттєвого — 3 файли замість 1 при solo-розробці не є overhead

**Повернемося коли:**
- `VerseTabContent` виросте більше 500 рядків → тоді вже ділити по компонентах (CrossRefs, Commentary у власні файли)

---

## Action Items

> ⚠️ Виконати ПІСЛЯ ADR-009 (HighlightRepository + BibleRepository)

1. [ ] Створити `Views/BottomSheet/` директорію
2. [ ] Перенести `WordTabView`, `WordSubTab`, `WordMeaningView`, `WordUsageView` → `WordTabContent.swift`
3. [ ] Перенести `VerseTabView`, `VersePill`, `CrossReferencesView`, `TranslationsView`, `OriginalWordsView`, `CommentariesView`, `CommentaryDetailView` → `VerseTabContent.swift`
4. [ ] `VerseBottomSheetView.swift` залишає тільки контейнер (~120 рядків)
5. [ ] Створити `Views/Components/FlowLayout.swift`
6. [ ] Перевірити що `#Preview` компілюються
