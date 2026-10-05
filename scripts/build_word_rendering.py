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
thou shalt hast wilt dost didst
""".split())
STOP_RU = frozenset("""
и в во на с со к ко по о об от до из за для не ни же ли бы что как его ее её их
мой моя мое моё твой твоя свой своя он она оно они мы вы ты я это тот та те а
но да у при над под пред перед чтобы ибо есть был была было были будет буду всё
все всех весь себя сей оный
будут будешь будем будете бывает некому некого нечего
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

# Кличний відмінок, який pymorphy3 зводить до чужої леми: «Господи» → «господин»
# (1 090 входжень H3068 у RST показувались як «Господин»). Лише перевірені заміром.
# Решта — словникові омоніми, де перший розбір майже завжди хибний для Біблії
# (заміряно на RST 2026-10-04): «род» → «родиться», «узы» → «уза», «елей» →
# «ель», «ложе» → «ложа»; «сиклей» лема «сикль» (інакше «сиклеить»);
# «Аллилуия» → «аллилуий» (pymorphy знає лише «аллилуйя»).
RU_LEMMA_OVERRIDE = {"господи": "господь", "род": "род", "узы": "узы", "елей": "елей",
                     "ложе": "ложе", "сиклей": "сикль", "аллилуия": "аллилуия"}
# «горе» — і «горе» (H1945 «Горе вам»), і місцевий відмінок «гора» («на горе»):
# вирішує попереднє слово (див. Normalizer.tokens).
RU_VERB_ENDINGS = ("л", "ла", "ло", "ли", "ет", "ит", "ут", "ют", "ат", "ят", "ешь", "ишь",
                   "ем", "им", "ете", "ите", "ть", "ти", "лся", "лась", "лись", "тся", "ться")
RU_GORE_PREPS = frozenset({"на", "в", "во", "о", "по", "при"})

# Дефіс усередині слова — частина слова: KJV «God-ward», «mercy-seat»,
# RST «кто-то». Раніше регулярка різала по дефісу, і передача ставала «god ward».
WORD_RE = re.compile(r"[A-Za-zА-Яа-яЁё]+(?:[-‐][A-Za-zА-Яа-яЁё]+)*(?:['’][A-Za-z]+)?")

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
                    # порт VerseParser: присвійне «'s» на початку вузла належить
                    # попередньому слову (ASV «man<S>5100</S>'s brother<S>80</S>»)
                    t = seg.text
                    if (len(t) > lead_len + 2 and t[lead_len] in "'’" and t[lead_len + 1] in "sS"
                            and t[lead_len + 2] in LEADING_SEPARATORS):
                        lead_len += 2
                        while lead_len < len(t) and t[lead_len] in LEADING_SEPARATORS:
                            lead_len += 1
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
    return drop_space_before_punct(segs)


def drop_space_before_punct(segs):
    """Порт VerseParser.droppingSpaceBeforePunctuation (bug-056): зайвий сегмент із
    самих пробілів (перед розділовим знаком чи іншим пробілом) зникає.
    Сегменти з Strong's не зачіпаються."""
    out = []
    for i, s in enumerate(segs):
        blank = (not s.strongs and not s.linebreak and not s.parabreak
                 and s.text != "" and set(s.text) == {" "})
        if blank:
            nxt = next((t for t in segs[i + 1:] if t.text != ""), None)
            prv = next((t for t in reversed(out) if t.text != ""), None)
            if nxt is not None and nxt.text[0] in ",.;:!?) ":
                continue
            if prv is not None and prv.text.endswith(" "):
                continue
        out.append(s)
    return out


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
    return [(w, s, o, t) for w, s, o, t, _ in pair_words_merged(words, segs)]


# Скільки сегментів з Strong's може стояти між шматками одного слова
# («cause<S>2289</S> them<S>846</S> to be put to death<S>2289</S>» — 1).
MERGE_GAP = 3


