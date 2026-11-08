"""Q4 independent fixtures: fixed A64 words, hand-calculated virtual addresses.

No production encoder/scanner is used to calculate expected results. The fixed
words are cross-checked with the already installed clang AArch64 assembler in
development; the portable gate itself only needs the project's Python packages.
"""

import hashlib
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import capstone
import lz4.block

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("S2A_ASPECT_LOCATOR", ROOT / "tools/arm64_aspect_locator.py"))
spec = importlib.util.spec_from_file_location("aspect_locator", TOOL)
locator = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = locator
spec.loader.exec_module(locator)

# movz w0,#0x8e39; movk w0,#0x3fe3,lsl#16; fmov s0,w0;
# fmul s2,s0,s1; ret. MOVZ commonly disassembles as the MOV alias.
MOV = 0x5291C720
KEEP = 0x72A7FC60
FMOV = 0x1E270000
MUL = 0x1E210802
RET = 0xD65F03C0
NOP = 0xD503201F
RATIO = 0x3FE38E39


def words(*values):
    return struct.pack("<" + "I" * len(values), *values)


def nso(text, ro=b"", data=b"", *, compressed=False, text_base=0x1000, ro_base=0x2000):
    """Authored NSO0 container, no real/game bytes; segments need not be adjacent."""
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    header[0x40:0x60] = bytes(range(32))
    payload = bytearray()
    for k, (base, content) in enumerate(((text_base, text), (ro_base, ro), (0x3000, data))):
        encoded = (
            lz4.block.compress(content, store_size=False) if compressed and content else content
        )
        struct.pack_into("<III", header, 0x10 + 16 * k, 0x100 + len(payload), base, len(content))
        struct.pack_into("<I", header, 0x60 + 4 * k, len(encoded))
        if compressed and content:
            header[0xC] |= 1 << k
        payload += encoded
    return bytes(header + payload)


def scan(text, ro=b"", **kwargs):
    return locator.analyze(nso(text, ro, **kwargs))


def candidates(report, kind=None):
    rows = report["candidates"]
    return rows if kind is None else [row for row in rows if row["kind"] == kind]


