#!/usr/bin/env python3
"""Independent synthetic geometry oracle for the actual aspect_measure CLI.

All expected measurements come from fixture construction, never the matcher.
This is host-only measurement coverage, not game assets or device evidence.
ASPECT_MEASURE may select a disposable mutated tool for negative controls.
"""

import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("ASPECT_MEASURE", ROOT / "tools/aspect_measure.py"))
REF_SIZE = (320, 180)  # Exactly 16:9.
REF_BOX = (37, 46, 100, 60)


def pattern(seed=17):
    """Opaque, asymmetric UI-like detail; neither a solid-color mask nor a grid."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[:60, :100]
    rgb = np.stack(
        [45 + (3 * x + y) % 153, 42 + (x + 4 * y) % 161,
         38 + (5 * x + 2 * y) % 173], axis=2
    )
    rgb = np.clip(rgb + rng.integers(-16, 17, rgb.shape), 0, 255).astype("uint8")
    icon = Image.fromarray(rgb)
    d = ImageDraw.Draw(icon)
    d.rounded_rectangle((3, 4, 96, 56), radius=9, outline=(221, 232, 237), width=3)
    d.ellipse((12, 13, 40, 42), fill=(29, 193, 172), outline=(12, 30, 53), width=2)
    d.polygon([(23, 16), (36, 31), (19, 37)], fill=(246, 131, 57))
    d.rectangle((53, 15, 88, 21), fill=(222, 191, 61))
    d.rectangle((55, 30, 79, 35), fill=(66, 104, 227))
    d.line([(50, 45), (62, 39), (72, 47), (89, 37)], fill=(245, 239, 221), width=2)
    return icon


def background(size, seed):
    rng = np.random.default_rng(seed)
    pixels = rng.integers(15, 55, (size[1], size[0], 3), dtype="uint8")
    image = Image.fromarray(pixels)
    d = ImageDraw.Draw(image)
    d.rectangle((5, 6, size[0] - 6, 17), fill=(39, 57, 75))
    d.line((4, size[1] - 12, size[0] - 5, size[1] - 7), fill=(71, 44, 66), width=3)
    return image


def add_icon(image, icon, box):
    x, y, width, height = box
    image.paste(icon.resize((width, height), Image.Resampling.BILINEAR), (x, y))


def reject_nonfinite(value):
    raise ValueError(f"non-finite JSON value: {value}")


class AspectMeasureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="aspect-measure-test-")
        cls.folder = Path(cls.tmp.name)
        cls.icon = pattern()
        cls.template = cls.folder / "template.png"
        cls.icon.save(cls.template)
        ref = background(REF_SIZE, 11)
        add_icon(ref, cls.icon, REF_BOX)
        cls.reference = cls.folder / "reference.png"
        ref.save(cls.reference)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def target(self, name, size, boxes, icon=None):
        image = background(size, 29)
        for box in boxes:
            add_icon(image, self.icon if icon is None else icon, box)
        path = self.folder / f"{name}.png"
        image.save(path)
        return path

    def invoke(self, target, *, template=None, reference=None, threshold="1"):
        inputs = [reference or self.reference, target, template or self.template]
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.exists()}
        run = subprocess.run(
            [sys.executable, str(TOOL), *map(str, inputs), "--max-stretch-pct", threshold],
            capture_output=True, text=True, timeout=60, check=False,
        )
        for path, digest in before.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest,
                             f"input was changed: {path.name}")
        self.assertIn(run.returncode, (0, 1, 2), run.stderr)
        try:
            result = json.loads(run.stdout, parse_constant=reject_nonfinite)
        except (ValueError, TypeError) as exc:
            self.fail(f"stdout must be one finite JSON object: {exc}; "
                      f"rc={run.returncode}; stdout={run.stdout!r}; stderr={run.stderr!r}")
        self.assertIsInstance(result, dict)
        status = result.get("status")
        self.assertIn(status, ("pass", "fail", "inconclusive", "error"), result)
        self.assertEqual(run.returncode,
                         {"pass": 0, "fail": 1, "inconclusive": 2, "error": 2}[status],
                         result)
        return result

    def close(self, actual, expected, label):
        self.assertIsInstance(actual, (int, float), label)
        self.assertTrue(math.isfinite(actual), label)
        self.assertAlmostEqual(actual, expected, delta=1e-9, msg=label)

    def measurement(self, row, size, box, label):
        self.assertEqual(row["image_size"], list(size), label)
        x, y, width, height = box
        self.assertEqual(row["bbox"], {"x": x, "y": y, "width": width, "height": height}, label)
        self.close(row["aspect_ratio"], width / height, f"{label} aspect")
        for axis, center in enumerate((x + width / 2, y + height / 2)):
            self.close(row["center_px"][axis], center, f"{label} pixel center {axis}")
            self.close(row["center_normalized"][axis], center / size[axis],
                       f"{label} normalized center {axis}")
        confidence = row["confidence"]
        for key in ("correlation", "normalized_rmse"):
            self.assertTrue(math.isfinite(confidence[key]), f"{label} {key}")

    def geometry(self, result, size, box, status, ref_box=REF_BOX, ref_size=REF_SIZE):
        self.assertEqual(result["status"], status, result)
        self.measurement(result["reference"], ref_size, ref_box, "reference")
        self.measurement(result["target"], size, box, "target")
        comparison = result["comparison"]
        expected_stretch = 100 * ((box[2] / box[3]) / (ref_box[2] / ref_box[3]) - 1)
        self.close(comparison["stretch_pct"], expected_stretch, "signed stretch")
        self.close(comparison["absolute_stretch_pct"], abs(expected_stretch), "absolute stretch")
        ref_center = (ref_box[0] + ref_box[2] / 2, ref_box[1] + ref_box[3] / 2)
        target_center = (box[0] + box[2] / 2, box[1] + box[3] / 2)
        for axis in range(2):
            self.close(comparison["center_delta_px"][axis], target_center[axis] - ref_center[axis],
                       f"raw displacement {axis}")
            self.close(comparison["center_delta_normalized"][axis],
                       target_center[axis] / size[axis] - ref_center[axis] / ref_size[axis],
                       f"normalized displacement {axis}")
        self.close(result["thresholds"]["max_stretch_pct"], 1, "explicit threshold")

    def test_translation_on_wide_and_narrow_canvases(self):
        for name, size, box in (
            ("wide", (420, 180), (203, 73, 100, 60)),
            ("narrow", (240, 180), (109, 91, 100, 60)),
        ):
            with self.subTest(name=name):
                target = self.target(name, size, [box])
                self.geometry(self.invoke(target), size, box, "pass")

    def test_noninteger_uniform_scale(self):
        size, box = (420, 180), (181, 61, 125, 75)  # Exactly 1.25 on both axes.
        self.geometry(self.invoke(self.target("uniform", size, [box])), size, box, "pass")

    def test_two_percent_anisotropy_is_red(self):
        size, box = (420, 180), (197, 71, 102, 60)  # 100 -> 102, not rounded 1.02*35.
        self.geometry(self.invoke(self.target("stretch", size, [box])), size, box, "fail")
        # Both screenshots also need automatic scale measurement; using the
        # template's dimensions as the reference measurement would miss this.
        ref_box, scaled_box = (37, 46, 150, 90), (197, 71, 153, 90)
        reference = self.target("scaled_reference", REF_SIZE, [ref_box])
        target = self.target("scaled_stretch", size, [scaled_box])
        self.geometry(self.invoke(target, reference=reference), size, scaled_box, "fail", ref_box)

    def test_missing_duplicate_and_degraded_match_never_pass(self):
        size = (420, 180)
        degraded = self.icon.copy()
        rng = np.random.default_rng(903)
        degraded.paste(Image.fromarray(rng.integers(0, 256, (60, 80, 3), dtype="uint8")), (10, 0))
        cases = [
            self.target("missing", size, []),
            self.target("duplicate", size, [(27, 47, 100, 60), (251, 89, 100, 60)]),
            self.target("degraded", size, [(197, 71, 100, 60)], degraded),
        ]
        for target in cases:
            with self.subTest(name=target.stem):
                result = self.invoke(target)
                self.assertIn(result["status"], ("inconclusive", "error"), result)
                self.assertTrue(result.get("reason"), result)
        missing_reference = self.target("missing_reference", REF_SIZE, [])
        result = self.invoke(self.reference, reference=missing_reference)
        self.assertIn(result["status"], ("inconclusive", "error"), result)
        self.assertTrue(result.get("reason"), result)

    def test_flat_template_never_passes(self):
        flat = self.folder / "flat.png"
        Image.new("RGB", (100, 60), (66, 66, 66)).save(flat)
        result = self.invoke(self.reference, template=flat)
        self.assertIn(result["status"], ("inconclusive", "error"), result)
        self.assertTrue(result.get("reason"), result)

    def test_opaque_rgba_and_rejection_of_transparency(self):
        opaque = self.folder / "opaque.png"
        # A second independently generated image exercises another texture,
        # not just the same solid-color or one-pattern detection shortcut.
        other_icon = pattern(131).transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        other_icon.convert("RGBA").save(opaque)
        other_reference = background(REF_SIZE, 131)
        add_icon(other_reference, other_icon, REF_BOX)
        reference = self.folder / "other_reference.png"
        other_reference.save(reference)
        size, box = (240, 180), (109, 91, 100, 60)
        target = self.target("rgba", size, [box], other_icon)
        self.geometry(self.invoke(target, template=opaque, reference=reference), size, box, "pass")
        alpha = other_icon.convert("RGBA")
        alpha.putpixel((50, 30), (12, 34, 56, 0))
        transparent = self.folder / "transparent.png"
        alpha.save(transparent)
        result = self.invoke(target, template=transparent, reference=reference)
        self.assertEqual(result["status"], "error", result)
        self.assertTrue(result.get("reason"), result)

    def test_uncertain_scale_cannot_report_invented_geometry(self):
        # Off common coarse grids. Conservative inconclusive is allowed; if a
        # measurement is asserted it must be the actual 113x67 (1.19402985%).
        size, box = (420, 180), (184, 77, 113, 67)
        result = self.invoke(self.target("off_grid", size, [box]))
        if result["status"] == "inconclusive":
            self.assertTrue(result.get("reason"), result)
        else:
            self.geometry(result, size, box, "fail")

    def test_near_threshold_cannot_be_rounded_to_false_green(self):
        # Integer 99x60 is exactly -1%: either correctly measure it (the
        # maximum is inclusive) or report precision limits, not a grid snap.
        size, box = (240, 180), (109, 91, 99, 60)
        result = self.invoke(self.target("boundary", size, [box]))
        if result["status"] == "inconclusive":
            self.assertTrue(result.get("reason"), result)
        else:
            self.geometry(result, size, box, "pass")

    def test_smooth_geometry_uncertainty_never_becomes_false_green(self):
        # Smooth but nonflat, opaque synthetic signal. Neighboring dimensions
        # can fit similarly well; choosing one coarse/local optimum is not
        # evidence that the actual 100 -> 102 stretch is below 1%.
        y, x = np.mgrid[:60, :100]
        window = np.sin(np.pi * x / 99) ** 2 * np.sin(np.pi * y / 59) ** 2
        rgb = np.stack([40 + 70 * window, 40 + 70 * window * (0.6 + 0.4 * x / 99),
                        40 + 70 * window * (0.5 + 0.5 * y / 59)], axis=2)
        icon = Image.fromarray(rgb.astype("uint8"))
        template = self.folder / "smooth_template.png"
        icon.save(template)
        size, box = (420, 180), (184, 77, 102, 60)
        paths = []
        for name, canvas_size, icon_box in (("smooth_reference", REF_SIZE, REF_BOX),
                                            ("smooth_target", size, box)):
            image = Image.new("RGB", canvas_size, (40, 40, 40))
            add_icon(image, icon, icon_box)
            path = self.folder / f"{name}.png"
            image.save(path)
            paths.append(path)
        result = self.invoke(paths[1], template=template, reference=paths[0])
        if result["status"] == "inconclusive":
            self.assertTrue(result.get("reason"), result)
        else:
            self.geometry(result, size, box, "fail")

    def test_overlapping_periodic_matches_have_no_unique_center(self):
        # Literal independent reviewer fixture: six identical 20px tiles hold
        # two equally exact five-tile template crops, just 20px apart. They
        # overlap by 80%, but are different possible element locations.
        rng = np.random.default_rng(881)
        tile = rng.integers(15, 240, (20, 20, 3), dtype="uint8")
        icon = Image.fromarray(np.tile(tile, (5, 5, 1)))
        strip = Image.fromarray(np.tile(tile, (5, 6, 1)))
        template = self.folder / "periodic_template.png"
        icon.save(template)
        paths = []
        for name, size, position in (("periodic_reference", (640, 360), (80, 100)),
                                     ("periodic_target", (640, 480), (180, 130))):
            image = Image.new("RGB", size, (9, 14, 23))
            image.paste(strip, position)
            x, y = position
            for shift in (0, 20):
                crop = image.crop((x + shift, y, x + shift + 100, y + 100))
                self.assertEqual(crop.tobytes(), icon.tobytes())
            path = self.folder / f"{name}.png"
            image.save(path)
            paths.append(path)
        result = self.invoke(paths[1], template=template, reference=paths[0])
        self.assertEqual(result["status"], "inconclusive", result)
        self.assertTrue(result.get("reason"), result)

    def test_drawn_badge_twofold_uniform_scale_is_not_stretch(self):
        # Literal independent reviewer fixture: several asymmetric drawn
        # shapes, not the primary textured pattern. Exact 2x BILINEAR scaling
        # changes 100x70 to 200x140, never 200x138.
        icon = Image.new("RGB", (100, 70), (17, 32, 49))
        draw = ImageDraw.Draw(icon)
        draw.polygon([(7, 61), (13, 8), (70, 17), (93, 49)], fill=(226, 184, 31))
        draw.ellipse((31, 23, 61, 53), fill=(24, 99, 178))
        draw.line((4, 42, 92, 15), fill=(209, 34, 123), width=4)
        for i in range(8):
            draw.rectangle((72 + i * 3, 5 + i * 2, 73 + i * 3, 7 + i * 2),
                           fill=(50 + i * 20, 234, 82))
        template = self.folder / "badge_template.png"
        icon.save(template)
        ref_size, ref_box = (640, 360), (71, 92, 100, 70)
        size, box = (780, 360), (231, 127, 200, 140)
        paths = []
        for name, canvas_size, icon_box in (("badge_reference", ref_size, ref_box),
                                            ("badge_target", size, box)):
            image = Image.new("RGB", canvas_size, (9, 14, 23))
            add_icon(image, icon, icon_box)
            path = self.folder / f"{name}.png"
            image.save(path)
            paths.append(path)
        result = self.invoke(paths[1], template=template, reference=paths[0])
        self.geometry(result, size, box, "pass", ref_box, ref_size)

    def test_input_errors_and_required_threshold(self):
        result = self.invoke(self.folder / "does-not-exist.png")
        self.assertEqual(result["status"], "error", result)
        self.assertTrue(result.get("reason"), result)
        command = [sys.executable, str(TOOL), str(self.reference),
                   str(self.reference), str(self.template)]
        for args in ([], ["--max-stretch-pct", "nan"], ["--max-stretch-pct", "-1"]):
            with self.subTest(arguments=args):
                run = subprocess.run(command + args, capture_output=True, text=True,
                                     timeout=10, check=False)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertNotIn('"status": "pass"', run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
