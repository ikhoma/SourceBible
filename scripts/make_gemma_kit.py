#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the Gemma kit for branch B of the interlinear pilot.

    python3 scripts/make_gemma_kit.py   ->  data/SourceBible_UK_Interlinear_Gemma_kit.zip

Follows the kit conventions of the `calvin-ru-uk` skill: one user turn (no system
role), temp 0.2, per-verse blocks, READ_ME_FIRST, and an output format that
collates back against the source.

WHY THERE IS NO GLOSSARY INJECT
-------------------------------
The calvin-ru-uk kit ships `glossary_inject_RU-UK.txt` into the model. This kit
deliberately does NOT, and that is a measurement decision, not an omission.

Branch B exists to be compared against branch A on the same 60 gold units. Branch
A received exactly two things: the conventions document and the input data. A
glossary listing "יהוה → Господь" would hand branch B answers the gold set
contains — and hand them only to branch B. The comparison would then measure the
glossary, not the model.

A glossary is the obvious next lever for the production run. At that point BOTH
branches get it and the comparison stays honest.

Note also that calvin-ru-uk renders the divine name «Ягве». The interlinear does
not: the reviewer's gold set uses «Господь». Two surfaces, two conventions — do
not "fix" one to match the other.
"""

import csv
import os
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data")
IN_UNITS = os.path.join(DATA, "pilot_gen_input.tsv")
IN_CONV = os.path.join(REPO, "docs", "features", "conventions-uk-interlinear.md")
KIT_NAME = "SourceBible_UK_Interlinear_Gemma_kit"
OUT_DIR = os.path.join(DATA, KIT_NAME)
OUT_ZIP = os.path.join(DATA, KIT_NAME + ".zip")

BOOKS = {"GEN": "Буття", "LEV": "Левит", "DEU": "Повторення Закону",
         "1CH": "1 Хроніки", "PSA": "Псалми", "PRO": "Приповісті",
         "ISA": "Ісая", "JON": "Йона"}

MORPH_KEY = """КОДИ morph (Macula), морфеми через `·`:
  R  прийменник        C  сполучник         Td артикль
  Nc іменник           Np власна назва      Ac числівник
  V  дієслово          Pp особовий займенник
  Sp займенниковий суфікс                   Tn заперечна частка
  D  прислівник        Ti питальна частка    Tm вказівна частка
Далі в коді іменника: рід (m/f/b), число (s/p), стан (a=абсолютний, c=конструкт).
Далі в коді дієслова: стем (q=Qal, N=Niphal, p=Piel, h=Hiphil, t=Hithpael),
аспект (p=перфект, i=імперфект, w=wayyiqtol, v=імператив, q=перфект-консекутив,
r=активний дієприкметник, a=інфінітив абсолютний, c=інфінітив конструкт),
потім особа/рід/число."""

PROMPT_HEAD = """Ти складаєш український **послівний підрядник** до івритського тексту Старого Заповіту.

Підрядник — це не переклад вірша. Це підпис під кожним івритським словом, який
каже, що саме тут стоїть. Читач бачить стовпчик українських глос під рядком
івриту, тому послідовність важливіша за красу окремого слова.

{conventions}

{morph_key}

ЯК ВИРІШУВАТИ
Англійська глоса дає **лексичний вибір**. Форму — відмінок, число, особу, час,
стан — бери з `morph`. Два українські переклади вірша подані для лексики й
регістру: щоб не вийшла калька і щоб слово звучало по-українськи. Граматику з них
НЕ копіюй: якщо `morph` каже однину, глоса однина, навіть якщо в перекладі множина.

ФОРМАТ ВІДПОВІДІ
Тільки рядки виду

  uid<TAB>українська глоса

Один рядок на одну одиницю, у тому самому порядку, що нижче. Жодного тексту до
чи після. Без markdown-огорожі, без нумерації, без пояснень. Одна-три українські
словоформи в глосі, без лапок, без крапки в кінці.

ОДИНИЦІ ДЛЯ ГЛОСУВАННЯ
"""

READ_ME = """SourceBible — кит для локальної Gemma
Український послівний підрядник, гілка B пілоту
Створено: {stamp_note}

ЩО ЦЕ
-----
209 унікальних display-слів (слотів) із 24 віршів, 8 жанрів. Це та сама вибірка,
на якій уже прогнано гілку A (сильна модель). Мета — порівняти дві гілки на тих
самих одиницях проти золотого набору з 60 глос, написаних рецензентом наосліп.