def pair_words_merged(words, segs):
    """Як pair_words, але «зайвий» повторний тег (той самий номер, а слів із ним
    в оригіналі вже не лишилось) не відкидається, а доклеюється до слова, яке
    забрав попередній шматок: KJV «put<S>2289</S> him to death<S>2289</S>» —
    одне θανατόω. П'ятий елемент — [(seg_ord, seg_text)] доклеєних шматків.
    Swift (`verseWordSegmentPairs`) сегменти так само не парує — `seg_ord`
    першого шматка, за яким застосунок знаходить рядок, не змінюється."""
    pool: dict[str, list] = defaultdict(list)
    for w in words:
        if w[1]:
            pool[base_number(w[1])].append(w)
    cursor: Counter = Counter()
    seen: set = set()
    out = []
    last: dict = {}                     # base → (індекс у out, ord останнього шматка)
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
                    out.append((w[0], w[1], ord_, seg.text, []))
                    seen.add(w[0])
                    last[base] = (len(out) - 1, ord_)
            elif base in last and ord_ - last[base][1] <= MERGE_GAP + 1 and last[base][1] != ord_:
                i, _ = last[base]
                out[i][4].append((ord_, seg.text))
                last[base] = (i, ord_)
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

    # Словник слів перекладу (нижній регістр). Задає collect(); потрібен, щоб
    # обрати лему НЕЗНАЙОМОГО pymorphy слова (переважно біблійні імена).
    vocab: frozenset = frozenset()

    def lemma(self, w: str) -> str:
        if self.lang != "ru":
            return w
        r = self._lem.get(w)
        if r is None:
            r = RU_LEMMA_OVERRIDE.get(w) or self._guess(w)
            self._lem[w] = r
        return r

    def _guess(self, w: str) -> str:
        """Слово зі словника pymorphy — перший розбір. Незнайоме (імена) —
        вгадувач ріже як заманеться: «Авессалом» → «авессало», «Иоав» →
        «иоать», «Иеровоам» → «иерово». Тоді з кандидатів беремо ті, що самі
        трапляються в тексті перекладу (не коротші за слово мінус одна літера),
        і з них найкоротший («Иоава» → «иоав»)."""
        ps = self._ma.parse(w)
        if ps[0].is_known or not self.vocab:
            return ps[0].normal_form
        first = ps[0].normal_form
        # дієслова вгадувач розбирає добре («соделал» → «соделать», «приидет» →
        # «приидти») — якщо й саме слово має дієслівне закінчення. «Иоав» → GRND
        # «иоать» — ні: «-ав» не дієслівне.
        if ps[0].tag.POS in ("VERB", "INFN", "PRTF", "PRTS", "GRND") and w.endswith(RU_VERB_ENDINGS):
            return first
        cands = list(dict.fromkeys(p.normal_form for p in ps))
        # відрізати можна щонайбільше одну літеру закінчення («Едом» ≠ «ед»);
        # присвійні «-ов/-ев/-ин» — будь-яке закінчення («Израилевой» → «израилев»)
        seen = [c for c in cands if c in self.vocab
                and (len(c) >= len(w) - 1 or (c.endswith(("ов", "ев", "ин")) and w.startswith(c)))]
        return min(seen, key=len) if seen else first

    def is_stop(self, w: str) -> bool:
        return w in self.stop or (self.lang == "ru" and self.lemma(w) in self.stop)

    def __call__(self, seg_text: str) -> str:
        """Хвіст сегмента після останнього службового слова; для RU — леми."""
        return " ".join(n for _, n in self.tokens(seg_text))

    def tokens(self, seg_text: str, prefix: str | None = None) -> list:
        """Той самий хвіст, але парами (сире слово, нормалізоване): сире потрібне,
        щоб повернути велику літеру власним назвам («God», «LORD», «Бог»).
        З `prefix` (текст вірша ДО сегмента) — трійки (сире, нормалізоване,
        на_початку_речення): велика літера на початку речення не є доказом
        власної назви (RST «Памятными соделал…» → «Памятный»)."""
        ms = list(WORD_RE.finditer(seg_text))
        raw = [re.sub(r"['’][sS]$", "", m.group(0)) for m in ms]
        words = [w.lower().replace("ё", "е") for w in raw]
        # EN: кінцеві частки фразового дієслова відкладаємо й повертаємо після
        # ядра («and passed by» → ядро «passed» + «by» → «passed by»).
        n_part = 0
        if self.lang == "en":
            while n_part < len(words) and words[len(words) - 1 - n_part] in PARTICLES_EN:
                n_part += 1
        end = len(words) - n_part
        while end > 0 and self.is_stop(words[end - 1]):
            end -= 1
        i = end
        while i > 0 and not self.is_stop(words[i - 1]):
            i -= 1
        idx = list(range(i, end)) + list(range(len(words) - n_part, len(words)))
        out = []
        for k in idx:
            norm = self.lemma(words[k]) if (self.lang == "ru" and k < end) else words[k]
            if norm == "гора" and words[k] == "горе" and (k == 0 or words[k - 1] not in RU_GORE_PREPS):
                norm = "горе"
            if prefix is None:
                out.append((raw[k], norm))
            else:
                out.append((raw[k], norm, _sentence_start(prefix + seg_text[:ms[k].start()]),
                            ms[k].start(), ms[k].start() + len(raw[k])))
        return out

    def _personal(self, t) -> bool:
        n = t[1]
        if self.lang == "ru":
            return n in PRONOUNS_RU
        return n in PRONOUNS_EN or n in POSSESSIVES_EN

    def pick(self, seg_text: str, prefix: str, lex_class: str | None, gloss: str = ""):
        """Передача входження за групою випадку. None — рядок не пишемо (займенник
        оригіналу). Елементи — п'ятірки (сире, норм., на_початку_речення, start, end)."""
        if lex_class in FUNC_SKIP:
            return None
        aw = self.all_words(seg_text, prefix, strip=False)
        if not aw:
            return []
        if lex_class == "pron_show":
            # займенник, що варто показувати: слово(а) як є, без прийменника/артикля
            # зліва, щонайбільше два («any man», «one another», «many as»)
            chunk = list(aw)
            while len(chunk) > 1 and (chunk[0][1] in PRON_LEAD_EN if self.lang == "en"
                                      else self._prep_conj(chunk[0])):
                chunk = chunk[1:]
            chunk = chunk[-2:]
            # KJV добудовує курсивом «man/thing»: «a certain man», «any thing» —
            # передача займенника тут «certain», «any» (крім «one another»)
            if len(chunk) == 2 and chunk[1][1] in ("man", "men", "thing", "things"):
                chunk = chunk[:1]
            return chunk
        if lex_class in FUNC_KEEP:
            # службове слово перекладу — і є передача («upon», «according to»,
            # «round about»). Займенник ділить сегмент: береться шматок після
            # останнього («unto him for» → «for»); артиклі й «and» з лівого краю геть.
            cut = max((i + 1 for i, t in enumerate(aw) if self._personal(t)), default=0)
            chunk = aw[cut:]
            lead = ARTICLES_EN | ({"and", "и"} if lex_class not in ("cj", "conj") else set())
            while chunk and chunk[0][1] in lead:
                chunk = chunk[1:]
            # довше двох слів — хвіст із двох: «thereof round about» → «round about»
            chunk = chunk[-2:]
            if self.lang == "ru" and len(chunk) > 1:
                # «к востоку», «по причине»: леми окремо дають «к восток» — беремо як у тексті
                chunk = [(t[0], t[0].lower().replace("ё", "е")) + tuple(t[2:]) for t in chunk]
            return chunk
        if self.lang == "en":
            # глоса Macula з ≥2 слів дослівно є в сегменті → саме цей фрагмент
            # («the master of the house» → «master of the house», «fine flour»).
            g = re.sub(r"[.\[\]()]", " ", gloss.lower()).strip()
            while GLOSS_EDGE_RE.match(g):
                g = GLOSS_EDGE_RE.sub("", g, count=1)
            gw = g.split()
            if len(gw) >= 2:
                low = [t[0].lower() for t in aw]
                for i in range(len(low) - len(gw) + 1):
                    if low[i:i + len(gw)] == gw:
                        return aw[i:i + len(gw)]
                # глоса-зворот з «of», а переклад обрав інший іменник: KJV «the goodman
                # of the house» при глосі «master of the house» → «goodman of the house»
                if "of" in gw[1:-1]:
                    low = [t[0].lower() for t in aw]
                    for i in range(len(low) - 3, -1, -1):
                        j = i + 2 + (low[i + 2] in ARTICLES_EN if i + 2 < len(low) - 1 else 0)
                        if (low[i + 1] == "of" and j == len(low) - 1
                                and low[i] not in STOP_EN and low[-1] not in STOP_EN):
                            return aw[i:]
            if aw[-1][1] in COLLIDE_EN:
                return aw[-1:]
        toks = self.tokens(seg_text, prefix)
        if toks:
            return toks
        # усе службове («to do», «ye shall do», «did») — останнє слово, що може бути
        # змістовим: не займенник, не прийменник/сполучник («to», «with», «и»)
        cand = [t for t in aw if not self._personal(t) and not self._prep_conj(t)]
        return cand[-1:]

    def _prep_conj(self, t) -> bool:
        if self.lang == "en":
            return t[1] in PREP_CONJ_EN
        return self._ma.parse(t[0].lower())[0].tag.POS in ("PREP", "CONJ", "PRCL")

    # Допоміжні дієслова: «стали служить», «будет делать» — передача у другому слові.
    RU_AUX = frozenset({"быть", "стать", "начать", "мочь"})

    def ru_head(self, toks: list) -> list:
        """Склеєна RU-фраза → ядро. Леми слів окремо ламають узгодження
        («приношение хлебный»), тож: дієслово (не допоміжне) → лише воно
        («будут преследовать» → «преследовать», «Некому было помочь» → «помочь»);
        інакше іменник — з узгодженим прикметником («хлебное приношение» за будь-
        якого порядку) або з прийменниковим додатком («жертва за грех»), або сам."""
        parses = [self._ma.parse(t[0].lower().replace("ё", "е"))[0] for t in toks]
        tags = [p.tag for p in parses]
        pos = [tg.POS for tg in tags]

        def with_norm(t, n):
            return (t[0], n) + tuple(t[2:])

        for t, p in zip(toks, pos):
            # дієприкметник теж дієслово: «предан смерти» → «предать»
            if p in ("VERB", "INFN", "PRTF", "PRTS", "GRND") and t[1] not in self.RU_AUX:
                return [t]
        nouns = [i for i, p in enumerate(pos) if p == "NOUN"]
        if not nouns:
            return [toks[-1]]
        i = nouns[0]
        low = [t[0].lower() for t in toks]
        if i + 2 < len(toks) and pos[i + 1] == "PREP" and pos[i + 2] == "NOUN":
            return [toks[i], with_norm(toks[i + 1], low[i + 1]), with_norm(toks[i + 2], low[i + 2])]
        if i == 1 and pos[0] == "PREP":                 # «без порока»
            return [with_norm(toks[0], low[0]), with_norm(toks[1], low[1])]

        def is_adj(j):
            return (0 <= j < len(toks) and pos[j] == "ADJF"
                    and ("Apro" not in tags[j].grammemes or toks[j][1] == "другой"))

        j = i - 1 if is_adj(i - 1) else i + 1 if is_adj(i + 1) else None
        if j is None:
            return [toks[i]]
        noun = parses[i].inflect({"nomn", "sing"}) or parses[i]
        gender = noun.tag.gender or "masc"
        inf = parses[j].inflect({gender, "nomn", "sing"})
        return [with_norm(toks[j], inf.word if inf else toks[j][1]), toks[i]]

    def all_words(self, seg_text: str, prefix: str, strip: bool = True) -> list:
        """Усі слова сегмента п'ятірками (сире, норм., на_початку_речення, start, end).
        `strip` — службові слова по краях відкидаються, всередині лишаються:
        « to be put to death» → «be put to death»? ні — «be» службове → «put to death»."""
        out = []
        for m in WORD_RE.finditer(seg_text):
            r = re.sub(r"['’][sS]$", "", m.group(0))
            w = r.lower().replace("ё", "е")
            n = self.lemma(w)
            if n == "гора" and w == "горе" and (not out or out[-1][5] not in RU_GORE_PREPS):
                n = "горе"
            out.append((r, n, _sentence_start(prefix + seg_text[:m.start()]),
                        m.start(), m.start() + len(r), w))
        if strip:
            while out and self.is_stop(out[-1][5]):
                out.pop()
            while out and self.is_stop(out[0][5]):
                out.pop(0)
        return [t[:5] for t in out]


