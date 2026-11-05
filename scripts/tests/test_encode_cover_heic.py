"""Тести encode_cover_heic.py і перевірки обкладинок у check_bundle_db.py.

Фікстура відтворює РЕАЛЬНУ форму: `<book>_header.imageset/` з Contents.json у тому
форматі, який лежить у репо (ключ без пробілу перед двокрапкою, без \\n у кінці), PNG
1320×1320 RGBA без справжньої прозорості — як експорт із Figma. Картинка — тонкі
штрихи на градієнті, щоб кодек мав що втрачати (як гравюра), а не пласка заливка.
Без pillow-heif тести кодування пропускаються; тести гейта працюють завжди.
    python3 -m unittest discover scripts/tests
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import check_bundle_db as G  # noqa: E402

try:
    import encode_cover_heic as M  # noqa: E402
    HAVE_HEIF = True
except SystemExit:
    HAVE_HEIF = False

CONTENTS = ('{\n  "images": [\n    {\n      "idiom": "universal",\n      "scale": "1x"\n    },\n'
            '    {\n      "idiom": "universal",\n      "scale": "2x"\n    },\n'
            '    {\n      "filename": "%s",\n      "idiom": "universal",\n      "scale": "3x"\n'
            '    }\n  ],\n  "info": {\n    "author": "xcode",\n    "version": 1\n  }\n}')


def engraving(alpha_min=255, size=(1320, 1320)) -> Image.Image:
    """Синій тон, градієнт «небо → земля» і тонкі косі штрихи — як гравюра Доре.
    Лише Pillow: numpy на Mac немає (і конвеєру він не потрібен)."""
    w, h = size
    im = Image.new("RGBA", size)
    px = ImageDraw.Draw(im)
    for y in range(h):                                         # градієнт
        lum = 40 + 120 * y / h
        px.line([(0, y), (w, y)], fill=(int(lum * 0.45), int(lum * 0.62), int(lum), 255))
    for x0 in range(-h, w, 4):                                 # штрихи кроком 4 px
        px.line([(x0, 0), (x0 + h // 5, h)], fill=(70, 100, 160, 255), width=1)
    if alpha_min < 255:
        im.putpixel((0, 0), (0, 0, 0, alpha_min))
    return im


def make_imageset(root: Path, book="exo", img=None) -> Path:
    d = root / "Assets.xcassets" / f"{book}_header.imageset"
    d.mkdir(parents=True)
    (d / "Contents.json").write_text(CONTENTS % f"{book}.png")
    (img or engraving()).save(d / f"{book}.png")
    return d / f"{book}.png"


@unittest.skipUnless(HAVE_HEIF, "pillow-heif не встановлено")
class Encode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_converts_and_rewrites_only_the_filename(self):
        png = make_imageset(self.root)
        before = (png.parent / "Contents.json").read_text()
        heic, size, psnr = M.encode(png)
        self.assertFalse(png.exists())
        self.assertTrue(heic.exists())
        self.assertLessEqual(size, M.MAX_BYTES)
        self.assertGreaterEqual(psnr, M.MIN_LUMA_PSNR)
        after = (png.parent / "Contents.json").read_text()
        self.assertEqual(after, before.replace('"exo.png"', '"exo.heic"'))   # формат не чіпали
        self.assertEqual(G.cover_problems(str(self.root)), [])

    def test_real_transparency_refused_and_nothing_touched(self):
        png = make_imageset(self.root, img=engraving(alpha_min=0))
        before = (png.parent / "Contents.json").read_text()
        with self.assertRaises(ValueError):
            M.encode(png)
        self.assertTrue(png.exists())
        self.assertFalse(png.with_suffix(".heic").exists())
        self.assertEqual((png.parent / "Contents.json").read_text(), before)

    def test_wrong_size_refused(self):
        png = make_imageset(self.root, img=engraving(size=(880, 880)))
        with self.assertRaises(ValueError):
            M.encode(png)
        self.assertTrue(png.exists())

    def test_cli_nonzero_on_failure(self):
        png = make_imageset(self.root, img=engraving(alpha_min=0))
        self.assertEqual(M.main([str(png)]), 1)


class CoverGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_png_cover_flagged(self):
        # Так виглядали всі 46 обкладинок до 2026-11-05.
        make_imageset(self.root)
        p = G.cover_problems(str(self.root))
        self.assertEqual(len(p), 1, p)
        self.assertIn("не HEIC", p[0])

    def test_oversized_heic_flagged_and_small_one_passes(self):
        d = self.root / "Assets.xcassets" / "psa_header.imageset"
        d.mkdir(parents=True)
        (d / "Contents.json").write_text(CONTENTS % "psa.heic")
        (d / "psa.heic").write_bytes(b"\0" * 1000)
        self.assertEqual(G.cover_problems(str(self.root)), [])            # контроль
        (d / "psa.heic").write_bytes(b"\0" * (G.COVER_MAX_BYTES + 1))
        self.assertIn("psa.heic", G.cover_problems(str(self.root))[0])

    def test_contents_names_missing_file(self):
        d = self.root / "Assets.xcassets" / "gen_header.imageset"
        d.mkdir(parents=True)
        (d / "Contents.json").write_text(CONTENTS % "gen.heic")
        (d / "gen.png").write_bytes(b"x")
        text = " | ".join(G.cover_problems(str(self.root)))
        self.assertIn("не HEIC", text)
        self.assertIn("gen.heic", text)

    def test_other_imagesets_ignored(self):
        d = self.root / "Assets.xcassets" / "calvin.imageset"
        d.mkdir(parents=True)
        (d / "Contents.json").write_text(CONTENTS % "calvin.png")
        (d / "calvin.png").write_bytes(b"x")
        self.assertEqual(G.cover_problems(str(self.root)), [])


if __name__ == "__main__":
    unittest.main()
