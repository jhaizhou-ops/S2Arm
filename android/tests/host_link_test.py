#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""host_link 自身的四种结局（合成种子 + 真实生产提供方 direct/json.c；约 2 秒）：
① 种子强引用生产符号、清单里没有提供方 → 自动补链 direct/json.c，链过、运行 rc=0（清单落后不再红）
② 只有弱引用、全仓无定义 → 链过（macOS 自动 -U），运行时为空指针 rc=0
③ 强引用全仓无定义 → 链接红，报错点名该符号（不猜、不静默）
④ 测试自带同名强替身 → 不补链，替身生效
"""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import host_link  # noqa: E402

PROBE = 's2a_host_link_absent_probe'


class HostLinkTest(unittest.TestCase):
    def build(self, td, name, code):
        src = Path(td) / (name + '.c')
        src.write_text(code)
        exe = Path(td) / name
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            r = host_link.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Werror',
                               '-I' + str(host_link.ROOT / 'android/native/direct'), str(src), '-o', str(exe)],
                              capture_output=True, text=True)
        return r, err.getvalue(), exe

    def test_outcomes(self):
        with tempfile.TemporaryDirectory(prefix='host-link-test-') as td:
            r, log, exe = self.build(td, 'strong', 'extern void s2a_json_get(void);\nint main(void) { void (*volatile f)(void) = s2a_json_get; return f == 0; }\n')
            print('①', r.returncode, log.strip())
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('自动补链 android/native/direct/json.c（提供 s2a_json_get）', log)
            self.assertEqual(subprocess.run([str(exe)]).returncode, 0)

            r, log, exe = self.build(td, 'weak', f'extern void {PROBE}(void) __attribute__((weak));\nint main(void) {{ return {PROBE} != 0; }}\n')
            print('②', r.returncode, log.strip())
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(subprocess.run([str(exe)]).returncode, 0)

            r, log, _ = self.build(td, 'missing', f'extern void {PROBE}(void);\nint main(void) {{ {PROBE}(); return 0; }}\n')
            print('③', r.returncode, log.strip())
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(f'【红】host_link：符号 {PROBE} 闭合不了链接', log)

            r, log, exe = self.build(td, 'stub', 'void s2a_json_get(void) {}\nint main(void) { s2a_json_get(); return 0; }\n')
            print('④', r.returncode, log.strip())
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn('自动补链', log)


if __name__ == '__main__':
    unittest.main()