_POSS_RE = re.compile(r"^(\s*)['’][sS]\b")


def blank_possessive(seg_text: str) -> str:
    """ASV `man<S>5100</S>'s brother<S>80</S>`: «'s» належить попередньому слову.
    Замінюємо пробілами тієї ж довжини — зсуви підсвітки (`hl`) не зсуваються."""
    m = _POSS_RE.match(seg_text)
    return seg_text if not m else m.group(1) + " " * (m.end() - len(m.group(1))) + seg_text[m.end():]


# Межа речення: початок вірша або . ! ? : ; (можливо, далі лапки/дужки/пробіли).
_SENT_END_RE = re.compile(r"(?:^|[.!?:;…,—–][\s\"“”«»'’()\[\]]*)$")


def _sentence_start(before: str) -> bool:
    return bool(_SENT_END_RE.search(before.strip(" \t\n\u00a0\u202f\u2009")))


EN_SUFFIXES = (("ies", "y"), ("ied", "y"), ("es", ""), ("s", ""), ("ed", ""),
               ("ed", "e"), ("eth", ""), ("eth", "e"), ("est", ""), ("est", "e"),
               ("ing", ""), ("ing", "e"))


def merge_forms(by_key: dict[str, Counter], lang: str,
                keep: dict | None = None) -> dict[tuple[str, str], str]:
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
                        stem = last[: -len(suf)] + rep
                        cand = " ".join(ws[:k] + [stem] + ws[k + 1:])
                        # «evening» ≠ «even»: службове слово не буває лемою
                        if cand in forms and stem not in STOP_EN:
                            tgt = cand
                            break
            lemm[r] = tgt
        finals = set(lemm.values())
        kept = (keep or {}).get(key, set())

        def collapse(t: str) -> str:
            # до нерухомої точки: «therefore thus saith» → «thus saith» → «saith»
            while True:
                ws = t.split()
                for i in range(1, len(ws)):
                    # не згортати до голої частки: «pass over» ≠ «over»
                    if all(w in PARTICLES_EN for w in ws[i:]):
                        continue
                    suf = " ".join(ws[i:])
                    # стійкий зворот («put to death») ріжеться лише до іншого
                    # стійкого: «cause to be put to death» → «put to death», не «death»
                    if t in kept and suf not in kept:
                        continue
                    # «went in» не згортається до голого «in»
                    if " " not in suf and (suf in STOP_EN or suf in STOP_RU):
                        continue
                    if suf in finals:
                        t = suf
                        break
                else:
                    return t

        fcount: Counter = Counter()
        for r, c in cnt.items():
            fcount[lemm[r]] += c

        def fill_gap(t: str) -> str:
            # ASV «put<S>2289</S> him to<S>1519</S> death<S>2289</S>» — «to» розмічене
            # окремим словом (εἰς), тож склейка дає «put death». Якщо слова — це
            # частіший стійкий зворот з пропусками (ті ж перше й останнє слово,
            # бракує ≤ 2), передача і є цим зворотом.
            ws = t.split()
            for k in sorted(kept, key=len):
                kw = k.split()
                if (len(ws) >= 2 and fcount[k] > fcount[t] and kw[0] == ws[0] and kw[-1] == ws[-1]
                        and 0 < len(kw) - len(ws) <= 2 and _is_subseq(ws, kw)
                        and set(kw) - set(ws) <= GAP_WORDS_EN):
                    return k
            return t

        for r, t in lemm.items():
            out[(key, r)] = collapse(fill_gap(t))
    return out