class LocatorTests(unittest.TestCase):
    def test_movwide_float_use_exact_provenance(self):
        report = scan(words(MOV, KEEP, FMOV, MUL, RET))
        rows = candidates(report)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(
            (row["address"], row["kind"], row["bits"], row["precision"]),
            ("0x1000", "movwide", "3fe38e39", 32),
        )
        self.assertEqual(row["source_addresses"], ["0x1000", "0x1004"])
        self.assertEqual(row["float_use_addresses"], ["0x1008", "0x100c"])
        self.assertEqual(row["confidence"], "medium")
        self.assertFalse(row["aspect_proven"])
        self.assertIn("not_aspect_proof", row["reason"])
        self.assertEqual(report["schema"], "s2arm.arm64-aspect-candidates.v1")

    def test_switch2_flag_0x40_read_zbic_rejected(self):
        # Switch 2 头标志 0x40 与段解码无关（Splatoon Raiders main 为 0x7f）→ 照常读；
        # 0x80 = 段压缩方式是 ZBIC（事实取自 Eden-NS2 nso.h），经 tools/nso_plain.py 交 nx_unpack 解：段没标压缩 → 照常读；
        #   text 标了压缩、内容却不是 ZBIC 帧 → 拒绝
        blob = bytearray(nso(words(MOV, KEEP, FMOV, MUL, RET)))
        blob[0xC] |= 0x40
        self.assertEqual(len(candidates(locator.analyze(bytes(blob)))), 1)
        blob[0xC] |= 0x80
        self.assertEqual(len(candidates(locator.analyze(bytes(blob)))), 1)
        blob[0xC] |= 0x01
        with self.assertRaises(ValueError):
            locator.analyze(bytes(blob))

    def test_nonadjacent_and_high_half_first(self):
        # movz w0,#0x3fe3,lsl#16; nop; movk w0,#0x8e39; fmov; fmul
        row = candidates(scan(words(0x52A7FC60, NOP, 0x7291C720, FMOV, MUL, RET)))[0]
        self.assertEqual(row["source_addresses"], ["0x1000", "0x1008"])
        self.assertEqual(row["confidence"], "medium")

    def test_same_value_integer_only_is_low(self):
        # and w2,w0,w1: same bits are an integer mask, no floating use.
        row = candidates(scan(words(MOV, KEEP, 0x0A010002, RET)))[0]
        self.assertEqual(row["confidence"], "low")
        self.assertEqual(row["float_use_addresses"], [])

    def test_general_float_addition_does_not_claim_ratio(self):
        row = candidates(scan(words(MOV, KEEP, FMOV, 0x1E212802, RET)))[0]
        self.assertEqual(row["confidence"], "low")
        self.assertFalse(row["aspect_proven"])

    def test_movk_without_known_initializer_is_not_constant(self):
        self.assertEqual(candidates(scan(words(KEEP, FMOV, MUL, RET))), [])

    def test_register_mismatch_does_not_join(self):
        self.assertEqual(candidates(scan(words(MOV, KEEP | 1, FMOV, MUL, RET))), [])

    def test_zero_register_is_not_storage(self):
        self.assertEqual(candidates(scan(words(MOV | 31, KEEP | 31, FMOV, MUL, RET))), [])

    def test_intervening_overwrite_loses_half(self):
        self.assertEqual(candidates(scan(words(MOV, 0x52800000, KEEP, FMOV, MUL, RET))), [])

    def test_floating_alias_write_kills_value(self):
        # movi v0.16b,#0 writes the same vector storage as s0.
        row = candidates(scan(words(MOV, KEEP, FMOV, 0x4F00E400, MUL, RET)))[0]
        self.assertEqual(row["confidence"], "low")
        self.assertNotIn("0x1010", row["float_use_addresses"])

    def test_branch_and_call_clear_provenance(self):
        for barrier in (0x14000001, 0x94000001, RET, 0xD61F0020, 0x54000020):
            with self.subTest(barrier=hex(barrier)):
                self.assertEqual(candidates(scan(words(MOV, barrier, KEEP, FMOV, MUL, RET))), [])

    def test_exception_debug_and_return_clear_provenance(self):
        # Independently assembled with clang, not encoded by the analyzer. Pinned
        # Capstone 5.0.7 omits control-flow groups for several of these opcodes.
        barriers = {
            "brk": 0xD4200000,
            "hlt": 0xD4400000,
            "svc": 0xD4000001,
            "hvc": 0xD4000002,
            "smc": 0xD4000003,
            "eret": 0xD69F03E0,
            "drps": 0xD6BF03E0,
            "udf": 0x00000000,
            "dcps1": 0xD4A00001,
            "dcps2": 0xD4A00002,
            "dcps3": 0xD4A00003,
            "eretaa": 0xD69F0BFF,
            "eretab": 0xD69F0FFF,
        }
        for name, barrier in barriers.items():
            with self.subTest(instruction=name, position="between_halves"):
                self.assertEqual(candidates(scan(words(MOV, barrier, KEEP, FMOV, MUL, RET))), [])
            with self.subTest(instruction=name, position="after_float_transfer"):
                rows = candidates(scan(words(MOV, KEEP, FMOV, barrier, MUL, RET)))
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["confidence"], "low")
                self.assertEqual(rows[0]["float_use_addresses"], ["0x1008"])

    def test_exception_immediate_payload_does_not_preserve_state(self):
        for base in (
            0xD4200000,
            0xD4400000,
            0xD4000001,
            0xD4000002,
            0xD4000003,
            0xD4A00001,
            0xD4A00002,
            0xD4A00003,
        ):
            for immediate in (1, 0xFFFF):
                with self.subTest(base=hex(base), immediate=immediate):
                    row = candidates(scan(words(MOV, KEEP, FMOV, base | immediate << 5, MUL, RET)))[
                        0
                    ]
                    self.assertEqual(row["confidence"], "low")
                    self.assertEqual(row["float_use_addresses"], ["0x1008"])

    def test_incoming_target_prevents_partial_path_proof(self):
        # Later b at +20 targets KEEP at +4: not all arrivals have MOVZ.
        self.assertEqual(candidates(scan(words(MOV, KEEP, FMOV, MUL, RET, 0x17FFFFFC))), [])

    def test_invalid_instruction_breaks_chain(self):
        self.assertEqual(candidates(scan(words(MOV, 0, KEEP, FMOV, MUL, RET))), [])

    def test_window_expiration(self):
        report = locator.analyze(nso(words(MOV, NOP, NOP, KEEP, FMOV, MUL, RET)), window=2)
        self.assertEqual(candidates(report), [])

    def test_gpr_copy_keeps_provenance(self):
        # mov w3,w0; fmov s0,w3
        row = candidates(scan(words(MOV, KEEP, 0x2A0003E3, 0x1E270060, MUL, RET)))[0]
        self.assertEqual(row["confidence"], "medium")

    def test_literal_load_from_rodata(self):
        # PC=0x1000; imm19=0x400 => LDR S0 from 0x2000.
        row = candidates(scan(words(0x1C008000, MUL, RET), words(RATIO)), "literal")[0]
        self.assertEqual(row["address"], "0x1000")
        self.assertEqual(row["source_addresses"], ["0x2000"])
        self.assertEqual(row["confidence"], "medium")

    def test_literal_load_in_text(self):
        report = scan(words(0x1C000080, MUL, RET, NOP, RATIO))
        row = candidates(report, "literal")[0]
        self.assertEqual(row["source_addresses"], ["0x1010"])
        self.assertEqual(row["confidence"], "medium")
        raw = candidates(report, "text_constant")[0]
        self.assertEqual((raw["address"], raw["confidence"]), ("0x1010", "low"))

    def test_negative_literal_displacement(self):
        # LDR at0x1008 reads0x1000: imm19=(-2)&0x7ffff.
        row = candidates(scan(words(RATIO, 0, 0x1CFFFFC0, MUL, RET)), "literal")[0]
        self.assertEqual(row["source_addresses"], ["0x1000"])

    def test_integer_literal_then_float_transfer(self):
        row = candidates(scan(words(0x18008000, FMOV, MUL, RET), words(RATIO)), "literal")[0]
        self.assertEqual(row["confidence"], "medium")

    def test_unmapped_and_partial_literal_are_not_values(self):
        for text, ro in (
            (words(0x1C008020, MUL, RET), words(RATIO)),
            (words(0x5C008000, MUL, RET), words(RATIO)),
        ):
            report = scan(text, ro)
            self.assertEqual(candidates(report), [])
            self.assertEqual(report["unresolved_literal_loads"], 1)

    def test_data_is_not_disassembled_as_instructions(self):
        report = scan(words(RET), words(MOV, KEEP, FMOV, MUL, RET))
        self.assertEqual(candidates(report), [])

    def test_double_literal(self):
        # ldr d0,0x2000; fmul d2,d0,d1; ret
        row = candidates(
            scan(words(0x5C008000, 0x1E610802, RET), bytes.fromhex("1cc7711cc771fc3f")), "literal"
        )[0]
        self.assertEqual(
            (row["precision"], row["bits"], row["confidence"]), (64, "3ffc71c71c71c71c", "medium")
        )

    def test_x_register_then_w_transfer_uses_low32(self):
        # Add nonzero top half to x0, then read w0 via FMOV.
        row = candidates(
            scan(words(MOV | 0x80000000, KEEP | 0x80000000, 0xF2C00020, FMOV, MUL, RET))
        )[0]
        self.assertEqual(row["confidence"], "medium")

    def test_scalar_fmov_immediates_cannot_encode_16_over_9(self):
        # Oracle is explicit ISA expansion: ±(16+fraction)/16 * 2**exponent.
        expected = {
            sign * (16 + fraction) / 16 * 2**exponent
            for sign in (-1, 1)
            for fraction in range(16)
            for exponent in range(-3, 5)
        }
        md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
        md.detail = True
        for base in (0x1E201000, 0x1E601000):
            blob = words(*(base | imm << 13 for imm in range(256)))
            actual = {ins.operands[1].fp for ins in md.disasm(blob, 0)}
            self.assertEqual(actual, expected)
            self.assertNotIn(struct.unpack("<f", words(RATIO))[0], actual)
            self.assertEqual(candidates(scan(blob, ro_base=0x4000)), [])

    def test_compressed_segments_same_candidates(self):
        blob = words(0x1C008000, MUL, RET)
        self.assertEqual(
            candidates(scan(blob, words(RATIO))),
            candidates(scan(blob, words(RATIO), compressed=True)),
        )

    def test_decoder_chunk_boundary_keeps_same_block_provenance(self):
        text = words(NOP) * 4095 + words(MOV, KEEP, FMOV, MUL, RET)
        row = candidates(scan(text))[0]
        self.assertEqual(row["source_addresses"], ["0x4ffc", "0x5000"])
        self.assertEqual(row["confidence"], "medium")

    def test_literal_pool_words_are_not_treated_as_live_code(self):
        # LDR Q0,+16 marks the next four words as data despite valid opcodes.
        self.assertEqual(
            candidates(scan(words(0x9C000080, RET, NOP, NOP, MOV, KEEP, FMOV, MUL))), []
        )

    def test_segment_hash_when_declared(self):
        raw = bytearray(nso(words(MOV, KEEP, FMOV, MUL, RET)))
        raw[0xC] |= 8
        raw[0xA0:0xC0] = hashlib.sha256(raw[0x100:]).digest()
        self.assertEqual(len(candidates(locator.analyze(bytes(raw)))), 1)
        raw[0x100] ^= 1
        with self.assertRaisesRegex(ValueError, "hash"):
            locator.analyze(bytes(raw))

    def test_reject_malformed_header_and_spans(self):
        original = nso(words(RET), words(RATIO))
        malformed = [b"", b"NSO0", b"ELF!" + original[4:], original[:-1]]
        for offset, value in (
            (4, 1),
            (0xC, 0x100),
            (0x10, 4),
            (0x14, 0x1001),
            (0x18, 3),
            (0x24, 0x1000),
            (0x60, 1),
            (0x28, 0xFFFFFFFF),
        ):
            raw = bytearray(original)
            struct.pack_into("<I", raw, offset, value)
            malformed.append(bytes(raw))
        for raw in malformed:
            with self.subTest(prefix=raw[:32].hex()):
                with self.assertRaises(ValueError):
                    locator.analyze(raw)

    def test_compression_errors_are_not_partial_success(self):
        raw = bytearray(nso(words(MOV, KEEP, FMOV, MUL, RET), compressed=True))
        raw[0x100:] = bytes(len(raw) - 0x100)
        with self.assertRaisesRegex(ValueError, "LZ4|length"):
            locator.analyze(bytes(raw))

    def test_decompression_budget_checked_before_allocating_declared_size(self):
        raw = bytearray(nso(words(RET), compressed=True))
        struct.pack_into("<I", raw, 0x18, 0xFFFFFFFC)
        with self.assertRaisesRegex(ValueError, "decompressed byte limit"):
            locator.analyze(bytes(raw), max_bytes=1024)

    def test_file_payload_overlap_is_rejected(self):
        raw = bytearray(nso(words(RET), words(RATIO)))
        struct.pack_into("<I", raw, 0x20, 0x100)
        with self.assertRaisesRegex(ValueError, "file segments overlap"):
            locator.analyze(bytes(raw))

    def test_sparse_high_address_does_not_allocate_holes(self):
        report = scan(words(MOV, KEEP, FMOV, MUL, RET), text_base=0xFFFF0000, ro_base=0)
        self.assertEqual(candidates(report)[0]["address"], "0xffff0000")

    def test_resource_limits_are_explicit_failures(self):
        raw = nso(words(MOV, KEEP, FMOV, MUL, RET))
        with self.assertRaisesRegex(ValueError, "limit"):
            locator.analyze(raw, max_bytes=16)
        with self.assertRaisesRegex(ValueError, "candidate"):
            locator.analyze(nso(words(RATIO, RATIO)), max_candidates=1)
        for window in (0, 65):
            with self.assertRaises(ValueError):
                locator.analyze(raw, window=window)

    def test_cli_json_tsv_readonly_deterministic_and_errors(self):
        with tempfile.TemporaryDirectory(prefix="aspect fixture ") as tmp:
            path = Path(tmp) / "main"
            raw = nso(words(MOV, KEEP, FMOV, MUL, RET))
            path.write_bytes(raw)

            def run(*args):
                return subprocess.run(
                    [sys.executable, str(TOOL), str(path), *args],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )

            first, second = run(), run()
            self.assertEqual((first.returncode, first.stderr), (0, ""))
            self.assertEqual(first.stdout, second.stdout)
            result = json.loads(first.stdout)
            self.assertEqual(result["input_sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(result["module_id"], bytes(range(32)).hex())
            self.assertEqual(len(candidates(result)), 1)
            tsv = run("--format", "tsv")
            self.assertEqual(tsv.returncode, 0)
            self.assertEqual(len(tsv.stdout.splitlines()), 2)
            self.assertIn("0x1000\tmovwide\t32\t3fe38e39\tmedium", tsv.stdout)
            self.assertEqual(path.read_bytes(), raw)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["main"])
            path.write_bytes(b"bad input")
            bad = run()
            self.assertEqual(bad.returncode, 2)
            self.assertEqual(bad.stdout, "")
            self.assertIn("NSO", bad.stderr)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_cli_rejects_fifo_without_waiting_for_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            fifo = Path(tmp) / "fifo"
            os.mkfifo(fifo)
            result = subprocess.run(
                [sys.executable, str(TOOL), str(fifo)], capture_output=True, text=True, timeout=5
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("regular file", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
