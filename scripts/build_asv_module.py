#!/usr/bin/env python3
"""Власний MyBible-модуль ASV з OpenBible ASV Interlinear (ADR-042, фаза 1).

ЩО РОБИТЬ
---------
Читає ЛИШЕ закріплений вхід OpenBible (`data/obi-asv/usx-english-aligned` +
`usx-original-aligned`, коміт PINNED_COMMIT) і дві курованих таблиці, і пише три файли
стандартного для конвеєра вигляду:

    data/ASV.SQLite3                 info / books / verses  (MyBible)
    data/ASV.commentaries.SQLite3    commentaries — виноски перекладачів, якорі <f>[n]</f>
    data/ASV.alignment.tsv           повне вирівнювання (задаток для verse_markup, фаза 2)

Далі `build_db.py` імпортує модуль як будь-який інший (TRANSLATIONS → ASV.SQLite3,
виноски — «Strategy 2», сусідній *.commentaries.SQLite3). Конвертер НЕ читає
sourcebible.db і Macula: усе, що з них потрібно, уже лежить у курованих таблицях.

ПРАВИЛА (ADR-042 + рішення Івана 2026-10-07)
-------------------------------------------
* Тег `<S>N</S>` лише на ГОЛОВНИЙ токен слова оригіналу — та сама одиниця, що й у
  вкладці «Оригінал» (`headToken` у BibleModels.swift: останній не-енклітичний токен).
  Слово івриту = токени, не розділені пробілом/макафом/пасеком. В оригінальному USX
  бракує ~822 пробілів (Бут 1:12 «פְּרִיאֲשֶׁר»), тому межа слова ставиться ще й тоді, коли
  попередній токен не проклітика (C, R, Td, Ti, Tr), а наступний — не енклітика.
  Енклітика = займенниковий суфікс (x-morph S…) або арамейський емфатичний артикль -א
  (Td після іменника без розділювача; Дан, Езд). Заміряно: 99,98% збігу зі слотами Macula.
* Грека: тег на кожен вирівняний токен, КРІМ артикля G3588 (рішення: як іврит-префікс і KJV).
  Номер форми → номер леми Macula за `data/strongs/canonical_greek.tsv` (57 рядків):
  без цього «this is my body» тегується G5124/G2076/G3450, яких немає ні в лексиконі,
  ні в конкордансі.
* Іврит-токени без Strong's у джерелі (складені імена: Бет-Ель, Вифлеєм) — номер із
  `data/asv/name_strongs.tsv` за id токена.
* Номер базовий, без суфікса (H2617a → 2617), як KJV. `added`, варіантні (`.vNNN`) і
  токени без номера — без тега.
* Розміщення: тег після останнього англійського слова одиниці; розірвана одиниця — після
  токена з x-head. Кілька головних токенів — кілька тегів підряд («a year old<S>1121</S><S>8141</S>»).
* Виноска в USX стоїть ПЕРЕД словом, яке пояснює (95% випадків). Якір `<f>[n]</f>` ставимо
  ПІСЛЯ одиниці, до якої належить наступне слово, разом із її тегами — як у RST
  («provide<S>7200</S><f>[1]</f>»). Виноска в надписі псалма — одразу після `</n>`.
* Надпис псалма (para d) → `<n>…</n>` на початку вірша 1, без тегів (bug-058 / ADR-028:
  build_versification перевіряє `<n>` структурно).
* «’» → «'» у віршах і виносках. NBSP зберігаються (є лише у виносках): пробіли
  стискаються класом `[ \\t\\r\\n]`, НЕ `\\s` — Python `\\s` ловить NBSP.
* Назви книг — нинішні 66 назв ASV (у USX назв немає).

ЗАПУСК
------
    python3 scripts/build_asv_module.py            # повна збірка + еталони + гейти
Ненульовий код виходу на будь-якому провалі; вихідні файли тоді НЕ пишуться.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC_DIR = DATA / "obi-asv"
MANIFEST = DATA / "asv" / "obi-asv.SHA256SUMS"
CANON_TSV = DATA / "strongs" / "canonical_greek.tsv"
NAMES_TSV = DATA / "asv" / "name_strongs.tsv"
OUT_BIBLE = DATA / "ASV.SQLite3"
OUT_NOTES = DATA / "ASV.commentaries.SQLite3"
OUT_ALIGN = DATA / "ASV.alignment.tsv"

PINNED_COMMIT = "b6580247af63991b406f02f612f73deca85235ff"   # openbibleinfo/American-Standard-Version-Bible
MANIFEST_SHA256 = "9d8540a800769878d8de56232fc96da7ef85ee6531c796fe0da5183d5793b95f"

XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"

# (USX code, MyBible book_number, long_name, short_name) — назви = нинішні назви ASV у book_name.
# Номери MyBible: OT < 470, NT ≥ 470, зростають у протестантському порядку → _build_book_mapping.
BOOKS = [
    ("GEN", 10, "Genesis", "Gen"), ("EXO", 20, "Exodus", "Exo"), ("LEV", 30, "Leviticus", "Lev"),
    ("NUM", 40, "Numbers", "Num"), ("DEU", 50, "Deuteronomy", "Deu"), ("JOS", 60, "Joshua", "Josh"),
    ("JDG", 70, "Judges", "Judg"), ("RUT", 80, "Ruth", "Ruth"), ("1SA", 90, "1 Samuel", "1Sam"),
    ("2SA", 100, "2 Samuel", "2Sam"), ("1KI", 110, "1 Kings", "1Kin"), ("2KI", 120, "2 Kings", "2Kin"),
    ("1CH", 130, "1 Chronicles", "1Chr"), ("2CH", 140, "2 Chronicles", "2Chr"), ("EZR", 150, "Ezra", "Ezr"),
    ("NEH", 160, "Nehemiah", "Neh"), ("EST", 190, "Esther", "Esth"), ("JOB", 220, "Job", "Job"),
    ("PSA", 230, "Psalms", "Ps"), ("PRO", 240, "Proverbs", "Prov"), ("ECC", 250, "Ecclesiastes", "Eccl"),
    ("SNG", 260, "Song of Solomon", "Song"), ("ISA", 290, "Isaiah", "Isa"), ("JER", 300, "Jeremiah", "Jer"),
    ("LAM", 310, "Lamentations", "Lam"), ("EZK", 330, "Ezekiel", "Ezek"), ("DAN", 340, "Daniel", "Dan"),
    ("HOS", 350, "Hosea", "Hos"), ("JOL", 360, "Joel", "Joel"), ("AMO", 370, "Amos", "Am"),
    ("OBA", 380, "Obadiah", "Oba"), ("JON", 390, "Jonah", "Jona"), ("MIC", 400, "Micah", "Mic"),
    ("NAM", 410, "Nahum", "Nah"), ("HAB", 420, "Habakkuk", "Hab"), ("ZEP", 430, "Zephaniah", "Zeph"),
    ("HAG", 440, "Haggai", "Hag"), ("ZEC", 450, "Zechariah", "Zech"), ("MAL", 460, "Malachi", "Mal"),
    ("MAT", 470, "Matthew", "Mat"), ("MRK", 480, "Mark", "Mar"), ("LUK", 490, "Luke", "Luk"),
    ("JHN", 500, "John", "John"), ("ACT", 510, "Acts", "Acts"), ("ROM", 520, "Romans", "Rom"),
    ("1CO", 530, "1 Corinthians", "1Cor"), ("2CO", 540, "2 Corinthians", "2Cor"), ("GAL", 550, "Galatians", "Gal"),
    ("EPH", 560, "Ephesians", "Eph"), ("PHP", 570, "Philippians", "Phil"), ("COL", 580, "Colossians", "Col"),
    ("1TH", 590, "1 Thessalonians", "1Ths"), ("2TH", 600, "2 Thessalonians", "2Ths"), ("1TI", 610, "1 Timothy", "1Tim"),
    ("2TI", 620, "2 Timothy", "2Tim"), ("TIT", 630, "Titus", "Tit"), ("PHM", 640, "Philemon", "Phlm"),
    ("HEB", 650, "Hebrews", "Heb"), ("JAS", 660, "James", "Jam"), ("1PE", 670, "1 Peter", "1Pet"),
    ("2PE", 680, "2 Peter", "2Pet"), ("1JN", 690, "1 John", "1Jn"), ("2JN", 700, "2 John", "2Jn"),
    ("3JN", 710, "3 John", "3Jn"), ("JUD", 720, "Jude", "Jud"), ("REV", 730, "Revelation", "Rev"),
]
BOOK_NUM = {b[0]: b[1] for b in BOOKS}

SKIP_PARA = {"s1", "ms1", "b"}               # заголовки розділів, «BOOK I», порожні — не текст вірша
TITLE_PARA = "d"                              # надпис псалма
PROCLITIC = {"C", "R", "Td", "Ti", "Tr"}
VARIANT_RE = re.compile(r"\.v\d+")
WS_RE = re.compile(r"[ \t\r\n]+")            # ⛔ НЕ \s: Python \s ловить NBSP (U+00A0)
GREEK_ARTICLE = "G3588"
# Уламок розірваної одиниці, що складається лише з цих слів, тег НЕ отримує: «of … the chronicles»,
# «I will … open», «a … nation» — тап по «of» відкривав би іменник. Тег дістають лише уламки зі
# змістовим словом («put … to death», «make … great»).
FUNCTION_WORDS = {
    "a", "an", "the", "of", "by", "to", "in", "on", "at", "for", "with", "from", "unto", "upon", "into",
    "and", "or", "but", "that", "which", "who", "whom", "whose", "as", "so", "not", "no",
    "is", "are", "was", "were", "be", "been", "am", "art", "shall", "will", "shalt", "wilt", "hath", "have",
    "has", "had", "do", "did", "doth", "it", "he", "she", "they", "him", "her", "them", "his", "its", "their",
    "i", "me", "my", "mine", "thou", "thee", "thy", "thine", "ye", "you", "your", "we", "us", "our",
}

ATTRIBUTION = (
    "American Standard Version (1901): public domain; digital edition, footnotes and "
    "interlinear alignment by OpenBible.info (github.com/openbibleinfo/American-Standard-Version-Bible, "
    f"commit {PINNED_COMMIT[:7]}). This work contains public-domain American Standard Version and "
    "Westminster Leningrad Codex biblical text. Its original-language alignments are derived from the "
    "MACULA Greek and MACULA Hebrew Linguistic Datasets (© 2022–2024 Biblica, Inc.), the Open Scriptures "
    "Hebrew Bible project, the SBL Greek New Testament (© 2010 Society of Biblical Literature and Logos "
    "Bible Software), and J. J. McCollum's SBLGNT-TEI transcription and apparatus encoding. Hebrew syntax "
    "fields include data from the Westminster Hebrew Syntax without Morphology (© 1991–2018 J. Alan Groves "
    "Center for Advanced Biblical Research). Gloss data includes the public-domain Berean Interlinear Bible "
    "and Cherith glosses by Andi Wu (© 2022–2023 Cherith Analytics). Licensed source data is used under the "
    "Creative Commons Attribution 4.0 International License (creativecommons.org/licenses/by/4.0/). "
    "Modified by SourceBible: Strong's tags reduced to the head token of each original word, Greek form "
    "numbers normalized to lemma numbers, typography normalized."
)


# ── Таблиці ──────────────────────────────────────────────────────────────────
def _read_tsv(path: Path) -> list[list[str]]:
    rows = []
    with open(path, encoding="utf-8") as f:
        header_seen = False
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            if not header_seen:
                header_seen = True
                continue
            rows.append(line.rstrip("\n").split("\t"))
    return rows


def load_canonical(path: Path = CANON_TSV) -> dict[str, str]:
    return {r[0]: r[1] for r in _read_tsv(path)}


def load_names(path: Path = NAMES_TSV) -> dict[str, str]:
    return {r[0]: r[2] for r in _read_tsv(path)}


def verify_manifest(src_dir: Path = SRC_DIR, manifest: Path = MANIFEST) -> list[str]:
    """Звіряє всі 134 файли входу з маніфестом закріпленого коміту. → список провалів."""
    fails = []
    raw = manifest.read_bytes()
    if hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256:
        fails.append(f"маніфест {manifest.name} змінено: sha256 ≠ {MANIFEST_SHA256[:12]}…")
    for line in raw.decode().splitlines():
        digest, rel = line.split(None, 1)
        p = src_dir / rel.strip()
        if not p.exists():
            fails.append(f"нема файлу входу: {p}")
            continue
        if hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            fails.append(f"файл входу відрізняється від коміту {PINNED_COMMIT[:7]}: {rel}")
    return fails


# ── Оригінал: головні токени ────────────────────────────────────────────────
def _cls(morph: str | None) -> str:
    m = morph or "-"
    if m.startswith("S"):
        return "S"
    if m.startswith("T"):
        return m[:2]
    return m[0]


def _is_enclitic(tok: dict, prev: dict | None) -> bool:
    m = tok.get("x-morph") or ""
    if m.startswith("S"):
        return True
    # Арамейський емфатичний артикль -א: Td ПІСЛЯ іменника без розділювача (Дан, Езд).
    return (m == "Td" and tok.get(XML_LANG) == "arc" and prev is not None
            and prev["sep_after"] == "" and _cls(prev.get("x-morph")) not in PROCLITIC)


def hebrew_words(toks: list[dict]) -> list[list[dict]]:
    """Ділить токени вірша на слова: розділювач (пробіл/макаф/пасек/соф пасук) АБО
    «не-проклітика + не-енклітика» (у джерелі бракує пробілів)."""
    words: list[list[dict]] = []
    cur: list[dict] = []
    for t in toks:
        if cur:
            a = cur[-1]
            if a["sep_after"] != "" or (_cls(a.get("x-morph")) not in PROCLITIC and not _is_enclitic(t, a)):
                words.append(cur)
                cur = []
        cur.append(t)
    if cur:
        words.append(cur)
    return words


def head_of(word: list[dict]) -> dict:
    cand = [t for i, t in enumerate(word) if not _is_enclitic(t, word[i - 1] if i else None)]
    return (cand or word)[-1]


def parse_original(path: Path) -> dict[str, dict]:
    """x-id → токен оригіналу (атрибути + 'sep_after' + 'is_head')."""
    root = ET.parse(path).getroot()
    by_ref: dict[str, list[dict]] = collections.defaultdict(list)
    cur = {"ref": None}

    def add_tail(ch):
        lst = by_ref.get(cur["ref"])
        if ch.tail and lst:
            lst[-1]["sep_after"] += ch.tail

    def rec(el):
        if el.tag == "verse":
            cur["ref"] = el.get("x-ref") if el.get("sid") else None
            return
        if el.tag == "note":
            return
        if el.tag == "para" and el.get("style") == TITLE_PARA and el.get("x-ref"):
            saved, cur["ref"] = cur["ref"], el.get("x-ref")
            for ch in el:
                rec(ch)
                add_tail(ch)
            cur["ref"] = saved
            return
        if el.tag == "char" and el.get("style") == "w":
            d = dict(el.attrib)
            d["surface"] = el.text or ""
            d["sep_after"] = ""
            by_ref[cur["ref"]].append(d)
            return
        for ch in el:
            rec(ch)
            add_tail(ch)

    rec(root)
    out: dict[str, dict] = {}
    for ref, toks in by_ref.items():
        heb = [t for t in toks if t["x-id"].startswith("WLC.")]
        for w in hebrew_words(heb):
            h = head_of(w)
            for t in w:
                t["is_head"] = t is h
        for t in toks:
            t.setdefault("is_head", True)          # грека: кожен токен — окреме слово
            out[t["x-id"]] = t
    return out


# ── Англійський текст ───────────────────────────────────────────────────────
@dataclass
class Item:
    kind: str                 # 'w' | 'text' | 'note'
    title: bool
    text: str = ""
    attrs: dict = field(default_factory=dict)
    note: ET.Element | None = None


def parse_english(path: Path) -> tuple[str, dict[str, list[Item]], list[str]]:
    """→ (book, {sid: [Item]}, problems). Слова в SKIP_PARA = проблема (текст не губимо мовчки)."""
    root = ET.parse(path).getroot()
    book = root.find("book").get("code")
    verses: dict[str, list[Item]] = collections.OrderedDict()
    problems: list[str] = []
    st = {"sid": None, "para": None}

    def emit(kind, **kw):
        if st["sid"] is None:
            if kind == "w":
                problems.append(f"{book}: слово поза віршем: {kw.get('text')!r}")
            return
        if st["para"] in SKIP_PARA:
            if kind == "w":
                problems.append(f"{st['sid']}: слово в абзаці {st['para']} пропущено б: {kw.get('text')!r}")
            return
        verses.setdefault(st["sid"], []).append(Item(kind, st["para"] == TITLE_PARA, **kw))

    def text(s):
        if s:
            emit("text", text=s)

    def rec(el):
        tag, style = el.tag, el.get("style")
        if tag == "verse":
            if el.get("sid"):
                st["sid"] = el.get("sid")
                verses.setdefault(st["sid"], [])
            elif el.get("eid"):
                st["sid"] = None
            return
        if tag == "para" and style == "qa":
            # Літера акровірша Пс 119 («א Aleph.» / «ב Beth.») → «ALEPH. » на початку вірша,
            # як у ASV+ і KJV. Слова тут — назва літери, не текст вірша: без тегів.
            # Віршовий мілстоун може стояти ВСЕРЕДИНІ абзацу qa — обробити його першим.
            parts = [el.text or ""]
            for ch in el:
                if ch.tag == "verse":
                    rec(ch)
                else:
                    parts.append("".join(ch.itertext()))
                parts.append(ch.tail or "")
            label = re.sub(r"[\u0590-\u05FF]", "", "".join(parts)).strip(" .\t\r\n")
            st["para"] = None
            text(label.upper() + ". ")
            return
        if tag == "para":
            st["para"] = style
            text(el.text)
            for ch in el:
                rec(ch)
                text(ch.tail)
            st["para"] = None
            text(" ")                       # межа абзацу = пробіл між віршами/рядками поезії
            return
        if tag == "note":
            emit("note", note=el)
            return
        if tag == "char" and style == "w":
            emit("w", text="".join(el.itertext()), attrs=dict(el.attrib))
            return
        if tag in ("chapter", "book"):
            return
        text(el.text)
        for ch in el:
            rec(ch)
            text(ch.tail)

    rec(root)
    return book, verses, problems


def note_text(note: ET.Element) -> str:
    """Текст виноски: курсив → <i>…</i>, решта розмітки — текстом. NBSP не чіпаємо."""
    def rec(el) -> str:
        out = el.text or ""
        for ch in el:
            inner = rec(ch)
            if ch.tag == "char" and ch.get("style") == "it":
                inner = f"<i>{inner}</i>"
            out += inner + (ch.tail or "")
        return out
    s = WS_RE.sub(" ", rec(note)).strip(" ")
    return s.replace("’", "'")


@dataclass
class Stats:
    c: collections.Counter = field(default_factory=collections.Counter)


def strong_number(raw: str | None, canon: dict[str, str]) -> str | None:
    if not raw:
        return None
    raw = canon.get(raw, raw)
    m = re.match(r"[HG](\d+)", raw)
    return str(int(m.group(1))) if m else None


def render_verse(sid: str, items: list[Item], org: dict[str, dict], canon: dict[str, str],
                 names: dict[str, str], stats: collections.Counter,
                 align_rows: list | None = None) -> tuple[str, list[str]]:
    """→ (verse text з <S>/<n>/<f>, [тексти виносок у порядку маркерів])."""
    book, cv = sid.split(" ")
    ch, vs = cv.split(":")
    # одиниці вирівнювання
    units: dict[tuple, dict] = collections.OrderedDict()
    windex: dict[int, tuple] = {}
    for i, it in enumerate(items):
        if it.kind != "w":
            continue
        key = (it.title, it.attrs.get("x-align"))
        u = units.setdefault(key, {"idx": [], "tnum": [], "src": [], "status": it.attrs.get("x-status"),
                                   "xhead": None})
        u["idx"].append(i)
        u["tnum"].append(int(re.sub(r"\D", "", it.attrs.get("x-id", "0")) or 0))
        if it.attrs.get("x-src"):
            u["src"] = it.attrs["x-src"].split()
        if it.attrs.get("x-head") == "true":
            u["xhead"] = i
        windex[i] = key
    tags_at: dict[int, str] = {}
    end_of: dict[tuple, int] = {}
    unit_nums: dict[tuple, tuple[list[str], bool]] = {}
    for key, u in units.items():
        contig = u["tnum"] == list(range(u["tnum"][0], u["tnum"][0] + len(u["tnum"])))
        pos = u["idx"][-1] if contig or u["xhead"] is None else u["xhead"]
        end_of[key] = pos
        if key[0]:
            stats["title_units"] += 1
            continue                         # надпис — без тегів (<n>)
        if u["status"] == "added" or not u["src"]:
            stats["units_no_source"] += 1
            continue
        nums = []
        for s in u["src"]:
            if VARIANT_RE.search(s):
                stats["src_variant_skipped"] += 1
                continue
            t = org.get(s)
            if t is None:
                stats["src_missing_in_original"] += 1
                continue
            if not t["is_head"]:
                continue
            raw = t.get("strong")
            if not raw and s in names:
                raw = names[s]
                stats["tags_from_name_table"] += 1
            if raw == GREEK_ARTICLE:
                stats["greek_article_skipped"] += 1
                continue
            if raw and raw in canon:
                stats["tags_canonicalized"] += 1
            n = strong_number(raw, canon)
            if n is None:
                stats["head_without_strong"] += 1
                continue
            nums.append(n)
        if nums:
            tags_at[pos] = tags_at.get(pos, "") + "".join(f"<S>{n}</S>" for n in nums)
            stats["tags"] += len(nums)
            unit_nums[key] = (nums, contig)
    # Розірвана одиниця («put … him … to death», θανατόω): тег і на інших фрагментах, як у KJV
    # («put<S>2289</S> him<S>846</S> to death<S>2289</S>») — читач тапає обидва шматки, а
    # «Translated as» бачить «put to death», не «death». ЛИШЕ якщо номер у вірші єдиний:
    # інакше зайвий тег спарувався б (consume-in-order, ADR-016) з ЧУЖИМ словом.
    verse_count = collections.Counter(n for nums, _ in unit_nums.values() for n in nums)
    for key, (nums, contig) in unit_nums.items():
        if contig or any(verse_count[n] > 1 for n in nums):
            continue
        u = units[key]
        frags, cur_f = [], [u["idx"][0]]
        for a, b, ta, tb in zip(u["idx"], u["idx"][1:], u["tnum"], u["tnum"][1:]):
            if tb == ta + 1:
                cur_f.append(b)
            else:
                frags.append(cur_f)
                cur_f = [b]
        frags.append(cur_f)
        for fr in frags:
            if end_of[key] in fr:
                continue
            if all(items[i].text.lower() in FUNCTION_WORDS for i in fr):
                stats["split_fragment_function_skipped"] += 1
                continue
            tags_at[fr[-1]] = tags_at.get(fr[-1], "") + "".join(f"<S>{n}</S>" for n in nums)
            stats["split_fragment_tags"] += len(nums)

    # Складене ім'я через дефіс з однаковими тегами («Beth<S>1008</S>-el<S>1008</S>») → один
    # сегмент «Beth-el<S>1008</S><S>1008</S>»: два слова Macula (בֵּית־אֵל) лишаються спарені,
    # а читач і «Translated as» бачать ім'я цілим, як у KJV.
    tagged = sorted(tags_at)
    for i in tagged:
        if i not in tags_at:
            continue
        j = next((k for k in range(i + 1, len(items)) if items[k].kind != "text"), None)
        if j is None or items[j].kind != "w" or items[j].title != items[i].title:
            continue
        between = "".join(items[k].text for k in range(i + 1, j))
        if between == "-" and tags_at.get(j) == tags_at[i]:
            tags_at[j] = tags_at.pop(i) + tags_at[j]
            stats["hyphen_names_joined"] += 1

    # виноски: якір після одиниці наступного слова
    anchors_after: dict[int, list[str]] = collections.defaultdict(list)
    anchors_here: dict[int, list[str]] = collections.defaultdict(list)
    title_anchors: list[str] = []
    note_bodies: list[str] = []
    note_ids: list[str] = []
    for i, it in enumerate(items):
        if it.kind != "note":
            continue
        nid = f"N{len(note_bodies)}"
        note_bodies.append(note_text(it.note))
        note_ids.append(nid)
        if it.title:
            title_anchors.append(nid)
            stats["notes_in_title_moved"] += 1
            continue
        nxt = next((j for j in range(i + 1, len(items)) if items[j].kind == "w" and not items[j].title), None)
        if nxt is None:
            anchors_here[i].append(nid)
            stats["notes_at_verse_end"] += 1
            continue
        tgt = end_of[windex[nxt]]
        anchors_after[max(tgt, nxt)].append(nid)

    title_parts: list[str] = []
    main_parts: list[str] = []
    for i, it in enumerate(items):
        parts = title_parts if it.title else main_parts
        if it.kind == "w":
            parts.append(it.text + tags_at.get(i, "") + "".join(f"\x00{n}\x00" for n in anchors_after.get(i, [])))
        elif it.kind == "text":
            parts.append(it.text)
        elif it.kind == "note" and i in anchors_here:
            while parts and parts[-1].strip(" \t\r\n") == "":
                parts.pop()
            if parts:
                parts[-1] = parts[-1].rstrip(" \t\r\n")
            parts.append("".join(f"\x00{n}\x00" for n in anchors_here[i]))

    def fin(p):
        return WS_RE.sub(" ", "".join(p)).strip(" ").replace("’", "'")

    text = fin(main_parts)
    if title_parts:
        text = "<n>" + fin(title_parts) + "</n>" + "".join(f"\x00{n}\x00" for n in title_anchors) + " " + text
    # маркери нумеруємо за порядком у тексті
    order = re.findall(r"\x00(N\d+)\x00", text)
    num = {nid: k + 1 for k, nid in enumerate(order)}
    text = re.sub(r"\x00(N\d+)\x00", lambda m: f"<f>[{num[m.group(1)]}]</f>", text)
    notes = [""] * len(order)
    for nid, body in zip(note_ids, note_bodies):
        notes[num[nid] - 1] = body

    if align_rows is not None:
        for key, u in units.items():
            heads = [s for s in u["src"] if s in org and org[s]["is_head"] and not VARIANT_RE.search(s)]
            strongs = " ".join((org[s].get("strong") or names.get(s, "")) for s in u["src"] if s in org)
            for k, i in enumerate(u["idx"]):
                it = items[i]
                align_rows.append((book, ch, vs, "title" if key[0] else "main", it.attrs.get("x-id", ""),
                                   it.text.replace("’", "'"), key[1] or "", u["status"] or "",
                                   " ".join(u["src"]), strongs, " ".join(heads),
                                   "1" if i == (u["xhead"] if u["xhead"] is not None else u["idx"][-1]) else "0"))
    return text, notes


def build(src_dir: Path, books: list[str] | None = None) -> tuple[dict, dict, list, collections.Counter, list[str]]:
    """→ (verses {(book,ch,v): text}, notes {(book,ch,v): [text]}, align_rows, stats, problems)."""
    canon, names = load_canonical(), load_names()
    stats: collections.Counter = collections.Counter()
    problems: list[str] = []
    verses: dict = {}
    notes: dict = {}
    align: list = []
    eng_files = sorted((src_dir / "usx-english-aligned").glob("*.usx"))
    for ef in eng_files:
        code = ef.stem.split("-", 1)[1]
        if books and code not in books:
            continue
        org = parse_original(src_dir / "usx-original-aligned" / ef.name)
        book, vmap, probs = parse_english(ef)
        problems += probs
        for sid, items in vmap.items():
            text, ns = render_verse(sid, items, org, canon, names, stats, align)
            b, cv = sid.split(" ")
            c, v = map(int, cv.split(":"))
            if not text:
                problems.append(f"{sid}: порожній вірш")
                continue
            verses[(b, c, v)] = text
            if ns:
                notes[(b, c, v)] = ns
    return verses, notes, align, stats, problems


# ── Еталони і гейти ─────────────────────────────────────────────────────────
# (ref, підрядок, що МАЄ бути у verses.text)
GOLDEN_CONTAINS = [
    (("GEN", 22, 8), "my son<S>1121</S>"),                       # ASV+: «will<S>1121</S>» — перестановка
    (("GEN", 22, 8), "they went<S>1980</S>"),                    # ASV+: «my son<S>3212</S>»
    (("GEN", 22, 8), "provide<S>7200</S><f>[1]</f>"),            # якір після одиниці «will provide»
    (("EXO", 12, 5), "a year old<S>1121</S><S>8141</S>"),        # noncompositional — два теги
    (("JER", 27, 3), "children<S>1121</S> of Ammon<S>5983</S>"),
    (("ROM", 4, 7), "Blessed are they<S>3107</S>"),
    (("1CH", 1, 46), "the name<S>8034</S>"),
    (("GEN", 12, 2), "make<S>1431</S> thy name<S>8034</S> great<S>1431</S>"),  # ASV+: «make they name»; розірвана одиниця
    (("PSA", 23, 4), "though<S>3588</S> I walk<S>1980</S>"),     # ASV+: «thou I walk»
    (("MAT", 18, 15), "if<S>1437</S> thy<S>4771</S> brother<S>80</S>"),   # ASV+ осучаснено «your»
    (("MRK", 14, 55), "put<S>2289</S> him<S>846</S> to death<S>2289</S>"),  # розірвана одиниця, номер єдиний
    (("MAT", 26, 26), "this<S>3778</S> is<S>1510</S> my<S>1473</S> body<S>4983</S>"),  # canonical_greek
    (("GEN", 12, 8), "Beth-el<S>1008</S><S>1008</S>"),           # name_strongs + дефіс
    (("PSA", 3, 1), "<n>A Psalm of David, when he fled from Absalom his son.</n> Jehovah<S>3068</S>"),
    (("SNG", 1, 1), "The Song<S>7892</S> of songs<S>7892</S>"),  # вірш, якого не було в ASV+
    (("JHN", 1, 18), "<f>[1]</f>"),
]
# (ref, точний текст) — контрольні: службові слова/префікси БЕЗ тега
GOLDEN_EXACT = [
    (("GEN", 1, 1), "In the beginning<S>7225</S> God<S>430</S> created<S>1254</S> the heavens<S>8064</S> and the earth<S>776</S>."),
]
GOLDEN_STARTS = [
    (("JOB", 21, 5), "Mark<S>"),                 # ASV+: «480»
    (("1CH", 5, 5), "Micah<S>"),                 # ASV+: «400»
    (("JER", 39, 1), "(in the ninth"),           # межа віршів як у друці 1901
    (("PSA", 119, 1), "ALEPH. Blessed"),         # літера акровірша, як у ASV+ і KJV
    (("PSA", 119, 9), "BETH. Wherewith"),
]
GOLDEN_ENDS = [
    (("1CH", 27, 30), "Jaziz the Hagrite."),
]
GOLDEN_NOTES = [
    (("GEN", 22, 8), "Hebrew <i>see for himself</i>."),
    (("JHN", 1, 18), "Many very ancient authorities read <i>God only begotten</i>."),
    (("PSA", 23, 4), "Or, <i>deep darkness</i> (and so elsewhere)"),
]
NT_BOOKS = {b[0] for b in BOOKS if b[1] >= 470}

EXPECT_VERSES = 31086
EXPECT_NOTES = 10116
EXPECT_TITLES = 116
MIN_TAGS = 400_000
EXPECT_NOTE_NBSP = 384


def check(verses: dict, notes: dict, stats: collections.Counter, problems: list[str], full: bool = True) -> list[str]:
    fails = list(problems)
    if full:
        def ref(k): return f"{k[0]} {k[1]}:{k[2]}"
        for k, sub in GOLDEN_CONTAINS:
            got = verses.get(k, "<нема вірша>")
            if sub not in got:
                fails.append(f"еталон {ref(k)}: очікував «{sub}»\n      отримав «{got}»")
        for k, exp in GOLDEN_EXACT:
            if verses.get(k) != exp:
                fails.append(f"еталон {ref(k)}:\n      очікував «{exp}»\n      отримав «{verses.get(k)}»")
        for k, exp in GOLDEN_STARTS:
            if not verses.get(k, "").startswith(exp):
                fails.append(f"еталон {ref(k)}: має починатись «{exp}», отримав «{verses.get(k, '')[:60]}»")
        for k, exp in GOLDEN_ENDS:
            if not verses.get(k, "").endswith(exp):
                fails.append(f"еталон {ref(k)}: має закінчуватись «{exp}», отримав «…{verses.get(k, '')[-60:]}»")
        for k, exp in GOLDEN_NOTES:
            if exp not in notes.get(k, []):
                fails.append(f"еталон виноски {ref(k)}: очікував «{exp}», отримав {notes.get(k)}")
        n_notes = sum(len(v) for v in notes.values())
        titles = sum(1 for t in verses.values() if t.startswith("<n>"))
        nbsp_notes = sum(x.count("\xa0") for v in notes.values() for x in v)
        for label, got, exp in [("віршів", len(verses), EXPECT_VERSES), ("виносок", n_notes, EXPECT_NOTES),
                                ("надписів <n>", titles, EXPECT_TITLES), ("NBSP у виносках", nbsp_notes, EXPECT_NOTE_NBSP)]:
            if got != exp:
                fails.append(f"гейт: {label} {got}, очікував {exp}")
        if stats["tags"] < MIN_TAGS:
            fails.append(f"гейт: тегів {stats['tags']} < {MIN_TAGS}")
        if {k[0] for k in verses} != set(BOOK_NUM):
            fails.append("гейт: набір книг ≠ 66")
    # структурні інваріанти — і для фікстур
    for k, t in verses.items():
        r = f"{k[0]} {k[1]}:{k[2]}"
        if "’" in t:
            fails.append(f"{r}: «’» у тексті вірша")
        if "\xa0" in t:
            fails.append(f"{r}: NBSP у тексті вірша")
        if "\x00" in t:
            fails.append(f"{r}: незамінений якір")
        if re.search(r"<n>[^<]*<(S|f)>", t) or t.count("<n>") > 1 or ("<n>" in t and not t.startswith("<n>")):
            fails.append(f"{r}: тег/якір усередині надпису або надпис не на початку: {t[:80]}")
        stripped = re.sub(r"</?(S|f|n)>|<S>[^<]*</S>|<f>\[\d+\]</f>", "", t)
        stripped = re.sub(r"<S>[^<]*</S>|<f>[^<]*</f>|</?n>", "", t)
        if "<" in stripped or ">" in stripped:
            fails.append(f"{r}: стороння розмітка: {stripped[:80]}")
        markers = re.findall(r"<f>\[(\d+)\]</f>", t)
        if markers != [str(i + 1) for i in range(len(markers))] or len(markers) != len(notes.get(k, [])):
            fails.append(f"{r}: маркери виносок {markers} ≠ {len(notes.get(k, []))} виносок")
        if k[0] in NT_BOOKS and "<S>3588</S>" in t:
            fails.append(f"{r}: тег артикля G3588 (рішення: не тегувати)")
        if re.search(r"<S>\d+</S>\S*<S>", t) and re.search(r"<S>\d+</S>[A-Za-z]", t):
            fails.append(f"{r}: тег всередині слова")
    for k, ns in notes.items():
        for x in ns:
            if "’" in x:
                fails.append(f"{k}: «’» у виносці")
            if not x or re.sub(r"</?i>", "", x).count("<"):
                fails.append(f"{k}: порожня виноска або стороння розмітка: {x[:60]}")
    return fails


# ── Запис ───────────────────────────────────────────────────────────────────
def write_outputs(verses: dict, notes: dict, align: list, out_bible: Path = OUT_BIBLE,
                  out_notes: Path = OUT_NOTES, out_align: Path = OUT_ALIGN) -> None:
    for p in (out_bible, out_notes):
        tmp = p.with_suffix(".tmp")
        if tmp.exists():
            tmp.unlink()
    tmpb = out_bible.with_suffix(".tmp")
    con = sqlite3.connect(tmpb)
    con.executescript("""
        CREATE TABLE info (name TEXT, value TEXT);
        CREATE TABLE books (book_number NUMERIC, short_name TEXT, long_name TEXT);
        CREATE TABLE verses (book_number NUMERIC, chapter NUMERIC, verse NUMERIC, text TEXT);
    """)
    con.executemany("INSERT INTO info VALUES (?,?)", [
        ("description", "American Standard Version (1901) — OpenBible.info digital edition with Strong's"),
        ("language", "en"), ("strong_numbers", "true"), ("right_to_left", "false"),
        ("origin", f"github.com/openbibleinfo/American-Standard-Version-Bible @ {PINNED_COMMIT}"),
        ("detailed_info", ATTRIBUTION),
    ])
    con.executemany("INSERT INTO books VALUES (?,?,?)", [(n, s, l) for (_, n, l, s) in BOOKS])
    order = {b[0]: i for i, b in enumerate(BOOKS)}
    con.executemany("INSERT INTO verses VALUES (?,?,?,?)",
                    [(BOOK_NUM[b], c, v, t) for (b, c, v), t in
                     sorted(verses.items(), key=lambda kv: (order[kv[0][0]], kv[0][1], kv[0][2]))])
    con.commit()
    con.close()
    tmpn = out_notes.with_suffix(".tmp")
    con = sqlite3.connect(tmpn)
    con.executescript("""
        CREATE TABLE commentaries (book_number NUMERIC, chapter_number_from NUMERIC, verse_number_from NUMERIC,
                                   chapter_number_to NUMERIC, verse_number_to NUMERIC, marker TEXT, text TEXT);
    """)
    con.executemany("INSERT INTO commentaries VALUES (?,?,?,?,?,?,?)",
                    [(BOOK_NUM[b], c, v, c, v, f"[{i + 1}]", x)
                     for (b, c, v), ns in sorted(notes.items(), key=lambda kv: (order[kv[0][0]], kv[0][1], kv[0][2]))
                     for i, x in enumerate(ns)])
    con.commit()
    con.close()
    tmpb.replace(out_bible)
    tmpn.replace(out_notes)
    with open(out_align, "w", encoding="utf-8") as f:
        f.write("book\tchapter\tverse\tsection\ttoken_id\ttext\tunit_id\tstatus\tsrc_ids\tsrc_strongs\tsrc_heads\ten_head\n")
        for r in align:
            f.write("\t".join(map(str, r)) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", type=Path, default=SRC_DIR)
    ap.add_argument("--out-dir", type=Path, default=DATA,
                    help="куди писати ASV.SQLite3 / .commentaries / .alignment.tsv (типово data/)")
    args = ap.parse_args()
    print(f"▸ OpenBible ASV @ {PINNED_COMMIT[:7]} — {args.src}")
    if not (args.src / "usx-english-aligned").is_dir():
        print(f"✗ нема входу {args.src}/usx-english-aligned — див. docs/BUILD.md (OpenBible ASV)")
        return 1
    fails = verify_manifest(args.src)
    if fails:
        print("✗ вхід не збігається з закріпленим комітом:\n  " + "\n  ".join(fails[:20]))
        return 1
    verses, notes, align, stats, problems = build(args.src)
    fails = check(verses, notes, stats, problems)
    for k in sorted(stats):
        print(f"  {k:28} {stats[k]:>9,}")
    print(f"  {'verses':28} {len(verses):>9,}\n  {'footnotes':28} {sum(len(v) for v in notes.values()):>9,}")
    if fails:
        print(f"\n✗ {len(fails)} провалів — файли НЕ записано:")
        for f in fails[:40]:
            print("  " + f)
        return 1
    od = args.out_dir
    write_outputs(verses, notes, align, od / OUT_BIBLE.name, od / OUT_NOTES.name, od / OUT_ALIGN.name)
    print(f"✓ {od}/{{{OUT_BIBLE.name}, {OUT_NOTES.name}, {OUT_ALIGN.name}}}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
