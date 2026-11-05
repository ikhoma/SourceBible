#!/usr/bin/env python3
"""encode_cover_heic.py — обкладинка книги PNG (експорт з Figma) → HEIC в Assets.xcassets.

Навіщо. 46 обкладинок у PNG займали 147 МБ в Assets.car (Xcode стискає PNG лише без
втрат, `deepmap2`). HEIC q60 — 32.6 МБ на всі 46 при PSNR яскравості 40–44 дБ
(заміряно 2026-11-05; JPEG тієї ж ваги помітно розмиває штрихи гравюри).

Параметри — ті, якими конвертовано всі обкладинки 2026-11-05:
  • HEVC 4:2:0, 8 біт (Main / Main Still Picture — профілі, які iOS декодує апаратно;
    4:4:4 = Range Extensions, Apple його не заявляє);
  • quality 60;
  • колір sRGB явно в nclx (primaries 1, transfer 13, matrix 6, full range) — Figma
    пише PNG з позначкою sRGB без ICC; без явного nclx колір може зсунутись.

Що робить: для кожного PNG у `<book>_header.imageset/` пише поруч `<book>.heic`,
у Contents.json міняє ЛИШЕ ім'я файлу і видаляє PNG (оригінал лишається в git).
Перевіряє: 1320×1320, без справжньої прозорості, PSNR яскравості ≥ 38 дБ, зсув
середнього кольору ≤ 1.5/255, файл ≤ 1.2 МБ. Будь-який провал — нічого не змінено
для цієї обкладинки, ненульовий код виходу.

Потрібен pillow-heif (requirements-build.txt; тягне Pillow). numpy не потрібен.

    python3 scripts/encode_cover_heic.py SourceBible/Assets.xcassets/exo_header.imageset/exo.png [...]
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

try:
    import pillow_heif
except ImportError:
    sys.exit("✗ немає pillow-heif: python3 -m pip install --user --break-system-packages "
             "-r requirements-build.txt")

pillow_heif.register_heif_opener()

SIZE = (1320, 1320)               # 440 pt @3x
QUALITY = 60
NCLX = dict(color_primaries=1, transfer_characteristics=13, matrix_coefficients=6,
            full_range_flag=1)    # sRGB
MIN_LUMA_PSNR = 38.0              # усі 46 обкладинок: 40.19–44.07; JPEG q60 на Псалмах: 30.93
MAX_COLOR_SHIFT = 1.5             # середнє по каналу, з 255
MAX_BYTES = 1_200_000


# Лише Pillow, без numpy: решта конвеєра numpy не потребує, і на Mac його немає.
# convert("L") — яскравість за ITU-R 601 (0.299/0.587/0.114).
def luma_psnr(ref: Image.Image, out: Image.Image) -> float:
    diff = ImageChops.difference(ref.convert("L"), out.convert("L"))
    mse = ImageStat.Stat(diff).sum2[0] / (diff.size[0] * diff.size[1])
    return float("inf") if mse == 0 else 10 * math.log10(255.0 ** 2 / mse)


def color_shift(ref: Image.Image, out: Image.Image) -> float:
    """Найбільша різниця середнього значення каналу R/G/B, з 255."""
    return max(abs(a - b) for a, b in zip(ImageStat.Stat(ref).mean, ImageStat.Stat(out).mean))


def encode(png: Path) -> tuple[Path, int, float]:
    """Повертає (heic, байти, psnr). Кидає ValueError, якщо обкладинка не проходить."""
    imageset = png.parent
    if not imageset.name.endswith("_header.imageset"):
        raise ValueError(f"{png}: не в <book>_header.imageset")
    contents = imageset / "Contents.json"
    text = contents.read_text()
    if text.count(f'"{png.name}"') != 1:
        raise ValueError(f"{contents}: '{png.name}' згадано не рівно один раз")

    src = Image.open(png)
    if src.size != SIZE:
        raise ValueError(f"{png}: {src.size}, очікувано {SIZE}")
    if src.mode in ("RGBA", "LA") and src.getchannel("A").getextrema()[0] < 255:
        raise ValueError(f"{png}: є справжня прозорість — HEIC 4:2:0 її не збереже")
    im = src.convert("RGB")

    heic = png.with_suffix(".heic")
    im.save(heic, "HEIF", quality=QUALITY, **NCLX)
    try:
        back = Image.open(heic).convert("RGB")
        psnr = luma_psnr(im, back)
        shift = color_shift(im, back)
        size = heic.stat().st_size
        if psnr < MIN_LUMA_PSNR:
            raise ValueError(f"{png}: PSNR яскравості {psnr:.1f} < {MIN_LUMA_PSNR}")
        if shift > MAX_COLOR_SHIFT:
            raise ValueError(f"{png}: зсув кольору {shift:.2f} > {MAX_COLOR_SHIFT}")
        if size > MAX_BYTES:
            raise ValueError(f"{png}: {size:,} Б > {MAX_BYTES:,}")
    except BaseException:
        heic.unlink(missing_ok=True)
        raise

    contents.write_text(text.replace(f'"{png.name}"', f'"{heic.name}"'))
    json.loads(contents.read_text())          # не зламали JSON
    png.unlink()
    return heic, size, psnr


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    failed = 0
    for arg in argv:
        try:
            heic, size, psnr = encode(Path(arg))
            print(f"✓ {heic}  {size / 1e6:.2f} МБ  PSNR(Y) {psnr:.1f} дБ")
        except ValueError as e:
            print(f"✗ {e}", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
