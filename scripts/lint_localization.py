#!/usr/bin/env python3
"""Лінтер узгодження числа з іменником у локалізації (bug-041).

Українська має ТРИ форми множини, англійська — дві. Будь-яке місце, де кількість
склеюється з іменником в обхід CLDR, дає «3 розділів» замість «3 розділи». Скрипт
ловить сам клас, а не три його випадки:

  1. `%lld`/`%d` + іменник у значенні uk БЕЗ plural-варіацій;
  2. plural-варіації, у яких для uk не всі чотири категорії (one/few/many/other);
  3. Swift, що форматує plural-ключ БЕЗ явної локалі інтерфейсу. Заміряно 2026-08-17:
     swizzle `LocalizedBundle` підміняє БАНДЛ, але не `Locale.current`, тож
     `String.localizedStringWithFormat` (як і `String(format:)` без `locale:`) бере
     СИСТЕМНУ мову — і на українських рядках спрацювали англійські правила: «3 розділу»
     замість «3 розділи». Правильно: `String(format:locale:)` з `\.locale` середовища,
     або `Text("key \(n)")`, який бере локаль із середовища сам;
  4. тернар «однина/множина» в Swift (`count == 1 ? … : …` навколо NSLocalizedString).

Запуск:  python3 scripts/lint_localization.py
Ненульовий код виходу = знайдено розходження. Друкує ключ і значення, а не лише «є проблема».
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT     = pathlib.Path(__file__).resolve().parent.parent
XCSTRING = ROOT / "SourceBible" / "Localizable.xcstrings"
SWIFT    = (ROOT / "SourceBible").rglob("*.swift")

UK_CATEGORIES = {"one", "few", "many", "other"}   # CLDR для uk

# Значення, де число НЕ узгоджується з іменником, тому plural не потрібен:
# скорочення («гл.»), чисті числа, відсотки, посилання на вірш.
EXEMPT_KEYS = {
    "nav.chapters_count",       # «%d гл.» — скорочення не відмінюється
    "picker.chapters_count",    # те саме
    "%lld", "%lld%%", "%lld. %@", "%@ %lld:%lld", "%@ · %@",
}

NUM_FMT = re.compile(r"%(?:\d+\$)?(?:lld|d)")
# Іменник поруч із числом: слово з 3+ літер (кирилиця або латиниця) у тому ж рядку.
NOUN    = re.compile(r"[A-Za-zА-Яа-яЄєІіЇїҐґ]{3,}")

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"  ✗ {msg}")


def main() -> int:
    data = json.loads(XCSTRING.read_text())
    strings = data["strings"]
    plural_keys: set[str] = set()

    print("▸ Ключі з числом і без plural-варіацій")
    for key, entry in sorted(strings.items()):
        locs = entry.get("localizations", {})
        uk   = locs.get("uk", {})
        if "variations" in uk:
            plural_keys.add(key)
            continue
        value = uk.get("stringUnit", {}).get("value", "")
        haystack = f"{key} {value}"
        if key in EXEMPT_KEYS or not value:
            continue
        if NUM_FMT.search(haystack) and NOUN.search(value):
            fail(f"{key}: uk «{value}» — число біля іменника без plural-варіацій "
                 f"(2/3/4 дадуть чужу форму)")
    if not failures:
        print("  ✓ таких ключів немає")

    print("\n▸ Повнота категорій uk у plural-ключах")
    for key in sorted(plural_keys):
        got = set(strings[key]["localizations"]["uk"]["variations"]["plural"])
        missing = UK_CATEGORIES - got
        if missing:
            fail(f"{key}: для uk немає категорій {sorted(missing)} — CLDR впаде на 'other'")
        else:
            print(f"  ✓ {key}: {sorted(got)}")

    print("\n▸ Swift: plural-ключ мусить форматуватись із ЯВНОЮ локаллю інтерфейсу")
    # Прямі літерали + константи MorphKey (їх значення теж plural-ключі).
    morph = {}
    mk = ROOT / "SourceBible" / "Services" / "Localization" / "MorphKey.swift"
    for name, val in re.findall(r'static let (\w+)\s*=\s*"([^"]+)"', mk.read_text()):
        morph[name] = val
    plural_tokens = {f'"{k}"' for k in plural_keys}
    plural_tokens |= {f"MorphKey.{n}" for n, v in morph.items() if v in plural_keys}

    ternary = re.compile(r"==\s*1\s*\?[^\n]*NSLocalizedString|NSLocalizedString[^\n]*==\s*1\s*\?")
    for path in SWIFT:
        text = path.read_text()
        rel  = path.relative_to(ROOT)
        for i, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//") or line.lstrip().startswith("///"):
                continue
            if "String(format:" in line or "localizedStringWithFormat" in line \
               or re.search(r"String\(\s*$", line):
                window = "\n".join(text.splitlines()[i - 1:i + 4])
                if any(tok in window for tok in plural_tokens):
                    if "localizedStringWithFormat" in window:
                        fail(f"{rel}:{i}: localizedStringWithFormat на plural-ключі — він пінить "
                             f"Locale.current (СИСТЕМНУ мову), тож форму обере чужа мова; "
                             f"треба String(format:locale:) з \\.locale середовища")
                    elif "locale:" not in window:
                        fail(f"{rel}:{i}: plural-ключ форматується без locale: — CLDR візьме "
                             f"системну мову, а не мову інтерфейсу (bug-041)")
            if ternary.search(line):
                fail(f"{rel}:{i}: тернар однина/множина навколо NSLocalizedString — "
                     f"це англійське правило, українська має три форми")
    print("  ✓ перевірено" if not failures else "")

    print()
    if failures:
        print(f"✗ Розходжень: {len(failures)}")
        return 1
    print("✓ Локалізація числа й іменника узгоджена")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
