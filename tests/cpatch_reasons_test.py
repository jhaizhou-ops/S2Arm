#!/usr/bin/env python3
"""D2: 手写说明/分类期望；真实 plan 只用自造未压缩模块与补丁。"""

import csv
import hashlib
import importlib.util
import io
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cpatch_reasons", ROOT / "graphics/cpatch/reasons.py")
reasons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reasons)

# 不用实现生成 oracle；下面逐字依据 plan writer 的六个分支手写。
CASES = [
    (
        "写入 0x5000+4 超出模块映像",
        "outside_image",
        "这次筛选未收录：补丁要修改的位置超出了游戏程序模块的范围。",
    ),
    (
        "与 gfx:0000000000000001 改同一处 main+0x100",
        "patch_conflict",
        "这次筛选未收录：这份补丁与另一份补丁修改了同一位置。",
    ),
    (
        "数据写入 main+0x3800 落在代码段末页上（只读可执行，运行时写不了）",
        "readonly_code_page",
        "这次筛选未收录：补丁要修改的数据位于运行时不可写的代码页。",
    ),
    (
        "改到我方改写点 main+0x104（宽屏点 / x18 等，两套改动叠在同一条指令上）",
        "rewrite_conflict",
        "这次筛选未收录：补丁与 S2Arm 的代码改写位置重叠。",
    ),
    (
        "本款已有我方帧率表（fps.tsv），社区帧率类不收",
        "builtin_fps",
        "这次筛选未收录：游戏已有 S2Arm 帧率方案，不再收录社区帧率补丁。",
    ),
    (
        "main 已有 64 份补丁（槽 2046 位数用尽）",
        "module_limit",
        "这次筛选未收录：这个程序模块已达到 64 份补丁的上限。",
    ),
]
UNKNOWN = "此条拒收原因尚无对应说明，请查看原文。"


