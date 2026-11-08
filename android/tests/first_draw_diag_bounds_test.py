#!/usr/bin/env python3
"""Fixture driver for first_draw_diag_bounds_test.c (#1229 / P0-9).

Compiles the production nvn_vk_draw_diag.c with the fixture under ASan and
runs it. The fixture embeds the pre-fix diagnostic reads verbatim as baseline
replicas — the child-process runs are expected to die on the stack overrun /
guard page, which is the issue's pre-fix evidence.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CC = shutil.which('cc') or shutil.which('clang')

INCLUDES = [HERE, HERE / 'vkhost', HERE / 'hostvk',
            HERE.parent / 'native', HERE.parent / 'native/direct',
            HERE.parent / 'native/nvn',
            REPO / 'graphics/nvn/gfx/nvn', REPO / 'graphics/nvn/gfx/nvn/include',
            REPO / 'graphics/nvn/third_party/vulkan-headers/include']


class FirstDrawDiagBoundsTest(unittest.TestCase):
    def test_bounds(self):
        if not CC:
            self.skipTest('native compiler unavailable')
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td) / 'first-draw-diag-bounds'
            cmd = [CC, '-std=gnu11', '-fsanitize=address', '-fno-omit-frame-pointer',
                   '-g', '-Wall', '-Wextra', '-Werror']
            for directory in INCLUDES:
                cmd += ['-I', str(directory)]
            cmd += [str(HERE / 'first_draw_diag_bounds_test.c'),
                    str(HERE.parent / 'native/nvn/nvn_vk_draw_diag.c'),
                    '-o', str(binary)]
            subprocess.run(cmd, check=True)
            # 两个平台统一成「崩溃即带信号退出」：夹具用 WIFSIGNALED 判修前基线如期崩溃。
            # Linux 的 ASan 缺省 abort_on_error=0，报告后以退出码 1 退出（WIFSIGNALED 为假，
            # 门禁会假红）；显式 abort_on_error=1 让它和 macOS 一样 SIGABRT。
            # detect_leaks=0：夹具故意不释放部分缓冲，Linux 的 LeakSanitizer 缺省开启，
            # 会在父进程正常退出时把退出码改成非 0。
            env = dict(os.environ)
            env['ASAN_OPTIONS'] = 'abort_on_error=1:detect_leaks=0'
            r = subprocess.run([str(binary)], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('buggy attr list crashed as expected', r.stdout)
            self.assertIn('buggy guest reads crashed as expected', r.stdout)
            self.assertIn('fixed diag survived', r.stdout)
            self.assertIn('bounded read kept legit data', r.stdout)


if __name__ == '__main__':
    unittest.main()
