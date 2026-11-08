#!/usr/bin/env python3
"""Offline checks for the #1449 decoder-equivalence diff tool; synthetic frames only."""

import contextlib
import importlib.util
import io
import struct
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "s2a_yuvdiff", Path(__file__).resolve().parents[1] / "tools/s2a_yuvdiff.py"
)
yd = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(yd)


def synth(w, h, seed):
    """Deterministic I420 planes: every byte depends on position and seed."""
    def plane(pw, ph, salt):
        return bytes(((x * 7 + y * 13 + seed * 31 + salt) & 0xFF)
                     for y in range(ph) for x in range(pw))
    return plane(w, h, 0), plane((w + 1) // 2, (h + 1) // 2, 91), \
        plane((w + 1) // 2, (h + 1) // 2, 167)


def pad_plane(plane, w, h, stride, rows):
    """Embed a w x h plane into a stride x rows buffer; padding is 0xEE."""
    out = bytearray([0xEE] * (stride * rows))
    for r in range(h):
        out[r * stride:r * stride + w] = plane[r * w:(r + 1) * w]
    return bytes(out)


def pack_i420(y, u, v, w, h, stride_pad=0, rows_pad=0, crop=(0, 0, 0, 0)):
    cw, ch = (w + 1) // 2, (h + 1) // 2
    return {
        "fmt": yd.FMT_I420, "w": w, "h": h, "crop": crop,
        "stride": (w + stride_pad, cw + stride_pad, cw + stride_pad),
        "rows": (h + rows_pad, ch + rows_pad, ch + rows_pad),
        "planes": (pad_plane(y, w, h, w + stride_pad, h + rows_pad),
                   pad_plane(u, cw, ch, cw + stride_pad, ch + rows_pad),
                   pad_plane(v, cw, ch, cw + stride_pad, ch + rows_pad)),
    }


def pack_semi(y, u, v, w, h, fmt, stride_pad=0, rows_pad=0, crop=(0, 0, 0, 0)):
    """NV12/NV21 buffer: Y plane then one interleaved chroma plane."""
    cw, ch = (w + 1) // 2, (h + 1) // 2
    a, b = (u, v) if fmt == yd.FMT_NV12 else (v, u)
    uv = bytearray()
    for r in range(ch):
        for x in range(cw):
            uv += bytes((a[r * cw + x], b[r * cw + x]))
    y_stride, uv_stride = w + stride_pad, 2 * cw + stride_pad
    return {
        "fmt": fmt, "w": w, "h": h, "crop": crop,
        "stride": (y_stride, uv_stride, 0),
        "rows": (h + rows_pad, ch + rows_pad, 0),
        "planes": (pad_plane(y, w, h, y_stride, h + rows_pad),
                   pad_plane(uv, 2 * cw, ch, uv_stride, ch + rows_pad), b""),
    }


def pack_yv12(y, u, v, w, h, **kw):
    rec = pack_i420(y, u, v, w, h, **kw)
    rec["fmt"] = yd.FMT_YV12
    for key in ("stride", "rows", "planes"):
        v = rec[key]
        rec[key] = (v[0], v[2], v[1])
    return rec


def dump(frames):
    """Serialize frame dicts (as pack_* returns plus au/emit) to S2AY bytes."""
    out = bytearray(struct.pack("<II", yd.FILE_MAGIC, yd.FILE_VERSION))
    for f in frames:
        sizes = [len(p) for p in f["planes"]] + [0] * (3 - len(f["planes"]))
        out += struct.pack("<20I", yd.FRAME_MAGIC, f["au"], f.get("emit", f["au"]),
                           f["fmt"], f["w"], f["h"], *f["crop"],
                           *f["stride"], *f["rows"], *sizes, 0)
        out += b"".join(f["planes"])
    return bytes(out)


def run_cli(a_bytes, b_bytes):
    """Write two dumps to temp files, run main(), return (rc, output)."""
    with tempfile.TemporaryDirectory() as td:
        pa, pb = Path(td) / "a.s2ay", Path(td) / "b.s2ay"
        pa.write_bytes(a_bytes)
        pb.write_bytes(b_bytes)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = yd.main([str(pa), str(pb)])
    return rc, buf.getvalue()


W, H = 32, 24   # synthetic coded size


class SelfCompareTests(unittest.TestCase):
    """Task case 1: same decoder output on both sides must compare green,
    including after a round trip through NV12 packing + normalization."""

    def test_identical_dumps_green(self):
        frames = [dict(pack_i420(*synth(W, H, s), W, H), au=s) for s in range(4)]
        blob = dump(frames)
        rc, out = run_cli(blob, blob)
        self.assertEqual(rc, 0, out)
        self.assertIn("IDENTICAL: 4 frames", out)

    def test_i420_vs_nv12_padded_cropped_green(self):
        """Same visible picture: plain I420 vs NV12 with stride/slice padding
        and a 1088-style crop — normalization must prove them equal."""
        y, u, v = synth(W, H, 3)
        i420 = dict(pack_i420(y, u, v, W, H), au=0)
        w2, h2 = W + 2, H + 8   # coded buffer carries crop to W x H
        y2 = pad_plane(y, W, H, w2, h2)
        u2 = pad_plane(u, W // 2, H // 2, w2 // 2, h2 // 2)
        v2 = pad_plane(v, W // 2, H // 2, w2 // 2, h2 // 2)
        nv12 = dict(pack_semi(y2[:w2 * h2], u2[:(w2 // 2) * (h2 // 2)],
                              v2[:(w2 // 2) * (h2 // 2)], w2, h2,
                              yd.FMT_NV12, stride_pad=16, rows_pad=8,
                              crop=(0, 0, 2, 8)), au=0)
        rc, out = run_cli(dump([i420]), dump([nv12]))
        self.assertEqual(rc, 0, out)
        self.assertIn("IDENTICAL: 1 frames", out)


class NegativeTests(unittest.TestCase):
    """Task case 2: a single flipped byte must go red at the right position."""

    def test_byte_flip_reports_position(self):
        y, u, v = synth(W, H, 1)
        good = dict(pack_i420(y, u, v, W, H), au=0)
        bad_v = bytearray(v)
        bad_v[3 * (W // 2) + 5] ^= 0xFF          # V plane row 3, col 5
        bad = dict(pack_i420(y, u, bytes(bad_v), W, H), au=0)
        rc, out = run_cli(dump([good]), dump([bad]))
        self.assertEqual(rc, 1, out)
        self.assertIn("au=0", out)
        self.assertIn("plane=V", out)
        self.assertIn("row=3 col=5", out)
        self.assertIn("1/", out)                 # one byte differs in the plane

    def test_frame_count_mismatch_red(self):
        a = [dict(pack_i420(*synth(W, H, s), W, H), au=s) for s in range(3)]
        rc, out = run_cli(dump(a), dump(a[:2]))
        self.assertEqual(rc, 1, out)
        self.assertIn("MISMATCH", out)
        self.assertIn("only in a: [2]", out)

    def test_empty_dumps_not_green(self):
        blob = dump([])
        rc, out = run_cli(blob, blob)
        self.assertEqual(rc, 1, out)
        self.assertIn("no frames", out)


class NormalizeTests(unittest.TestCase):
    """Task case 3: one normalization case per input shape."""

    def setUp(self):
        self.y, self.u, self.v = synth(W, H, 2)
        self.want = (W, H, (self.y, self.u, self.v))

    def norm(self, rec):
        return yd.normalize(dict(rec, au=0, emit=0, planes=list(rec["planes"]),
                                 offset=0))

    def test_i420_passthrough(self):
        self.assertEqual(self.norm(pack_i420(self.y, self.u, self.v, W, H)), self.want)

    def test_nv12_deinterleave(self):
        rec = pack_semi(self.y, self.u, self.v, W, H, yd.FMT_NV12)
        self.assertEqual(self.norm(rec), self.want)

    def test_nv21_deinterleave(self):
        rec = pack_semi(self.y, self.u, self.v, W, H, yd.FMT_NV21)
        self.assertEqual(self.norm(rec), self.want)

    def test_yv12_plane_order(self):
        rec = pack_yv12(self.y, self.u, self.v, W, H)
        self.assertEqual(self.norm(rec), self.want)

    def test_stride_and_slice_height_padding(self):
        cases = (
            pack_i420(self.y, self.u, self.v, W, H, stride_pad=12, rows_pad=6),
            pack_yv12(self.y, self.u, self.v, W, H, stride_pad=12, rows_pad=6),
            pack_semi(self.y, self.u, self.v, W, H, yd.FMT_NV12, stride_pad=12, rows_pad=6),
            pack_semi(self.y, self.u, self.v, W, H, yd.FMT_NV21, stride_pad=12, rows_pad=6),
        )
        for i, rec in enumerate(cases):
            self.assertEqual(self.norm(rec), self.want, f"case {i}")

    def test_crop_four_sides(self):
        rec = pack_i420(self.y, self.u, self.v, W, H, crop=(2, 4, 6, 8))
        vw, vh = W - 2 - 6, H - 4 - 8
        ey = b"".join(self.y[(4 + r) * W + 2:(4 + r) * W + 2 + vw] for r in range(vh))
        cw, ch = vw // 2, vh // 2
        eu = b"".join(self.u[(2 + r) * (W // 2) + 1:(2 + r) * (W // 2) + 1 + cw]
                      for r in range(ch))
        ev = b"".join(self.v[(2 + r) * (W // 2) + 1:(2 + r) * (W // 2) + 1 + cw]
                      for r in range(ch))
        self.assertEqual(self.norm(rec), (vw, vh, (ey, eu, ev)))

    def test_malformed_rejected(self):
        rec = pack_i420(self.y, self.u, self.v, W, H, crop=(1, 0, 0, 0))
        with self.assertRaises(yd.Incomparable):
            self.norm(rec)                     # odd left crop: not chroma aligned
        rec = pack_i420(self.y, self.u, self.v, W, H, crop=(0, 0, W, 0))
        with self.assertRaises(yd.Incomparable):
            self.norm(rec)                     # nothing visible left
        rec = pack_i420(self.y, self.u, self.v, W, H)
        rec["fmt"] = 99
        with self.assertRaises(yd.Incomparable):
            self.norm(rec)                     # unknown format: red, never silent


class ParseTests(unittest.TestCase):
    def test_truncated_file_is_parse_error(self):
        good = dump([dict(pack_i420(*synth(W, H, 0), W, H), au=0)])
        with tempfile.TemporaryDirectory() as td:
            pa, pb = Path(td) / "a.s2ay", Path(td) / "b.s2ay"
            pa.write_bytes(good)
            pb.write_bytes(good[:-7])          # cut inside the last plane
            self.assertEqual(yd.main([str(pa), str(pb)]), 2)

    def test_duplicate_au_red(self):
        f = dict(pack_i420(*synth(W, H, 0), W, H), au=0)
        rc, out = run_cli(dump([f, f, dict(f, au=1)]), dump([f, dict(f, au=1)]))
        self.assertEqual(rc, 1, out)
        self.assertIn("duplicate au", out)


if __name__ == "__main__":
    unittest.main()
