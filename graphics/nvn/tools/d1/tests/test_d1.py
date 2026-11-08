#!/usr/bin/env python3
"""D1 采集/对比的合成数据自测（不需要 Mac、不需要 GPU）。

    python3 graphics/nvn/tools/d1/tests/test_d1.py
"""
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture  # noqa: E402
import compare  # noqa: E402

HEADER = "frame\twall_us\trb_us\tdraw_n\tpass_n\tupload_n\trw_kb\tshader_miss\tpso_n\tpso_us\tgpuq_us\n"


def write_frames(run_dir, n=100, wall=16000, upload=2, high_every=0, high_wall=None):
    rows = []
    for i in range(n):
        w = high_wall if (high_every and i % high_every == 0 and high_wall) else wall
        rows.append(f"{i + 1}\t{w}\t10\t3\t1\t{upload}\t4\t0\t0\t0\t0")
    (run_dir / "frames.tsv").write_text(HEADER + "\n".join(rows) + "\n", encoding="utf-8")


def write_png(path, rgba):
    def chunk(ctype, data):
        return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    idat = zlib.compress(b"\x00" + bytes(rgba))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


class D1Test(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def capture(self, name, **kw):
        d = self.root / name
        d.mkdir()
        write_frames(d, **{k: v for k, v in kw.items() if k in ("n", "wall", "upload", "high_every", "high_wall")})
        write_png(d / "shots" / "frame_0001.png", [255, 0, 0, 255])
        return capture.build_capture(d, game="demo", device="mac-test", mode="direct", metal_api=4,
                                     commit=kw.get("commit", "abc123"))

    def test_repeatability_ok(self):
        r = compare.compare(self.capture("a"), self.capture("b"), "repeatability")
        self.assertTrue(r["ok"], r)

    def test_pixel_diff_fails(self):
        a = self.capture("a")
        d = self.root / "b"
        d.mkdir()
        write_frames(d)
        write_png(d / "shots" / "frame_0001.png", [0, 255, 0, 255])
        b = capture.build_capture(d, game="demo", device="mac-test", mode="direct", metal_api=4, commit="abc123")
        r = compare.compare(a, b, "repeatability")
        self.assertFalse(r["ok"])
        self.assertFalse([c for c in r["checks"] if c["kind"] == "pixels"][0]["ok"])

    def test_p95_drift_fails(self):
        a = self.capture("a")
        b = self.capture("b", high_every=10, high_wall=40000)
        r = compare.compare(a, b, "repeatability")
        self.assertFalse(r["ok"])
        self.assertFalse([c for c in r["checks"] if c["name"] == "帧时 p95"][0]["ok"])

    def test_rate_drift_fails(self):
        a = self.capture("a")
        b = self.capture("b", upload=4)
        r = compare.compare(a, b, "repeatability")
        self.assertFalse(r["ok"])
        self.assertFalse([c for c in r["checks"] if c["name"] == "上传次数/帧"][0]["ok"])

    def test_ab_regression_and_improvement(self):
        a = self.capture("a")
        worse = self.capture("worse", wall=24000)
        better = self.capture("better", wall=15000)
        self.assertFalse(compare.compare(a, worse, "ab")["ok"])
        self.assertTrue(compare.compare(a, better, "ab")["ok"])

    def test_device_mismatch_is_invalid(self):
        a = self.capture("a")
        b = self.capture("b")
        b["environment"]["device"] = "other"
        with self.assertRaises(compare.Invalid):
            compare.compare(a, b, "repeatability")

    def test_commit_mismatch_is_invalid(self):
        a = self.capture("a")
        b = self.capture("b", commit="def456")
        with self.assertRaises(compare.Invalid):
            compare.compare(a, b, "repeatability")

    def test_missing_frames_is_invalid(self):
        d = self.root / "empty"
        d.mkdir()
        with self.assertRaises(capture.CaptureError):
            capture.build_capture(d, game="demo", device="mac-test", mode="direct", metal_api=4, commit="abc123")


if __name__ == "__main__":
    unittest.main(verbosity=2)