class ReasonsTest(unittest.TestCase):
    def test_six_exact_messages_and_raw(self):
        for raw, code, message in CASES:
            with self.subTest(code=code):
                self.assertEqual(
                    reasons.describe_reason(raw), dict(code=code, message_zh=message, raw=raw)
                )

    def test_variable_module_and_offsets(self):
        values = [
            ("写入 -0x1+12 超出模块映像", "outside_image"),
            ("与 fps:ABCDEF1234567890 改同一处 模块 ＋+0xabc", "patch_conflict"),
            ("与 gfx:bad 改同一处 main+0x100", "patch_conflict"),
            (" main 已有 64 份补丁（槽 2046 位数用尽）", "module_limit"),
            (
                "数据写入 sdk+0xface 落在代码段末页上（只读可执行，运行时写不了）",
                "readonly_code_page",
            ),
            (
                "改到我方改写点 模块 ＋+0x100（宽屏点 / x18 等，两套改动叠在同一条指令上）",
                "rewrite_conflict",
            ),
            ("模块 ＋ 已有 64 份补丁（槽 2046 位数用尽）", "module_limit"),
        ]
        for raw, code in values:
            with self.subTest(raw=raw):
                self.assertEqual(reasons.describe_reason(raw)["code"], code)
                self.assertEqual(reasons.describe_reason(raw)["raw"], raw)

    def test_no_substring_or_whitespace_normalization(self):
        for raw, code, _ in CASES:
            candidates = [raw + "后缀", raw + " ", raw + "\n", raw + "\x00"]
            # 模块名本身可含前缀/前导空格；不能把有效文件名当负例。
            if code != "module_limit":
                candidates += ["前缀" + raw, " " + raw]
            for candidate in candidates:
                with self.subTest(raw=candidate):
                    self.assertEqual(
                        reasons.describe_reason(candidate),
                        dict(code="unknown", message_zh=UNKNOWN, raw=candidate),
                    )

    def test_near_miss_unknown(self):
        values = [
            "main 已有 63 份补丁（槽 2046 位数用尽）",
            "main 已有 64 份补丁（槽 2047 位数用尽）",
            "写入 0xZZ+4 超出模块映像",
            "写入 0x10+-4 超出模块映像",
            "与 other:bad 改同一处 main+0x100",
            "数据写入 main+0x3800 落在代码段末页上",
            "补丁已收录",
            "",
            "改写器缺口：main+0x100 p 点补丁指令要翻译",
            "改写器缺口：main+0x100 AssertionError: 测试",
            "改写器缺口：main+0x100 AssertionError: " + CASES[5][0],
            "模块\t名字 已有 64 份补丁（槽 2046 位数用尽）",
        ]
        for raw in values:
            with self.subTest(raw=raw):
                self.assertEqual(
                    reasons.describe_reason(raw), dict(code="unknown", message_zh=UNKNOWN, raw=raw)
                )

    def test_non_strings_rejected(self):
        for value in [None, 1, b"reason", [], {}]:
            with self.subTest(value=value), self.assertRaises(TypeError):
                reasons.describe_reason(value)

    def test_returns_independent_results(self):
        raw = CASES[0][0]
        first = reasons.describe_reason(raw)
        first["code"] = "changed"
        self.assertEqual(reasons.describe_reason(raw)["code"], "outside_image")

    def test_c4_reason_field_does_not_change_rows_or_counts(self):
        # #522 的既有 UTF-8/CSV-quoted TSV 四列合同；本片不重解析 plan.log。
        content = (
            "game\tcategory\treason\tcount\n"
            "合成甲\tgfx\t写入 0x5000+4 超出模块映像\t3\n"
            '合成甲\tfps\t"未知原因：""原文"""\t2\n'
        )
        rows = list(csv.DictReader(io.StringIO(content), delimiter="\t"))
        before = [dict(row) for row in rows]
        descriptions = [reasons.describe_reason(row["reason"]) for row in rows]
        self.assertEqual(rows, before)
        self.assertEqual([r["count"] for r in rows], ["3", "2"])
        self.assertEqual([r["code"] for r in descriptions], ["outside_image", "unknown"])
        self.assertEqual(descriptions[1]["raw"], '未知原因："原文"')

    def test_pure_function_does_not_access_files_or_network(self):
        import socket

        with (
            patch("builtins.open", side_effect=AssertionError("file read")),
            patch("io.open", side_effect=AssertionError("file read")),
            patch("os.open", side_effect=AssertionError("file read")),
            patch("os.listdir", side_effect=AssertionError("scan")),
            patch("os.scandir", side_effect=AssertionError("scan")),
            patch.object(socket, "socket", side_effect=AssertionError("network")),
        ):
            for raw, code, _ in CASES:
                self.assertEqual(reasons.describe_reason(raw)["code"], code)
            self.assertEqual(reasons.describe_reason("新原因")["code"], "unknown")

    def test_real_plan_writer_all_six_families(self):
        for which, expected in enumerate(CASES):
            with self.subTest(code=expected[1]), tempfile.TemporaryDirectory() as temporary:
                root, index = fixture(Path(temporary))
                writes = [(0x100, "1F2003D5")]
                if which == 0:
                    writes = [(0x5000, "1F2003D5")]
                elif which == 1:
                    writes = [(0x100, "1F2003D5"), (0x100, "20008052")]   # 同处不同值；同内容两份按内容编号去重成一份，不算冲突
                elif which == 2:
                    writes = [(0x3800, "11223344")]
                elif which == 3:
                    writes = [(0x104, "1F2003D5")]
                    (root / "main.sites.tsv").write_text("0x104\tx18\n")
                elif which == 4:
                    (root / "fps.tsv").write_text("c\t合成\n")
                elif which == 5:
                    writes = [(0x200 + i * 4, "1F2003D5") for i in range(65)]
                ids = write_patches(index, writes, fps=(which == 4))
                result = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "pack/cpatch.py"),
                        "plan",
                        str(root),
                        "",
                        str(index),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                # 夹具只用普通段名；这是检查已知生产输出形状，不是新日志解析器。
                rejected = [
                    line.split("\t")
                    for line in (root / "cpatch_plan.log").read_text().splitlines()
                    if line.startswith("不收\t")
                ]
                self.assertEqual(len(rejected), 1)
                self.assertEqual(len(rejected[0]), 5)
                raw, code, message = expected
                raw = raw.replace("0000000000000001", ids[0])   # 编号 = 夹具文件内容 SHA-256 前 16 位（审计 #829）
                self.assertEqual(rejected[0][4], raw)
                self.assertEqual(
                    reasons.describe_reason(rejected[0][4]),
                    dict(code=code, message_zh=message, raw=raw),
                )

    def test_real_plan_does_not_assume_module_or_hash_whitelist(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, index = fixture(Path(temporary))
            (root / "exefs/main").rename(root / "exefs/ 模块 ＋ ")
            ids = write_patches(index, [(0x100, "1F2003D5"), (0x100, "20008052")])
            result = subprocess.run(
                [sys.executable, str(ROOT / "pack/cpatch.py"), "plan", str(root), "", str(index)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            row = (root / "cpatch_plan.log").read_text().splitlines()[-1].split("\t")
            raw = f"与 gfx:{ids[0]} 改同一处  模块 ＋ +0x100"
            self.assertEqual(row[4], raw)
            self.assertEqual(
                reasons.describe_reason(raw),
                dict(code="patch_conflict", message_zh=CASES[1][2], raw=raw),
            )

    def test_real_prune_writer_is_unknown_not_plan(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, index = fixture(Path(temporary))
            ids = write_patches(index, [(0x100, "1F2003D5")])
            subprocess.run(
                [sys.executable, str(ROOT / "pack/cpatch.py"), "plan", str(root), "", str(index)],
                capture_output=True,
                check=True,
                timeout=10,
            )
            (root / "main.gaps.tsv").write_text("0x100\tcpatch\tp 点补丁指令要翻译\n")
            result = subprocess.run(
                [sys.executable, str(ROOT / "pack/cpatch.py"), "prune", str(root)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 10, result.stderr)
            last = (root / "cpatch_plan.log").read_text().splitlines()[-1].split("\t")
            self.assertEqual(
                last, ["不收", f"gfx:{ids[0]}", "改写器缺口：main+0x100 p 点补丁指令要翻译"]
            )
            self.assertEqual(
                reasons.describe_reason(last[2]),
                dict(code="unknown", message_zh=UNKNOWN, raw=last[2]),
            )


def fixture(base):
    root, index = base / "root", base / "index"
    (root / "exefs").mkdir(parents=True)
    index.mkdir()
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    header[0x40:0x50] = bytes.fromhex("a1" * 16)
    text = bytearray(0x3000)
    struct.pack_into("<II", text, 0x100, 0x52800020, 0xAA1203E0)
    segments = [(0, text), (0x3000, bytes(0x1000)), (0x4000, bytes(0x1000))]
    for k, (offset, data) in enumerate(segments):
        struct.pack_into("<III", header, 0x10 + 0x10 * k, 0x100 + offset, offset, len(data))
        struct.pack_into("<I", header, 0x60 + 4 * k, len(data))
    (root / "exefs/main").write_bytes(bytes(header) + b"".join(bytes(data) for _, data in segments))
    npdm = bytearray(0x120)
    struct.pack_into("<I", npdm, 0x70, 0x100)
    struct.pack_into("<Q", npdm, 0x110, 0x0100000000001000)
    (root / "exefs/main.npdm").write_bytes(npdm)
    return root, index


def write_patches(index, writes, fps=False):
    """索引写每份补丁的真实内容 SHA-256（cpatch 核对内容，审计 #829）；返回各份编号（前 16 位）"""
    columns = ["title_id", "kind", "path", "sha256"] + (["target_fps"] if fps else [])
    ids = []
    with (index / "INDEX.tsv").open("w", newline="", encoding="utf-8") as source:
        writer = csv.writer(source, delimiter="\t", lineterminator="\n")
        writer.writerow(columns)
        for number, (offset, value) in enumerate(writes, 1):
            name = f"synthetic-{number}.pchtxt"
            (index / name).write_text(
                f"@nsobid-{'A1' * 16}\n@flag offset_shift 0x100\n@enabled\n{offset:08X} {value}\n@stop\n"
            )
            digest = hashlib.sha256((index / name).read_bytes()).hexdigest()
            ids.append(digest[:16])
            writer.writerow(["0100000000001000", "pchtxt", name, digest] + (["60"] if fps else []))
    return ids

if __name__ == "__main__":
    unittest.main()
