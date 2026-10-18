"""Тести серіалізатора nbsp_xcstrings.dumps_xcode — формат Xcode байт у байт.

Якщо скрипт пише .xcstrings не так, як Xcode, Xcode після кожної збірки
переформатовує весь файл (тисячі рядків у git diff). Див. docs/LOG.md, 2026-10-19.
    python3 -m unittest discover scripts/tests
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import nbsp_xcstrings as M  # noqa: E402

XCSTRINGS = HERE.parents[1] / "SourceBible" / "Localizable.xcstrings"

# Фрагмент, записаний Xcode 26 (структура з реального файлу).
SAMPLE = (
    '{\n'
    '  "sourceLanguage" : "en",\n'
    '  "strings" : {\n'
    '    "" : {\n'
    '\n'
    '    },\n'
    '    "a.key" : {\n'
    '      "extractionState" : "stale",\n'
    '      "localizations" : {\n'
    '        "uk" : {\n'
    '          "stringUnit" : {\n'
    '            "state" : "translated",\n'
    '            "value" : "Ще не повʼязано\\nз номерами {} «лапки»"\n'
    '          }\n'
    '        }\n'
    '      }\n'
    '    },\n'
    '    "last" : {\n'
    '\n'
    '    }\n'
    '  },\n'
    '  "version" : "1.0"\n'
    '}'
)


class DumpsXcode(unittest.TestCase):
    def test_sample_roundtrip(self):
        self.assertEqual(M.dumps_xcode(json.loads(SAMPLE)), SAMPLE)

    def test_no_trailing_newline(self):
        self.assertFalse(M.dumps_xcode({"a": {}}).endswith("\n"))

    def test_braces_inside_string_untouched(self):
        out = M.dumps_xcode({"k": "x {}"})
        self.assertIn('"x {}"', out)

    def test_repo_file_is_in_xcode_format(self):
        """Файл у репо має бути у форматі Xcode — інакше цикл переписування повернеться."""
        raw = XCSTRINGS.read_text(encoding="utf-8")
        self.assertEqual(M.dumps_xcode(json.loads(raw)), raw)


if __name__ == "__main__":
    unittest.main()
