#!/usr/bin/env python3
"""Original fixed A64 words; expected edges/strides do not use the decoder."""

import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import arm64_loops as tool


def nso(words):
    text = struct.pack("<" + "I" * len(words), *words)
    h = bytearray(256)
    h[:4] = b"NSO0"
    struct.pack_into("<III", h, 16, 256, 0x1000, len(text))
    struct.pack_into("<I", h, 0x60, len(text))
    return bytes(h) + text


class Tests(unittest.TestCase):
    def test_loop_stride(self):
        # ldr x1,[x0]; add x0,x0,#8; subs x2,x2,#1; b.ne 0x1000; ret
        r = tool.analyze(nso([0xF9400001, 0x91002000, 0xF1000442, 0x54FFFFA1, 0xD65F03C0]))
        self.assertEqual(len(r["loops"]), 1)
        loop = r["loops"][0]
        self.assertEqual(loop["header"], 0x1000)
        self.assertEqual(loop["back_edges"], [[0x100C, 0x1000]])
        self.assertEqual(loop["memory"][0]["address"], 0x1000)
        self.assertEqual(loop["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_no_cycle(self):
        self.assertEqual(tool.analyze(nso([0xD503201F, 0xD65F03C0]))["loops"], [])

    def test_unknown_register_update(self):
        r = tool.analyze(nso([0xF9400001, 0x8B030000, 0x17FFFFFE]))
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])

    def test_exception_stops_flow(self):
        for w in [0xD4200000, 0xD4400000, 0xD69F03E0, 0xD6BF03E0, 0]:
            with self.subTest(word=w):
                r = tool.analyze(nso([w, 0x17FFFFFF]))
                self.assertEqual(r["loops"], [])

    def test_bad_nso(self):
        with self.assertRaises(ValueError):
            tool.analyze(b"NSO0")

    def test_self_loop(self):
        r = tool.analyze(nso([0x14000000]))
        self.assertEqual(r["loops"][0]["back_edges"], [[0x1000, 0x1000]])

    def test_forward_branch_not_loop(self):
        self.assertEqual(tool.analyze(nso([0x14000002, 0xD503201F, 0xD65F03C0]))["loops"], [])

    def test_indirect_not_fabricated(self):
        r = tool.analyze(nso([0xD61F0000, 0x17FFFFFF]))  # br x0; b -4
        self.assertEqual(r["loops"], [])
        self.assertEqual(r["unresolved"][0]["kind"], "indirect_transfer")

    def test_reset_is_not_stride(self):
        r = tool.analyze(nso([0xF9400001, 0xD2800100, 0x17FFFFFE]))  # mov x0,#8
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])

    def test_w_write_is_not_x_stride(self):
        r = tool.analyze(nso([0xF9400001, 0x11002000, 0x17FFFFFE]))
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])

    def test_32bit_special_register_aliases(self):
        for load, update, base in [
            (0xF94003E1, 0x110023FF, "sp"),
            (0xF94003A1, 0x110023BD, "fp"),
            (0xF94003C1, 0x110023DE, "lr"),
        ]:
            with self.subTest(base=base):
                r = tool.analyze(nso([load, update, 0x17FFFFFE]))
                self.assertIsNone(r["loops"][0]["base_strides"][base]["bytes_per_iteration"])

    def test_64bit_special_register_updates(self):
        for load, update, base in [
            (0xF94003E1, 0x910023FF, "sp"),
            (0xF94003A1, 0x910023BD, "fp"),
            (0xF94003C1, 0x910023DE, "lr"),
        ]:
            with self.subTest(base=base):
                r = tool.analyze(nso([load, update, 0x17FFFFFE]))
                self.assertEqual(r["loops"][0]["base_strides"][base]["bytes_per_iteration"], 8)

    def test_special_register_overwrite(self):
        # add sp,x0,#8 and MOV immediate to fp/lr are not self recurrences.
        for load, update, base in [
            (0xF94003E1, 0x9100201F, "sp"),
            (0xF94003A1, 0xD280011D, "fp"),
            (0xF94003C1, 0xD280011E, "lr"),
        ]:
            with self.subTest(base=base):
                r = tool.analyze(nso([load, update, 0x17FFFFFE]))
                self.assertIsNone(r["loops"][0]["base_strides"][base]["bytes_per_iteration"])

    def test_zero_stride(self):
        r = tool.analyze(nso([0xF9400001, 0x17FFFFFF]))
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], 0)

    def test_negative_stride(self):
        r = tool.analyze(nso([0xF9400001, 0xD1002000, 0x17FFFFFE]))
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], -8)

    def test_conditional_update_unknown(self):
        # ldr; cbz x2, backedge; add x0,#8; b header
        r = tool.analyze(nso([0xF9400001, 0xB4000042, 0x91002000, 0x17FFFFFD]))
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])

    def test_equal_branch_updates(self):
        # ldr; cbz x2, second add; add +8; b latch; add +8; b header
        r = tool.analyze(
            nso([0xF9400001, 0xB4000062, 0x91002000, 0x14000002, 0x91002000, 0x17FFFFFB])
        )
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_multiple_latches(self):
        # ldr; add +8; cbz x2, header; b header
        r = tool.analyze(nso([0xF9400001, 0x91002000, 0xB4FFFFC2, 0x17FFFFFD]))
        self.assertEqual(r["loops"][0]["back_edges"], [[0x1008, 0x1000], [0x100C, 0x1000]])
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_nested(self):
        # outer: nop; inner: ldr; add; cbnz x2, inner; cbnz x3, outer; ret
        r = tool.analyze(
            nso([0xD503201F, 0xF9400001, 0x91002000, 0xB5FFFFC2, 0xB5FFFF83, 0xD65F03C0])
        )
        self.assertEqual([loop["header"] for loop in r["loops"]], [0x1000, 0x1004])
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])
        self.assertEqual(r["loops"][1]["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_irreducible(self):
        # entry cbz -> B, fallthrough A; A b B; B cbnz -> A; ret
        r = tool.analyze(nso([0xB4000040, 0x14000001, 0xB5FFFFE1, 0xD65F03C0]))
        self.assertEqual(r["loops"], [])
        self.assertEqual(r["cyclic_regions"][0]["entries"], [0x1004, 0x1008])
        self.assertEqual(r["cyclic_regions"][0]["kind"], "multiple_or_unknown_entry")

    def test_disconnected_cycle_inventory(self):
        # No evidence that ret's next instruction is a real function entry.
        r = tool.analyze(nso([0xD65F03C0, 0x14000000]))
        self.assertEqual(r["loops"], [])
        self.assertEqual(r["cyclic_regions"][0]["nodes"], [0x1004])
        self.assertEqual(r["cyclic_regions"][0]["entries"], [])

    def test_direct_call_entry(self):
        # bl self-loop function at +8; ret; b self
        r = tool.analyze(nso([0x94000002, 0xD65F03C0, 0x14000000]))
        self.assertEqual(r["loops"][0]["header"], 0x1008)

    def test_call_clobbers(self):
        r = tool.analyze(nso([0xF9400001, 0x94000004, 0x17FFFFFE]))
        self.assertIsNone(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"])

    def test_post_index(self):
        # ldr x1,[x0],#8; b header
        r = tool.analyze(nso([0xF8408401, 0x17FFFFFF]))
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_pre_index(self):
        r = tool.analyze(nso([0xF8408C01, 0x17FFFFFF]))
        self.assertEqual(r["loops"][0]["base_strides"]["x0"]["bytes_per_iteration"], 8)

    def test_literal_memory(self):
        r = tool.analyze(nso([0x58000040, 0x17FFFFFF, 0xD65F03C0]))
        self.assertEqual(r["loops"][0]["memory"][0]["operands"][0]["literal_address"], 0x1008)

    def test_writeback_base_destination_alias(self):
        # ldr x0,[x0],#8: constrained-unpredictable alias must not prove +8.
        r = tool.analyze(nso([0xF8408400, 0x17FFFFFF]))
        self.assertEqual(r["loops"], [])
        self.assertEqual(r["unresolved"][0]["kind"], "undecodable_or_udf")

    def test_tbz_backedge(self):
        r = tool.analyze(nso([0xD503201F, 0x3607FFE0, 0xD65F03C0]))
        self.assertEqual(r["loops"][0]["back_edges"], [[0x1004, 0x1000]])

    def test_unaligned_text_rejected(self):
        raw = bytearray(nso([0x14000000]))
        struct.pack_into("<I", raw, 20, 0x1001)
        with self.assertRaises(ValueError):
            tool.analyze(bytes(raw))

    def test_compressed(self):
        import lz4.block

        original = nso([0x14000000])
        h = bytearray(original[:256])
        body = lz4.block.compress(original[256:], store_size=False)
        struct.pack_into("<I", h, 12, 1)
        struct.pack_into("<I", h, 0x60, len(body))
        self.assertEqual(tool.analyze(bytes(h) + body)["loops"][0]["header"], 0x1000)

    def test_budgets(self):
        with self.assertRaisesRegex(ValueError, "instruction budget"):
            tool.analyze(nso([0xD503201F, 0x17FFFFFF]), max_instructions=1)
        with self.assertRaisesRegex(ValueError, "cyclic region budget"):
            tool.analyze(nso([0xD503201F, 0x17FFFFFF]), max_region=1)
        with self.assertRaises(ValueError):
            tool.analyze(nso([0x14000000]), max_bytes=255)

    def test_cli_readonly(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "input.nso"
            raw = nso([0x14000000])
            path.write_bytes(raw)
            cmd = [sys.executable, str(Path(tool.__file__)), str(path)]
            a = subprocess.run(cmd, capture_output=True, check=True)
            b = subprocess.run(cmd, capture_output=True, check=True)
            self.assertEqual(a.stdout, b.stdout)
            self.assertEqual(path.read_bytes(), raw)
            self.assertEqual(json.loads(a.stdout)["input_sha256"], hashlib.sha256(raw).hexdigest())
            path.write_bytes(b"bad")
            bad = subprocess.run(cmd, capture_output=True)
            self.assertEqual(bad.returncode, 2)
            self.assertEqual(bad.stdout, b"")
            fifo = Path(d) / "fifo"
            os.mkfifo(fifo)
            bad = subprocess.run(cmd[:-1] + [str(fifo)], capture_output=True, timeout=5)
            self.assertEqual(bad.returncode, 2)


if __name__ == "__main__":
    unittest.main()