МОДЕЛЬ І ПАРАМЕТРИ
------------------
Локальна Gemma (гемма4 31B).
  * НЕ використовувати system-роль. Усе в один user-turn.
  * temperature 0.2
  * якщо вивід дрейфує або повторюється — крутити penalties, не температуру вгору

ЯК ПРОГНАТИ
-----------
У теці `prompts/` лежать {n_prompts} готових файлів, по одному на вірш. Кожен —
це ВЕСЬ user-turn: правила, ключ морфології, формат і одиниці саме цього вірша.
Нічого доклеювати не треба.

  1. Береш `prompts/01_1CH_1-1.txt`, віддаєш моделі як один user-turn.
  2. Відповідь зберігаєш ЯК Є у `output/01_1CH_1-1.txt`.
  3. Так по всіх {n_prompts} файлах. Порядок не має значення.

Розбито по віршах, а не одним куском, з двох причин: контекст локальної моделі
менший, і якщо один вірш зіпсується, решта не пропаде.

ЯК ЗІБРАТИ РЕЗУЛЬТАТ
--------------------
  python3 merge_output.py

Скрипт прочитає `output/*.txt`, складе `branch_b.tsv` і ПЕРЕВІРИТЬ:
усі {n_units} uid присутні, немає порожніх, немає дублів, немає markdown-огорожі
й службового тексту. При будь-якій проблемі — ненульовий код виходу і перелік
того, що саме не так. Не «схоже, все ок», а падіння.

Далі віддаєш `branch_b.tsv` — я порівнюю три речі: Gemma проти золотого набору,
Gemma проти гілки A, і де обидві гілки помиляються однаково (це вже не модель, а
дірка в конвенціях).

ЧОГО ТУТ НАВМИСНО НЕМА
----------------------
Немає glossary_inject. У киті `calvin-ru-uk` він є і йде в модель, а тут його
нема свідомо: гілка A отримала лише конвенції плюс дані, і якщо гілці B дати
ще й список «יהוה → Господь», вона отримає готові відповіді із золотого набору,
а порівняння почне міряти глосарій, а не модель. Глосарій — наступний важіль, і
тоді його отримають обидві гілки.

Друга розбіжність із тим китом: там Боже ім'я передається як «Ягве», тут — як у
золотому наборі рецензента. Це дві різні поверхні з різними конвенціями; не
зводити одну до одної.

ФАЙЛИ
-----
  prompts/           {n_prompts} готових user-turn, по віршу
  output/            сюди кладеш відповіді моделі, ті самі імена файлів
  units.tsv          усі {n_units} одиниць із повним контекстом (довідка)
  conventions.md     ті самі правила, що були в гілки A
  merge_output.py    збірка + перевірки з ненульовим кодом виходу
"""

MERGE_PY = r'''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Collect output/*.txt into branch_b.tsv and fail loudly on anything wrong.

    python3 merge_output.py

A merger that quietly drops a malformed line would hand the comparison a smaller
sample and a better-looking score. Every problem below exits non-zero instead.
"""

import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNITS = os.path.join(HERE, "units.tsv")
OUTDIR = os.path.join(HERE, "output")
RESULT = os.path.join(HERE, "branch_b.tsv")

FENCE = re.compile(r"^\s*(```|~~~)")
UID = re.compile(r"^\[?(U\d{3})\]?[\t ]+(.+)$")


