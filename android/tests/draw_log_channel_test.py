#!/usr/bin/env python3
"""Fixture driver for the s2arm.draw_log startup channel (#1229).

C side (draw_log_channel_test.c): includes nvn_vk_first_draw.c as its own
translation unit and checks the override precedence of
s2a_fd_set_draw_log() over the debug.s2a.draw_log property.

The guest-memory bounds fixes live in nvn_vk_draw_diag.c and are covered by
first_draw_diag_bounds_test.py (landed separately); this driver only checks
the production switch channel and that the call site stays behind it.
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ANDROID = HERE.parent
CC = shutil.which('cc') or shutil.which('clang')

INCLUDES = [HERE, HERE / 'vkhost', HERE / 'hostvk',
            ANDROID / 'native', ANDROID / 'native/direct',
            ANDROID / 'native/nvn',
            REPO / 'graphics/nvn/gfx/nvn', REPO / 'graphics/nvn/gfx/nvn/include',
            REPO / 'graphics/nvn/third_party/vulkan-headers/include']


class DrawLogChannelTest(unittest.TestCase):
    def test_override_precedence(self):
        if not CC:
            self.skipTest('native compiler unavailable')
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td) / 'draw-log-channel'
            cmd = [CC, '-std=gnu11', '-ffunction-sections', '-fdata-sections']
            for directory in INCLUDES:
                cmd += ['-I', str(directory)]
            cmd += [str(HERE / 'draw_log_channel_test.c'),
                    '-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections',
                    '-o', str(binary)]
            subprocess.run(cmd, check=True)
            r = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('override precedence ok', r.stdout)

    def test_diag_call_site_is_behind_channel(self):
        # 诊断函数本身（边界实现）归 draw_diag；调用点必须由 fd_verbose() 把关，
        # 默认关时整段不执行。
        first_draw = (ANDROID / 'native/nvn/nvn_vk_first_draw.c').read_text()
        call = 'if (fd_verbose()) s2a_first_draw_diag('
        self.assertEqual(first_draw.count(call), 1)
        diag = (ANDROID / 'native/nvn/nvn_vk_draw_diag.c').read_text()
        signature = diag[diag.index('void s2a_first_draw_diag'):]
        signature = signature[:signature.index(')') + 1]
        self.assertNotIn('verbose', signature, '边界实现不应带开关参数，开关只在调用点')

    def test_java_channel_reaches_native_before_start(self):
        java = ANDROID / 'app/src/main/java/org/s2arm/android'
        activity = (java / 'MainActivity.java').read_text()
        parse = activity[activity.index('private static int drawLogFromIntent'):]
        parse = parse[:parse.index('\n    }')]
        self.assertIn('"s2arm.draw_log"', parse)
        self.assertIn('"1".equals(value)', parse)
        self.assertIn('"0".equals(value)', parse)
        self.assertIn('return -1;', parse)
        start = activity[activity.index('    private void tryStartGame() {'):]
        self.assertLess(start.index('NativeBridge.setDrawLog(drawLogFromIntent(getIntent()));'),
                        start.index('exportPreviousShaderCache()'))
        self.assertIn('static native void setDrawLog(int value);',
                      (java / 'NativeBridge.java').read_text())
        bridge = (ANDROID / 'native/bridge.cpp').read_text()
        self.assertIn('Java_org_s2arm_android_NativeBridge_setDrawLog', bridge)
        self.assertIn('s2a_fd_set_draw_log((int)draw_log);', bridge)


if __name__ == '__main__':
    unittest.main()