# Чим можна заповнити пропуск у зворот: лише службові частини дієслівних ідіом
# («put to death», «be put to death»), не займенники («sent him away») і не
# сполучники між двома іменниками («sin-offering for a burnt-offering»).
NUMBERS_EN = frozenset("""one two three four five six seven eight nine ten eleven twelve
twenty thirty forty fifty sixty seventy eighty ninety hundred hundreds thousand thousands
score threescore fourscore twain""".split())
CLAUSE_EN = frozenset("and or but nor so that as if when for yet because lest".split())

GAP_WORDS_EN = frozenset({"to", "be", "up", "out", "down", "forth"})

# ── Групи випадків (docs/features/report-adr041-rendering-cases.md) ──────────
# За частиною мови ОРИГІНАЛУ (`word.lexical_class`, Macula):
# займенники/артиклі/את — передачі «him/them/the» нічого не дають: рядків не пишемо,
# гейт покриття не пройде, і застосунок лишає стару розбивку по книгах (§3).
FUNC_SKIP = frozenset({"pron", "det", "art", "om", "x"})
# Але займенники не однорідні (заміряно на KJV 2026-10-04): питальні τίς (what/who/why),
# неозначені τις (certain/some/any man), вказівні ἐκεῖνος/οὗτος, відносні ὅς/ὅστις/ὅσος
# і зворотні/взаємні ἑαυτοῦ, ἀλλήλων — переклад справді вибирає, графік корисний.
# Тип — `word.gr_type` (Macula); зворотні Macula позначає «personal», тож — списком.
PRON_SHOW_TYPES = frozenset({"demonstrative", "relative", "interrogative", "indefinite"})
PRON_SHOW_STRONGS = frozenset({"G1438", "G1683", "G4572", "G240"})
# Слова, що відкидаються з лівого краю передачі такого займенника («unto him» → «him»,
# «of that» → «that», «the same» → «same»).
PRON_LEAD_EN = frozenset("""to unto with and or but for of in on at by from upon into the a an
shall will is was are were be""".split())

