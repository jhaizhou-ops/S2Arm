#!/usr/bin/env python3
"""Synthetic logs only. Expected counts are handwritten, not computed by the tool.

CPATCH_REJECTIONS_TOOL can select an isolated negative-control copy. Production
plan/prune are also executed on tiny, hand-built uncompressed NSO/NPDM fixtures;
no game files, external dependencies, network or production roots are used.
"""

import csv
import hashlib
import io
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("CPATCH_REJECTIONS_TOOL", ROOT / "tools/cpatch_rejections.py"))
A = "a" * 16
B = "b" * 16
HEADER = b"game\tcategory\treason\tcount\n"


class RejectionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def log(self, name, text):
        path = self.root / name
        path.write_bytes(text.encode("utf-8") if isinstance(text, str) else text)
        return path

    def run_tool(self, *args, env=None):
        return subprocess.run(
            [sys.executable, str(TOOL), *map(str, args)],
            capture_output=True,
            env=env,
            timeout=15,
        )

    def assert_ok(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout, expected)

    def assert_bad(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(message, result.stderr.decode("utf-8"))
        self.assertNotIn(b"Traceback", result.stderr)

    def test_hand_count_grouping_order_and_readonly(self):
        # Game A: fps/reason x twice in first log + once in second = 3;
        # graphics/prune = 1, widescreen/reason x = 1. Game B stays separate (= 1).
        p = self.log(
            "first.log",
            (
                f"不收\tfps:{A}\tmain\t任意名称\t原因 x\n"
                f"收\tfps:{B}\tmain\t不收\t正常\n"
                "跳过 7 段：IPS 格式不对\n社区补丁 9 份匹配，进包 4 份\n\n"
                f"不收\tfps:{A}\tmain\t任意名称\t原因 x\n"
                f"不收\tgfx:{B}\t改写器缺口：main+0x10 合成缺口\n"
                f"不收\twidescreen:{A}\tmain\t\t原因 x\n"
            ),
        )
        q = self.log("second.log", f"不收\tfps:{B}\tsdk\t另一个补丁\t原因 x\n")
        r = self.log("third.log", f"不收\tfps:{A}\tmain\t\t原因 x\n")
        neighbor = self.log("unrequested.log", b"\xff\xfe")
        before = {f: (f.read_bytes(), f.stat().st_mtime_ns) for f in (p, q, r, neighbor)}
        expected = (
            HEADER
            + (
                "A\tfps\t原因 x\t3\n"
                "A\tgfx\t改写器缺口：main+0x10 合成缺口\t1\n"
                "A\twidescreen\t原因 x\t1\n"
                "B\tfps\t原因 x\t1\n"
            ).encode()
        )
        self.assert_ok(self.run_tool("--log", "B", r, "--log", "A", q, "--log", "A", p), expected)
        self.assert_ok(self.run_tool("--log", "A", p, "--log", "A", q, "--log", "B", r), expected)
        self.assertEqual({f: (f.read_bytes(), f.stat().st_mtime_ns) for f in before}, before)
        self.assertEqual(set(self.root.iterdir()), set(before))

    def test_empty_and_irrelevant(self):
        for text in ("", "\n", '收\tanything\n跳过 2 段\n诊断含「不收」但非事件\n"不收"\tx\n'):
            with self.subTest(text=text):
                self.assert_ok(
                    self.run_tool("--log", "空游戏", self.log("empty.log", text)), HEADER
                )

    def test_quotes_are_literal_and_output_uses_tsv_quoting(self):
        p = self.log("quoted.log", f'不收\tgfx:{A}\tmain\t名称 "乙"\t原因 "甲"\r\n')
        game = '游戏\t"甲"\n第二行'
        expected = HEADER + '"游戏\t""甲""\n第二行"\tgfx\t"原因 ""甲"""\t1\n'.encode()
        result = self.run_tool("--log", game, p)
        self.assert_ok(result, expected)
        self.assertEqual(
            list(csv.reader(io.StringIO(result.stdout.decode()), delimiter="\t")),
            [["game", "category", "reason", "count"], [game, "gfx", '原因 "甲"', "1"]],
        )

    def test_exact_reasons_not_normalized_and_final_line_without_newline(self):
        p = self.log(
            "reasons.log",
            (
                f"不收\tgfx:{A}\tmain\t\t改到 main+0x10\n"
                f"不收\tgfx:{A}\tmain\t\t改到 main+0x20\n"
                f"不收\tgfx:{B}\tmain\t\t改到 main+0x10 "
            ),
        )
        self.assert_ok(
            self.run_tool("--log", "A", p),
            HEADER
            + (
                "A\tgfx\t改到 main+0x10\t1\nA\tgfx\t改到 main+0x10 \t1\nA\tgfx\t改到 main+0x20\t1\n"
            ).encode(),
        )

    def test_malformed_target_lines_fail_without_partial_output(self):
        malformed = [
            "不收",
            "不收 bad",
            "不收\t",
            f"不收\tfps:{A}\t原因缺少模块与段名",
            f"不收\tgfx:{A}\tmain\t原因",
            f"不收\tgfx:{A}\tmain\t段名\t",
            f"不收\tgfx:{A}\t\t段名\t原因",
            f"不收\tunknown:{A}\tmain\t段名\t原因",
            "不收\tfps:\tmain\t段名\t原因",
            f"不收\tfps:{'a' * 17}\tmain\t段名\t原因",
            "不收\tfps:a\tb\tmain\t段名\t原因",
            "不收\tfps:a\rb\tmain\t段名\t原因",
            "不收\tfps:a\nb\tmain\t段名\t原因",
            "不收\tfps:a\x00b\tmain\t段名\t原因",
            f"不收\tfps:{A}\t改写器缺口：",
            f"不收\tgfx:{A}\tmain\t段名\t原因\x00",
            f"不收\tfps:{A}\t改写器缺口：\t额外列",
            f"不收\tfps:{A}\t改写器缺口：main\tname\treason",
        ]
        valid = f"不收\tfps:{A}\tmain\t\t原因\n"
        for text in malformed:
            with self.subTest(text=text):
                p = self.log("broken.log", valid + text + "\n")
                self.assert_bad(self.run_tool("--log", "A", p), ":2:")

    def test_bad_utf8_and_missing_input_are_not_zero_counts(self):
        p = self.log("valid.log", f"不收\tgfx:{A}\tmain\t\t原因\n")
        bad = self.log("bad.log", b"\xff")
        for q in (bad, self.root / "missing.log", self.root):
            with self.subTest(q=q):
                self.assert_bad(self.run_tool("--log", "A", p, "--log", "B", q), str(q))

    def test_repeated_input_file_rejected_including_alias(self):
        p = self.log("input.log", f"不收\tgfx:{A}\tmain\t\t原因\n")
        alias = self.root / "alias.log"
        alias.symlink_to(p)
        hardlink = self.root / "hardlink.log"
        hardlink.hardlink_to(p)
        for q in (p, alias, hardlink):
            with self.subTest(q=q):
                self.assert_bad(self.run_tool("--log", "A", p, "--log", "B", q), "重复输入")

    def test_fifo_rejected_without_waiting_for_writer(self):
        fifo = self.root / "pipe"
        os.mkfifo(fifo)
        self.assert_bad(self.run_tool("--log", "A", fifo), "普通文件")

    def test_cli_requires_explicit_nonblank_game_and_path(self):
        p = self.log("empty.log", "")
        for args in ((), ("--log", "A"), ("--log", "", p), ("--log", " \t", p)):
            with self.subTest(args=args):
                result = self.run_tool(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
        self.assertEqual(self.run_tool("--help").returncode, 0)

    def test_bom_crlf_and_uppercase_digest(self):
        p = self.log("bom.log", f"\ufeff不收\tgfx:{A.upper()}\tmain\t\t原因\r\n")
        self.assert_ok(self.run_tool("--log", "A", p), HEADER + "A\tgfx\t原因\t1\n".encode())

    def test_stdout_is_utf8_even_with_ascii_stdio_environment(self):
        p = self.log("unicode.log", f"不收\tgfx:{A}\tmain\t\t中文原因\n")
        env = dict(os.environ, PYTHONIOENCODING="ascii", LC_ALL="C")
        self.assert_ok(
            self.run_tool("--log", "合成游戏", p, env=env),
            HEADER + "合成游戏\tgfx\t中文原因\t1\n".encode(),
        )

    def production_log(self, module="main", section="合成段名", prune=True, ids=None):
        """ids=None：索引写两份补丁的真实内容 SHA-256（cpatch 核对内容，审计 #829 F-cpatch-index-trust），self.ids 记下编号前 16 位；
        给了 ids 就原样写进索引（与内容不符），用来测整份不收。"""
        # Fully hand-built, uncompressed module: three 16-byte segments. The
        # first patch claims code byte 0; the second conflicts. prune then
        # rejects the first via its real emitted ownership row. No mocks.
        exefs = self.root / "exefs"
        exefs.mkdir()
        header = bytearray(0x100)
        header[:4] = b"NSO0"
        bid = "AABBCCDDEEFF11223344556677889911"
        header[0x40:0x50] = bytes.fromhex(bid)
        for k in range(3):
            struct.pack_into("<III", header, 0x10 + 0x10 * k, 0x100 + 16 * k, 16 * k, 16)
            struct.pack_into("<I", header, 0x60 + 4 * k, 16)
        (exefs / module).write_bytes(header + bytes(48))
        npdm = bytearray(0x200)
        struct.pack_into("<I", npdm, 0x70, 0x100)
        struct.pack_into("<Q", npdm, 0x110, 0x0100000000000000)
        (exefs / "main.npdm").write_bytes(npdm)
        index = self.root / "synthetic-index"
        index.mkdir()
        for name, word in (("a", "1F2003D5"), ("b", "20008052")):
            (index / f"{name}.pchtxt").write_text(
                f"@nsobid-{bid}\n@flag offset_shift 0x100\n// {section}\n"
                f"@enabled\n00000000 {word}\n@stop\n",
                encoding="utf-8",
            )
        real = [hashlib.sha256((index / f"{n}.pchtxt").read_bytes()).hexdigest() for n in ("a", "b")]
        written = ids or real
        self.ids = (real[0][:16], real[1][:16])
        (index / "INDEX.tsv").write_text(
            "title_id\tkind\tpath\tsha256\n"
            f"0100000000000000\tpchtxt\ta.pchtxt\t{written[0]}\n"
            f"0100000000000000\tpchtxt\tb.pchtxt\t{written[1]}\n",
            encoding="utf-8",
        )
        producer = [sys.executable, str(ROOT / "pack/cpatch.py")]
        plan = subprocess.run(
            [*producer, "plan", str(self.root), "", str(index)], capture_output=True, timeout=15
        )
        self.assertEqual(plan.returncode, 0, plan.stderr)
        self.plan_stderr = plan.stderr.decode("utf-8", "replace")
        if ids:
            return self.root / "cpatch_plan.log"
        if prune:
            (self.root / f"{module}.gaps.tsv").write_text(
                "0x0\tcpatch\t合成缺口\n", encoding="utf-8"
            )
            result = subprocess.run(
                [*producer, "prune", str(self.root)], capture_output=True, timeout=15
            )
            self.assertEqual(result.returncode, 10, result.stderr)
        log = self.root / "cpatch_plan.log"
        self.assertIn(
            f"不收\tgfx:{self.ids[1]}\t{module}\t{section}\t与 gfx:{self.ids[0]}".encode(),
            log.read_bytes(),
        )
        return log

    def test_actual_plan_and_prune_writers(self):
        log = self.production_log()
        self.assert_ok(
            self.run_tool("--log", "synthetic", log),
            HEADER
            + (
                f"synthetic\tgfx\t与 gfx:{self.ids[0]} 改同一处 main+0x0\t1\n"
                "synthetic\tgfx\t改写器缺口：main+0x0 合成缺口\t1\n"
            ).encode(),
        )

    def test_index_hash_not_matching_content_is_dropped(self):
        # 审计 #829 F-cpatch-index-trust：索引列不是这份文件内容的 SHA-256（短、非十六进制、自造编号、错哈希）→ 整份不收，
        # 不再当编号流进不收 / 冲突事件；plan 的 stderr 记「索引哈希与内容不符」
        for number, ids in enumerate((("x", "y"), ("abc", "not-a-digest"), ("Z" * 16, "社区:自造编号"), ("0" * 64, "1" * 64))):
            with self.subTest(ids=ids):
                parent, self.root = self.root, self.root / str(number)
                self.root.mkdir()
                try:
                    log = self.production_log(ids=ids)
                    self.assertNotIn(b"\xe4\xb8\x8d\xe6\x94\xb6\tgfx:", log.read_bytes() if log.exists() else b"")
                    self.assertIn("跳过 2 段：索引哈希与内容不符", self.plan_stderr)
                finally:
                    self.root = parent

    def test_actual_writer_tab_in_name_is_rejected_as_ambiguous(self):
        log = self.production_log(section="合成\t段名")
        self.assert_bad(self.run_tool("--log", "synthetic", log), "未转义")

    def test_actual_writer_tab_in_module_is_rejected_as_ambiguous(self):
        log = self.production_log(module="ma\tin", prune=False)
        self.assert_bad(self.run_tool("--log", "synthetic", log), "未转义")


if __name__ == "__main__":
    unittest.main()
