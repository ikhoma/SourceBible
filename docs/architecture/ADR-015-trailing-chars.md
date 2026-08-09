# ADR-015: Trailing Characters from Macula `after` Attribute

**Status:** Accepted (реалізовано 2026-06; статус виправлено 2026-08-07 lint-ом)  
**Date:** 2026-06-01  
**Реалізація:** колонка `word.after_char` у схемі, 12 місць у `scripts/build_db.py`  
**Deciders:** Ivan  
**Spec:** `docs/features/spec-trailing-chars.md`

---

## Context

Macula Hebrew and Greek datasets store post-word characters (maqaf `־`, sof pasuq `׃`, paseq `׀`, Greek commas/periods) in a separate XML `after` attribute on each `<w>` node — deliberately not part of the `surface` (pointed word form). Our DB import strips these out; the Original tab therefore shows `אַ֥שְֽׁרֵי` instead of `אַ֥שְֽׁרֵי־`.

This ADR reviews the solution proposed in `spec-trailing-chars.md`, identifies three defects in the draft, and records the corrected decision.

---

## Decision

Accept the four-layer DB→Model→Service→View approach with the corrections documented below. Store `after_char TEXT` as a sparse nullable column. Populate via a standalone migration script; wire into `loadWords()` and surface in `WordRow`.

---

## Options Considered

### Option A: DB column `after_char` (proposed)

| Dimension | Assessment |
|---|---|
| Complexity | Low — one-line addition to an existing XML loop |
| Data fidelity | High — source-of-truth is Macula XML, not reconstructed |
| Surface-field hygiene | ✅ `surface` stays clean; Strong's/xlit/search unaffected |
| Rebuild cost | Incremental migration script ~1 min |
| Runtime cost | Zero — no computation, one extra column in SELECT |

**Pros:** Authoritative, fast, fits existing enrichment architecture, trivially handles the view layer.  
**Cons:** Requires developer to run migration before shipping.

### Option B: Compute at runtime from raw verse string

**Pros:** No DB change.  
**Cons:** Macula TSV/XML already parsed at build time; reconstructing character order from verse-level raw text is fragile under cantillation marks and compound tokens. Not worth the complexity.

### Option C: Embed trailing char in `surface` at import time

**Pros:** Single field to render.  
**Cons:** Breaks Strong's occurrence-index matching in `_xml_match_verse`, breaks `xlit` lookup, and corrupts FTS search index. Hard no.

**Decision: Option A**, with the corrections below.

---

## Defects Found in Draft Spec

### Defect 1 — `.strip()` destroys the space-detection logic

Draft spec:
```python
raw_after = mac.get('after', '').strip()
after_char = raw_after if raw_after and raw_after != ' ' else None
```

Problem: `.strip()` converts `" "` → `""` before the `!= ' '` check runs, so the check becomes dead code. Result: every word-boundary space is already stripped away and the guard is vacuous — harmless in this case, but the logic is wrong and would silently break if Macula ever uses multi-character `after` values with leading spaces.

**Corrected:**
```python
raw_after = mac.get('after', '')          # do NOT strip — preserve exact value
after_char = raw_after if raw_after not in ('', ' ') else None
```

---

### Defect 2 — Backward-compat claim is incorrect

Draft spec states: *"if `after_char` is NULL (column absent in old DB), display gracefully degrades"*.

Backward-compat does NOT work automatically. If the `word` table lacks `after_char`, the `SELECT … w.after_char` statement returns `SQLITE_ERROR` (column not found), not NULLs — the entire `loadWords()` call fails. Column index 10 in `optString(stmt, 10)` is never reached.

This is **not a real problem in practice** — the DB is bundled in the app, so it is always migrated before Xcode builds. But the spec's claim is wrong and could mislead future readers into thinking no migration is needed.

**Corrected stance:** Remove the backward-compat claim. The migration script is required before shipping. `MigrationService.swift` does not need a runtime SQLite ALTER — it is a developer pre-ship step only.

---

### Defect 3 — View code has a dead `foregroundColor` modifier

Draft spec offers two alternatives and notes "simpler":
```swift
// Option 1 (proposed as primary — has a bug):
(Text(word.text) + Text(word.afterChar ?? "").foregroundColor(.secondary))
    .font(...)
    .foregroundStyle(.primary)

// Option 2 (proposed as "simpler"):
Text(word.text + (word.afterChar ?? ""))
    .font(.system(size: 26, weight: .light))
    .foregroundStyle(.primary)
```

Option 1's `.foregroundColor(.secondary)` is overridden immediately by `.foregroundStyle(.primary)` on the concatenated `Text`. The maqaf gets primary colour anyway, making the styling intent meaningless. More importantly, maqaf and sof pasuq are graphically part of the word cluster — secondary colour would look wrong.

**Decision:** Use Option 2 (plain string concat) as the sole implementation. Maqaf `־` is a single Unicode code point in the same Hebrew block; same font, weight, and colour is typographically correct.

Additionally, add a computed property to `BibleWord` to avoid scattering the concatenation:
```swift
/// Surface form as it appears in the text, including any trailing connector (maqaf ־, sof pasuq ׃, etc.).
var displayText: String { text + (afterChar ?? "") }
```

`WordRow` and any future consumer uses `word.displayText` not `word.text + (word.afterChar ?? "")`.

---

## Consequences

**Becomes easier:**
- Future addition of Greek `after` (Phase 2) is a straight copy of the Hebrew enrichment loop
- Any other Macula XML attribute can be added the same way (`n` attribute for cantillation note, etc.)

**Becomes harder / watch for:**
- Words without a Strong's match get no `after_char` (existing `_xml_match_verse` limitation). For most particles with maqaf this is fine because they have Strong's IDs. Low risk.
- The migration script must be re-run after any `build_db.py` full rebuild (the column and its data are part of the DB, not the schema DDL alone)

**Revisit when:**
- Greek trailing chars become a correctness concern (Phase 2)
- `_xml_match_verse` matching rate is measured — if >5% unmatched, improve the fallback strategy

---

## Corrected Files Checklist

| File | Change |
|---|---|
| `scripts/build_db.py` | Add `after_char TEXT` to `CREATE TABLE word`; fix `.strip()` → no-strip + `not in ('', ' ')` guard in `enrich_macula_from_xml` |
| `scripts/add_after_char.py` | New — developer migration, same fix applied |
| `SourceBible/Models/BibleModels.swift` | Add `afterChar: String?` + `displayText` computed var |
| `SourceBible/Services/DatabaseService.swift` | Add `w.after_char` at column index 10 in `loadWords()` |
| `SourceBible/Views/BottomSheet/WordTabContent.swift` | Use `word.displayText` in `WordRow` |

---

## Action Items

1. - [ ] Fix `.strip()` → no-strip + `not in ('', ' ')` in `enrich_macula_from_xml` (build_db.py)
2. - [ ] Write `scripts/add_after_char.py` (reuse `_xml_match_verse`, same fix)
3. - [ ] Add `afterChar: String?` and `displayText` to `BibleWord`
4. - [ ] Add `w.after_char` to `loadWords()` SELECT (column 10)
5. - [ ] Update `WordRow` to use `word.displayText`
6. - [ ] Run migration: `python3 scripts/add_after_char.py sourcebible.db` → copy → Clean Build
7. - [ ] Spot-check Ps 1:1 (`אַ֥שְֽׁרֵי־`), Ps 1:2 (maqaf mid-verse), Gen 1:1 (normal spaces) in simulator
