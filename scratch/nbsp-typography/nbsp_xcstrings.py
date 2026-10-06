#!/usr/bin/env python3
"""
NBSP-склейка коротких прийменників/сполучників/часток у Localizable.xcstrings.

Ідемпотентно вставляє U+00A0 замість звичайного пробілу після короткого
службового слова (uk/en), щоб воно ніколи не лишалось саме в кінці рядка.
Торкається лише простих stringUnit-записів (translated) для "en"/"uk" —
plural-variations і НЕ-"translated" (new/needs_review) стани пропускаються,
щоб не чіпати те, що ще не перевірено чи має іншу структуру.

Використання:
  python3 nbsp_xcstrings.py --dry-run   # тільки звіт, нічого не пишеться
  python3 nbsp_xcstrings.py --write     # записує назад у файл (робить .bak)
"""
import json
import re
import sys
import shutil
from pathlib import Path

NBSP = " "

UK_SHORT_WORDS = {
    "а", "б", "в", "і", "й", "з", "к", "о", "у", "є",
    "до", "від", "під", "по", "за", "на", "із", "зі", "як", "що",
    "чи", "та", "не", "ні", "це", "коли", "або", "бо", "хоч",
    "лиш", "теж", "аж", "уже", "ще", "тож", "щоб",
}
EN_SHORT_WORDS = {
    "a", "an", "the", "to", "of", "in", "on", "at", "by", "is",
    "or", "and", "if", "as", "it", "be", "but", "for", "nor",
    "so", "yet", "my", "no", "up", "we", "he", "she", "you",
}
WORD_LISTS = {"uk": UK_SHORT_WORDS, "en": EN_SHORT_WORDS}

_PATTERNS = {}
for _lang, _words in WORD_LISTS.items():
    _alt = "|".join(sorted((re.escape(w) for w in _words), key=len, reverse=True))
    _PATTERNS[_lang] = re.compile(
        rf"(?<![^\s ])({_alt})([ \t]+)(?=\S)", re.IGNORECASE | re.UNICODE
    )


def glue_short_words(text: str, lang: str) -> str:
    pattern = _PATTERNS.get(lang)
    if pattern is None:
        return text
    return pattern.sub(lambda m: m.group(1) + NBSP, text)


def visualize(s: str) -> str:
    return s.replace(NBSP, "‿")


def process(path: Path, write: bool):
    data = json.loads(path.read_text(encoding="utf-8"))
    strings = data.get("strings", {})

    total_keys = 0
    changed_entries = []  # (key, lang, before, after)
    skipped_non_stringunit = 0

    for key, entry in strings.items():
        locs = entry.get("localizations", {})
        for lang in ("en", "uk"):
            loc = locs.get(lang)
            if not loc:
                continue
            unit = loc.get("stringUnit")
            if unit is None:
                # variations (plural), substitutions, etc. — skip for now
                if "variations" in loc or "substitutions" in loc:
                    skipped_non_stringunit += 1
                continue
            total_keys += 1
            if unit.get("state") != "translated":
                continue
            before = unit.get("value", "")
            after = glue_short_words(before, lang)
            if after != before:
                changed_entries.append((key, lang, before, after))
                if write:
                    unit["value"] = after

    print(f"Проглянуто localizations (en+uk, stringUnit): {total_keys}")
    print(f"Пропущено (plural/substitutions, не чіпаємо):  {skipped_non_stringunit}")
    print(f"Змінено:                                       {len(changed_entries)}")
    print()
    for key, lang, before, after in changed_entries:
        print(f"[{lang}] {key}")
        print(f"  до:    {before}")
        print(f"  після: {visualize(after)}")
        print()

    if write and changed_entries:
        backup = path.with_suffix(path.suffix + ".bak")
        shutil.copy2(path, backup)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Записано. Бекап оригіналу: {backup}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    xcstrings_path = Path(__file__).resolve().parents[2] / "SourceBible" / "Localizable.xcstrings"
    process(xcstrings_path, write=(mode == "--write"))
