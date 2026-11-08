#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 S2Arm contributors
"""Exercise optional table opens through the real C CLI and an original NSO."""
import errno
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


CLI = str(Path(sys.argv.pop(1)).resolve())
PRODUCTS = ("patched.bin", "fixups.tsv", "gaps.tsv", "gates.tsv", "sites.tsv")
TABLES = (("S2A_FPS_TSV", "帧率表"), ("S2A_CPATCH_TSV", "社区补丁表"))


def write_nso(path):
    # AArch64: mov w1,#1; mov w2,#2; ret. Tables replace the two MOVs with
    # mov w1,#3 (0x52800061) and mov w2,#4 (0x52800082), respectively.
    text = bytearray(0x1000)
    struct.pack_into("<II", text, 0, 0x14000040, 0x1000)
    struct.pack_into("<III", text, 0x100, 0x52800021, 0x52800042, 0xD65F03C0)
    ro = bytearray(0x1000)
    struct.pack_into("<4sIIIii", ro, 0, b"MOD0", 0, 0, 0, 0x100, 0x120)
    struct.pack_into("<BBBBiIii", ro, 0x100, 1, 0x1B, 0x03, 0x3B,
                     0xFC, 1, -0x1000, 0x118)
    cie = struct.pack("<II", 0x14, 0) + b"\x01zR\0\x04\x78\x1e\x01\x1b" + bytes(7)
    ro[0x200:0x218] = cie
    struct.pack_into("<IIii", ro, 0x218, 0x10, 0x1C, -0x1120, 12)
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    for index in range(3):
        struct.pack_into("<III", header, 0x10 + 0x10 * index,
                         0x100 + 0x1000 * index, 0x1000 * index, 0x1000)
        struct.pack_into("<I", header, 0x60 + 4 * index, 0x1000)
    header[0x40:0x50] = bytes(range(16))
    path.write_bytes(header + text + ro + bytes(0x1000))


class TableOpenTest(unittest.TestCase):
    def test_real_cli(self):
        with tempfile.TemporaryDirectory(prefix="rewriter-table-open-") as temporary:
            root = Path(temporary)
            nso = root / "main"
            write_nso(nso)
            fps = root / "fps.tsv"
            fps.write_text("c main 0x100 word 52800021 52800061\n")
            cpatch = root / "cpatch.tsv"
            cpatch.write_text("w main 0x104 52800042 52800082\n")
            regular = root / "regular-file"
            regular.write_text("not a directory\n")
            missing = root / "missing.tsv"
            notdir = regular / "table.tsv"
            # Unlike chmod(000), ENOTDIR also fails when tests run as root.
            for path, expected in ((missing, errno.ENOENT), (notdir, errno.ENOTDIR)):
                with self.assertRaises(OSError) as caught:
                    path.open("rb")
                self.assertEqual(caught.exception.errno, expected)

            def run(target, name, tables):
                out = root / (target + "-" + name)
                out.mkdir()
                env = {key: value for key, value in os.environ.items()
                       if not key.startswith("S2A_")}
                env.update(S2A_TARGET=target, LC_ALL="C")
                env.update(tables)
                result = subprocess.run([CLI, str(nso), str(out), "main"],
                                        env=env, capture_output=True, text=True, timeout=30)
                products = {name: (out / ("main." + name)).read_bytes()
                            for name in PRODUCTS if (out / ("main." + name)).is_file()}
                return result.returncode, result.stdout + result.stderr, products

            for target in ("apple", "android"):
                rc, log, baseline = run(target, "unset", {})
                self.assertEqual(rc, 0, log)
                self.assertEqual(set(baseline), set(PRODUCTS))
                self.assertEqual(struct.unpack_from("<II", baseline["patched.bin"], 0x100),
                                 (0x52800021, 0x52800042))
                for _, label in TABLES:
                    self.assertNotIn(label, log)
                with self.subTest(target=target, case="empty"):
                    rc, log, products = run(target, "empty", {key: "" for key, _ in TABLES})
                    self.assertEqual(rc, 0, log)
                    self.assertEqual(products, baseline)
                    for _, label in TABLES:
                        self.assertNotIn(label, log)

                for name, tables, expected in (
                    ("fps", {"S2A_FPS_TSV": str(fps)}, (0x52800061, 0x52800042)),
                    ("cpatch", {"S2A_CPATCH_TSV": str(cpatch)}, (0x52800021, 0x52800082)),
                    ("both", {"S2A_FPS_TSV": str(fps), "S2A_CPATCH_TSV": str(cpatch)},
                     (0x52800061, 0x52800082)),
                ):
                    with self.subTest(target=target, case=name):
                        rc, log, products = run(target, name, tables)
                        self.assertEqual(rc, 0, log)
                        self.assertEqual(set(products), set(PRODUCTS))
                        self.assertEqual(struct.unpack_from("<II", products["patched.bin"], 0x100), expected)
                        hashes = " ".join(hashlib.sha256(products[key]).hexdigest() for key in PRODUCTS)
                        print(f"正常产物 {target}/{name}: {hashes}", flush=True)

                for key, label in TABLES:
                    with self.subTest(target=target, table=key, case="ENOENT"):
                        rc, log, products = run(target, key + "-missing", {key: str(missing)})
                        self.assertEqual(rc, 0, log)
                        self.assertEqual(products, baseline)
                        self.assertIn(label + "不存在，跳过", log)
                    with self.subTest(target=target, table=key, case="ENOTDIR"):
                        rc, log, _ = run(target, key + "-notdir", {key: str(notdir)})
                        self.assertEqual(rc, 1, f"{key} ENOTDIR must fail, got {rc}: {log}")
                        self.assertIn("无法打开" + label, log)
                        self.assertIn(os.strerror(errno.ENOTDIR), log)


if __name__ == "__main__":
    unittest.main()
