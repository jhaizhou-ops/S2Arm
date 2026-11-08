#!/usr/bin/env python3
"""T87 纯手写 TSV：手算分子分母，不读取任何真实普查或游戏数据。"""

import csv
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "quicktest" / "rates.py"
HEADER = "源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n"


def row(source, pid, fail="-", frame="是", crash="否", verdict=None, entry=None, seconds=None):
    values = [source, source, pid, verdict or ("通过" if fail == "-" else "失败"), fail,
              "1", "2", seconds if seconds is not None else ("0" if frame == "-" else "3"), frame, "100" if frame == "是" else "-", "1", "直连", "否", crash, "-", entry if entry is not None else frame]
    return "\t".join(values) + "\n"


class RatesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="quicktest-rates-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)

    def table(self, name, rows, header=HEADER):
        path = self.directory / name
        path.write_text(header + "".join(rows), encoding="utf-8")
        return path

    def run_tool(self, *args):
        return subprocess.run([sys.executable, str(TOOL), *map(str, args)], text=True,
                              encoding="utf-8", capture_output=True, timeout=10,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), check=False)

    def test_hand_counted_rates_deduplicate_across_files(self):
        first = self.table("先.tsv", [
            row("旧甲", "00000000000000AB", "首帧", "否"),
            row("乙", "0000000000000002", "崩溃：abort", "是", "是"),
            row("丙", "0000000000000003", "首帧", "否"),
            row("解包坏", "-", "解包", "-", "-"),
            row("重跑无号", "-", "解包", "-", "-"),
            row("32位", "-", "不支持：32位", "-", "-"),
            # 参数错误不会由 one_game.sh 写表；此行模拟外部明确补记，不能猜。
            row("参数", "-", "参数问题", "-", "-", "参数问题"),
        ])
        last = self.table("后.tsv", [
            row("新甲", "00000000000000ab"),
            row("重跑无号", "-", "出包：改写", "-", "-"),
            row("丁", "0000000000000004"),
        ])
        before = (first.read_bytes(), last.read_bytes())
        result = self.run_tool(first, last)
        self.assertEqual(result.returncode, 0, result.stderr)
        # 去重后八款：参数排除；32位只排除解包。解包5/6，进局3/7；四局甲丙丁不崩3/4。
        self.assertEqual(result.stdout.splitlines()[:3], [
            "解包成功率\t5/6\t83.33%", "进局率\t3/7\t42.86%", "0 崩率\t3/4\t75.00%",
        ])
        self.assertIn("32位\t-\t32位\t不支持：32位", result.stdout)
        self.assertIn("参数\t-\t参数\t参数问题", result.stdout)
        self.assertEqual((first.read_bytes(), last.read_bytes()), before)

    def test_last_physical_row_wins_in_both_directions(self):
        good = row("同源", "0000000000000001")
        bad = row("同源", "0000000000000001", "解包", "-", "-")
        for rows, expected in [([bad, good], "解包成功率\t1/1\t100.00%"),
                               ([good, bad], "解包成功率\t0/1\t0.00%")]:
            with self.subTest(rows=rows):
                result = self.run_tool(self.table("重跑.tsv", rows))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[0], expected)

    def test_exclusion_uses_last_row_and_explicit_parameter_marker(self):
        rows = [
            row("重试", "0000000000000001", "不支持：32位", "-", "-"),
            row("重试", "0000000000000001"),
            row("反转", "0000000000000002"),
            row("反转", "0000000000000002", "不支持：32位", "-", "-"),
            row("参数结论", "-", verdict="参数问题"),
            row("参数失败点", "-", "参数问题", "-", "-"),
        ]
        result = self.run_tool(self.table("排除.tsv", rows))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3], [
            "解包成功率\t1/1\t100.00%", "进局率\t1/2\t50.00%", "0 崩率\t1/1\t100.00%",
        ])
        self.assertNotIn("重试\t0000000000000001", result.stdout)
        self.assertIn("反转\t0000000000000002\t反转\t不支持：32位", result.stdout)
        self.assertIn("参数结论\t-\t参数结论\t参数问题", result.stdout)
        self.assertIn("参数失败点\t-\t参数失败点\t参数问题", result.stdout)

    def test_missing_program_uses_source_not_game_name(self):
        rows = [row("源甲", "-"), row("源乙", "-", "解包", "-", "-")]
        rows = [value.replace("源甲\t源甲", "源甲\t同款名").replace("源乙\t源乙", "源乙\t同款名") for value in rows]
        result = self.run_tool(self.table("无号.tsv", rows))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3], [
            "解包成功率\t1/2\t50.00%", "进局率\t1/2\t50.00%", "0 崩率\t1/1\t100.00%",
        ])

    def test_unpack_subtype_and_nonzero_run_are_not_success(self):
        result = self.run_tool(self.table("细分.tsv", [
            row("校验", "-", "解包：源文件校验不过（先换一份完整原件再判）", "-", "-"),
            row("被杀", "0000000000000001", "崩溃：局异常退出", "是", "局rc=143"),
            row("非零", "0000000000000002", "崩溃：局异常退出", "是", "rc=3"),
            row("首帧前", "0000000000000003", "首帧", "否", "否"),
        ]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3], [
            "解包成功率\t3/4\t75.00%", "进局率\t2/4\t50.00%", "0 崩率\t1/3\t33.33%",
        ])

    def test_failure_counts_are_descending_and_exclude_non_defects(self):
        result = self.run_tool("--by", "失败点", self.table("失败点.tsv", [
            row("无图甲", "0000000000000001", "首帧", "否"),
            row("无图乙", "0000000000000002", "首帧", "否"),
            row("解包", "-", "解包", "-", "-"),
            row("正常", "0000000000000003"),
            row("不支持", "-", "不支持：32位", "-", "-"),
        ]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("失败点\t款数\n", 1)[1].splitlines(), ["首帧\t2", "解包\t1"])

    def test_empty_and_all_excluded_have_no_measured_rate(self):
        for rows in [[], [row("未判", "-", "局没起", "-", "-", "未判")]]:
            with self.subTest(rows=rows):
                result = self.run_tool(self.table("空.tsv", rows))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[:3], [
                    "解包成功率\t0/0\tN/A（无样本）", "进局率\t0/0\tN/A（无样本）", "0 崩率\t0/0\tN/A（无样本）",
                ])

    def test_current_census_contract_and_cli_equality(self):
        # Ten synthetic identities. source-bad/undetermined excluded entirely;
        # 32-bit remains entry denominator; entry-undetermined only leaves entry.
        rows = [
            row("yes", "-", entry="是"),
            row("no", "-", frame="否", entry="否"),
            row("maybe", "-", crash="是", entry="疑似"),
            row("vision", "-", entry="未判"),
            row("static", "-", frame="-", entry="-", seconds="0"),
            row("32", "-", "不支持：32位", "-", "-", entry="否"),
            row("unpack", "-", "解包", "-", "-", entry="-"),
            row("infra", "-", "局没起", "-", "-", "未判", entry="未判"),
            row("bad", "-", "解包", "-", "-", "源文件坏", entry="-"),
            row("shutdown", "-", crash="收局", entry="否"),
        ]
        table = self.table("contract.tsv", rows)
        result = self.run_tool(table, "--by", "失败点")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3], [
            "解包成功率\t6/7\t85.71%", "进局率\t1/7\t14.29%", "0 崩率\t4/5\t80.00%",
        ])
        self.assertIn("未判条数\t1", result.stdout)
        self.assertNotIn("局没起", result.stdout.split("失败点\t款数\n")[1])
        # Same deduplicated physical rows, independently fed to real census CLI.
        with table.open() as stream:
            records = list(csv.DictReader(stream, delimiter="\t"))
        for record in records:
            record["名称"] = record["款"]
        with (self.directory / "总表.tsv").open("w") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(records[0]), delimiter="\t")
            writer.writeheader()
            writer.writerows(records)
        census = subprocess.run([sys.executable, str(ROOT / "tools/census/census.py"),
                                 "sum", str(self.directory)], capture_output=True, text=True, timeout=10)
        self.assertEqual(census.returncode, 0, census.stderr)
        self.assertEqual(re.findall(r"[0-9]+/[0-9]+", census.stdout.splitlines()[0]), ["6/7", "1/7", "4/5"])
        self.assertEqual(re.findall(r"[0-9]+/[0-9]+", census.stdout.splitlines()[0]),
                         re.findall(r"[0-9]+/[0-9]+", "\n".join(result.stdout.splitlines()[:3])))

    def test_old_header_with_new_rows_has_actionable_error(self):
        old = HEADER.replace("\t进局", "")
        result = self.run_tool(self.table("旧表.tsv", [row("new", "-")], header=old))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("旧表没有进局列，算不了进局率", result.stderr)
        self.assertIn("重新", result.stderr)

    def test_bad_input_fails_without_partial_rates(self):
        for contents in ["", "源\t款\n甲\t乙\n", HEADER + "短行\n", HEADER + row("甲", "invalid")]:
            with self.subTest(contents=contents):
                path = self.directory / "坏.tsv"
                path.write_text(contents, encoding="utf-8")
                result = self.run_tool(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("坏.tsv", result.stderr)
        missing = self.run_tool(self.directory / "不存在.tsv")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(missing.stdout, "")

    def test_named_columns_accept_bom_and_reordering(self):
        header = HEADER.rstrip("\n").split("\t")
        cells = row("甲", "0000000000000001").rstrip("\n").split("\t")
        path = self.table("列顺序.tsv", ["\t".join(reversed(cells)) + "\n"],
                          header="\ufeff" + "\t".join(reversed(header)) + "\n")
        result = self.run_tool(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "解包成功率\t1/1\t100.00%")


if __name__ == "__main__":
    unittest.main(verbosity=2)