# прийменники/сполучники/частки/прислівники — службове слово перекладу І Є передачею
# («upon», «against», «until»): стоп-список не застосовується (§3).
FUNC_KEEP = frozenset({"prep", "cj", "conj", "ptcl", "rel", "adv", "ij", "intj"})
# Слова зі стоп-списку, що бувають змістовими: «until the even» (вечір), «his might»
# (сила), «shall be» (הָיָה), «all» (כֹּל). Для змістового оригіналу останнє слово
# сегмента з цього набору не вирізається — тег у KJV/ASV стоїть ПІСЛЯ передачі (§5).
COLLIDE_EN = frozenset("""even might will be been being is was were are am art all own mine
can may did do doth does""".split())
ARTICLES_EN = frozenset({"the", "a", "an"})
PREP_CONJ_EN = frozenset("""to unto with and or but for of in on at by from upon into then also not nor
as that which who whom whose o let up out than""".split())
POSSESSIVES_EN = frozenset("his her their my thy thine your our its".split())
PRONOUNS_RU = frozenset("""он она оно они я ты мы вы себя его ее её их мой твой свой наш ваш
сам который тот этот то это""".split())
GLOSS_EDGE_RE = re.compile(r"^(?:the|a|an|of|to|and|in|for|with|from|by|on|at)\s+")

# Займенник усередині склеєної EN-фрази — це додаток, а не передача:
# «sent<S>…</S> him away<S>…</S>» → «sent away».
PRONOUNS_EN = frozenset("him them her me thee us you ye it they he she we i".split())


def _is_subseq(short: list, long: list) -> bool:
    it = iter(long)
    return all(w in it for w in short)


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
    lexinfo: dict = {}
    for wid, b, c, v, sid, lc, gl, gt in conn.execute(
            "SELECT id, book_id, chapter, verse, strongs_id, lexical_class, gloss, gr_type FROM word "
            "ORDER BY book_id, chapter, verse, position"):
        words_by_verse[(b, c, v)].append((wid, sid))
        if lc == "pron" and (gt in PRON_SHOW_TYPES or sid in PRON_SHOW_STRONGS):
            lc = "pron_show"
        lexinfo[wid] = (lc, gl or "")
    org = defaultdict(list)
    for b, c, v, ob, oc, ov in conn.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse FROM verse_org "
            "WHERE translation = ? ORDER BY book_id, chapter, verse, org_chapter, org_verse", (translation,)):
        org[(b, c, v)].append((ob, oc, ov) if ob is not None and oc is not None and ov is not None else None)

    rows, seen_words = [], set()
    stats = Counter()
    if norm.lang == "ru" and not norm.vocab:
        voc = set()
        for (t,) in conn.execute("SELECT text FROM verse WHERE translation = ?", (translation,)):
            voc.update(w.lower().replace("ё", "е") for w in WORD_RE.findall(re.sub(r"<[^>]*>", " ", t or "")))
        norm.vocab = frozenset(voc)
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
        segs = parse_segments(text)
        prefix_by_ord, acc, o = {}, "", -1
        for s_ in segs:
            if s_.strongs:
                o += 1
                prefix_by_ord[o] = acc
            acc += s_.text
        text_by_ord = {o_: s_.text for o_, s_ in enumerate(t for t in segs if t.strongs)}
        for wid, sid, ord_, seg_text, extra in pair_words_merged(words, segs):
            if wid in seen_words:             # 1:N verse_org — слово вже враховане
                stats["dup_word"] += 1
                continue
            seen_words.add(wid)
            pref = prefix_by_ord.get(ord_, "")
            seg_text = blank_possessive(seg_text)
            lc, gl = lexinfo.get(wid, (None, ""))
            picked = norm.pick(seg_text, pref, lc, gl)
            if picked is None:
                stats["skip_pronoun"] += 1
                continue
            toks = [t + (ord_,) for t in picked]
            merged = False
            if extra:
                # Шматки одного слова: хвіст першого + змістові слова решти
                # («put» + «to death» → «put to death»; «будут» + «преследовать»
                # → «преследовать»). Задовге — це вже не передача, а фраза:
                # лишаємо перший шматок, як було.
                m_toks = list(toks)
                for o2, t2 in extra:
                    more = [t + (o2,) for t in
                            norm.all_words(t2, prefix_by_ord.get(o2, ""), strip=False)]
                    # повтор того самого слова («ears to hear, let him hear») —
                    # це не шматок, а друге вживання: не клеїмо
                    if {t[1] for t in more} & {t[1] for t in m_toks if not norm.is_stop(t[1])}:
                        continue
                    if norm.lang == "en":
                        more = [t for t in more if t[1] not in PRONOUNS_EN]
                        # шматок клеїться, лише якщо його змістові слова є в глосі Macula
                        # цього слова («put … to death» — глоса «put to death»), або це
                        # частки/числа («gather … together»). ASV Лк 6:22
                        # «Son<S>5207</S> of man's sake<S>5207</S>» — «sake» не υἱός.
                        gwords = {w[:4] for w in re.findall(r"[a-z]+", gl.lower())}
                        content = [t[1] for t in more if not norm.is_stop(t[1])
                                   and t[1] not in PARTICLES_EN and t[1] not in NUMBERS_EN]
                        if content and not all(w[:4] in gwords for w in content):
                            continue
                    m_toks += more
                # службові слова — лише по краях усієї фрази: «to» в «put to death» лишається
                while m_toks and norm.is_stop(m_toks[-1][0].lower().replace("ё", "е")):
                    m_toks.pop()
                while m_toks and norm.is_stop(m_toks[0][0].lower().replace("ё", "е")):
                    m_toks.pop(0)
                # сполучник між шматками — межа речення: «said my daughter and
                # she told», «looked and they fell» — це два вживання, не одне слово
                # (числа — виняток: «threescore and ten» = сімдесят)
                if (norm.lang == "en" and any(t[1] in CLAUSE_EN for t in m_toks[len(toks):])
                        and not all(t[1] in NUMBERS_EN or norm.is_stop(t[1]) for t in m_toks)):
                    m_toks = []
                if norm.lang == "ru" and len(m_toks) > 1:
                    m_toks = norm.ru_head(m_toks)
                if m_toks and len(m_toks) <= MAX_MERGED_WORDS:
                    toks, merged = m_toks, True
                    stats["merged"] += 1
            if not toks:
                stats["empty"] += 1
                continue
            rows.append([canon.get(sid, sid), toks, verse_key(book_num[b], c, v), ord_,
                         seg_text, pref, merged, text_by_ord])
            stats["rows"] += 1

    # Стійкі звороти: фраза, яку сам переклад розмітив кількома тегами одного
    # слова («put … to death»), — еталон передачі цього Strong's. Той самий зворот
    # в одному сегменті («being put to death<S>2289</S>») нормалізація інакше
    # обрізала б до «death». Тут повертаємо йому повну форму.
    keep: dict = defaultdict(set)
    for r in rows:
        if r[6] and len(r[1]) >= 2:
            keep[r[0]].add(" ".join(t[1] for t in r[1]))
    for r in rows:
        if r[6] or r[0] not in keep:
            continue
        aw = [t + (r[3],) for t in norm.all_words(r[4], r[5], strip=False)]
        norms = [t[1] for t in aw]
        for ph in sorted(keep[r[0]], key=lambda x: -len(x.split())):
            pw = ph.split()
            if len(pw) > len(r[1]) and norms[-len(pw):] == pw:
                r[1] = aw[-len(pw):]
                stats["kept_phrase"] += 1
                break

    out = [(r[0], r[1], r[2], r[3], highlight_spec(r[1], r[3], r[7])) for r in rows]
    return apply_case(out, norm.lang, text_case_counts(conn, translation, norm)), stats, keep