def main():
    if not os.path.exists(UNITS):
        sys.exit("немає units.tsv — кит розпакований не повністю")
    with open(UNITS, encoding="utf-8") as f:
        want = [r["uid"] for r in csv.DictReader(f, delimiter="\t")]

    if not os.path.isdir(OUTDIR):
        sys.exit("немає теки output/ — спершу проженіть prompts/ через модель")
    files = sorted(fn for fn in os.listdir(OUTDIR) if fn.endswith(".txt"))
    if not files:
        sys.exit("output/ порожня — жоден вірш не прогнано")

    got, problems, fences = {}, [], 0
    for fn in files:
        path = os.path.join(OUTDIR, fn)
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln, line in enumerate(f, 1):
                if not line.strip():
                    continue
                if FENCE.match(line):
                    fences += 1
                    continue
                m = UID.match(line.rstrip("\n"))
                if not m:
                    problems.append("%s:%d нерозпізнаний рядок: %r"
                                    % (fn, ln, line.strip()[:70]))
                    continue
                uid, uk = m.group(1), " ".join(m.group(2).split())
                uk = uk.strip().strip('"').strip("'")
                if uid in got and got[uid] != uk:
                    problems.append("%s: %s вже був зі значенням %r, тепер %r"
                                    % (fn, uid, got[uid], uk))
                got[uid] = uk

    missing = [u for u in want if u not in got]
    empty = [u for u, v in got.items() if not v]
    extra = [u for u in got if u not in want]

    if missing:
        problems.append("не знайдено %d одиниць: %s%s"
                        % (len(missing), ", ".join(missing[:12]),
                           " …" if len(missing) > 12 else ""))
    if empty:
        problems.append("порожні глоси: %s" % ", ".join(sorted(empty)[:12]))
    if extra:
        problems.append("зайві uid, яких немає у вибірці: %s"
                        % ", ".join(sorted(extra)[:12]))
    if fences:
        problems.append("markdown-огорожа у виводі: %d рядків — модель порушує "
                        "формат, варто затягнути промпт" % fences)

    if problems:
        sys.exit("ЗБІРКА НЕ ПРОЙШЛА (%d проблем):\n  - %s"
                 % (len(problems), "\n  - ".join(problems)))

    with open(RESULT, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["uid", "uk"])
        for u in want:
            w.writerow([u, got[u]])
    print("✓ %s — %d одиниць, усі присутні й непорожні" % (RESULT, len(want)))
    print("  віддайте цей файл на порівняння")


if __name__ == "__main__":
    main()
