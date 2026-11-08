#!/usr/bin/env python3
"""T80：手写 host.log / T79 JSON，全部是假设夹具，不是输入设备或游戏实测。"""

import csv
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "input_caps_scan.py"
PID = "00000000000000AB"


def summary(styles="ProController", sixaxis=2, calls=5, nonzero=3):
    return f"[输入能力] styles={styles} sixaxis_start={sixaxis} vib_calls={calls} vib_nonzero={nonzero}\n"


class InputCapsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="input-caps-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)

    def run_dir(self, name, body, pid=PID):
        directory = self.directory / name
        directory.mkdir()
        identity = f"[s2a] 程序号 {pid}\n" if pid else ""
        (directory / "host.log").write_text(identity + body, encoding="utf-8")
        return directory

    def static_json(self, **updates):
        value = {"styles": False, "vibration": False, "sixaxis": False,
                 "evidence": {"styles": [], "vibration": [], "sixaxis": []},
                 "ok": True, "why": "仅声明引用；未命中不证明不支持"}
        value.update(updates)
        path = self.directory / "static.json"
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        return path, value

    def invoke(self, *args):
        result = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True,
                                text=True, encoding="utf-8", timeout=10, check=False,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        return result, list(csv.DictReader(io.StringIO(result.stdout), delimiter="\t"))

    def test_01_single_run_all_capabilities_and_last_summary(self):
        directory = self.run_dir("单局", summary("Handheld", 9, 9, 9) + summary())
        result, rows = self.invoke(directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0], {
            "程序号": PID, "局目录名": '单局', "styles": "ProController",
            "sixaxis_start": "2", "vib_calls": "5", "vib_nonzero": "3",
            "手柄样式": "声明了：ProController", "震动": "调用过且非零", "六轴": "启动过", "状态": "已解析",
        })

    def test_02_merge_styles_union_and_counts_max_not_sum(self):
        a = self.run_dir("甲", summary("ProController,JoyconPair", 2, 8, 1))
        b = self.run_dir("乙", summary("Handheld,ProController", 5, 3, 2), pid=PID.lower())
        result, rows = self.invoke(a, b)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["程序号"], PID)
        self.assertEqual(rows[0]["局目录名"], "甲; 乙")
        self.assertEqual(rows[0]["styles"], "ProController,Handheld,JoyconPair")
        self.assertEqual([rows[0][name] for name in ["sixaxis_start", "vib_calls", "vib_nonzero"]], ["5", "8", "2"])

    def test_03_missing_summary_stays_unknown_outside_merge(self):
        good = self.run_dir("有行", summary())
        missing = self.run_dir("缺行", "其他日志\n")
        result, rows = self.invoke(good, missing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 2)
        valid = next(row for row in rows if row["状态"] == "已解析")
        absent = next(row for row in rows if row["状态"] == "缺摘要行")
        self.assertEqual(valid["局目录名"], "有行")
        self.assertEqual(absent["局目录名"], "缺行")
        self.assertEqual([absent[name] for name in ["sixaxis_start", "vib_calls", "vib_nonzero"]], ["-", "-", "-"])
        self.assertEqual([absent[name] for name in ["手柄样式", "震动", "六轴"]], ["未测"] * 3)

    def test_directory_display_preserves_names_and_deduplicates_runs(self):
        a = self.run_dir(' 甲,;"局\t ', summary())
        b = self.run_dir('乙; ,"\n尾 ', summary())
        result, rows = self.invoke(a, b, a)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["局目录名"], ' 甲,;"局\t ; 乙; ,"\n尾 ')
        self.assertEqual(rows[0]["状态"], "已解析")
        self.assertEqual(rows[0]["vib_calls"], "5")
        self.assertEqual(len(rows[0]), 10)

    def test_unmeasured_directory_display_preserves_special_names(self):
        missing = self.run_dir(' 缺,;"\t摘要 ', "其他日志\n")
        bad = self.run_dir(' 坏; ,"\n摘要 ', "[输入能力] broken\n")
        result, rows = self.invoke(missing, bad)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([row["局目录名"] for row in rows],
                         [' 缺,;"\t摘要 ', ' 坏; ,"\n摘要 '])
        self.assertEqual([row["状态"] for row in rows], ["缺摘要行", "摘要行格式错"])
        self.assertTrue(all(row["styles"] == "未测" and len(row) == 10 for row in rows))

    def test_04_zero_amplitude_is_not_never_called(self):
        directory = self.run_dir("零幅", summary("ProController", 0, 4, 0))
        result, rows = self.invoke(directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["震动"], "只发零幅")
        self.assertEqual(rows[0]["六轴"], "没启动")

    def test_05_dash_styles_and_zero_counters(self):
        result, rows = self.invoke(self.run_dir("未调用", summary("-", 0, 0, 0)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["styles"], "-")
        self.assertEqual(rows[0]["手柄样式"], "未声明")
        self.assertEqual(rows[0]["震动"], "没调用")

    def test_06_malformed_last_summary_does_not_fall_back(self):
        bad_lines = [
            "[输入能力] styles=ProController sixaxis_start=2 vib_calls=5\n",
            "[输入能力] styles=ProController sixaxis_start=bad vib_calls=5 vib_nonzero=1\n",
            summary("UnknownStyle"), summary("-", 0, 1, 2),
        ]
        for index, line in enumerate(bad_lines):
            with self.subTest(index=index):
                directory = self.run_dir(f"坏{index}", summary() + line)
                result, rows = self.invoke(directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["状态"], "摘要行格式错")
                self.assertEqual(rows[0]["震动"], "未测")
                self.assertIn("摘要行格式错", result.stderr)

    def test_07_static_conflicts_preserve_both_sources(self):
        static, original = self.static_json()
        result, rows = self.invoke(self.run_dir("冲突", summary()), "--merge-static", static)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["状态"], "证据冲突：手柄样式、震动、六轴")
        self.assertEqual(rows[0]["震动"], "调用过且非零")
        self.assertEqual(rows[0]["sixaxis_start"], "2")
        self.assertEqual(json.loads(rows[0]["声明引用"]), original)

    def test_zero_amplitude_call_is_still_a_static_call_conflict(self):
        static, _ = self.static_json(styles=True, sixaxis=True)
        result, rows = self.invoke(self.run_dir("零幅冲突", summary("-", 0, 2, 0)), "--merge-static", static)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["状态"], "证据冲突：震动")
        self.assertEqual(rows[0]["震动"], "只发零幅")

    def test_static_unknown_or_missing_field_is_not_negative(self):
        directory = self.run_dir("未知静态", summary())
        for missing_field in [False, True]:
            with self.subTest(missing_field=missing_field):
                static, value = self.static_json(ok=False)
                if missing_field:
                    value["ok"] = True
                    del value["styles"]
                    static.write_text(json.dumps(value), encoding="utf-8")
                result, rows = self.invoke(directory, "--merge-static", static)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(rows[0]["状态"], "已解析；静态未知")
                self.assertEqual(json.loads(rows[0]["声明引用"]), value)

    def test_static_without_identity_rejects_multiple_programs(self):
        static, _ = self.static_json()
        a = self.run_dir("甲款", summary())
        b = self.run_dir("乙款", summary(), pid="0000000000000002")
        result, rows = self.invoke(a, b, "--merge-static", static)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(rows, [])
        self.assertIn("唯一程序号", result.stderr)

    def test_positive_static_and_no_runtime_call_are_not_conflicts(self):
        directory = self.run_dir("只声明", summary("-", 0, 0, 0))
        static, value = self.static_json(styles=True, vibration=True, sixaxis=True)
        before = ((directory / "host.log").read_bytes(), static.read_bytes())
        result, rows = self.invoke(directory, "--merge-static", static)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["状态"], "已解析")
        self.assertEqual(rows[0]["震动"], "没调用")
        self.assertEqual(json.loads(rows[0]["声明引用"]), value)
        self.assertEqual(((directory / "host.log").read_bytes(), static.read_bytes()), before)

    def test_bad_static_file_fails_without_partial_tsv(self):
        directory = self.run_dir("静态坏", summary())
        static = self.directory / "bad.json"
        for value in ["{", "[]"]:
            with self.subTest(value=value):
                static.write_text(value, encoding="utf-8")
                result, rows = self.invoke(directory, "--merge-static", static)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(rows, [])
                self.assertIn("静态 JSON", result.stderr)

    def test_malformed_run_does_not_hide_other_valid_run(self):
        good = self.run_dir("合法", summary())
        bad = self.run_dir("非法", summary("-", 0, 0, 1))
        result, rows = self.invoke(good, bad)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["状态"], "已解析")
        self.assertEqual(rows[0]["vib_nonzero"], "3")
        self.assertEqual(rows[1]["状态"], "摘要行格式错")
        self.assertEqual(rows[1]["vib_nonzero"], "-")

    def test_missing_or_ambiguous_program_and_missing_file_fail(self):
        no_pid = self.run_dir("缺程序号", summary(), pid=None)
        two_pid = self.run_dir("多程序号", "程序号 0000000000000002\n" + summary())
        missing_file = self.directory / "缺日志"
        missing_file.mkdir()
        for directory in [no_pid, two_pid, missing_file]:
            with self.subTest(directory=directory):
                result, rows = self.invoke(directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["震动"], "未测")


if __name__ == "__main__":
    unittest.main(verbosity=2)
