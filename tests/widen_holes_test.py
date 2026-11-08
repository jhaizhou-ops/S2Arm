#!/usr/bin/env python3
# 门禁覆盖：tests/visual/widen_holes.py
"""T81 深度量具：手造 f32/json，不使用真实游戏深度或设备。

12×4，中间宽8，两侧每行4像素。天空行不算；其余三行侧洞4、2、0，
所以侧带6/16=37.5%，全图6/48=12.5%，洞行2/4。
量具本身只输出比例、成功退出0；闭环 closed_loop.sh 按侧带 <=0.5% 才判过。
因此负控检查实际读数及闭环阈值，不伪称量具在露空时会退出1。
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tests" / "visual" / "widen_holes.py"


def ground_and_sky():
    depth = np.zeros((4, 12), dtype=np.float32)
    depth[0] = 1
    depth[1, :2] = depth[1, -2:] = 1
    depth[2, 0] = depth[2, -1] = 1
    return depth


class WidenHolesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="widen-holes-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)

    def run_tool(self, depth, *args, w0=8, missing=None, tool=TOOL):
        meta = {"w": depth.shape[1], "h": depth.shape[0], "w0": w0, "clear": 1.0, "format": "D32_SFLOAT"}
        if missing:
            del meta[missing]
        path = self.directory / "depth_1.json"
        path.write_text(json.dumps(meta), encoding="utf-8")
        depth.astype(np.float32).tofile(self.directory / "depth_1.f32")
        return subprocess.run([sys.executable, str(tool), str(path), *map(str, args)],
                              text=True, encoding="utf-8", capture_output=True, timeout=20,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), check=False)

    def side_percent(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        match = re.search(r"露空面积占两侧带 ([0-9.]+)%", result.stdout)
        self.assertIsNotNone(match, result.stdout)
        return float(match[1])

    def assert_ground_holes(self, result):
        self.assertEqual(self.side_percent(result), 37.5)
        self.assertIn("占全图 12.5%", result.stdout)
        self.assertIn("按行口径平均 37.5%，露空 >5% 的行 2/4", result.stdout)
        self.assertIn("中间区没画 25.0%、两侧没画 62.5%", result.stdout)
        self.assertGreater(self.side_percent(result), 0.5)  # 闭环不通过。

    def test_01_pixel_hole_area_matches_hand_count(self):
        self.assert_ground_holes(self.run_tool(ground_and_sky()))

    def test_02_full_clear_sky_does_not_count(self):
        result = self.run_tool(np.ones((4, 12), dtype=np.float32))
        self.assertEqual(self.side_percent(result), 0)
        self.assertIn("占全图 0.0%", result.stdout)
        self.assertIn("露空 >5% 的行 0/4", result.stdout)
        self.assertIn("中间区没画 100.0%、两侧没画 100.0%", result.stdout)

    def test_03_explicit_w0_overrides_guest_full_width(self):
        self.assert_ground_holes(self.run_tool(ground_and_sky(), "--w0", 8, w0=12))
        no_extension = self.run_tool(ground_and_sky(), w0=12)
        self.assertEqual(no_extension.returncode, 2, no_extension.stderr)
        self.assertEqual(no_extension.stdout.strip(), "不是加宽图（w == w0）")

    def test_04_missing_required_metadata_fails(self):
        for field in ["w", "h", "w0", "clear"]:
            with self.subTest(field=field):
                result = self.run_tool(ground_and_sky(), missing=field)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("KeyError", result.stderr)
                self.assertIn(repr(field), result.stderr)
                self.assertNotIn("露空面积", result.stdout)

    def test_ground_threshold_includes_exactly_95_percent(self):
        depth = np.zeros((2, 24), dtype=np.float32)
        depth[:, :2] = depth[:, -2:] = 1
        depth[0, 2] = 1       # 19/20有画=95%，侧带4洞应算。
        depth[1, 2:4] = 1     # 18/20有画=90%，侧带4洞不算。
        result = self.run_tool(depth, w0=20)
        self.assertEqual(self.side_percent(result), 50)
        self.assertIn("占全图 8.3%", result.stdout)
        self.assertIn("露空 >5% 的行 1/2", result.stdout)

    def test_negative_control_bad_ground_threshold_hides_holes(self):
        # 把地面门槛抬到不可能的110%，原来37.5%的洞变成0%，闭环误判过。
        source = TOOL.read_text(encoding="utf-8")
        self.assertEqual(source.count(">= 0.95"), 2, "量具阈值结构变化，重新审查负控")
        mutant = self.directory / "widen_mutant.py"
        mutant.write_text(source.replace(">= 0.95", ">= 1.1"), encoding="utf-8")
        self.assert_ground_holes(self.run_tool(ground_and_sky()))
        result = self.run_tool(ground_and_sky(), tool=mutant)
        self.assertEqual(self.side_percent(result), 0)
        self.assertLessEqual(self.side_percent(result), 0.5)  # 按现有闭环阈值误判过。
        with self.assertRaises(AssertionError):
            self.assert_ground_holes(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
