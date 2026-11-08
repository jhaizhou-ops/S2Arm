#!/usr/bin/env python3
"""Generate redistributable J02 PNG evidence with Python stdlib only.

All measurements below come from the generated pixels, never the expected label.
This synthetic producer is not a replacement for auto_table's real depth/UI data.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

W0, W1, HEIGHT, FPS = 320, 392, 180, 30
CASES = ("correct", "stretch_1_22", "ui_shift", "center_shift", "alternating_flicker")
TEST_POLICY = {"version": "s2a-widen-judge/1", "ui_ratio_tolerance": 0.01,
               "flicker_excess_luma_max": 2 / 255,
               "basis": "SYNTHETIC TEST ONLY; not an approved production threshold"}
UI = (250, 240, 12)


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def png(rows):
    h, w = len(rows), len(rows[0])
    scan = b"".join(b"\x00" + bytes(v for pixel in row for v in pixel) for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scan)) + chunk(b"IEND", b""))


def scene(x, y, ui_offset=0):
    if 65 + ui_offset <= x < 125 + ui_offset and 20 <= y < 45:
        return UI
    if (x - 170) ** 2 + (y - 95) ** 2 < 22 ** 2:
        return (235, 60, 40)
    # Continuous world outside the central 16:9, with enough distinctive texture.
    return (25 + (x * 3 + y * 2) % 150, 30 + (x + y * 3) % 140, 35 + (x * 2 + y) % 130)


def image(case, wide, odd=False):
    width = W1 if wide else W0
    out = []
    for y in range(HEIGHT):
        row = []
        for x in range(width):
            world = x - (W1 - W0) // 2 if wide else x
            shift = 38 if wide and case == "ui_shift" else 0
            if wide and case == "stretch_1_22":
                world = round((x - W1 / 2) / 1.22 + W0 / 2)
            if wide and case == "center_shift":
                world += 15
            pixel = scene(world, y, shift)
            if wide and case == "alternating_flicker" and odd:
                pixel = tuple(min(255, c + 70) for c in pixel) if pixel != UI else pixel
            row.append(pixel)
        out.append(row)
    return out


def psnr(orig, wide):
    off = (W1 - W0) // 2
    mse = sum((a - b) ** 2 for y in range(HEIGHT) for x in range(W0)
              for a, b in zip(orig[y][x], wide[y][x + off])) / (W0 * HEIGHT * 3)
    return 999.0 if mse == 0 else 10 * math.log10(255 ** 2 / mse)


def ui_size(img):
    pts = [(x, y) for y, row in enumerate(img) for x, px in enumerate(row) if px == UI]
    return max(x for x, _ in pts) - min(x for x, _ in pts) + 1, max(y for _, y in pts) - min(y for _, y in pts) + 1


def luma(img):
    return sum((r + g + b) / (3 * 255) for row in img for r, g, b in row) / (len(img) * len(img[0]))


def generate(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "test-policy.json").write_text(json.dumps(TEST_POLICY, indent=2) + "\n")
    summary = []
    for case in CASES:
        root = output / case
        for side in ("orig", "wide"):
            (root / side).mkdir(parents=True, exist_ok=True)
        orig = image(case, False)
        variants = [image(case, True, odd) for odd in (False, True)]
        encoded = {"orig": [png(orig)] * 2, "wide": [png(img) for img in variants]}
        def pair(frame, label):
            record = {"frame": frame}
            for side in ("orig", "wide"):
                data = encoded[side][frame % 2]
                file = f"{side}/{label}_{frame:04d}.png"
                (root / file).write_bytes(data)
                record[side] = {"file": file, "sha256": hashlib.sha256(data).hexdigest()}
            return record
        uw, uh = ui_size(orig)
        ratios = [(ui_size(img)[0] / uw, ui_size(img)[1] / uh) for img in variants]
        # The synthetic ground occupies y>=90 and is completely drawn. Its known
        # depth-clear marker is black, so the same ground-row side fraction is 0.
        off = (W1 - W0) // 2
        hole = max(sum(px == (0, 0, 0) for row in im[90:] for px in row[:off] + row[-off:])
                   / ((HEIGHT - 90) * off * 2) for im in variants)
        metrics = {"hole_side_fraction_max": hole,
                   "center_psnr_db_min": min(psnr(orig, im) for im in variants),
                   "ui_width_ratio_min": min(w for w, _ in ratios),
                   "ui_width_ratio_max": max(w for w, _ in ratios),
                   "ui_height_ratio_min": min(h for _, h in ratios),
                   "ui_height_ratio_max": max(h for _, h in ratios),
                   "flicker_excess_luma_max": abs(luma(variants[1]) - luma(variants[0]))}
        doc = {"version": "s2a-widen-judge/1",
               "capture": {"replay_sha256": hashlib.sha256(b"J02 deterministic procedural scene v1").hexdigest(), "fps": FPS},
               "key_frames": [pair(n, "key") for n in (10, 20, 30, 40)],
               "continuous_frames": [pair(n, "sequence") for n in range(60, 2 * FPS + 61)],
               "mark": pair(40, "MARK"), "metrics": metrics}
        (root / "metrics.json").write_text(json.dumps(doc, indent=2) + "\n")
        summary.append({"sample": case, "visual_intent": "过" if case == "correct" else "不过", "metrics": metrics})
    (output / "samples.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return summary


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("output", help="caller-owned cache directory, never a source tree")
    generate(p.parse_args().output)
