#!/usr/bin/env python3
"""Будує `rendering` + `word_rendering` — як переклад передає кожне слово оригіналу
(ADR-041 «Translated as», частина 1: дані, без UI).

ЩО РОБИТЬ
---------
Для кожного вірша перекладу (KJV, ASV, RST):
  1. Слова Macula цього вірша — так само, як `DatabaseService.loadOriginalWords`
     (forward `verse_org`, усі org-рядки по черзі; немає рядка → identity;
     лише NULL-org → жодних слів).
  2. Сегменти тексту — дослівний порт `VerseParser.swift` (Strong's чіпляється
     до ОСТАННЬОГО непорожнього текстового вузла, провідні роздільники
     відрізаються в окремий сегмент без Strong's).
  3. Пари слово↔сегмент — дослівний порт `ReaderViewModel.verseWordSegmentPairs`
     (пул слів за базовим номером, сегменти в порядку читання, consume-in-order,
     повторний word.id пропускається).
  4. Сегмент → «передача» (нормалізація ADR-041 п.2), EN — злиття форм лише за
     наявності «сусіда» в даних, RU — лема pymorphy3, далі згортання суфікса.
  5. Рядок на КОЖНЕ входження: (translation, strongs_key, rendering_id,
     verse_key, seg_ord). `seg_ord` — порядковий № сегмента серед сегментів
     вірша, що мають Strong's (0-based) — саме його Swift підсвічує.

Джерело правди для п.2–3 — Swift-код застосунку. Якщо він зміниться, цей порт
мусить змінитись разом із ним, інакше графік і клікабельність розійдуться.

NASB свідомо пропущено (ADR-041 Amendment 2026-09-28): ліцензія не вирішена,
тому й `nasbExtendedOverride` тут не портовано.

ВИКОРИСТАННЯ
------------
    python3 scripts/build_word_rendering.py [sourcebible.db]

⛔ ПИШЕ в базу (DROP/CREATE двох таблиць) — запускати ТІЛЬКИ на Mac, на
робочій копії білду (див. CLAUDE.md «База даних»), не з пісочниці.
Ненульовий код виходу, якщо еталони (hesed) розійшлися — `rebuild.sh` тоді
спиняється ДО копіювання в бандл.
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TRANSLATIONS = ("KJV", "ASV", "RST")
LANG = {"KJV": "en", "ASV": "en", "RST": "ru"}

# ── Стоп-слова: службові слова, що НЕ є передачею слова оригіналу ────────────
# Потрапляють у сегмент, бо в KJV/ASV/RST тег стоїть після всієї фрази
# («for his mercy<S>2617</S>»). Передача = хвіст сегмента після останнього
# службового слова. Список консервативний: краще лишити зайве слово в хвості
# (його згорне п.4 «суфікс»), ніж відрізати справжню передачу.
STOP_EN = frozenset("""
a an the and or but for of in on to unto with by from at as that which who whom
whose his her their its my thy thine your our him them me thee us you ye he she
it they we i is are was were be been being shall will should would have hath had
has not no nor so then also even all this these those there upon into out up o
let do did doth does may might can could must am art wast mine
thine own
""".split())
STOP_RU = frozenset("""
и в во на с со к ко по о об от до из за для не ни же ли бы что как его ее её их
мой моя мое моё твой твоя свой своя он она оно они мы вы ты я это тот та те а
но да у при над под пред перед чтобы ибо есть был была было были будет буду всё
все всех весь себя сей оный
""".split())

# Прислівникові частки фразових дієслів (ADR-041, Amendment 3). У KJV/ASV тег
# стоїть після всієї фрази: «passed over<S>5674</S>», «went out<S>3318</S>»,
# «cut off<S>3772</S>». Частка — частина передачі, а не службове слово: без
# неї «pass over» і «pass through» зливаються, а з правилом «хвіст після
# службового слова» лишається сама частка («over» 168 для H5674).
# Навмисно БЕЗ чистих прийменників (in, on, to, unto, into, upon, with, for,
# of, from, at): «trust in», «call on» лишаються зведеними до дієслова.
PARTICLES_EN = frozenset("""
over through away past by out up down off forth back about aside along across
around round again abroad asunder together near nigh hither thither
""".split())

WORD_RE = re.compile(r"[A-Za-zА-Яа-яЁё]+(?:['’][A-Za-z]+)?")

# ── Порт VerseParser.swift ───────────────────────────────────────────────────
# Роздільники, що НЕ належать слову (VerseParser.leadingSeparators).
LEADING_SEPARATORS = set(",.;:!?…—–()[]\"“”«»") | set(" \t\n\r\x0b\x0c   ")


def _tokenize(text: str):
    """Tokenizer.tokenize(): текст / <tag> / </tag> / <tag/>, теги lowercased."""
    out, buf, i, n = [], [], 0, len(text)
    while i < n:
        if text[i] == "<":
            if buf:
                out.append(("text", "".join(buf)))
                buf = []
            j = text.find(">", i + 1)
            content = text[i + 1:] if j < 0 else text[i + 1:j]
            i = n if j < 0 else j + 1
            raw = content.strip(" ")
            if raw.startswith("/"):
                out.append(("close", raw[1:].lower()))
                continue
            name = raw.strip("/ ").lower()
            if raw.endswith("/") or name in ("br", "pb"):
                out.append(("self", name))
            else:
                out.append(("open", name))
        else:
            buf.append(text[i])
            i += 1
    if buf:
        out.append(("text", "".join(buf)))
    return out


class Seg:
    __slots__ = ("text", "strongs", "linebreak", "parabreak")

    def __init__(self, text, strongs=None, linebreak=False, parabreak=False):
        self.text = text
        self.strongs = strongs or []
        self.linebreak = linebreak
        self.parabreak = parabreak


def _parse_ids(raw: str):
    out = []
    for part in raw.split(","):
        s = part.strip()
        if not s:
            continue
        out.append(s.upper() if s[0].isalpha() else "S" + s)
    return out


def parse_segments(raw_text: str) -> list[Seg]:
    """VerseParser.parse(...).segments — лише те, що впливає на Strong's-сегменти."""
    segs: list[Seg] = []
    inside_s = inside_n = inside_f = False
    sbuf = ""

    def last_text_idx():
        for k in range(len(segs) - 1, -1, -1):
            s = segs[k]
            if not s.linebreak and not s.parabreak and s.text.strip(" \t") != "":
                return k
        return None

    for kind, val in _tokenize(raw_text):
        if kind == "text":
            if val == "":
                continue
            if inside_s:
                sbuf += val
            elif inside_n or inside_f:
                pass
            else:
                segs.append(Seg(val))
        elif kind == "open":
            if val == "s":
                inside_s, sbuf = True, ""
            elif val == "n":
                inside_n = True
            elif val == "f":
                inside_f = True
        elif kind == "close":
            if val == "s":
                inside_s = False
                ids = _parse_ids(sbuf)
                idx = last_text_idx()
                if ids and idx is not None:
                    seg = segs[idx]
                    lead_len = 0
                    for ch in seg.text:
                        if ch in LEADING_SEPARATORS:
                            lead_len += 1
                        else:
                            break
                    if lead_len == 0 or lead_len >= len(seg.text):
                        # як у Swift після bug-055: ДОДАВАННЯ — «longsuffering<S>750</S>
                        # <S>639</S>» несе обидва номери, перший лишається першим.
                        seg.strongs = seg.strongs + ids
                    else:
                        segs[idx] = Seg(seg.text[:lead_len])
                        segs.insert(idx + 1, Seg(seg.text[lead_len:], ids))
                sbuf = ""
            elif val == "n":
                inside_n = False
            elif val == "f":
                inside_f = False
                segs.append(Seg(""))            # невидимий маркер виноски
        elif kind == "self":
            if val == "br":
                segs.append(Seg("\n", linebreak=True))
            elif val == "pb":
                segs.append(Seg("", parabreak=True))
    return segs