def text_case_counts(conn, translation: str, norm) -> tuple:
    """Регістр слова по ВСЬОМУ тексту перекладу (§8): скільки разів воно з великої
    посеред речення і скільки з малої. Початок речення і позиція після коми (там у
    KJV/ASV починається пряма мова: «said unto him, Son») не рахуються."""
    up: Counter = Counter()
    low: Counter = Counter()
    for (t,) in conn.execute("SELECT text FROM verse WHERE translation = ?", (translation,)):
        # номери Strong's і виноски — не текст: «Кореевых.<S>7141</S> Псалом» інакше
        # дає «7141 Псалом», і «Псалом» рахується як велика посеред речення
        plain = re.sub(r"<([SsFfNn])>.*?</\1>", "", t or "")
        plain = re.sub(r"<[^>]*>", " ", plain)
        for m in WORD_RE.finditer(plain):
            w = m.group(0)
            n = norm.lemma(re.sub(r"['’][sS]$", "", w).lower().replace("ё", "е"))
            if w[:1].islower():
                low[n] += 1
                continue
            before = plain[:m.start()].rstrip()
            if not before or before[-1] in ".!?:;…,(\"“«—–-":
                continue
            up[n] += 1
    return up, low


# Довша склеєна фраза — вже переказ, а не передача. 6 — щоб «cause to be put to
# death» дійшла до merge_forms і згорнулась там до стійкого «put to death».
MAX_MERGED_WORDS = 6


def highlight_spec(toks, ord_: int, text_by_ord: dict) -> str | None:
    """Що підсвічувати в застосунку: «ord:start:len;…» (зсуви — у Unicode-скалярах
    тексту сегмента, як `String.unicodeScalars` у Swift). NULL — весь сегмент
    `ord_` (передача = увесь його текст), як було до цього поля."""
    spans: dict = {}
    for t in toks:
        o, st, en = t[5], t[3], t[4]
        a, b = spans.get(o, (st, en))
        spans[o] = (min(a, st), max(b, en))
    if list(spans) == [ord_]:
        st, en = spans[ord_]
        txt = text_by_ord.get(ord_, "")
        if txt[st:en] == txt.strip(" \t\n,.;:!?…—–()[]\"“”«»'’"):
            return None
    return ";".join(f"{o}:{a}:{b - a}" for o, (a, b) in sorted(spans.items()))


