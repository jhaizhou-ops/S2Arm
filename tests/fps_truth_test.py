#!/usr/bin/env python3
"""T82：帧率真值判据的纯合成回归，不代表游戏或设备帧率实测。

期望独立手算：丢最前两条匹配行；余下仅 fifo < 50 且 fps > 0。
59、59.9、72 的中位是 59.9；29、30 的中位是 29.5；40、45、50
的中位是 45。中位 >= 58 判 60，闭区间 [28, 32] 判 30，其余不判。
所有 CLI 都显式将 S2A_FPS_TRUTH_TSV 指向临时目录，绝不写真实登记表。
"""

import csv
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "fps_truth.py"
SPEC = importlib.util.spec_from_file_location("fps_truth_under_test", TOOL)
TRUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRUTH)

# 不从被测 HEAD 生成期望，防止表头实现被改坏后测试跟着改口径。
HEADER = "程序号\t款\t目标帧率\t实测中位帧率\tGPU队列中位%\t样本数\t证据\t日期"
LOAD = "[fps] game 120 fifo 0 frametime 8.3\n" * 2


def log_lines(samples):
    return LOAD + "".join(
        f"[fps] game {fps} fifo {fifo} frametime 16.7\n" for fps, fifo in samples
    )


class JudgeTests(unittest.TestCase):
    def check_judge(self, log, expected):
        target, median, fifo, count, why = TRUTH.judge(log)
        self.assertEqual((target, median, fifo, count), expected)
        self.assertTrue(why)

    def test_01_median_59_9_is_60(self):
        self.check_judge(log_lines([(72, 30), (59, 10), (59.9, 20)]), (60, 59.9, 20, 3))

    def test_02_even_median_29_5_is_30(self):
        self.check_judge(log_lines([(30, 9), (29, 7)]), (30, 29.5, 8, 2))

    def test_03_median_45_is_unknown(self):
        self.check_judge(log_lines([(50, 30), (40, 10), (45, 20)]), (None, 45, 20, 3))

    def test_04_discards_exactly_two_loading_samples(self):
        # 只留一个 30：不丢/少丢会变成 120/75，多丢则没有样本。
        self.check_judge(log_lines([(30, 10)]), (30, 30, 10, 1))
        # 丢的是匹配的 fps 行，不是任意日志行。
        noisy = "启动\n" + LOAD.splitlines(keepends=True)[0] + "加载\n" + LOAD.splitlines(keepends=True)[1]
        self.check_judge(noisy + "[fps] game 30 fifo 10 frametime 33.3\n", (30, 30, 10, 1))

    def test_05_fifo_at_or_above_50_has_no_usable_sample(self):
        result = TRUTH.judge(log_lines([(60, 50), (30, 100)]))
        self.assertEqual(result[:4], (None, None, None, 0))
        self.assertIn("没有可用样本", result[4])

    def test_fifo_filter_applies_to_both_medians_and_count(self):
        # 合格两条 (30, 0)、(29, 49.5)：中位 29.5、24.75；队列 50 已不合格。
        self.check_judge(
            log_lines([(60, 50), (120, 99), (29, 49.5), (30, 0)]),
            (30, 29.5, 24.75, 2),
        )

    def test_zero_fps_is_excluded_from_both_medians_and_count(self):
        self.check_judge(log_lines([(0, 1), (0, 4), (30, 25)]), (30, 30, 25, 1))

    def test_06_closed_threshold_boundaries(self):
        for median, target in [(58, 60), (57.9, None), (32, 30), (32.1, None), (28, 30), (27.9, None)]:
            with self.subTest(median=median):
                self.check_judge(log_lines([(median, 12)]), (target, median, 12, 1))

    def test_empty_and_loading_only_have_no_usable_sample(self):
        for log in ["", "无帧率日志\n", LOAD]:
            with self.subTest(log=log):
                self.assertEqual(TRUTH.judge(log)[:4], (None, None, None, 0))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fps-truth-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.table = self.directory / "truth.tsv"
        self.log = self.directory / "stderr.txt"

    def run_cli(self, samples, *, game="合成样本", pid="00000000000000AB", write=False):
        self.log.write_text(log_lines(samples), encoding="utf-8")
        env = dict(os.environ, S2A_FPS_TRUTH_TSV=str(self.table), PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run(
            [sys.executable, str(TOOL), game, pid, str(self.log), *(["--write"] if write else [])],
            env=env, cwd=self.directory, text=True, encoding="utf-8", capture_output=True,
            timeout=10, check=False,
        )

    def read_rows(self):
        text = self.table.read_text(encoding="utf-8")
        self.assertEqual(text.splitlines()[0], HEADER)
        self.assertEqual(text.splitlines().count(HEADER), 1)
        return list(csv.DictReader(text.splitlines(), delimiter="\t"))

    def test_cli_decisions_and_no_implicit_write(self):
        for fps, code, target in [(59.9, 0, "60"), (29.5, 0, "30"), (45, 1, "None")]:
            with self.subTest(fps=fps):
                result = self.run_cli([(fps, 10)])
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout.split("\t")[:3], ["合成样本", "00000000000000ab", target])
                self.assertFalse(self.table.exists())
                self.assertFalse((self.directory / "fps_truth").exists())

    def test_03_unknown_write_does_not_create_or_modify_table_or_evidence(self):
        # 拒判既不新建，也不覆盖已有登记/证据；含 45、32.1 和全被过滤三类。
        before = HEADER + "\n0000000000000001\t保留\t30\t30.0\t10\t1\tfps_truth/保留.log\t01-01 00:00\n"
        evidence = self.directory / "fps_truth" / "合成样本.log"
        for existing in [False, True]:
            for samples in [[(45, 10)], [(32.1, 10)], [(60, 50)]]:
                with self.subTest(existing=existing, samples=samples):
                    if existing:
                        self.table.write_text(before, encoding="utf-8")
                        evidence.parent.mkdir(exist_ok=True)
                        evidence.write_text("保留的合成证据\n", encoding="utf-8")
                    result = self.run_cli(samples, write=True)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    if existing:
                        self.assertEqual(self.table.read_bytes(), before.encode("utf-8"))
                        self.assertEqual(evidence.read_text(encoding="utf-8"), "保留的合成证据\n")
                        self.assertEqual(list(evidence.parent.iterdir()), [evidence])
                    else:
                        self.assertFalse(self.table.exists())
                        self.assertFalse(evidence.parent.exists())

    def test_07_write_appends_updates_and_keeps_header_and_other_rows(self):
        # 新建表 + 追加不同程序号；再按大小写相同的程序号更新，不能重复插入。
        first = self.run_cli([(59, 10), (59.9, 20), (72, 30)], game="合成甲", write=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        rows = self.read_rows()
        self.assertEqual(len(rows), 1)
        original = rows[0]
        self.assertEqual(
            [original[h] for h in HEADER.split("\t")[:-1]],
            ["00000000000000ab", "合成甲", "60", "59.9", "20", "3", "fps_truth/合成甲.log"],
        )
        self.assertRegex(original["日期"], r"^\d{2}-\d{2} \d{2}:\d{2}$")
        evidence = self.directory / "fps_truth" / "合成甲.log"
        self.assertEqual(evidence.read_text(encoding="utf-8"), LOAD.replace(" 8.3", "") +
                         "[fps] game 59 fifo 10 frametime\n[fps] game 59.9 fifo 20 frametime\n[fps] game 72 fifo 30 frametime\n")

        appended = self.run_cli([(29, 7), (30, 9)], game="合成乙", pid="0000000000000001", write=True)
        self.assertEqual(appended.returncode, 0, appended.stderr)
        rows = self.read_rows()
        self.assertEqual([row["程序号"] for row in rows], ["0000000000000001", "00000000000000ab"])
        self.assertEqual(rows[1], original)
        other = rows[0]
        self.assertEqual([other[h] for h in ["目标帧率", "实测中位帧率", "GPU队列中位%", "样本数"]], ["30", "29.5", "8", "2"])

        updated = self.run_cli([(32, 12)], game="合成甲更新", pid="00000000000000ab", write=True)
        self.assertEqual(updated.returncode, 0, updated.stderr)
        rows = self.read_rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], other)
        self.assertEqual(
            [rows[1][h] for h in HEADER.split("\t")[:-1]],
            ["00000000000000ab", "合成甲更新", "30", "32.0", "12", "1", "fps_truth/合成甲更新.log"],
        )
        self.assertEqual((self.directory / "fps_truth" / "合成甲更新.log").read_text(encoding="utf-8"),
                         "[fps] game 120 fifo 0 frametime\n[fps] game 120 fifo 0 frametime\n[fps] game 32 fifo 12 frametime\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