# ── Порт ReaderViewModel.verseWordSegmentPairs ───────────────────────────────
def base_number(sid: str) -> str:
    """baseStrongsNumber: цифри після першого нецифрового префікса."""
    i = 0
    while i < len(sid) and not sid[i].isdigit():
        i += 1
    j = i
    while j < len(sid) and sid[j].isdigit():
        j += 1
    return sid[i:j]


def pair_words(words, segs):
    """words: [(word_id, strongs_id)] у порядку position. Повертає
    [(word_id, strongs_id, seg_ord, seg_text)]."""
    pool: dict[str, list] = defaultdict(list)
    for w in words:
        if w[1]:
            pool[base_number(w[1])].append(w)
    cursor: Counter = Counter()
    seen: set = set()
    out = []
    ord_ = -1
    for seg in segs:
        if not seg.strongs:
            continue
        ord_ += 1
        for raw_id in seg.strongs:
            base = base_number(raw_id)      # NASB-оверайд не потрібен (NASB пропущено)
            idx = cursor[base]
            bucket = pool.get(base)
            if bucket and idx < len(bucket):
                w = bucket[idx]
                cursor[base] = idx + 1
                if w[0] not in seen:
                    out.append((w[0], w[1], ord_, seg.text))
                    seen.add(w[0])
    return out