# ── Велика літера власних назв ────────────────────────────────────────────────
# Нормалізація зводить усе до нижнього регістру, тож «God» ставав «god», а
# «LORD» — «lord». Мала літера в тексті — завжди справжня; велика буває і від
# власної назви, і від початку речення/цитати («said, Let»). Тому для кожного
# слова ОКРЕМОГО Strong's рахуємо: якщо великих більше, ніж малих, — це власна
# назва, і беремо найчастішу велику форму («God», «LORD»; RU — лема з великої).
# Інакше велика — випадковий початок речення, і слово йде в нижньому регістрі.
# Побічно це розводить «God» (H430 про Бога) і «gods»/«god» (про ідолів).
# Велика літера НА ПОЧАТКУ РЕЧЕННЯ доказом не рахується зовсім (інакше одиничне
# «Памятными» на початку вірша давало 1:0 → «Памятный»). Виняток — усі великі
# («LORD»): це розмітка власної назви незалежно від позиції.
# Якщо в межах Strong's доказів немає зовсім (кожне входження — на початку
# речення), рішення бере все слово в перекладі під будь-яким номером: трапляється
# з малої хоч раз частіше, ніж з великої посеред речення → загальне слово
# («памятный»); інакше — рідкісне ім'я, що випадково стоїть лише на початку
# речення (KJV «Achar», «Jemuel», «Higgaion»).
def apply_case(rows, lang: str, case_counts: tuple | None = None):
    """rows: [(key, [(raw, norm[, sentence_start, …])], vk, ord, *rest)]
    → [(key, rendering, vk, ord, *rest)]"""
    upper: dict = defaultdict(Counter)   # (key, norm) → Counter(raw форм з великої)
    lower: Counter = Counter()           # (key, norm) → скільки разів з малої

    def evidence(t) -> bool:
        raw = t[0]
        start = len(t) > 2 and t[2]
        return not start or (len(raw) > 1 and raw.isupper())

    upper_any: Counter = Counter()       # norm → великих посеред речення (усі ключі)
    lower_any: Counter = Counter()       # norm → з малої (усі ключі)
    for key, toks, *_ in rows:
        for t in toks:
            raw, n = t[0], t[1]
            if raw[:1].isupper():
                if evidence(t):
                    upper[(key, n)][raw] += 1
                    upper_any[n] += 1
            else:
                lower[(key, n)] += 1
                lower_any[n] += 1

    def proper(n, raw):
        return lang == "ru" and n[:1].upper() + n[1:] or raw.replace("’", "'")

    def cased(key, raw, n):
        if not raw[:1].isupper():
            return n
        ups_k = upper[(key, n)]
        if case_counts is not None and not ups_k and not lower[(key, n)]:
            # у межах Strong's доказів нема (лише початок речення / після коми,
            # «said unto him, Son») — вирішує весь текст перекладу (§8)
            if len(raw) > 1 and raw.isupper():          # «LORD»
                return raw
            g_up, g_low = case_counts
            if g_up[n] <= g_low[n]:
                return n
            if lang == "ru":
                return n[:1].upper() + n[1:]
            ups = upper[(key, n)]
            return (ups.most_common(1)[0][0] if ups else raw).replace("’", "'")
        ups = upper[(key, n)]
        if not ups and not lower[(key, n)]:
            return n if lower_any[n] > upper_any[n] else proper(n, raw)
        if sum(ups.values()) <= lower[(key, n)]:
            return n
        if lang == "ru":
            return n[:1].upper() + n[1:]
        return ups.most_common(1)[0][0].replace("’", "'")

    return [(key, " ".join(cased(key, t[0], t[1]) for t in toks), vk, o, *rest)
            for key, toks, vk, o, *rest in rows]


# ── Вірш-приклад для кожної передачі (ADR-041 ч.5, Amendment 4) ────────────────
# «Вага» вірша = сума голосів OpenBible за всі перехресні посилання з нього і на
# нього (ідея proposal_smarter_examples_v1.5). Голоси прив'язані до АНГЛІЙСЬКОЇ
# нумерації, тож вірш перекладу спершу переводиться через verse_org в оригінал, а
# звідти — у вірш(і) KJV. Без цього RST-Псалтир брав вагу чужого вірша
# («милость → Пс 51:10» = вага KJV 51:10 «create in me a clean heart»).
def verse_weights(conn, translation: str) -> dict:
    """verse_key ПЕРЕКЛАДУ → вага (сума голосів у KJV-нумерації)."""
    num = {b: n for b, n in conn.execute("SELECT id, num FROM book")}
    eng = Counter()
    for bk, ch, vs, votes in conn.execute(
            "SELECT from_book, from_chapter, from_verse, votes FROM cross_reference "
            "UNION ALL SELECT to_book, to_chapter, to_verse, votes FROM cross_reference"):
        eng[(bk, ch, vs)] += votes or 0
    kjv_by_org = defaultdict(list)
    for b, c, v, ob, oc, ov in conn.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse "
            "FROM verse_org WHERE translation = 'KJV' AND org_book_id IS NOT NULL"):
        kjv_by_org[(ob, oc, ov)].append((b, c, v))
    out: dict = {}
    seen = set()
    for b, c, v, ob, oc, ov in conn.execute(
            "SELECT book_id, chapter, verse, org_book_id, org_chapter, org_verse "
            "FROM verse_org WHERE translation = ?", (translation,)):
        vk = verse_key(num[b], c, v)
        seen.add((b, c, v))
        if ob is None:
            continue
        w = max((eng[k] for k in kjv_by_org.get((ob, oc, ov), [])), default=0)
        out[vk] = max(out.get(vk, 0), w)
    # Вірші без рядків verse_org — тотожна нумерація.
    for (b, c, v), w in eng.items():
        if (b, c, v) not in seen and b in num:
            out.setdefault(verse_key(num[b], c, v), w)
    return out


def pick_examples(rows_final, weights: dict) -> dict:
    """(strongs_key, rendering_text) → (verse_key, seg_ord): найвагоміший вірш;
    нічия або нульова вага → найраніший (канонічний порядок)."""
    best: dict = {}
    for key, r, vk, o in rows_final:
        cand = (weights.get(vk, 0), -vk, -o)
        cur = best.get((key, r))
        if cur is None or cand > cur[0]:
            best[(key, r)] = (cand, vk, o)
    return {k: (vk, o) for k, (_, vk, o) in best.items()}


EXAMPLE_GOLDEN = [
    # (translation, strongs_key, rendering, expected "BOOK ch:v")
    ("KJV", "H2617", "mercy", "MIC 6:8"),
    ("KJV", "G26", "charity", "1CO 13:13"),
]


