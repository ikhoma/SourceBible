// StrongsMergeMap+Canonical.swift
// SourceBible
//
// Ключ групи Strong's для таблиці `word_rendering` (ADR-041). Живе ОКРЕМО від
// згенерованого StrongsMergeMap.swift, бо той перезаписує build_strongs_merge_map.py.

extension StrongsMergeMap {
    /// Канонічний id групи: перший член відсортованої групи (база: H835 для H835/H835a),
    /// або сам id, якщо він ні з чим не зливається (H2617 і H2617a — різні ключі).
    ///
    /// ⛔ Мусить збігатися з `canonical_map()` у scripts/build_word_rendering.py
    /// (`members[0]` тієї самої відсортованої групи) — інакше запит не знайде рядків.
    static func canonical(_ id: String) -> String {
        groups[id]?.first ?? id
    }
}