# ── Нормалізація сегмента → передача (ADR-041 п.2) ───────────────────────────
class Normalizer:
    def __init__(self, lang: str):
        self.lang = lang
        self.stop = STOP_RU if lang == "ru" else STOP_EN
        self._lem = {}
        if lang == "ru":
            try:
                import pymorphy3  # noqa: F401
            except ImportError:
                sys.stderr.write(
                    "\n✗ pymorphy3 не встановлено — потрібен для RST (ADR-041).\n"
                    "  python3 -m pip install --user --break-system-packages -r requirements-build.txt\n\n")
                raise SystemExit(1)
            self._ma = pymorphy3.MorphAnalyzer()

    def lemma(self, w: str) -> str:
        if self.lang != "ru":
            return w
        r = self._lem.get(w)
        if r is None:
            r = self._ma.parse(w)[0].normal_form
            self._lem[w] = r
        return r

    def is_stop(self, w: str) -> bool:
        return w in self.stop or (self.lang == "ru" and self.lemma(w) in self.stop)

    def __call__(self, seg_text: str) -> str:
        """Хвіст сегмента після останнього службового слова; для RU — леми."""
        words = [re.sub(r"['’]s$", "", m.group(0).lower().replace("ё", "е"))
                 for m in WORD_RE.finditer(seg_text)]
        # EN: кінцеві частки фразового дієслова відкладаємо й повертаємо після
        # ядра («and passed by» → ядро «passed» + «by» → «passed by»).
        particles = []
        if self.lang == "en":
            while words and words[-1] in PARTICLES_EN:
                particles.insert(0, words.pop())
        while words and self.is_stop(words[-1]):
            words.pop()
        i = len(words)
        while i > 0 and not self.is_stop(words[i - 1]):
            i -= 1
        tail = words[i:]
        if self.lang == "ru":
            tail = [self.lemma(w) for w in tail]
        return " ".join(tail + particles)


EN_SUFFIXES = (("ies", "y"), ("ied", "y"), ("es", ""), ("s", ""), ("ed", ""),
               ("ed", "e"), ("eth", ""), ("eth", "e"), ("est", ""), ("est", "e"),
               ("ing", ""), ("ing", "e"))


def merge_forms(by_key: dict[str, Counter], lang: str) -> dict[tuple[str, str], str]:
    """(strongs_key, raw_rendering) → фінальна передача.
    EN: форма зводиться до іншої ЛИШЕ якщо та теж є передачею цього ж слова
    (mercies→mercy тільки коли «mercy» трапляється). Далі — згортання суфікса:
    багатослівна передача → найдовший суфікс, що сам є передачею («ye showed
    kindness» → «kindness»; «wicked thing» лишається)."""
    out = {}
    for key, cnt in by_key.items():
        forms = set(cnt)
        lemm = {}
        for r in forms:
            tgt = r
            if lang == "en":
                ws = r.split()
                # змінюється останнє НЕ-частка слово: «passed over» → «pass over»
                k = len(ws) - 1
                while k > 0 and ws[k] in PARTICLES_EN:
                    k -= 1
                last = ws[k]
                for suf, rep in EN_SUFFIXES:
                    if last.endswith(suf) and len(last) > len(suf) + 2:
                        cand = " ".join(ws[:k] + [last[: -len(suf)] + rep] + ws[k + 1:])
                        if cand in forms:
                            tgt = cand
                            break
            lemm[r] = tgt
        finals = set(lemm.values())

        def collapse(t: str) -> str:
            # до нерухомої точки: «therefore thus saith» → «thus saith» → «saith»
            while True:
                ws = t.split()
                for i in range(1, len(ws)):
                    # не згортати до голої частки: «pass over» ≠ «over»
                    if all(w in PARTICLES_EN for w in ws[i:]):
                        continue
                    suf = " ".join(ws[i:])
                    if suf in finals:
                        t = suf
                        break
                else:
                    return t

        for r, t in lemm.items():
            out[(key, r)] = collapse(t)
    return out


# ── Ключ групи Strong's (той самий, що в Usage, bug-045) ─────────────────────
def canonical_map(conn) -> dict[str, str]:
    from build_strongs_merge_map import build_groups, load
    lemmas, glosses, counts = load(conn)
    groups = build_groups(lemmas, glosses, counts)
    return {sid: members[0] for sid, members in groups.items()}


def verse_key(book_num: int, ch: int, v: int) -> int:
    return book_num * 1_000_000 + ch * 1000 + v


