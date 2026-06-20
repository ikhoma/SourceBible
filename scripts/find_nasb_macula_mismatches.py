#!/usr/bin/env python3
"""
find_nasb_macula_mismatches.py

Знаходить систематичні розбіжності між Strong's нумерацією в NASB і Macula
і генерує готові Swift-словники для трьох типів фіксів.

Логіка:
  Для кожного вірша OT:
    - витягує набір Strong's чисел з NASB <S>NNN</S> тегів
    - витягує Strong's base numbers для Macula слів (тільки content words)
    - якщо Macula-слово не знаходиться в NASB-наборі → записує як "промах"
    - кандидатом на заміну вважається NASB-число з найбільшою co-occurrence,
      скоригованою на фоновий рівень (щоб відфільтрувати шум від дуже частих слів)

  Класифікація результатів:
    A. nasbStandardOverride  — NASB використовує стандартний H<9000 замість Macula
    B. nasbExtendedOverride  — NASB використовує H9000+ (proprietary), ще не у мапи
    C. Particles             — слова без NASB-кандидата (тегуються інакше або зовсім)

Запуск (тільки на Mac, sourcebible.db — APFS sparse):
    cd ~/Projects/SourceBible
    python3 scripts/find_nasb_macula_mismatches.py [--top N] [--min-count N] [--show-verses]
"""

import sqlite3
import re
import json
import argparse
import zipfile
import tempfile
from collections import defaultdict
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ROOT   = Path(__file__).parent.parent
NASB_ZIP       = PROJECT_ROOT / "data" / "NASB+.zip"
MAIN_DB        = PROJECT_ROOT / "SourceBible" / "Resources" / "sourcebible.db"
BOOK_MAP_FILE  = PROJECT_ROOT / "scripts" / ".cache" / "book_mapping_NASB.json"
OVERRIDE_SWIFT = PROJECT_ROOT / "SourceBible" / "Services" / "NASBExtendedOverride.swift"

# Відповідає helperStrongs у VerseTabContent.swift + known OT particles
# що NASB системно не тегує як окремі слова.
# Розширений список (більше ніж у Swift) щоб прибрати шум зі звіту.
KNOWN_PARTICLES = {
    "1886",  # הַ definite article   (H1886a)
    "871",   # בְּ inseparable prep  (H871a)
    "3509",  # כְּ inseparable prep  (H3509a)
    "1930",  # לְ inseparable prep   (H1930a)
    "3807",  # לְ variant tagging    (H3807a — missing from Swift helperStrongs!)
    "2050",  # maqaf connectors      (H2050b/c/d)
    "5105",  # waw conjunctive       (H5105b)
    "853",   # אֵת direct object marker — NASB never tags
}

# Morph prefixes що isClickable() відхиляє (копія з ReaderViewModel)
EXCLUDED_MORPH_PREFIXES = ("Td", "Sp", "Sd", "ART-")

# NASB numbers що зустрічаються в тисячах верш і є лише фоновим шумом
# (вони co-occur з усім підряд, не є справжнім кандидатом-замінником)
# Поріг: якщо NASB-число > BACKGROUND_THRESHOLD верш — вважаємо фоновим.
BACKGROUND_THRESHOLD = 2500

# ── Helpers ───────────────────────────────────────────────────────────────────

def open_zipped_sqlite(zip_path: Path):
    """Розпаковує першу SQLite3 з zip у temp-файл → (conn, temp_path)."""
    with zipfile.ZipFile(zip_path) as z:
        name = next(n for n in z.namelist() if n.endswith(".SQLite3") or n.endswith(".db"))
        data = z.read(name)
    tmp = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
    tmp.write(data)
    tmp.close()
    return sqlite3.connect(tmp.name), Path(tmp.name)

def load_book_map(path: Path) -> dict:
    with open(path) as f:
        raw = json.load(f)
    return {int(k): v for k, v in raw.items()}

def extract_nasb_strongs(text: str) -> set:
    return set(re.findall(r'<S>(\d+)</S>', text or ''))

