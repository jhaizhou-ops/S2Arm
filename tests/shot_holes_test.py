#!/usr/bin/env python3
# 门禁覆盖：tests/visual/shot_holes.py
"""T81 截图量具回归：只造 PNG；期望按 8×8 块手算，不读游戏截图。

144×384：中间 256 像素（16:9），两边各 64；18 行、两侧合计 16 列块。
前 8 行两侧清屏色：128 / 288 = 44.444…%，中间纹理不平，须退出 1。
平块小于 16 连片要去掉；整行天空在中间与两侧抵消；16:9 图按现约定退出 2。
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tests" / "visual" / "shot_holes.py"


def texture(width=384):
    y, x = np.indices((144, width))
    pixels = (32 + 128 * ((x + y) % 2)).astype(np.uint8)
    return np.repeat(pixels[:, :, None], 3, axis=2)


def holes():
    pixels = texture()
    pixels[:64, :64] = 0
    pixels[:64, -64:] = 0
    return pixels


class ShotHolesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="shot-holes-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)

    def run_tool(self, pixels, *args, tool=TOOL):
        image = self.directory / "synthetic.png"
        Image.fromarray(pixels).save(image)
        return subprocess.run([sys.executable, str(tool), str(image), *map(str, args)],
                              text=True, encoding="utf-8", capture_output=True, timeout=20,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), check=False)

    def assert_holes_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("两侧露空占两侧带 44.44%", result.stdout)
        self.assertIn("两侧平块 44.4%、中间平块 0.0%", result.stdout)
        self.assertIn("有超出的块行 8/18", result.stdout)

    def test_01_large_connected_clear_bands_match_hand_area(self):
        self.assert_holes_rejected(self.run_tool(holes()))

    def test_02_scattered_flat_blocks_are_not_holes(self):
        pixels = texture()
        # 每块与其他平块之间隔一块纹理，最大四邻接同色连片=1，严格小于16。
        for y in range(0, 18, 2):
            for x in [0, 2, 4, 6, 40, 42, 44, 46]:
                pixels[y * 8:(y + 1) * 8, x * 8:(x + 1) * 8] = 0
        result = self.run_tool(pixels)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("两侧露空占两侧带 0.00%", result.stdout)
        self.assertIn("两侧平块 0.0%、中间平块 0.0%", result.stdout)

    def test_03_sky_in_center_and_sides_cancels(self):
        pixels = texture()
        pixels[:64] = 0
        result = self.run_tool(pixels)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("两侧露空占两侧带 0.00%", result.stdout)
        self.assertIn("两侧平块 44.4%、中间平块 44.4%", result.stdout)
        self.assertIn("有超出的块行 0/18", result.stdout)

    def test_04_no_extension_is_exit_two_not_measured_zero(self):
        result = self.run_tool(texture(256))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout.strip(), "不是加宽图（宽 256，中间区 256）")

    def test_connected_component_boundary_15_vs_16_blocks(self):
        for count, code, percent in [(15, 0, "0.00%"), (16, 1, "5.56%")]:
            with self.subTest(count=count):
                pixels = texture()
                # 左侧第一列 count 行连成一片：16 / (18×16) = 5.555…%。
                pixels[:count * 8, :8] = 0
                result = self.run_tool(pixels)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn("两侧露空占两侧带 " + percent, result.stdout)

    def test_negative_control_relaxed_limit_turns_reject_to_accept(self):
        # 仅改临时副本 LIMIT；同一判不过断言必须对变异结果报红。
        source = TOOL.read_text(encoding="utf-8")
        old = "B, FLAT, MINC, LIMIT = 8, 2, 16, 0.5"
        self.assertEqual(source.count(old), 1, "量具阈值结构变化，重新审查负控")
        mutant = self.directory / "shot_mutant.py"
        mutant.write_text(source.replace(old, "B, FLAT, MINC, LIMIT = 8, 2, 16, 100.0"), encoding="utf-8")
        self.assert_holes_rejected(self.run_tool(holes()))
        result = self.run_tool(holes(), tool=mutant)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("两侧露空占两侧带 44.44%", result.stdout)
        with self.assertRaises(AssertionError):
            self.assert_holes_rejected(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