def collect(conn, translation: str, canon: dict[str, str], norm: Normalizer):
    """→ list[(strongs_key, raw_rendering, verse_key, seg_ord)], stats"""
    book_num = {b: n for b, n in conn.execute("SELECT id, num FROM book")}
    words_by_verse: dict[tuple, list] = defaultdict(list)
    for wid, b, c, v, sid in conn.execute(
            "SELECT id, book_id, chapter, verse, strongs_id FROM word ORDER BY book_id, chapter, verse, position"):
        words_by_verse[(b, c, v)].append((wid, sid))
    org = defaultdict(list)
    for b, c, v, ob, oc, ov in conn.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation = ? ORDER BY book_id, chapter, verse, org_chapter, org_verse", (translation,)):
        org[(b, c, v)].append((ob, oc, ov) if ob is not None and oc is not None and ov is not None else None)

    rows, seen_words = [], set()
    stats = Counter()
    verses = conn.execute(
        "SELECT v.book_id, v.chapter, v.verse, v.text FROM verse v JOIN book b ON b.id = v.book_id "
        "WHERE v.translation = ? ORDER BY b.num, v.chapter, v.verse", (translation,)).fetchall()
    for b, c, v, text in verses:
        key = (b, c, v)
        if key in org:
            words = []
            for ref in org[key]:
                if ref:
                    words += words_by_verse.get(ref, [])
        else:
            words = words_by_verse.get(key, [])
        if not words or not text:
            continue
        for wid, sid, ord_, seg_text in pair_words(words, parse_segments(text)):
            if wid in seen_words:             # 1:N verse_org — слово вже враховане
                stats["dup_word"] += 1
                continue
            seen_words.add(wid)
            r = norm(seg_text)
            if not r:
                stats["empty"] += 1
                continue
            rows.append((canon.get(sid, sid), r, verse_key(book_num[b], c, v), ord_))
            stats["rows"] += 1
    return rows, stats


GOLDEN = [
    # (translation, strongs_key, expected_total, expected_top_rendering)
    ("KJV", "H2617", 245, "mercy"),
    ("ASV", "H2617", 237, "lovingkindness"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default="sourcebible.db")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    canon = canonical_map(conn)
    conn.executescript("""
        DROP TABLE IF EXISTS word_rendering;
        DROP TABLE IF EXISTS rendering;
        CREATE TABLE rendering (
            id   INTEGER PRIMARY KEY,
            lang TEXT NOT NULL,
            text TEXT NOT NULL,
            UNIQUE (lang, text)
        );
        CREATE TABLE word_rendering (
            translation  TEXT    NOT NULL,
            strongs_key  TEXT    NOT NULL,
            rendering_id INTEGER NOT NULL,
            verse_key    INTEGER NOT NULL,
            seg_ord      INTEGER NOT NULL,
            PRIMARY KEY (translation, strongs_key, rendering_id, verse_key, seg_ord)
        ) WITHOUT ROWID;
    """)
    rid_cache: dict[tuple[str, str], int] = {}

    def rid(lang, text):
        k = (lang, text)
        if k not in rid_cache:
            conn.execute("INSERT OR IGNORE INTO rendering (lang, text) VALUES (?, ?)", k)
            rid_cache[k] = conn.execute(
                "SELECT id FROM rendering WHERE lang = ? AND text = ?", k).fetchone()[0]
        return rid_cache[k]

    failures = []
    for tr in TRANSLATIONS:
        lang = LANG[tr]
        rows, stats = collect(conn, tr, canon, Normalizer(lang))
        by_key: dict[str, Counter] = defaultdict(Counter)
        for key, r, _, _ in rows:
            by_key[key][r] += 1
        final = merge_forms(by_key, lang)
        conn.executemany(
            "INSERT OR IGNORE INTO word_rendering VALUES (?, ?, ?, ?, ?)",
            ((tr, key, rid(lang, final[(key, r)]), vk, o) for key, r, vk, o in rows))
        print(f"  {tr}: {stats['rows']} входжень, {len(by_key)} слів; "
              f"порожніх після нормалізації {stats['empty']}, дублів 1:N {stats['dup_word']}")

    for tr, key, total, top in GOLDEN:
        got = conn.execute(
            "SELECT r.text, COUNT(*) FROM word_rendering w JOIN rendering r ON r.id = w.rendering_id "
            "WHERE w.translation = ? AND w.strongs_key = ? GROUP BY r.text ORDER BY 2 DESC",
            (tr, key)).fetchall()
        n = sum(c for _, c in got)
        if n != total or not got or got[0][0] != top:
            failures.append(f"{tr} {key}: очікувалось {total} / «{top}», маємо {n} / {got[:3]}")
        else:
            print(f"  ✓ {tr} {key}: {n}, топ «{top}» ({got[0][1]})")
    if conn.execute("SELECT COUNT(*) FROM word_rendering WHERE strongs_key = 'H2617a'").fetchone()[0] == 0:
        failures.append("H2617a (hesed II) не має жодного рядка — омонім загубився")

    if failures:
        conn.rollback()
        sys.stderr.write("\n✗ Еталони ADR-041 розійшлися:\n  " + "\n  ".join(failures) + "\n\n")
        return 1
    conn.commit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
