#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build a blind gold-entry page from data/pilot_gold.tsv.

    python3 scripts/make_gold_entry_page.py        ->  data/gold_entry.html

Why a generator and not a hand-written page: the gold set gets redrawn (it
already has been, from 50 token rows to 60 slot rows), and a page with data
pasted into it would go stale the same way docs/db_build.md did. Regenerate
instead.

WHAT THIS PAGE DELIBERATELY DOES NOT SHOW
-----------------------------------------
* Any machine-proposed Ukrainian gloss. There is none yet, and there must be
  none while these 60 rows are written — acceptance rate measured against a
  gloss you have already seen is circular, which is the entire reason the gold
  set exists.
* `freq_slot_ot` and `tier`. Knowing a unit occurs 48 805 times invites more
  care than a unit occurring twice, and head vs tail accuracy are reported as
  two separate numbers. Leaking the tier into the input contaminates both.

It DOES show everything needed to decide: the merged display word, its
transliteration, the English gloss the reader sees today, the composed morph
code (case and person come from morphology, not from the English), and both
Ukrainian verses for register.

Per-unit timing is recorded in the page and exported, so seconds-per-unit stops
being a guess. Output TSV carries the original columns plus `uk`, `secs`,
`disputed`, `note`.

READ-ONLY on data/pilot_gold.tsv. Never opens sourcebible.db.
"""

import csv
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data")
IN_GOLD = os.path.join(DATA, "pilot_gold.tsv")
IN_SLOTS = os.path.join(DATA, "pilot_sample_slots.tsv")
OUT_HTML = os.path.join(DATA, "gold_entry.html")

BOOKS = {"GEN": "Буття", "LEV": "Левит", "DEU": "Повторення Закону",
         "1CH": "1 Хроніки", "PSA": "Псалми", "PRO": "Приповісті",
         "ISA": "Ісая", "JON": "Йона"}

# Hidden from the UI on purpose — see module docstring.
HIDE = ("freq_slot_ot", "tier")


def load():
    with open(IN_GOLD, encoding="utf-8") as f:
        rd = csv.DictReader(f, delimiter="\t")
        return rd.fieldnames, list(rd)


def check_no_leak(html, rows):
    """The hidden fields must be absent from what the page actually carries.

    Checked STRUCTURALLY, by parsing the payload back out of the finished page,
    not by searching the HTML text: `freq_slot_ot` values are small integers, so
    a substring search for "5" matches a chapter number, a slot index, half the
    stylesheet — a check that always fails is as useless as one that never does.

    Three assertions, and the third is the control: if a row genuinely has no
    hidden value to begin with, the first two prove nothing, so that case is
    called out instead of passing quietly.
    """
    m = re.search(r"const DATA = (\{.*?\});\nconst KEY", html, re.S)
    if not m:
        sys.exit("BUG: cannot find the payload in the generated page — the leak "
                 "check would silently pass on an unverified file")
    payload = json.loads(m.group(1))

    problems = []
    for i, r in enumerate(payload["rows"]):
        for h in HIDE:
            if (r.get(h) or "").strip():
                problems.append("rows[%d].%s = %r" % (i, h, r[h]))
    for i, it in enumerate(payload["items"]):
        for h in HIDE:
            if h in it:
                problems.append("items[%d] carries key %r" % (i, h))
    if problems:
        sys.exit("BUG: hidden fields leaked into the page (%d):\n  - %s"
                 % (len(problems), "\n  - ".join(problems[:10])))

    had = [h for h in HIDE if any((r.get(h) or "").strip() for r in rows)]
    if len(had) != len(HIDE):
        sys.exit("BUG: %s is empty in data/pilot_gold.tsv already, so hiding it "
                 "proves nothing — the source file is not what this script "
                 "expects" % ", ".join(sorted(set(HIDE) - set(had))))

    # And the payload must still carry what the page needs, or the check above
    # passed only because the payload is empty.
    if len(payload["items"]) != len(rows):
        sys.exit("BUG: payload holds %d items for %d gold rows"
                 % (len(payload["items"]), len(rows)))
    if not payload["items"][0].get("surface"):
        sys.exit("BUG: payload item 1 has no surface form")
    print("  ✓ blind check: %d units embedded, %s carry no value in the page"
          % (len(payload["items"]), " / ".join(HIDE)))



# ---------------------------------------------------------------------------
# Морфологія українською
# ---------------------------------------------------------------------------
#
# Рецензент повідомив, чому відкривав сторонній чат: щоб побачити, чи справді у
# складеному слові є сполучник, і яка словникова форма. Тобто сторінка показувала
# склеєний слот і складений код `R·Ncmsc·Sp2ms`, а з чого слово складається — ні.
# Це і є причина забруднення набору: за відповіддю доводилось іти назовні.
#
# Таблиці нижче повторюють MorphologyDecoder з WordTabContent.swift. Покривають усі
# 73 коди, що трапляються у вибірці; невідомий код показується як є, без вигадок.

_POS = {"C": "сполучник", "R": "прийменник", "Rd": "прийменник + артикль",
        "D": "прислівник", "Np": "власна назва",
        "Td": "артикль", "Tn": "заперечна частка", "Tm": "вказівна частка",
        "To": "частка прямого додатка (ет)", "Tr": "відносна частка (що/який)",
        "Te": "частка існування (є)", "Sd": "суфікс напрямку (-а локативне)"}
_STEM = {"q": "Qal", "N": "Niphal", "p": "Piel", "P": "Pual", "h": "Hiphil",
         "H": "Hophal", "t": "Hithpael", "o": "Poel", "O": "Poal", "D": "Poel"}
_ASPECT = {"p": "перфект", "i": "імперфект", "w": "вайїктол (наратив)",
           "j": "юсив", "v": "імператив", "q": "перфект-консекутив",
           "r": "активний дієприкметник", "s": "пасивний дієприкметник",
           "a": "інфінітив абсолютний", "c": "інфінітив конструкт"}
_GEN = {"m": "чол.", "f": "жін.", "b": "спільн.", "c": "спільн.", "x": "—"}
_NUM = {"s": "одн.", "p": "мн.", "d": "двоїна"}
_STATE = {"a": "абсолютний", "c": "конструкт"}
_ADJ = {"a": "прикметник", "c": "числівник кількісний", "o": "числівник порядковий"}


def _pgn(code):
    """особа/рід/число з трьох символів, напр. 3ms."""
    if len(code) < 3:
        return code
    per, gen, num = code[0], code[1], code[2]
    p = {"1": "1 ос.", "2": "2 ос.", "3": "3 ос."}.get(per, per)
    return "%s %s %s" % (p, _GEN.get(gen, gen), _NUM.get(num, num))


def morph_uk(code):
    """-> людський опис коду Macula. Невідоме повертається як є."""
    c = (code or "").strip()
    if not c:
        return ""
    if c in _POS:
        return _POS[c]
    if c.startswith("Nc") and len(c) >= 5:
        return "іменник, %s, %s, %s" % (_GEN.get(c[2], c[2]), _NUM.get(c[3], c[3]),
                                        _STATE.get(c[4], c[4]))
    if c.startswith("Sp"):
        return "займенниковий суфікс, %s" % _pgn(c[2:])
    if c.startswith("Pp"):
        return "особовий займенник, %s" % _pgn(c[2:])
    if c.startswith("Pd"):
        return "вказівний займенник"
    if c.startswith("A") and len(c) >= 5:
        return "%s, %s, %s, %s" % (_ADJ.get(c[1], "прикметник"), _GEN.get(c[2], c[2]),
                                   _NUM.get(c[3], c[3]), _STATE.get(c[4], c[4]))
    if c.startswith("V") and len(c) >= 3:
        stem = _STEM.get(c[1], c[1])
        asp = _ASPECT.get(c[2], c[2])
        rest = c[3:]
        if not rest:
            return "дієслово %s, %s" % (stem, asp)
        if c[2] in ("r", "s"):        # дієприкметник: рід/число/стан
            if len(rest) >= 3:
                return "дієслово %s, %s, %s, %s, %s" % (
                    stem, asp, _GEN.get(rest[0], rest[0]),
                    _NUM.get(rest[1], rest[1]), _STATE.get(rest[2], rest[2]))
            return "дієслово %s, %s" % (stem, asp)
        return "дієслово %s, %s, %s" % (stem, asp, _pgn(rest))
    return c


def load_morphemes():
    """-> {(osis, ch, vs, slot): [{heb, xlit, lemma, strong, morph, morph_uk, en}]}

    З токенного файла: з чого саме складається display-слово."""
    path = os.path.join(DATA, "pilot_sample.tsv")
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            k = (r["osis"], r["chapter"], r["verse"], r["slot"])
            out.setdefault(k, []).append({
                "heb": r["surface"], "xlit": r["xlit"] or "",
                "lemma": r["lemma"], "strong": r["strong"],
                "morph": r["morph"], "morph_uk": morph_uk(r["morph"]),
                # ПО-ТОКЕННА колонка, не gloss_display.
                #
                # `gloss_display` (як і `gloss_macula`, з якого він синтезований) — це
                # фраза рівня СЛОТА, порізана Macula по токенах довільно: у Пс. 23:2!3
                # дієслово 7257 несе "he", а займенниковий суфікс 5204a — "makes me lie
                # down". У розкладі на морфеми це прямо бреше: підпис під `נִי` каже, що
                # ця морфема означає «makes me lie down», хоч вона означає «me».
                #
                # `word.gloss` (TSV `english`) — єдина колонка, вирівняна токен-у-токен:
                # там 7257 = "lie down", 5204a = "me". Саме її і треба показувати, коли
                # ми пояснюємо, з чого складається слово.
                #
                # Це та сама пастка, що описана в docs/original-tab.md, і я в неї вступив
                # через дві години після того, як її задокументував. Знайшов рецензент.
                "en": r["gloss_en"] or r["gloss_display"] or r["gloss_macula"],
                "en_slot": r["gloss_display"] or r["gloss_macula"],
            })
    for v in out.values():
        v.sort(key=lambda t: 0)
    return out



def check_morpheme_labels(payload):
    """Кожен підпис у розкладі мусить бути ПО-ТОКЕННИМ, не фразою рівня слота.

    Баг, який це ловить: у розклад брався `gloss_display`, тобто фраза рівня слота,
    порізана Macula по токенах довільно. Підпис під займенниковим суфіксом `נִי`
    казав «makes me lie down», хоч морфема означає «me». Зачепило 41 морфему з 91
    у наборі — 45%, не крайній випадок. Знайшло око рецензента, бо дані виглядали
    правдоподібно й нічого не падало.

    Три перевірки, і третя — контрольна: без неї перші дві проходили б і на
    зіпсованому файлі.
    """
    problems = []
    parts = [(it, p) for it in payload["items"] for p in it.get("parts", [])]
    if not parts:
        sys.exit("BUG: у жодної одиниці немає розкладу на морфеми")

    # 1. Структурна: підпис морфеми не може дорівнювати слотовій фразі, якщо
    #    морфем більше однієї. Саме так виглядав баг.
    for it, p in parts:
        if it["ntok"] > 1 and p["en"] and p["en"] == p["en_slot"] and \
                len(p["en"].split()) > 2:
            problems.append("%s слот %s: морфема %s підписана слотовою фразою %r"
                            % (it["ref"], it["slot"], p["morph"], p["en"]))

    # 2. Евристична: займенниковий суфікс не може означати ціле речення. По корпусу
    #    таких у `english` 306 із 45 607 (0.7%), у цій вибірці — жодного, тож поріг
    #    у три слова тут безпечний. Якщо колись спрацює законно — розширити поріг
    #    свідомо, а не мовчки.
    for it, p in parts:
        if p["morph"].startswith("Sp") and len(p["en"].split()) > 3:
            problems.append("%s слот %s: суфікс %s підписаний %r — це не морфема, "
                            "а фраза" % (it["ref"], it["slot"], p["morph"], p["en"]))

    # 3. КОНТРОЛЬНА. Якщо по-токенна й слотова колонки ніде не розходяться, перші дві
    #    перевірки нічого не доводять — вони пройдуть і на неправильній колонці.
    differ = sum(1 for _it, p in parts if p["en"] != p["en_slot"])
    if differ == 0:
        problems.append("контроль: по-токенна й слотова глоси не розходяться в жодній "
                        "із %d морфем — перевірка вище нічого не доводить, бо не може "
                        "відрізнити колонки" % len(parts))

    if problems:
        sys.exit("MORPHEME LABELS FAILED (%d):\n  - %s"
                 % (len(problems), "\n  - ".join(problems[:12])))
    print("  ✓ розклад морфем: %d морфем, по-токенних підписів; розходяться зі "
          "слотовою фразою в %d (%.0f%%)" % (len(parts), differ,
                                             100.0 * differ / len(parts)))


def load_verse_strips():
    """-> {(osis, ch, vs): [{slot, surface, en}, …]} in reading order.

    The reviewer reported the real slowdown: nothing showed WHICH word of the
    verse was being glossed, so short particles had to be hunted for. The whole
    verse is therefore rendered as an interlinear strip with the current slot
    marked. Ukrainian is NOT aligned — there is no token-level alignment to the
    translations, and inventing one would be a guess shown as a fact.
    """
    if not os.path.exists(IN_SLOTS):
        return {}
    strips = {}
    with open(IN_SLOTS, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            key = "%s %s:%s" % (r["osis"], r["chapter"], r["verse"])
            strips.setdefault(key, []).append({
                "slot": int(r["slot"]),
                "surface": r["surface"],
                "en": r["gloss_display"] or r["gloss_macula"],
            })
    for v in strips.values():
        v.sort(key=lambda s: s["slot"])
    return strips


def build(cols, rows):
    order = sorted(range(len(rows)), key=lambda i: (
        rows[i]["osis"], int(rows[i]["chapter"]),
        int(rows[i]["verse"]), int(rows[i]["slot"])))
    strips = load_verse_strips()
    morphemes = load_morphemes()
    items = []
    for n, i in enumerate(order, 1):
        r = rows[i]
        vkey = "%s %s:%s" % (r["osis"], r["chapter"], r["verse"])
        strip = strips.get(vkey, [])
        items.append({
            "parts": morphemes.get((r["osis"], r["chapter"], r["verse"], r["slot"]), []),
            "strip": strip,
            "nslots": len(strip),
            "pos": next((k for k, s in enumerate(strip, 1)
                         if s["slot"] == int(r["slot"])), None),
            "n": n,
            "row": i,
            "ref": "%s %s:%s" % (BOOKS.get(r["osis"], r["osis"]),
                                 r["chapter"], r["verse"]),
            "osis": r["osis"], "genre": r["genre"],
            "slot": r["slot"], "ntok": int(r["n_tokens"]),
            "surface": r["surface"], "xlit": r["xlit"],
            "morph": r["morph"], "headMorph": r["head_morph"],
            "headLemma": r["head_lemma"], "headPos": r["head_pos"],
            "strong": r["strong"],
            "en": r["gloss_display"] or r["gloss_macula"],
            "enRaw": r["gloss_macula"], "enTok": r["gloss_en"],
            "bsb": r["gloss_bsb"],
            "oh": r["uk_ohienko_verse"], "ohNum": r["uk_ohienko_numbering"],
            "gr": r["uk_gromov_verse"], "grNum": r["uk_gromov_numbering"],
        })
    # The hidden fields are stripped from the payload entirely, not merely left
    # out of the rendered card: otherwise the numbers still sit in the page
    # source, one devtools glance away from the blind pass they would bias.
    # The export therefore writes those columns empty; the analysis step re-joins
    # them from data/pilot_gold.tsv on (strong, morph, gloss_macula).
    safe_rows = [dict((k, "" if k in HIDE else v) for k, v in r.items())
                 for r in rows]
    payload = json.dumps({"cols": cols, "rows": safe_rows, "items": items},
                         ensure_ascii=False)
    return HTML.replace("__PAYLOAD__", payload)


HTML = r"""<!DOCTYPE html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Золотий набір — сліпе введення</title>
<style>
 :root{--bg:#0f1113;--s1:#17191c;--s2:#1f2226;--bd:#2a2e33;--tx:#e8eaed;
       --mu:#9aa1a9;--dim:#6b737c;--ac:#7aa2f7;--ok:#7ec699;--wn:#e0955f;
       --mono:ui-monospace,SFMono-Regular,Menlo,monospace}
 *{box-sizing:border-box}
 body{margin:0;background:var(--bg);color:var(--tx);
      font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
 .wrap{max-width:820px;margin:0 auto;padding:20px 18px 80px}
 .top{display:flex;align-items:center;gap:14px;flex-wrap:wrap;
      background:var(--s1);border:1px solid var(--bd);border-radius:10px;
      padding:10px 14px;margin-bottom:16px;font-size:13px}
 .top b{font-variant-numeric:tabular-nums}
 .track{flex:1;min-width:120px;height:6px;background:var(--s2);
        border-radius:3px;overflow:hidden}
 .fill{height:100%;width:0;background:var(--ok);transition:width .2s}
 .card{background:var(--s1);border:1px solid var(--bd);border-radius:12px;
       padding:18px 20px;margin-bottom:14px}
 .ref{font-size:12px;letter-spacing:.06em;color:var(--ac);font-weight:600}
 .vt{margin-top:8px;font-size:15px}
 .vt .lbl{color:var(--dim);font-size:11px;display:block;margin-top:8px}
 .heb{font-size:40px;direction:rtl;margin:14px 0 4px;line-height:1.4}
 .strip{direction:rtl;display:flex;flex-wrap:wrap;gap:2px;margin:12px 0 2px;
        background:var(--s2);border-radius:10px;padding:8px 10px}
 .sw{padding:4px 7px;border-radius:7px;text-align:center;min-width:34px}
 .sw .h{font-size:19px;line-height:1.5;color:var(--mu)}
 .sw .e{font-size:9.5px;line-height:1.3;color:var(--dim);direction:ltr;
        font-family:var(--mono);max-width:96px;overflow-wrap:anywhere}
 .sw.cur{background:rgba(122,162,247,.18);outline:1px solid var(--ac)}
 .sw.cur .h{color:var(--tx);font-weight:500}
 .sw.cur .e{color:var(--ac)}
 .pos{font-size:11px;color:var(--dim);margin-bottom:2px}
 .parts{margin:12px 0 4px;border:1px solid var(--bd);border-radius:10px;overflow:hidden}
 .parts .hd{font-size:10px;text-transform:uppercase;letter-spacing:.07em;
            color:var(--dim);padding:7px 11px;background:var(--s2)}
 .pt{display:flex;gap:10px;align-items:baseline;padding:8px 11px;
     border-top:1px solid rgba(42,46,51,.6);flex-wrap:wrap}
 .pt .h{font-size:20px;direction:rtl;min-width:44px}
 .pt .l{font-family:var(--mono);font-size:12px;color:var(--mu);min-width:70px}
 .pt .m{font-size:13px;color:var(--tx);flex:1;min-width:180px}
 .pt .g{font-family:var(--mono);font-size:12px;color:var(--ac);text-align:right}
 .pt .sl{font-family:var(--mono);font-size:10px;color:var(--dim);margin-top:2px}
 .pt .s{font-family:var(--mono);font-size:10px;color:var(--dim)}
 .xl{font-family:var(--mono);font-size:15px;color:var(--mu)}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
       gap:10px;margin:16px 0 4px}
 .kv{background:var(--s2);border-radius:8px;padding:8px 11px}
 .kv .k{font-size:10px;text-transform:uppercase;letter-spacing:.07em;
        color:var(--dim)}
 .kv .v{font-family:var(--mono);font-size:14px;margin-top:2px;word-break:break-all}
 .en{font-family:var(--mono);font-size:17px;color:#b9c0c8}
 input[type=text]{width:100%;background:var(--s2);border:1px solid var(--bd);
   border-radius:8px;color:var(--tx);padding:12px 14px;font-size:20px;
   font-family:inherit;margin-top:6px}
 input[type=text]:focus{outline:none;border-color:var(--ac);background:#1b2028}
 .row2{display:flex;gap:14px;align-items:center;margin-top:12px;
       flex-wrap:wrap;font-size:13px;color:var(--mu)}
 button{background:transparent;border:1px solid var(--bd);border-bottom-width:2px;
   border-radius:8px;color:var(--tx);padding:8px 14px;font-size:14px;
   font-family:inherit;cursor:pointer}
 button:hover{background:var(--s2)}
 button.pri{border-color:var(--ac);color:var(--ac)}
 .badge{display:inline-block;font-size:10px;padding:2px 8px;border-radius:20px;
   background:rgba(122,162,247,.13);color:var(--ac);font-weight:600;
   letter-spacing:.03em;vertical-align:3px;margin-left:8px}
 .note{background:var(--s1);border:1px solid var(--bd);border-left:3px solid var(--wn);
   border-radius:8px;padding:12px 14px;font-size:13px;color:var(--mu);margin-top:18px}
 kbd{background:var(--s2);border:1px solid var(--bd);border-bottom-width:2px;
   border-radius:5px;padding:1px 6px;font-family:var(--mono);font-size:11px;
   color:var(--mu)}
 .done{color:var(--ok)}
 @media(max-width:640px){.heb{font-size:32px}}
</style>
</head>
<body>
<div class="wrap">

 <div class="top">
  <span>одиниця</span><b id="pos">1 / 60</b>
  <div class="track"><div class="fill" id="fill"></div></div>
  <span>заповнено</span><b id="cnt">0</b>
  <span>·</span><span>сер. час</span><b id="avg">—</b>
  <span>·</span><span>усього</span><b id="tot">0:00</b>
  <button id="exp" class="pri">Завантажити TSV</button>
 </div>

 <div class="card" id="card"></div>

 <div class="note">
  <b>Це сліпе введення.</b> Тут немає жодного машинного варіанту — і не буде, поки
  всі 60 не заповнені. Частота й ярус приховані навмисно: знання, що слово
  трапляється 48 тисяч разів, змінює обережність, а head і tail рахуються окремо.
  Відмінок виводь із морфології, не з англійської глоси.
  <div style="margin-top:10px;color:var(--dim)">
   <kbd>⏎</kbd> далі · <kbd>⇧⏎</kbd> назад · <kbd>⌥d</kbd> позначити спірним ·
   прогрес зберігається в браузері, але тисни «Завантажити TSV» перед закриттям
  </div>
 </div>

</div>
<script>
const DATA = __PAYLOAD__;
const KEY = "sb_gold_entry_v1";
let st = {i:0, uk:{}, secs:{}, disp:{}, note:{}, total:0};
try{ const s=localStorage.getItem(KEY); if(s) st=Object.assign(st,JSON.parse(s)); }catch(e){}
let tStart = Date.now();
const items = DATA.items, N = items.length;
const $ = id => document.getElementById(id);

function fmt(s){ s=Math.round(s); return Math.floor(s/60)+":"+String(s%60).padStart(2,"0"); }

function save(){ try{ localStorage.setItem(KEY, JSON.stringify(st)); }catch(e){} }

function stamp(){
  const it = items[st.i];
  const d = (Date.now()-tStart)/1000;
  st.secs[it.row] = Math.round(((st.secs[it.row]||0) + d)*10)/10;
  st.total += d; tStart = Date.now();
}

function head(){
  const done = Object.values(st.uk).filter(v=>v&&v.trim()).length;
  $("pos").textContent = (st.i+1)+" / "+N;
  $("fill").style.width = (100*done/N)+"%";
  $("cnt").textContent = done;
  $("tot").textContent = fmt(st.total);
  const ss = Object.values(st.secs).filter(x=>x>0);
  $("avg").textContent = ss.length ? (ss.reduce((a,b)=>a+b,0)/ss.length).toFixed(1)+" с" : "—";
}

function parts(it){
  if(!it.parts || it.parts.length<1) return '';
  var t='<div class="parts"><div class="hd">з чого складається'
       +(it.parts.length>1?(' — '+it.parts.length+' морфеми'):' — одна морфема')+'</div>';
  it.parts.forEach(function(p){
    t+='<div class="pt"><div class="h">'+p.heb+'</div>'
      +'<div class="l">'+(p.lemma||'')+'</div>'
      +'<div class="m">'+(p.morph_uk||'')+' <span class="s">'+p.morph+' · H'+p.strong+'</span></div>'
      +'<div class="g">'+(p.en||'')
      + ((p.en_slot && p.en_slot!==p.en)
          ? '<div class="sl">у складі слова: '+p.en_slot+'</div>' : '')
      +'</div></div>';
  });
  return t+'</div>';
}

function strip(it){
  if(!it.strip || !it.strip.length) return '';
  var pos = it.pos ? ('слово '+it.pos+' з '+it.nslots) : '';
  var out = '<div class="pos">'+pos+' — підсвічене те, яке глосуємо</div><div class="strip">';
  it.strip.forEach(function(s){
    var cur = (s.slot===Number(it.slot)) ? ' cur' : '';
    out += '<div class="sw'+cur+'"><div class="h">'+s.surface+'</div>'
        +  '<div class="e">'+(s.en||'')+'</div></div>';
  });
  return out+'</div>';
}

function kv(k,v){ return v ? '<div class="kv"><div class="k">'+k+'</div><div class="v">'+v+'</div></div>' : ''; }

function render(){
  const it = items[st.i];
  const multi = it.ntok>1 ? '<span class="badge">'+it.ntok+' токени в слоті</span>' : '';
  $("card").innerHTML =
   '<div class="ref">'+it.ref+' · слот '+it.slot+' · '+it.genre+multi+'</div>'
   +'<div class="vt"><span class="lbl">Огієнко ('+it.ohNum+')</span>'+(it.oh||'—')+'</div>'
   +'<div class="vt"><span class="lbl">Громов ('+it.grNum+')</span>'+(it.gr||'—')+'</div>'
   +strip(it)
   +'<div class="heb">'+it.surface+'</div>'
   +parts(it)
   +'<div class="xl">'+(it.xlit||'')+'</div>'
   +'<div class="grid">'
     +kv('англійська глоса','<span class="en">'+(it.en||'')+'</span>')
     +kv('морфологія', it.morph)
     +kv('лема', it.headLemma)
     +kv("strong's", it.strong)
     +kv('BSB фраза', it.bsb)
     +kv('сира глоса Macula', it.enRaw)
   +'</div>'
   +'<label style="font-size:13px;color:var(--mu)">Українська глоса</label>'
   +'<input type="text" id="in" autocomplete="off" spellcheck="false" value="'
     +((st.uk[it.row]||'').replace(/"/g,'&quot;'))+'">'
   +'<div class="row2">'
     +'<button id="prev">‹ Назад</button>'
     +'<button id="next" class="pri">Далі ›</button>'
     +'<label><input type="checkbox" id="dsp" '+(st.disp[it.row]?'checked':'')+'> спірне</label>'
     +'<input type="text" id="nt" placeholder="нотатка (не обов’язково)" '
       +'style="flex:1;min-width:160px;font-size:14px;padding:7px 10px" value="'
       +((st.note[it.row]||'').replace(/"/g,'&quot;'))+'">'
     +'<span class="'+((st.uk[it.row]||'').trim()?'done':'')+'">'
       +((st.uk[it.row]||'').trim()?'✓ заповнено':'')+'</span>'
   +'</div>';
  const inp = $("in");
  inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length);
  $("next").onclick = ()=>go(1);
  $("prev").onclick = ()=>go(-1);
  $("dsp").onchange = e => { st.disp[it.row]=e.target.checked?1:0; save(); };
  $("nt").oninput = e => { st.note[it.row]=e.target.value; save(); };
  inp.oninput = e => { st.uk[it.row]=e.target.value; head(); save(); };
  head();
}

function go(d){
  stamp();
  st.i = Math.max(0, Math.min(N-1, st.i+d));
  save(); render();
}

document.addEventListener("keydown", e=>{
  if(e.key==="Enter"){ e.preventDefault(); go(e.shiftKey?-1:1); }
  if(e.altKey && (e.key==="d"||e.key==="D")){
    e.preventDefault();
    const it=items[st.i]; st.disp[it.row]=st.disp[it.row]?0:1; save(); render();
  }
});

$("exp").onclick = ()=>{
  stamp();
  const cols = DATA.cols.slice();
  ["secs","disputed","note"].forEach(c=>{ if(cols.indexOf(c)<0) cols.push(c); });
  const lines = [cols.join("\t")];
  DATA.rows.forEach((r,idx)=>{
    const o = Object.assign({}, r);
    o.uk = st.uk[idx]||"";
    o.secs = st.secs[idx]||"";
    o.disputed = st.disp[idx]?"1":"";
    o.note = st.note[idx]||"";
    lines.push(cols.map(c=>String(o[c]==null?"":o[c]).replace(/[\t\r\n]/g," ")).join("\t"));
  });
  const blob = new Blob([lines.join("\n")+"\n"], {type:"text/tab-separated-values"});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "pilot_gold_filled.tsv";
  a.click();
};

render();
</script>
</body>
</html>
"""


def main():
    if not os.path.exists(IN_GOLD):
        sys.exit("missing input: %s (run build_pilot_sample.py first)" % IN_GOLD)
    cols, rows = load()
    if not rows:
        sys.exit("%s has no rows" % IN_GOLD)

    filled = [r for r in rows if (r.get("uk") or "").strip()]
    if filled:
        print("  ! %d row(s) already carry a `uk` value — the page will show them "
              "as pre-filled, which is fine for resuming your own work but is NOT "
              "blind if they came from a model." % len(filled))

    missing = [c for c in ("n_tokens", "slot", "gloss_display", "head_morph")
               if c not in cols]
    if missing:
        sys.exit("%s predates the slot rework (missing %s) — rerun "
                 "build_pilot_sample.py" % (IN_GOLD, ", ".join(missing)))

    html = build(cols, rows)
    check_no_leak(html, rows)
    check_morpheme_labels(json.loads(
        re.search(r"const DATA = (\{.*?\});\nconst KEY", html, re.S).group(1)))

    with open(OUT_HTML, "w", encoding="utf-8") as f:
        f.write(html)
    print("─── blind gold entry ───")
    print("  units          : %d" % len(rows))
    print("  multi-token    : %d" % sum(1 for r in rows if int(r["n_tokens"]) > 1))
    print("  hidden fields  : %s" % ", ".join(HIDE))
    print("\n  %s" % OUT_HTML)
    print("  Open it in a browser. Export the TSV before closing the tab.")


if __name__ == "__main__":
    main()