# Еталони «вірш → передача»: по прикладу на кожну групу звіту
# docs/features/report-adr041-rendering-cases.md + кожен баг, знайдений на пристрої.
# Знайшов новий баг — додай сюди рядок. Розходження = білд не йде в бандл.
VERSE_GOLDEN = [
    # (translation, strongs, "BOOK ch:v", очікувана передача)
    ("KJV", "G2289", "MAT 26:59", "put to death"),        # розбиті теги
    ("KJV", "G2289", "MAT 10:21", "put to death"),        # «cause … to be put to death»
    ("ASV", "G2289", "MRK 14:55", "put to death"),        # «to» розмічене окремо (εἰς)
    ("RST", "H7291", "DEU 28:22", "преследовать"),        # «будут» — допоміжне
    ("RST", "H5337", "JDG 18:28", "помочь"),              # «Некому было помочь»
    ("RST", "H2143", "PSA 110:4", "памятный"),            # велика лише від початку вірша
    ("RST", "G5590", "JHN 10:24", "недоумение"),          # ідіома перекладу — чесно
    ("ASV", "G1909", "MAT 10:21", "against"),             # службове слово оригіналу
    ("ASV", "G80",   "MRK 12:19", "brother"),             # «man's brother» — без «s»
    ("ASV", "G5043", "MAT 9:2",   "son"),                 # кличний після коми
    ("ASV", "G3617", "MAT 10:25", "master of the house"), # глоса Macula як вказівник
    ("KJV", "H6153", "LEV 11:25", "even"),                # «until the even» — не «until»
    ("KJV", "H1121", "GEN 27:18", "son"),                 # «my son» — займенник геть
    ("KJV", "G1438", "LUK 9:23",  "himself"),             # зворотний займенник — показуємо
    ("ASV", "G5207", "LUK 6:22",  "Son"),                 # «'s sake» — не шматок υἱός
    ("ASV", "G3107", "ROM 4:7",   "blessed"),             # зсув тегу ASV (fix_asv_tag_drift.py)
]


GOLDEN = [
    # (translation, strongs_key, expected_total, expected_top_rendering)
    ("KJV", "H2617", 245, "mercy"),
    ("ASV", "H2617", 239, "lovingkindness"),   # 237 → 239: fix_asv_tag_drift повернув 2 зсунуті теги
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default="sourcebible.db")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    canon = canonical_map(conn)
    # BEGIN усередині скрипта: DDL у SQLite транзакційний, тож провал еталонів
    # відкочує і DROP/CREATE — стара таблиця лишається цілою. Без цього
    # executescript комітив DROP одразу, і rollback лишав порожні таблиці.
    conn.executescript("""
        BEGIN;
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
            hl           TEXT,          -- що підсвітити: «ord:start:len;…», NULL = весь сегмент
            PRIMARY KEY (translation, strongs_key, rendering_id, verse_key, seg_ord)
        ) WITHOUT ROWID;
        DROP TABLE IF EXISTS rendering_example;
        CREATE TABLE rendering_example (
            translation  TEXT    NOT NULL,
            strongs_key  TEXT    NOT NULL,
            rendering_id INTEGER NOT NULL,
            verse_key    INTEGER NOT NULL,
            seg_ord      INTEGER NOT NULL,
            hl           TEXT,
            PRIMARY KEY (translation, strongs_key, rendering_id)
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
        rows, stats, keep = collect(conn, tr, canon, Normalizer(lang))
        by_key: dict[str, Counter] = defaultdict(Counter)
        for key, r, *_ in rows:
            by_key[key][r] += 1
        final = merge_forms(by_key, lang, keep)
        conn.executemany(
            "INSERT OR IGNORE INTO word_rendering VALUES (?, ?, ?, ?, ?, ?)",
            ((tr, key, rid(lang, final[(key, r)]), vk, o, hl) for key, r, vk, o, hl in rows))
        rows_final = [(key, final[(key, r)], vk, o) for key, r, vk, o, _ in rows]
        hl_by = {(key, vk, o): hl for key, _, vk, o, hl in rows}
        examples = pick_examples(rows_final, verse_weights(conn, tr))
        conn.executemany(
            "INSERT INTO rendering_example VALUES (?, ?, ?, ?, ?, ?)",
            ((tr, key, rid(lang, text), vk, o, hl_by.get((key, vk, o)))
             for (key, text), (vk, o) in examples.items()))
        print(f"  {tr}: {stats['rows']} входжень, {len(by_key)} слів; "
              f"порожніх після нормалізації {stats['empty']}, дублів 1:N {stats['dup_word']}, "
              f"склеєних шматків {stats['merged']}, стійких зворотів {stats['kept_phrase']}")

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
    for tr, key, text, want in EXAMPLE_GOLDEN:
        # Рядок збираємо в Python: у SQLite `||` сильніший за `%`, тож
        # «' ' || x % 1000» рахувався як «(' ' || x) % 1000» → 0.
        row = conn.execute(
            "SELECT b.id, e.verse_key "
            "FROM rendering_example e JOIN rendering r ON r.id = e.rendering_id "
            "JOIN book b ON b.num = e.verse_key / 1000000 "
            "WHERE e.translation = ? AND e.strongs_key = ? AND r.text = ?", (tr, key, text)).fetchone()
        got = f"{row[0]} {row[1] // 1000 % 1000}:{row[1] % 1000}" if row else None
        if got != want:
            failures.append(f"приклад {tr} {key} «{text}»: очікувався {want}, маємо {got}")
        else:
            print(f"  ✓ приклад {tr} {key} «{text}»: {want}")
    for tr, sid, ref, want in VERSE_GOLDEN:
        bk, cv = ref.split()
        ch, vs = map(int, cv.split(":"))
        got = [r for (r,) in conn.execute(
            "SELECT r.text FROM word_rendering w JOIN rendering r ON r.id = w.rendering_id "
            "WHERE w.translation = ? AND w.strongs_key = ? "
            "AND w.verse_key = (SELECT num FROM book WHERE id = ?) * 1000000 + ? * 1000 + ?",
            (tr, canon.get(sid, sid), bk, ch, vs))]
        if want not in got:
            failures.append(f"{tr} {sid} {ref}: очікувалось «{want}», маємо {got}")
        else:
            print(f"  ✓ {tr} {sid} {ref}: «{want}»")
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