'''


def load_units():
    with open(IN_UNITS, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def verse_block(rows):
    """One verse: its two Ukrainian renderings once, then its units."""
    r0 = rows[0]
    ref = "%s %s:%s" % (BOOKS.get(r0["osis"], r0["osis"]), r0["chapter"], r0["verse"])
    # Жанр тут НЕ подається: його немає у вхідному файлі, і гілка A його теж не
    # бачила. Дати одній гілці підказку, якої не мала інша, — зіпсувати порівняння.
    out = ["ВІРШ: %s" % ref,
           "",
           "Огієнко: %s" % (r0["uk_ohienko_verse"] or "—"),
           "Громов : %s" % (r0["uk_gromov_verse"] or "—"),
           "",
           "Слова цього вірша по порядку (%d):" % len(rows), ""]
    for r in rows:
        out.append("uid: %s" % r["uid"])
        out.append("  іврит        : %s" % r["surface"])
        out.append("  транслітерація: %s" % (r["xlit"] or "—"))
        out.append("  morph        : %s   (морфем у слові: %s)"
                   % (r["morph"], r["n_tokens"]))
        out.append("  лема         : %s   (%s)" % (r["head_lemma"], r["head_pos"]))
        out.append("  англійська   : %s" % r["gloss_display"])
        if r["gloss_en"] and r["gloss_en"] != r["gloss_display"]:
            out.append("  англ. по-токенно: %s" % r["gloss_en"])
        if r["gloss_bsb"]:
            out.append("  BSB (фраза)  : %s" % r["gloss_bsb"])
        out.append("")
    out.append("Тепер поверни %d рядків виду `uid<TAB>українська глоса`, "
               "у цьому ж порядку, і нічого більше." % len(rows))
    return "\n".join(out)


def main():
    for p in (IN_UNITS, IN_CONV):
        if not os.path.exists(p):
            sys.exit("missing input: %s" % p)
    units = load_units()
    conventions = open(IN_CONV, encoding="utf-8").read().strip()

    by_verse = {}
    order = []
    for r in units:
        k = (r["osis"], int(r["chapter"]), int(r["verse"]))
        if k not in by_verse:
            by_verse[k] = []
            order.append(k)
        by_verse[k].append(r)
    order.sort()

    # Не rmtree: коли скрипт біжить над змонтованою текою (міст до Mac), видалення
    # заборонене — Operation not permitted. Пишемо поверх, а zip збираємо з явного
    # манифесту тих файлів, які щойно записали, щоб стороннє сміття в кит не
    # потрапило навіть якщо лежить у теці.
    os.makedirs(os.path.join(OUT_DIR, "prompts"), exist_ok=True)
    os.makedirs(os.path.join(OUT_DIR, "output"), exist_ok=True)
    manifest = []

    head = PROMPT_HEAD.format(conventions=conventions, morph_key=MORPH_KEY)
    names = []
    for i, k in enumerate(order, 1):
        name = "%02d_%s_%d-%d.txt" % (i, k[0], k[1], k[2])
        names.append(name)
        rel = os.path.join("prompts", name)
        with open(os.path.join(OUT_DIR, rel), "w", encoding="utf-8") as f:
            f.write(head + "\n" + verse_block(by_verse[k]) + "\n")
        manifest.append(rel)

    # units.tsv for reference and for merge_output.py's completeness check
    with open(os.path.join(OUT_DIR, "units.tsv"), "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(units[0].keys()), delimiter="\t",
                           extrasaction="ignore")
        w.writeheader()
        w.writerows(units)

    with open(os.path.join(OUT_DIR, "conventions.md"), "w", encoding="utf-8") as f:
        f.write(conventions + "\n")
    with open(os.path.join(OUT_DIR, "merge_output.py"), "w", encoding="utf-8") as f:
        f.write(MERGE_PY)
    with open(os.path.join(OUT_DIR, "READ_ME_FIRST.txt"), "w", encoding="utf-8") as f:
        f.write(READ_ME.format(n_prompts=len(order), n_units=len(units),
                               stamp_note="див. mtime файлів кита"))
    with open(os.path.join(OUT_DIR, "output", ".keep"), "w") as f:
        f.write("")
    manifest += ["units.tsv", "conventions.md", "merge_output.py",
                 "READ_ME_FIRST.txt", os.path.join("output", ".keep")]

    # Guard. Checked at the level of WHICH COLUMNS the kit is built from, not by
    # searching the text for suspicious words.
    #
    # The first version searched for the substring "золот" and flagged all 24
    # prompts, because the conventions document says where it came from — "із
    # подвійного проходу по золотому набору". A word-level check cannot separate
    # a leaked answer from a legitimate mention, and most gold answers are common
    # words ("не", "слово", "Бог") that appear in the Ukrainian verse texts the
    # prompt must include. So the invariant is structural: the source file carries
    # no answer column at all, and the assembler reads only whitelisted fields.
    ALLOWED = {"uid", "osis", "chapter", "verse", "slot", "n_tokens", "surface",
               "xlit", "strong", "morph", "head_morph", "head_lemma", "head_pos",
               "gloss_display", "gloss_en", "gloss_bsb",
               "uk_ohienko_verse", "uk_gromov_verse", "genre"}
    problems = []
    have = set(units[0].keys())
    if "uk" in have:
        problems.append("вхідний файл несе колонку `uk` — це відповіді, "
                        "їх у киті бути не може")
    stray = sorted(have - ALLOWED)
    if stray:
        problems.append("невідомі колонки у вхідному файлі: %s — перевір, чи "
                        "серед них немає відповідей" % ", ".join(stray))
    for name in names:
        txt = open(os.path.join(OUT_DIR, "prompts", name), encoding="utf-8").read()
        if "uid: U" not in txt:
            problems.append("%s: немає жодної одиниці" % name)
    total_uids = sum(open(os.path.join(OUT_DIR, "prompts", n),
                          encoding="utf-8").read().count("uid: U") for n in names)
    if total_uids != len(units):
        problems.append("у промптах %d одиниць, а у вибірці %d"
                        % (total_uids, len(units)))
    if problems:
        sys.exit("KIT FAILED:\n  - " + "\n  - ".join(problems))

    with zipfile.ZipFile(OUT_ZIP, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in manifest:
            z.write(os.path.join(OUT_DIR, rel), os.path.join(KIT_NAME, rel))

    print("─── Gemma kit ───")
    print("  віршів (промптів) : %d" % len(order))
    print("  одиниць           : %d" % len(units))
    print("  одиниць у промптах: %d ✓" % total_uids)
    print("  glossary inject   : навмисно відсутній (див. READ_ME_FIRST)")
    print("  розмір промпта    : мін %d, макс %d символів"
          % (min(len(open(os.path.join(OUT_DIR, 'prompts', n), encoding='utf-8').read()) for n in names),
             max(len(open(os.path.join(OUT_DIR, 'prompts', n), encoding='utf-8').read()) for n in names)))
    print("\n  %s  (%.0f КБ)" % (OUT_ZIP, os.path.getsize(OUT_ZIP) / 1024.0))


if __name__ == "__main__":
    main()