def base_strongs(sid: str) -> str:
    """H341 → '341',  H871a → '871'."""
    s = sid.lstrip('HG')
    return ''.join(c for c in s if c.isdigit())

def is_content_word(mbase: str, morph) -> bool:
    if mbase in KNOWN_PARTICLES:
        return False
    if morph:
        for p in EXCLUDED_MORPH_PREFIXES:
            if morph.startswith(p):
                return False
    return True

def load_existing_override(swift_path: Path) -> set:
    """Повертає set вже відомих NASB extended keys (рядки) з NASBExtendedOverride.swift."""
    if not swift_path.exists():
        return set()
    text = swift_path.read_text()
    # Рядки виду:  "9238": "3887",
    return set(re.findall(r'"(\d{4,5})":\s*"\d+"', text))

# ── Main ──────────────────────────────────────────────────────────────────────

def run(args):
    book_map = load_book_map(BOOK_MAP_FILE)
    existing_extended = load_existing_override(OVERRIDE_SWIFT)
    print(f"Existing nasbExtendedOverride entries: {len(existing_extended)}")

    print(f"Extracting NASB from {NASB_ZIP.name}…")
    nasb_conn, nasb_tmp = open_zipped_sqlite(NASB_ZIP)
    main_conn = sqlite3.connect(str(MAIN_DB))

    ot_macula_ids = {v for k, v in book_map.items() if k < 470}
    print(f"Loaded {len(ot_macula_ids)} OT books")

    # ── 1. НАСБ: Strong's per verse + global frequency per NASB number ────────
    nasb_verse_strongs = {}   # (macula_book_id, ch, vs) → set[str]
    nasb_global_freq   = defaultdict(int)  # nasb_num → кількість верш де зустрічається

    for book_num, ch, vs, text in nasb_conn.execute(
        "SELECT book_number, chapter, verse, text FROM verses WHERE book_number < 470"
    ):
        mid = book_map.get(book_num)
        if mid is None:
            continue
        nums = extract_nasb_strongs(text)
        nasb_verse_strongs[(mid, ch, vs)] = nums
        for n in nums:
            nasb_global_freq[n] += 1

    print(f"Loaded NASB tagging for {len(nasb_verse_strongs)} verses")

    # ── 2. Macula: content words ──────────────────────────────────────────────
    ot_ids_sql = "','".join(ot_macula_ids)
    macula_rows = main_conn.execute(f"""
        SELECT book_id, chapter, verse, strongs_id, morph
        FROM word
        WHERE book_id IN ('{ot_ids_sql}')
          AND strongs_id IS NOT NULL AND strongs_id != ''
        ORDER BY book_id, chapter, verse, position
    """).fetchall()

    nasb_conn.close(); nasb_tmp.unlink(missing_ok=True)
    main_conn.close()

    # ── 3. Агрегація ──────────────────────────────────────────────────────────
    miss_count   = defaultdict(int)        # mbase → кількість промахів
    hit_count    = defaultdict(int)        # mbase → кількість матчів
    cooccurrence = defaultdict(lambda: defaultdict(int))  # mbase → {nasb_num: count}
    examples     = defaultdict(list)       # mbase → [(book, ch, vs, nasb_nums)]

    for book_id, chapter, verse, strongs_id, morph in macula_rows:
        mbase = base_strongs(strongs_id)
        if not mbase or not is_content_word(mbase, morph):
            continue

        nasb_set = nasb_verse_strongs.get((book_id, chapter, verse))
        if nasb_set is None:
            continue

        if mbase in nasb_set:
            hit_count[mbase] += 1
        else:
            miss_count[mbase] += 1
            for nb in nasb_set:
                cooccurrence[mbase][nb] += 1
            if len(examples[mbase]) < 3:
                examples[mbase].append((book_id, chapter, verse, sorted(nasb_set)[:8]))

    # ── 4. Класифікація результатів ───────────────────────────────────────────
    # Для кожного mbase знаходимо "справжній кандидат":
    # — фільтруємо фонові слова (занадто часті у NASB)
    # — беремо число з найбільшою скоригованою co-occurrence

    cat_standard  = []  # (mc, miss_rate, mbase, hc, candidate_nasb, conf)
    cat_extended  = []  # те саме, але candidate_nasb >= 9000
    cat_particles = []  # без кандидата або тільки фонові слова

    for mbase, mc in miss_count.items():
        hc = hit_count.get(mbase, 0)
        total = mc + hc
        miss_rate = mc / total if total > 0 else 1.0
        if mc < args.min_count or miss_rate < 0.5:
            continue

        # Кандидати — NASB числа, скориговані на фоновий рівень
        co = cooccurrence[mbase]
        # Прибираємо фонові числа (YHWH, say, all, who...)
        filtered = {nb: cnt for nb, cnt in co.items()
                    if nasb_global_freq.get(nb, 0) <= BACKGROUND_THRESHOLD}
        # Якщо після фільтрації нічого не залишилось → particle
        if not filtered:
            cat_particles.append((mc, miss_rate, mbase, hc))
            continue

        # Топ-3 після фільтрації
        top = sorted(filtered.items(), key=lambda x: -x[1])[:3]
        candidate, best_cnt = top[0]
        total_filtered = sum(v for _, v in top)
        conf = best_cnt / total_filtered if total_filtered > 0 else 0

        # Мінімальна впевненість: кандидат домінує в co-occurrence
        if conf < 0.4 or best_cnt < args.min_count:
            cat_particles.append((mc, miss_rate, mbase, hc))
            continue

        cand_int = int(candidate)
        if cand_int >= 9000:
            cat_extended.append((mc, miss_rate, mbase, hc, candidate, conf, top))
        else:
            cat_standard.append((mc, miss_rate, mbase, hc, candidate, conf, top))

    cat_standard.sort(key=lambda x: -x[0])
    cat_extended.sort(key=lambda x: -x[0])
    cat_particles.sort(key=lambda x: -x[0])

    # ── 5. Вивід ──────────────────────────────────────────────────────────────
    SEP = "=" * 80
    sep = "-" * 80

    # ── A. Standard H→H mismatches ────────────────────────────────────────────
    print(f"\n{SEP}")
    print("A. nasbStandardOverride — NASB uses a different standard H-number than Macula")
    print(f"   Fix: add NASB_num → Macula_base mapping so isClickable() accepts the word")
    print(SEP)
    hdr = f"{'Macula':<10} {'NASB uses':<12} {'Conf':>6} {'Misses':>7} {'Hits':>6} {'Miss%':>7}  Alternatives"
    print(hdr); print(sep)
    for mc, mr, mbase, hc, cand, conf, top in cat_standard[:args.top]:
        alts = "  ".join(f"H{nb}(×{c})" for nb, c in top[1:3])
        print(f"H{mbase:<8}  H{cand:<10}  {conf*100:>5.0f}%  {mc:>6}  {hc:>6}  {mr*100:>6.1f}%  {alts}")

    if args.show_verses:
        print()
        for mc, mr, mbase, hc, cand, conf, top in cat_standard[:5]:
            print(f"  H{mbase} → NASB H{cand}:")
            for book, ch, vs, nums in examples.get(mbase, []):
                print(f"    {book} {ch}:{vs}  {nums}")

    # ── B. Extended number gaps ────────────────────────────────────────────────
    new_extended = [(mc, mr, mbase, hc, cand, conf, top)
                    for mc, mr, mbase, hc, cand, conf, top in cat_extended
                    if cand not in existing_extended]
    already = [(mc, mr, mbase, hc, cand, conf, top)
               for mc, mr, mbase, hc, cand, conf, top in cat_extended
               if cand in existing_extended]

    print(f"\n{SEP}")
    print("B. nasbExtendedOverride GAPS — Macula word maps to NASB H9000+ not yet in override")
    print(f"   Already mapped: {len(already)}   New gaps found: {len(new_extended)}")
    print(SEP)
    print(hdr); print(sep)
    for mc, mr, mbase, hc, cand, conf, top in new_extended[:args.top]:
        alts = "  ".join(f"H{nb}(×{c})" for nb, c in top[1:3])
        print(f"H{mbase:<8}  H{cand:<10}  {conf*100:>5.0f}%  {mc:>6}  {hc:>6}  {mr*100:>6.1f}%  {alts}")

    if args.show_verses and new_extended:
        print()
        for mc, mr, mbase, hc, cand, conf, top in new_extended[:5]:
            print(f"  H{mbase} ← NASB H{cand}:")
            for book, ch, vs, nums in examples.get(mbase, []):
                print(f"    {book} {ch}:{vs}  {nums}")

    # ── C. Particles (no clear candidate) ─────────────────────────────────────
    print(f"\n{SEP}")
    print("C. Likely particles / function words — no specific NASB candidate found")
    print(f"   These might need morph-exclusion fixes or are expected non-clickable")
    print(SEP)
    print(f"{'Macula':<12} {'Misses':>7} {'Hits':>6} {'Miss%':>7}")
    print(sep)
    for mc, mr, mbase, hc in cat_particles[:args.top]:
        print(f"H{mbase:<10}  {mc:>6}  {hc:>6}  {mr*100:>6.1f}%")

    # ── Swift output ──────────────────────────────────────────────────────────
    print(f"\n{SEP}")
    print("SWIFT — nasbStandardOverride (new file or extension)")
    print(SEP)
    print("// Maps NASB standard H-numbers to Macula equivalents.")
    print("// Handles cases where NASB and Macula assign different but related")
    print("// Strong's numbers to the same Hebrew word form.")
    print("extension ReaderViewModel {")
    print("    static let nasbStandardOverride: [String: String] = [")
    for mc, mr, mbase, hc, cand, conf, top in cat_standard:
        if mr < 0.9 or conf < 0.6:
            continue  # only high-confidence entries in Swift output
        alts_comment = ", ".join(f"H{nb}(×{c})" for nb, c in top)
        print(f'        "{cand}": "{mbase}",  '
              f'// NASB H{cand} → Macula H{mbase}  miss={mc}× conf={conf:.0%}  [{alts_comment}]')
    print("    ]")
    print("}")

    print(f"\n{SEP}")
    print("SWIFT — additions to nasbExtendedOverride (NASBExtendedOverride.swift)")
    print(SEP)
    print("// Paste these into the existing dictionary in NASBExtendedOverride.swift")
    for mc, mr, mbase, hc, cand, conf, top in new_extended:
        if conf < 0.6:
            continue
        alts_comment = ", ".join(f"H{nb}(×{c})" for nb, c in top)
        print(f'        "{cand}": "{mbase}",  '
              f'// NASB H{cand} → Macula H{mbase}  miss={mc}× conf={conf:.0%}  [{alts_comment}]')

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n{SEP}")
    high_conf_std = sum(1 for mc, mr, mbase, hc, cand, conf, top in cat_standard
                        if mr >= 0.9 and conf >= 0.6)
    high_conf_ext = sum(1 for mc, mr, mbase, hc, cand, conf, top in new_extended
                        if conf >= 0.6)
    print(f"Summary:")
    print(f"  A. Standard H→H mismatches:        {len(cat_standard):>4}  ({high_conf_std} high-confidence)")
    print(f"  B. Extended override gaps (new):    {len(new_extended):>4}  ({high_conf_ext} high-confidence)")
    print(f"  B. Extended already mapped:         {len(already):>4}")
    print(f"  C. Particles / no clear candidate:  {len(cat_particles):>4}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Find NASB ↔ Macula Strong's mismatches")
    parser.add_argument("--top",        type=int, default=30,  help="Rows per section (default 30)")
    parser.add_argument("--min-count",  type=int, default=5,   help="Min verse count (default 5)")
    parser.add_argument("--show-verses",action="store_true",   help="Show example verses")
    args = parser.parse_args()
    run(args)
