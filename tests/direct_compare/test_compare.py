#!/usr/bin/env python3
"""Independent PNG fixtures and hand-calculated comparison regressions."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/direct_compare/direct_compare.py"
BINARY = Path(os.environ["DIRECT_COMPARE_CODEC"]).resolve()
spec = importlib.util.spec_from_file_location("direct_compare", TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def png(w, h, pixel, channels=3):
    # Independent producer: filter 0, no ImageIO encoder.
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\0" + bytes(v for x in range(w) for v in pixel(x, y)) for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if channels == 3 else 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def decode_rgb(path):
    # Independent heatmap decoder verifies top-left coordinates and all PNG filters.
    data = path.read_bytes()
    offset, packed = 8, b""
    while offset < len(data):
        length, kind = struct.unpack_from(">I4s", data, offset)
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            w, h, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            assert depth == 8 and interlace == 0 and color in (2, 6)
            channels = 3 if color == 2 else 4
        if kind == b"IDAT":
            packed += payload
        offset += length + 12
    rows, previous, raw, pos = [], [0] * (w * channels), zlib.decompress(packed), 0
    for _ in range(h):
        kind, pos = raw[pos], pos + 1
        scan = list(raw[pos:pos + w * channels])
        pos += w * channels
        for i in range(len(scan)):
            a = scan[i - channels] if i >= channels else 0
            b, c = previous[i], previous[i - channels] if i >= channels else 0
            if kind < 4:
                predictor = (0, a, b, (a + b) // 2)[kind]
            else:
                assert kind == 4
                p = a + b - c
                d = (abs(p - a), abs(p - b), abs(p - c))
                predictor = (a, b, c)[d.index(min(d))]
            scan[i] = (scan[i] + predictor) & 255
        rows.append([tuple(scan[i:i + 3]) for i in range(0, len(scan), channels)])
        previous = scan
    return rows


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="case-", dir=os.environ["DIRECT_COMPARE_TEST_ROOT"])
        self.root, self.counter = Path(self.temp.name), 0

    def tearDown(self):
        self.temp.cleanup()

    def run_dir(self, name, frames=None, size=(8, 8), mode="generic"):
        directory = self.root / name
        directory.mkdir()
        frames = frames if frames is not None else [(1, lambda x, y: (255,)*3)]
        listed = []
        for frame_id, pixels in frames:
            filename = f"f_{frame_id}.png"
            (directory / filename).write_bytes(png(*size, pixels))
            listed.append(dict(id=frame_id, file=filename))
        self.save(directory, dict(version=1, game="synthetic", build="fixed-build", route="fixed-route",
                                  capture=name, mode=mode, frames=listed))
        return directory

    def save(self, directory, manifest):
        (directory / "direct_compare.json").write_text(json.dumps(manifest), encoding="utf-8")

    def change(self, directory, mutate):
        m = json.loads((directory / "direct_compare.json").read_text())
        mutate(m)
        self.save(directory, m)

    def call(self, a, b, *options, expected=0, out=None, calibrated=True):
        self.counter += 1
        out = out or self.root / f"output-{self.counter}"
        if calibrated and "--calibrate" not in options and "--calibration" not in options:
            raw = (a / "f_1.png").read_bytes() if (a / "f_1.png").exists() else b""
            size = struct.unpack_from(">II", raw, 16) if raw.startswith(b"\x89PNG") else (8, 8)
            manifest = json.loads((a / "direct_compare.json").read_text())
            ids = sorted({f["id"] for run in [a,b] for f in json.loads((run/"direct_compare.json").read_text())["frames"] if type(f["id"]) is int and f["id"] >= 0}) or [1]
            frames = [(i, lambda x,y:(255,)*3) for i in ids]
            c = self.run_dir(f"control-a-{self.counter}", frames, size=size, mode=manifest["mode"])
            d = self.run_dir(f"control-b-{self.counter}", frames, size=size, mode=manifest["mode"])
            options = (*options, "--calibrate", c, d)
        r = subprocess.run([sys.executable, str(TOOL), str(a), str(b), "--out", str(out),
                            "--codec", str(BINARY), *map(str, options)], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, expected, r.stdout + r.stderr)
        if (out / "report.json").exists():
            return json.loads((out / "report.json").read_text()), out
        self.assertFalse(out.exists(), "invalid input created output")
        self.assertEqual(json.loads(r.stderr)["classification"], "未验证")
        return None, out

    def test_identical_same_mode_and_inputs_unchanged(self):
        a, b = self.run_dir("左侧 输入"), self.run_dir("右侧 输入")
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for d in [a, b] for p in d.iterdir()}
        r, out = self.call(a, b)
        self.assertEqual(r["classification"], "一致")
        self.assertEqual(r["comparisonKind"], "same-mode-evaluation")
        self.assertEqual(r["pairs"][0]["metrics"]["ssimRGB"], 1)
        self.assertEqual(r["pairs"][0]["metrics"]["mae"], 0)
        self.assertEqual(decode_rgb(out / r["pairs"][0]["heatmap"])[0][0], (0, 0, 0))
        self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})

    def test_black_patch_hand_ssim_and_heatmap(self):
        a = self.run_dir("a")
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3 if x < 2 and y < 2 else (255,)*3)], mode="direct")
        r, out = self.call(a, b, expected=1)
        m = r["pairs"][0]["metrics"]
        self.assertEqual((m["changedPixels"], m["changedFraction"], m["mae"]), (4, 1/16, 255/16))
        # Constant A=255. B has 60 white + 4 black; variance B=255^2*15/256, covariance=0.
        mu, var = 255 * 15/16, 255**2 * 15/256
        expected = (2*255*mu + 6.5025)*58.5225 / ((255**2 + mu**2 + 6.5025)*(var + 58.5225))
        self.assertAlmostEqual(m["ssimRGB"], expected, places=12)
        self.assertEqual(r["classification"], "局部不一致")
        heat = decode_rgb(out / r["pairs"][0]["heatmap"])
        self.assertEqual(heat[0][0], (255, 0, 0))
        self.assertEqual(heat[1][1], (255, 0, 0))
        self.assertEqual(heat[7][7], (0, 0, 0))
        self.assertEqual(sum(p == (255, 0, 0) for row in heat for p in row), 4)

    def test_small_black_patch_not_diluted_by_full_frame(self):
        a = self.run_dir("a", size=(128, 128))
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3 if x < 2 and y < 2 else (255,)*3)], size=(128, 128))
        r, _ = self.call(a, b, expected=1)
        m = r["pairs"][0]["metrics"]
        self.assertLess(m["changedFraction"], .001)
        self.assertGreater(m["ssimRGB"], .995)
        self.assertEqual(m["badBlocks"], 1)
        self.assertEqual(r["classification"], "局部不一致")

    def test_blackout_hand_ssim(self):
        a = self.run_dir("a")
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3)])
        r, _ = self.call(a, b, expected=1)
        self.assertEqual(r["classification"], "大面积不一致")
        self.assertEqual(r["pairs"][0]["metrics"]["mae"], 255)
        self.assertAlmostEqual(r["pairs"][0]["metrics"]["ssimRGB"], 6.5025/(65025+6.5025), places=14)

    def test_brightness_ssim_alone_false_green(self):
        a = self.run_dir("a", [(1, lambda x, y: (100,)*3)])
        b = self.run_dir("b", [(1, lambda x, y: (110,)*3)])
        r, _ = self.call(a, b, expected=1)
        m = r["pairs"][0]["metrics"]
        self.assertAlmostEqual(m["ssimRGB"], (22000+6.5025)/(22100+6.5025), places=14)
        self.assertGreater(m["ssimRGB"], .995)
        self.assertEqual(m["changedPixels"], 64)
        self.assertEqual(r["classification"], "大面积不一致")

    def test_checkerboard_negative_covariance(self):
        a = self.run_dir("a", [(1, lambda x, y: (255,)*3 if (x+y)%2 else (0,)*3)])
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3 if (x+y)%2 else (255,)*3)])
        r, _ = self.call(a, b, expected=1)
        self.assertAlmostEqual(r["pairs"][0]["metrics"]["ssimRGB"],
                               (-32512.5+58.5225)/(32512.5+58.5225), places=14)

    def test_edge_windows_area_weighting(self):
        a = self.run_dir("a", size=(9, 9))
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3 if x == 8 and y == 8 else (255,)*3)], size=(9, 9))
        r, out = self.call(a, b, expected=1)
        m = r["pairs"][0]["metrics"]
        block_data = (out/r["pairs"][0]["blocksFile"]).read_bytes()
        blocks = json.loads(block_data)
        self.assertEqual(hashlib.sha256(block_data).hexdigest(), r["pairs"][0]["blocksSHA256"])
        self.assertNotIn("blocks", m)
        self.assertEqual([(v["width"], v["height"]) for v in blocks], [(8,8), (1,8), (8,1), (1,1)])
        self.assertAlmostEqual(m["ssimRGB"], (80+6.5025/(65025+6.5025))/81, places=14)
        self.assertEqual(decode_rgb(out/r["pairs"][0]["heatmap"])[8][8], (255, 0, 0))

    def test_color_only_change_channel_mae(self):
        a = self.run_dir("a", [(1, lambda x, y: (255, 0, 0))])
        b = self.run_dir("b", [(1, lambda x, y: (0, 0, 255))])
        r, _ = self.call(a, b, expected=1)
        self.assertEqual(r["pairs"][0]["metrics"]["mae"], 170)
        self.assertEqual(r["pairs"][0]["metrics"]["changedPixels"], 64)

    def test_pixel_delta_strict_boundary(self):
        a = self.run_dir("a", [(1, lambda x, y: (100,)*3)])
        b = self.run_dir("b", [(1, lambda x, y: (108,)*3)])
        r, _ = self.call(a, b, "--min-ssim", .9)
        self.assertEqual(r["pairs"][0]["metrics"]["changedPixels"], 0)
        r, _ = self.call(a, b, "--min-ssim", .9, "--pixel-delta", 7, expected=1)
        self.assertEqual(r["pairs"][0]["metrics"]["changedPixels"], 64)

    def test_missing_extra_frames_incomplete(self):
        a = self.run_dir("a", [(1, lambda x, y: (255,)*3), (2, lambda x, y: (0,)*3)])
        b = self.run_dir("b")
        r, _ = self.call(a, b, expected=2)
        self.assertEqual(r["classification"], "未验证")
        self.assertEqual(r["pairs"][1]["alignment"], "missing-frame-id")
        r, _ = self.call(b, a, expected=2)
        self.assertEqual(r["coverage"]["unusedRightFrameIDs"], [2])

    def test_swapped_content_not_sorted_to_green(self):
        a = self.run_dir("a", [(1, lambda x, y: (255,)*3), (2, lambda x, y: (0,)*3)])
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3), (2, lambda x, y: (255,)*3)])
        r, _ = self.call(a, b, expected=1)
        self.assertEqual(r["classification"], "大面积不一致")

    def test_one_bad_frame_not_hidden_by_sequence_mean(self):
        a = self.run_dir("a", [(i, lambda x, y: (255,)*3) for i in range(1, 5)])
        b = self.run_dir("b", [(i, (lambda x, y: (0,)*3) if i == 3 else (lambda x, y: (255,)*3)) for i in range(1, 5)])
        r, _ = self.call(a, b, expected=1)
        self.assertEqual(r["classification"], "大面积不一致")

    def test_feature_known_drift(self):
        a = self.run_dir("a", [(10, lambda x, y: (30,)*3), (20, lambda x, y: (220,)*3)])
        b = self.run_dir("b", [(13, lambda x, y: (30,)*3), (24, lambda x, y: (220,)*3)])
        r, _ = self.call(a, b, "--align", "feature", "--radius", 20)
        self.assertEqual([(p["leftFrame"], p["rightFrame"]) for p in r["pairs"]], [(10,13), (20,24)])
        self.assertTrue(all(p["featureDistance"] == 0 for p in r["pairs"]))

    def test_feature_blank_ambiguity_not_green(self):
        a = self.run_dir("a", [(10, lambda x, y: (0,)*3), (20, lambda x, y: (0,)*3)])
        b = self.run_dir("b", [(13, lambda x, y: (0,)*3), (24, lambda x, y: (0,)*3)])
        r, _ = self.call(a, b, "--align", "feature", "--radius", 30, expected=2)
        self.assertEqual(r["coverage"]["paired"], 0)
        self.assertEqual(r["pairs"][0]["alignment"], "ambiguous-feature")

    def test_feature_distance_radius_reject(self):
        a = self.run_dir("a")
        b = self.run_dir("b", [(1, lambda x, y: (0,)*3)])
        r, _ = self.call(a, b, "--align", "feature", "--radius", 5, expected=2)
        self.assertEqual(r["pairs"][0]["alignment"], "feature-too-far")
        self.change(b, lambda m: m["frames"][0].update(id=50))
        r, _ = self.call(a, b, "--align", "feature", "--radius", 5, expected=2)
        self.assertEqual(r["pairs"][0]["alignment"], "no-candidate")

    def test_feature_no_cross_back_or_reuse(self):
        a = self.run_dir("a", [(1, lambda x, y: (0,)*3), (2, lambda x, y: (255,)*3)])
        b = self.run_dir("b", [(1, lambda x, y: (255,)*3), (2, lambda x, y: (0,)*3)])
        r, _ = self.call(a, b, "--align", "feature", "--radius", 5, expected=2)
        self.assertEqual(r["pairs"][0]["rightFrame"], 2)
        self.assertIsNone(r["pairs"][1]["rightFrame"])

    def test_invalid_thresholds(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        for options in [("--pixel-delta", -1), ("--pixel-delta", 255), ("--min-ssim", "nan"),
                        ("--equal-fraction", .5, "--large-fraction", .1), ("--block-size", 0),
                        ("--feature-margin", 0), ("--large-fraction", 1.1), ("--min-ssim", "inf"),
                        ("--align", "feature"), ("--radius", 2)]:
            with self.subTest(options=options):
                self.call(a, b, *options, expected=2)

    def test_identity_and_self_comparison(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        self.call(a, a, expected=2)
        defaults = dict(game="synthetic", build="fixed-build", route="fixed-route", capture="b")
        for key in defaults:
            self.change(b, lambda m, k=key: m.update({k: "a" if k == "capture" else "other"}))
            self.call(a, b, expected=2)
            self.change(b, lambda m, k=key: m.update({k: defaults[k]}))

    def test_frame_order_duplicate_empty_boolean(self):
        a = self.run_dir("a", [(1, lambda x, y: (0,)*3), (2, lambda x, y: (255,)*3)])
        b = self.run_dir("b")
        original = json.loads((a/"direct_compare.json").read_text())
        for frames in [list(reversed(original["frames"])), [original["frames"][0]]*2, [],
                       [dict(id=True, file="f_1.png")], [dict(id=-1, file="f_1.png")],
                       [dict(id=1, file="f_1.png"), dict(id=2, file="f_1.png")]]:
            self.save(a, dict(original, frames=frames))
            self.call(a, b, expected=2)

    def test_size_difference_and_size_change(self):
        a, b = self.run_dir("a"), self.run_dir("b", size=(9, 8))
        self.call(a, b, expected=2)
        (a/"f_2.png").write_bytes(png(7, 8, lambda x, y: (0,)*3))
        self.change(a, lambda m: m["frames"].append(dict(id=2, file="f_2.png")))
        self.call(a, b, expected=2)

    def test_missing_bad_truncated_crc_png(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        good = (b/"f_1.png").read_bytes()
        for bad in [b"not png", good[:-8], good[:40]+bytes([good[40]^1])+good[41:], good+b"junk"]:
            (b/"f_1.png").write_bytes(bad)
            self.call(a, b, expected=2)
        (b/"f_1.png").unlink()
        self.call(a, b, expected=2)

    def test_bad_deflate_valid_crc_and_decoded_size(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind+payload) & 0xffffffff)
        header = png(8, 8, lambda x, y: (0,)*3)[:33]
        for compressed in [b"broken-deflate", zlib.compress(b"short"), zlib.compress(b"\x05"+b"\0"*199),
                           zlib.compress(b"\0"*200)+b"trailing"]:
            (b/"f_1.png").write_bytes(header+chunk(b"IDAT", compressed)+chunk(b"IEND", b""))
            self.call(a, b, expected=2)

    def test_transparent_16bit_png(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        (b/"f_1.png").write_bytes(png(8, 8, lambda x, y: (255,0,0,128), channels=4))
        self.call(a, b, expected=2)
        data = bytearray(png(8, 8, lambda x, y: (0,)*3))
        data[24] = 16
        data[29:33] = struct.pack(">I", zlib.crc32(data[12:29]) & 0xffffffff)
        (b/"f_1.png").write_bytes(data)
        self.call(a, b, expected=2)

    def test_path_escape_and_symlink(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        self.change(b, lambda m: m["frames"][0].update(file="../a/f_1.png"))
        self.call(a, b, expected=2)
        (b/"link.png").symlink_to(a/"f_1.png")
        self.change(b, lambda m: m["frames"][0].update(file="link.png"))
        self.call(a, b, expected=2)

    def test_existing_output_preserved_and_overlap(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        target = self.root/"existing"
        target.mkdir()
        marker = target/"keep"
        marker.write_text("keep")
        c, d = self.run_dir("ca"), self.run_dir("cb")
        r = subprocess.run([sys.executable, str(TOOL), str(a), str(b), "--out", str(target),
                            "--codec", str(BINARY), "--calibrate", str(c), str(d)], capture_output=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("output already exists", json.loads(r.stderr)["error"])
        self.assertEqual(marker.read_text(), "keep")
        self.call(a, b, out=a/"derived", expected=2)

    def test_duplicate_json_and_unknown_fields(self):
        a, b = self.run_dir("a"), self.run_dir("b")
        p = b/"direct_compare.json"
        raw = p.read_text()
        p.write_text(raw.replace('"version": 1', '"version": 2, "version": 1'))
        self.call(a, b, expected=2)
        p.write_text(raw)
        self.change(b, lambda m: m.update(unrecognized=True))
        self.call(a, b, expected=2)

    def test_index_numeric_order_no_input_write(self):
        a = self.root/"index"
        (a/"rec").mkdir(parents=True)
        for name in ["f_20.png", "f_3.png"]:
            (a/"rec"/name).write_bytes(png(1, 1, lambda x, y: (255,)*3))
        r = subprocess.run([sys.executable, str(TOOL), "index", str(a), "--game", "g", "--build", "b",
                            "--route", "r", "--capture", "c", "--mode", "generic"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([f["id"] for f in json.loads(r.stdout)["frames"]], [3,20])
        self.assertFalse((a/"direct_compare.json").exists())

    def test_native_top_left_and_opaque_rgba(self):
        data = png(2, 2, lambda x, y: (255,0,0,255) if x == 0 and y == 0 else (0,0,255,255), channels=4)
        self.assertEqual(module.codec(BINARY, "inspect", [data])["topLeftRGB"], [255,0,0])

    def test_exact_classification_boundaries(self):
        p = dict(module.DEFAULTS)
        self.assertEqual(module.classify(dict(changedFraction=.001, ssimRGB=.995), p), "一致")
        self.assertEqual(module.classify(dict(changedFraction=.00101, ssimRGB=1), p), "局部不一致")
        self.assertEqual(module.classify(dict(changedFraction=.25, ssimRGB=1), p), "大面积不一致")
        self.assertEqual(module.classify(dict(changedFraction=0, ssimRGB=.994), p), "局部不一致")


    def controls(self, size=(32, 16), change=lambda x, y: x < 8):
        c = self.run_dir("control-a", [(1, lambda x,y: (40,)*3 if change(x,y) else (130,)*3)], size=size, mode="direct")
        d = self.run_dir("control-b", [(1, lambda x,y: (220,)*3 if change(x,y) else (130,)*3)], size=size, mode="direct")
        return c, d

    def test_dynamic_heldout_static_metrics_and_heat(self):
        c, d = self.controls()
        a = self.run_dir("a", [(1, lambda x,y: (40,)*3 if x<8 else (130,)*3)], size=(32,16))
        b = self.run_dir("b", [(1, lambda x,y: (220,)*3 if x<8 else (130,)*3)], size=(32,16), mode="direct")
        r, out = self.call(a,b,"--calibrate",c,d)
        m = r["pairs"][0]["metrics"]
        self.assertEqual((m["staticPixels"],m["changedFraction"],m["ssimRGB"],m["mae"]),(384,0,1,0))
        self.assertEqual(m["rawMetrics"]["changedFraction"],.25)
        self.assertEqual(m["rawMetrics"]["mae"],45)
        self.assertEqual(r["calibration"]["maskedFraction"],.25)
        self.assertEqual(decode_rgb(out/r["pairs"][0]["heatmap"])[0][0],(0,0,64))
        self.assertEqual(decode_rgb(out/"dynamic-mask.png")[0][0],(0,0,255))
        cal=json.loads((out/"calibration.json").read_text())
        self.assertEqual(cal["coverage"]["paired"],1)
        self.assertEqual(cal["identities"][0]["mode"],"direct")
        self.assertEqual(cal["pairs"][0]["alignment"],"exact-frame-id")

    def test_missing_calibration_never_defaults_green(self):
        a,b=self.run_dir("a"),self.run_dir("b",mode="direct")
        self.call(a,b,calibrated=False,expected=2)

    def test_dynamic_does_not_hide_static_fault(self):
        c,d=self.controls()
        a=self.run_dir("a",[(1,lambda x,y:(130,)*3)],size=(32,16))
        b=self.run_dir("b",[(1,lambda x,y:(230,)*3 if x>=24 else (130,)*3)],size=(32,16),mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d,expected=1)
        self.assertEqual(r["pairs"][0]["metrics"]["changedFraction"],1/3)
        self.assertEqual(r["classification"],"大面积不一致")

    def test_mask_area_cap_and_exact_half(self):
        for width,expected in [(16,0),(24,2),(32,2)]:
            with self.subTest(width=width):
                c=self.run_dir(f"ca{width}",[(1,lambda x,y:(40,)*3)],size=(32,16),mode="direct")
                d=self.run_dir(f"cb{width}",[(1,lambda x,y:(220,)*3 if x<width else (40,)*3)],size=(32,16),mode="direct")
                a=self.run_dir(f"a{width}",size=(32,16));b=self.run_dir(f"b{width}",size=(32,16),mode="direct")
                r,_=self.call(a,b,"--calibrate",c,d,expected=expected)
                self.assertEqual(r["calibration"]["maskedFraction"],width/32)
                if expected: self.assertEqual(r["classification"],"未验证")
                if width==32:
                    self.assertIsNone(r["pairs"][0]["metrics"]["ssimRGB"])
                    self.assertEqual(r["observedClassification"],"未验证")

    def test_partial_edge_mask_area_not_block_count(self):
        c,d=self.controls((9,9),lambda x,y:x==8 and y==8)
        a,b=self.run_dir("a",size=(9,9)),self.run_dir("b",size=(9,9),mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d)
        self.assertEqual(r["calibration"]["maskedFraction"],1/81)
        self.assertEqual(r["calibration"]["staticPixels"],80)

    def test_missing_center_half_independent_of_ssim(self):
        texture=lambda x,y:((100 if (x+y)%2 else 200),)*3
        a=self.run_dir("a",[(1,texture)],size=(32,16))
        b=self.run_dir("b",[(1,lambda x,y:(0,)*3 if 8<=x<24 else texture(x,y))],size=(32,16),mode="direct")
        r,out=self.call(a,b,expected=1)
        m=r["pairs"][0]["metrics"]
        self.assertEqual((m["missingBlocks"],m["missingPixels"],m["missingFraction"]),(4,256,.5))
        self.assertEqual(r["classification"],"缺内容")
        blocks=json.loads((out/r["pairs"][0]["blocksFile"]).read_text())
        self.assertAlmostEqual(blocks[1]["leftLumaVariance"],2500,places=8)
        self.assertEqual((blocks[1]["leftNonBlackFraction"],blocks[1]["rightNonBlackFraction"]),(1,0))
        self.assertEqual(decode_rgb(out/r["pairs"][0]["missingHeatmap"])[0][8],(0,255,0))

    def test_brightness_097_is_not_missing(self):
        a=self.run_dir("a",[(1,lambda x,y:(100 if (x+y)%2 else 200,)*3)],size=(32,16))
        b=self.run_dir("b",[(1,lambda x,y:(97 if (x+y)%2 else 194,)*3)],size=(32,16),mode="direct")
        r,_=self.call(a,b)
        self.assertEqual(r["pairs"][0]["metrics"]["missingBlocks"],0)

    def test_missing_in_masked_region_still_detected_both_directions(self):
        c,d=self.controls()
        texture=lambda x,y:(100 if (x+y)%2 else 200,)*3
        a=self.run_dir("a",[(1,texture)],size=(32,16))
        b=self.run_dir("b",[(1,lambda x,y:(0,)*3 if x<8 else texture(x,y))],size=(32,16),mode="direct")
        for left,right in [(a,b),(b,a)]:
            r,_=self.call(left,right,"--calibrate",c,d,expected=1)
            self.assertEqual(r["classification"],"缺内容")
            self.assertEqual(r["pairs"][0]["metrics"]["staticClassification"],"一致")
            self.assertEqual(r["pairs"][0]["metrics"]["missingFraction"],.25)

    def test_calibration_cannot_learn_one_sided_missing(self):
        texture=lambda x,y:(100 if (x+y)%2 else 200,)*3
        c=self.run_dir("ca",[(1,texture)],size=(32,16),mode="direct")
        d=self.run_dir("cb",[(1,lambda x,y:(0,)*3 if x<8 else texture(x,y))],size=(32,16),mode="direct")
        a,b=self.run_dir("a",size=(32,16)),self.run_dir("b",size=(32,16),mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d,expected=2)
        self.assertIn("calibration-one-sided-missing-content",r["calibration"]["reasons"])

    def test_calibration_replay_hashes_and_tamper(self):
        c,d=self.controls()
        a,b=self.run_dir("a",size=(32,16)),self.run_dir("b",size=(32,16),mode="direct")
        r,out=self.call(a,b,"--calibrate",c,d)
        self.call(a,b,"--calibration",out/"calibration.json")
        self.call(a,b,"--calibration",out/"calibration.json","--pixel-delta",7,expected=2)
        original=(out/"calibration.json").read_text()
        cal=json.loads(original);cal["mask"][0]=False
        (out/"calibration.json").write_text(json.dumps(cal))
        self.call(a,b,"--calibration",out/"calibration.json",expected=2)
        (out/"calibration.json").write_text(original)
        (c/"f_1.png").write_bytes(png(32,16,lambda x,y:(90,)*3))
        self.call(a,b,"--calibration",out/"calibration.json",expected=2)

    def test_calibration_identity_mode_dimensions_frames(self):
        a,b=self.run_dir("a"),self.run_dir("b",mode="direct")
        for key,value in [("game","other"),("build","other"),("route","other"),("mode","generic")]:
            c=self.run_dir("c"+key,mode="direct");d=self.run_dir("d"+key,mode="direct")
            self.change(c,lambda m:m.update({key:value}))
            self.call(a,b,"--calibrate",c,d,expected=2)
        c=self.run_dir("c-size",size=(9,8),mode="direct");d=self.run_dir("d-size",size=(9,8),mode="direct")
        self.call(a,b,"--calibrate",c,d,expected=2)
        c=self.run_dir("c-frames",[(2,lambda x,y:(255,)*3)],mode="direct")
        d=self.run_dir("d-frames",mode="direct")
        self.call(a,b,"--calibrate",c,d,expected=2)

    def test_calibration_cannot_reuse_evaluation_capture_or_file(self):
        a,b=self.run_dir("a",mode="direct"),self.run_dir("b",mode="direct")
        c=self.run_dir("c",mode="direct")
        self.call(a,b,"--calibrate",a,c,expected=2)
        d=self.run_dir("d",mode="direct")
        self.change(d,lambda m:m.update(capture="a"))
        self.call(a,b,"--calibrate",c,d,expected=2)

    def test_missing_threshold_ranges(self):
        a,b=self.run_dir("a"),self.run_dir("b",mode="direct")
        for option,value in [("--near-black",255),("--near-black",-1),("--content-variance",0),
                             ("--content-variance","nan"),("--content-variance",17000),
                             ("--content-fraction",.01),("--black-fraction",.2),
                             ("--missing-fraction",.03),("--missing-fraction",0),("--missing-fraction","inf"),
                             ("--block-size",16)]:
            with self.subTest(option=option,value=value): self.call(a,b,option,value,expected=2)

    def test_union_mask_uses_all_calibration_frames(self):
        c=self.run_dir("ca",[(1,lambda x,y:(40,)*3),(2,lambda x,y:(40,)*3)],size=(32,16),mode="direct")
        d=self.run_dir("cb",[(1,lambda x,y:(220,)*3 if x<16 else (40,)*3),
                             (2,lambda x,y:(220,)*3 if x>=16 else (40,)*3)],size=(32,16),mode="direct")
        a,b=self.run_dir("a",size=(32,16)),self.run_dir("b",size=(32,16),mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d,expected=2)
        self.assertEqual(r["calibration"]["maskedFraction"],1)

    def test_missing_area_strict_two_percent_boundary(self):
        texture=lambda x,y:(100 if (x+y)%2 else 200,)*3
        for height,pixels,missing in [(40,64,False),(32,64,True)]:
            a=self.run_dir("a"+str(height),[(1,texture)],size=(80,height))
            b=self.run_dir("b"+str(height),[(1,lambda x,y:(0,)*3 if x<8 and y<8 else texture(x,y))],size=(80,height),mode="direct")
            r,_=self.call(a,b,expected=1)
            m=r["pairs"][0]["metrics"]
            self.assertEqual(m["missingPixels"],pixels)
            self.assertEqual(m["missingClassification"]=="缺内容",missing)

    def test_sequence_reports_keep_blocks_external(self):
        a=self.run_dir("a",[(i,lambda x,y:(130,)*3) for i in range(1,33)])
        b=self.run_dir("b",[(i,lambda x,y:(130,)*3) for i in range(1,33)],mode="direct")
        r,out=self.call(a,b)
        self.assertEqual(r["coverage"]["paired"],32)
        self.assertEqual(len(list(out.glob("blocks-*.json"))),32)
        self.assertTrue(all("blocks" not in p["metrics"] for p in r["pairs"]))


    def test_calibration_does_not_cover_unsampled_frame(self):
        c,d=self.controls()
        a=self.run_dir("a",[(2,lambda x,y:(130,)*3)],size=(32,16))
        b=self.run_dir("b",[(2,lambda x,y:(130,)*3)],size=(32,16),mode="direct")
        self.call(a,b,"--calibrate",c,d,expected=2)

    def test_blank_calibration_is_not_valid_reference(self):
        c=self.run_dir("ca",[(1,lambda x,y:(0,)*3)],mode="direct")
        d=self.run_dir("cb",[(1,lambda x,y:(0,)*3)],mode="direct")
        a,b=self.run_dir("a"),self.run_dir("b",mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d,expected=2)
        self.assertIn("calibration-blank-reference",r["unverifiedReasons"])

    def test_two_black_evaluation_frames_not_false_green(self):
        a=self.run_dir("a",[(1,lambda x,y:(0,)*3)])
        b=self.run_dir("b",[(1,lambda x,y:(0,)*3)],mode="direct")
        r,_=self.call(a,b,expected=2)
        self.assertIn("both-evaluation-frames-near-black",r["unverifiedReasons"])


    def test_persistent_and_intermittent_missing_are_separate(self):
        texture=lambda x,y:(100 if (x+y)%2 else 200,)*3
        for repeat in [False,True]:
            a=self.run_dir("a"+str(repeat),[(1,texture),(2,texture)],size=(32,16))
            black=lambda x,y:(0,)*3 if x<16 else texture(x,y)
            b=self.run_dir("b"+str(repeat),[(1,black),(2,black if repeat else texture)],size=(32,16),mode="direct")
            r,_=self.call(a,b,expected=1)
            self.assertEqual(r["missingContent"]["persistentMissingFraction"],.5 if repeat else 0)
            self.assertEqual(r["missingContent"]["persistence"],"persistent-across-all-pairs" if repeat else "intermittent")
            self.assertEqual(r["missingContent"]["flaggedPairs"],2 if repeat else 1)


    def test_masked_uniform_disappearance_is_unverified_not_green(self):
        c,d=self.controls()
        a=self.run_dir("a",[(1,lambda x,y:(130,)*3)],size=(32,16))
        b=self.run_dir("b",[(1,lambda x,y:(0 if x<8 else 130,)*3)],size=(32,16),mode="direct")
        for left,right in [(a,b),(b,a)]:
            r,out=self.call(left,right,"--calibrate",c,d,expected=2)
            self.assertEqual(r["classification"],"未验证")
            self.assertEqual(r["pairs"][0]["metrics"]["missingBlocks"],0)
            self.assertEqual(r["pairs"][0]["metrics"]["ambiguousBlackFraction"],.25)
            self.assertIn("masked-low-texture-one-sided-black",r["unverifiedReasons"])
            self.assertIn("masked-low-texture-one-sided-black",(out/"summary.md").read_text())
            self.assertEqual(decode_rgb(out/r["pairs"][0]["missingHeatmap"])[0][0],(255,255,0))

    def test_uniform_disappearance_not_learned_in_calibration(self):
        c=self.run_dir("ca",[(1,lambda x,y:(130,)*3)],size=(32,16),mode="direct")
        d=self.run_dir("cb",[(1,lambda x,y:(0 if x<8 else 130,)*3)],size=(32,16),mode="direct")
        a,b=self.run_dir("a",size=(32,16)),self.run_dir("b",size=(32,16),mode="direct")
        r,_=self.call(a,b,"--calibrate",c,d,expected=2)
        self.assertIn("calibration-low-texture-one-sided-black",r["unverifiedReasons"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
